//! Per-probe and interval output rendering for the CLI: the result callback
//! (onOutcome), reply/timeout lines, -D timestamps, -Q interval splits, JSON
//! and netdata renderers. All formats and spacing mirror fping's output.c.

const std = @import("std");
const Io = std.Io;
const fping = @import("zig_fping");
const options_mod = @import("options.zig");
const context = @import("context.zig");
const signals = @import("signals.zig");

const Ctx = context.Ctx;
const TargetState = context.TargetState;
const fmtMs = context.fmtMs;
const realNowNs = context.realNowNs;
const printPaddedName = context.printPaddedName;

// ---- Per-probe output -----------------------------------------------------

pub fn onOutcome(ctx_ptr: ?*anyopaque, id: fping.TargetId, probe: u16, outcome: fping.Outcome) void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr.?));
    outcomeImpl(ctx, id, probe, outcome) catch {};
}

fn outcomeImpl(ctx: *Ctx, id: fping.TargetId, probe: u16, outcome: fping.Outcome) !void {
    const st = ctx.state(id);
    const opts = &ctx.opts;

    switch (outcome) {
        .reply => |r| {
            st.resolved += 1;
            st.recv_total += 1;
            st.sent_i += 1;
            st.recv_i += 1;
            st.total_i += r.rtt_ns;
            // recv_i/g_recv were just incremented: 1 = first sample (0 ns is a valid RTT).
            if (st.recv_i == 1 or r.rtt_ns < st.min_i) st.min_i = r.rtt_ns;
            if (r.rtt_ns > st.max_i) st.max_i = r.rtt_ns;
            ctx.g_recv += 1;
            ctx.g_sum += r.rtt_ns;
            if (ctx.g_recv == 1 or r.rtt_ns < ctx.g_min) ctx.g_min = r.rtt_ns;
            if (r.rtt_ns > ctx.g_max) ctx.g_max = r.rtt_ns;
            if (probe < st.vcount_rtts.len) st.vcount_rtts[probe] = r.rtt_ns;

            if (!st.alive_announced) {
                st.alive_announced = true;
                ctx.num_alive += 1;
                // -X: stop as soon as enough hosts are alive.
                if (opts.fast_reachable and opts.reachable != null and
                    ctx.num_alive >= opts.reachable.?)
                    ctx.pinger.stop();

                if (ctx.verbose or opts.show_alive) {
                    try ctx.out.print("{s}", .{st.name});
                    if (ctx.verbose) try ctx.out.writeAll(" is alive");
                    try printRecvExt(ctx, r, false);
                    try ctx.out.writeAll("\n");
                    try ctx.out.flush();
                }
            }

            if (ctx.per_recv) try printRecv(ctx, st, probe, r);
        },
        .duplicate => |r| {
            // fping prints duplicates to stderr outside of per-recv mode.
            if (!ctx.per_recv) {
                try ctx.err.print("{s} : duplicate for [{d}], {d} bytes, ", .{ st.name, probe, r.size });
                try fmtMs(ctx.err, r.rtt_ns);
                try ctx.err.writeAll(" ms\n");
                try ctx.err.flush();
            }
        },
        .timeout => {
            st.resolved += 1;
            st.sent_i += 1;
            ctx.g_timeouts += 1;
            if (ctx.per_recv) try printTimeout(ctx, st, probe);
        },
        .send_error => {
            st.resolved += 1;
            st.sent_i += 1;
        },
        // fping's print_warning(): stderr, suppressed by -q (and -Q). The
        // probe itself still resolves via its timeout.
        .icmp_error => |e| if (!opts.quiet) {
            try writeIcmpError(ctx.err, e, st.name);
            try ctx.err.flush();
        },
    }

    if (signals.snapshot_requested.swap(false, .monotonic)) {
        if (opts.json) try printIntervalJson(ctx) else try printIntervalSplits(ctx);
    }

    if (opts.squiet_ns) |interval| {
        const now = fping.monoNow();
        if (now >= ctx.next_report_ns) {
            while (ctx.next_report_ns <= now) ctx.next_report_ns += @intCast(interval);
            if (opts.netdata) {
                try printNetdata(ctx);
            } else if (opts.json) {
                try printIntervalJson(ctx);
            } else {
                try printIntervalSplits(ctx);
            }
        }
    }
}

// ---- ICMP error warnings (fping decode_icmp_ipv4/ipv6) --------------------

/// fping's icmp_type_str[], indexed by ICMP type 0..18.
const icmp_type_str = [19][]const u8{
    "ICMP Echo Reply",        "",                       "",                     "ICMP Unreachable",
    "ICMP Source Quench",     "ICMP Redirect",          "",                     "",
    "ICMP Echo",              "",                       "",                     "ICMP Time Exceeded",
    "ICMP Parameter Problem", "ICMP Timestamp Request", "ICMP Timestamp Reply", "ICMP Information Request",
    "ICMP Information Reply", "ICMP Mask Request",      "ICMP Mask Reply",
};

/// fping's icmp_unreach_str[], indexed by ICMP unreachable code 0..15.
const icmp_unreach_str = [16][]const u8{
    "ICMP Network Unreachable",
    "ICMP Host Unreachable",
    "ICMP Protocol Unreachable",
    "ICMP Port Unreachable",
    "ICMP Unreachable (Fragmentation Needed)",
    "ICMP Unreachable (Source Route Failed)",
    "ICMP Unreachable (Destination Network Unknown)",
    "ICMP Unreachable (Destination Host Unknown)",
    "ICMP Unreachable (Source Host Isolated)",
    "ICMP Unreachable (Communication with Network Prohibited)",
    "ICMP Unreachable (Communication with Host Prohibited)",
    "ICMP Unreachable (Network Unreachable For Type Of Service)",
    "ICMP Unreachable (Host Unreachable For Type Of Service)",
    "ICMP Unreachable (Communication Administratively Prohibited)",
    "ICMP Unreachable (Host Precedence Violation)",
    "ICMP Unreachable (Precedence cutoff in effect)",
};

const icmp6_unreach_str = [10][]const u8{
    "No route to destination",
    "Communication with destination administratively prohibited",
    "Beyond scope of source address",
    "Address unreachable",
    "Port unreachable",
    "Source address failed ingress/egress policy",
    "Reject route to destination",
    "Error in Source Routing Header",
    "Headers too long",
    "Error in P-Route",
};

const icmp6_time_exceeded_str = [2][]const u8{
    "Hop limit exceeded in transit",
    "Fragment reassembly time exceeded",
};

const icmp6_param_prob_str = [11][]const u8{
    "Erroneous header field encountered",
    "Unrecognized Next Header type encountered",
    "Unrecognized IPv6 option encountered",
    "IPv6 First Fragment has incomplete IPv6 Header Chain",
    "SR Upper-layer Header Error",
    "Unrecognized Next Header type encountered by intermediate node",
    "Extension header too big",
    "Extension header chain too long",
    "Too many extension headers",
    "Too many options in extension header",
    "Option too big",
};

/// Render one fping-style ICMP error line ("<reason> from <addr> for ICMP
/// Echo sent to <host>\n"). `host` is the target as the user named it.
pub fn writeIcmpError(w: *Io.Writer, e: fping.IcmpError, host: []const u8) Io.Writer.Error!void {
    var from_buf: [64]u8 = undefined;
    var from_w: Io.Writer = .fixed(&from_buf);
    if (e.from) |a| a.format(&from_w) catch {};
    const from = from_w.buffered();

    switch (e.family) {
        .v4 => {
            if (e.icmp_type == fping.icmp.v4.dest_unreachable) {
                if (e.code >= icmp_unreach_str.len)
                    try w.writeAll("ICMP Unreachable (Invalid Code)")
                else
                    try w.writeAll(icmp_unreach_str[e.code]);
            } else if (e.icmp_type < icmp_type_str.len) {
                try w.writeAll(icmp_type_str[e.icmp_type]);
            } else {
                try w.print("ICMP {d}", .{e.icmp_type});
            }
            try w.print(" from {s} for ICMP Echo sent to {s}\n", .{ from, host });
        },
        .v6 => {
            const v6 = fping.icmp.v6;
            const tail_fmt = " from {s} for ICMPv6 Echo Request sent to {s}\n";
            switch (e.icmp_type) {
                v6.dest_unreachable => try writeV6Coded(w, "Destination Unreachable", &icmp6_unreach_str, e.code),
                v6.packet_too_big => try w.writeAll("ICMPv6 Packet Too Big"),
                v6.time_exceeded => try writeV6Coded(w, "Time Exceeded", &icmp6_time_exceeded_str, e.code),
                v6.param_problem => try writeV6Coded(w, "Parameter Problem", &icmp6_param_prob_str, e.code),
                else => try w.print("ICMPv6 Type {d} Code {d}", .{ e.icmp_type, e.code }),
            }
            try w.print(tail_fmt, .{ from, host });
        },
    }
}

fn writeV6Coded(w: *Io.Writer, name: []const u8, table: []const []const u8, code: u8) Io.Writer.Error!void {
    if (code >= table.len)
        try w.print("ICMPv6 {s} (Code {d})", .{ name, code })
    else
        try w.print("ICMPv6 {s} ({s})", .{ name, table[code] });
}

fn expectIcmpLine(expected: []const u8, e: fping.IcmpError, host: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeIcmpError(&w, e, host);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "icmp error lines match fping v4 wording" {
    const from = fping.Addr.parse("198.51.100.1") catch unreachable;
    const mk = struct {
        fn f(t: u8, c: u8, a: fping.Addr) fping.IcmpError {
            return .{ .family = .v4, .icmp_type = t, .code = c, .from = a };
        }
    }.f;
    try expectIcmpLine("ICMP Network Unreachable from 198.51.100.1 for ICMP Echo sent to h.example\n", mk(3, 0, from), "h.example");
    try expectIcmpLine("ICMP Unreachable (Communication Administratively Prohibited) from 198.51.100.1 for ICMP Echo sent to x\n", mk(3, 13, from), "x");
    try expectIcmpLine("ICMP Unreachable (Precedence cutoff in effect) from 198.51.100.1 for ICMP Echo sent to x\n", mk(3, 15, from), "x");
    // Code beyond the table.
    try expectIcmpLine("ICMP Unreachable (Invalid Code) from 198.51.100.1 for ICMP Echo sent to x\n", mk(3, 16, from), "x");
    try expectIcmpLine("ICMP Source Quench from 198.51.100.1 for ICMP Echo sent to x\n", mk(4, 0, from), "x");
    try expectIcmpLine("ICMP Redirect from 198.51.100.1 for ICMP Echo sent to x\n", mk(5, 1, from), "x");
    try expectIcmpLine("ICMP Time Exceeded from 198.51.100.1 for ICMP Echo sent to x\n", mk(11, 0, from), "x");
    try expectIcmpLine("ICMP Parameter Problem from 198.51.100.1 for ICMP Echo sent to x\n", mk(12, 0, from), "x");
    // Type beyond icmp_type_str.
    try expectIcmpLine("ICMP 19 from 198.51.100.1 for ICMP Echo sent to x\n", mk(19, 0, from), "x");
}

test "icmp error lines match fping v6 wording" {
    const from = fping.Addr.parse("2001:db8::1") catch unreachable;
    const mk = struct {
        fn f(t: u8, c: u8, a: fping.Addr) fping.IcmpError {
            return .{ .family = .v6, .icmp_type = t, .code = c, .from = a };
        }
    }.f;
    try expectIcmpLine("ICMPv6 Destination Unreachable (No route to destination) from 2001:db8::1 for ICMPv6 Echo Request sent to x\n", mk(1, 0, from), "x");
    try expectIcmpLine("ICMPv6 Destination Unreachable (Error in P-Route) from 2001:db8::1 for ICMPv6 Echo Request sent to x\n", mk(1, 9, from), "x");
    try expectIcmpLine("ICMPv6 Destination Unreachable (Code 10) from 2001:db8::1 for ICMPv6 Echo Request sent to x\n", mk(1, 10, from), "x");
    try expectIcmpLine("ICMPv6 Packet Too Big from 2001:db8::1 for ICMPv6 Echo Request sent to x\n", mk(2, 0, from), "x");
    try expectIcmpLine("ICMPv6 Time Exceeded (Fragment reassembly time exceeded) from 2001:db8::1 for ICMPv6 Echo Request sent to x\n", mk(3, 1, from), "x");
    try expectIcmpLine("ICMPv6 Time Exceeded (Code 2) from 2001:db8::1 for ICMPv6 Echo Request sent to x\n", mk(3, 2, from), "x");
    try expectIcmpLine("ICMPv6 Parameter Problem (Option too big) from 2001:db8::1 for ICMPv6 Echo Request sent to x\n", mk(4, 10, from), "x");
    try expectIcmpLine("ICMPv6 Parameter Problem (Code 11) from 2001:db8::1 for ICMPv6 Echo Request sent to x\n", mk(4, 11, from), "x");
    try expectIcmpLine("ICMPv6 Type 7 Code 3 from 2001:db8::1 for ICMPv6 Echo Request sent to x\n", mk(7, 3, from), "x");
}

fn printTimestamp(ctx: *Ctx, w: *Io.Writer) !void {
    if (!ctx.opts.timestamp) return;
    const now = realNowNs();
    const json = ctx.opts.json;
    switch (ctx.opts.timestamp_format) {
        .unix => {
            const secs = @as(f64, @floatFromInt(now)) / 1e9;
            if (json) try w.print("\"timestamp\": \"{d:.5}\", ", .{secs}) else try w.print("[{d:.5}] ", .{secs});
        },
        // Rendered in local time like fping's localtime(), using
        // /etc/localtime via std.tz (TZ env rule strings are not
        // interpreted — see src/tzlocal.zig).
        .ctime, .iso, .rfc3339 => {
            var buf: [64]u8 = undefined;
            const offset = ctx.tz.offsetAt(@divTrunc(now, std.time.ns_per_s));
            const text = formatTimestamp(&buf, now, ctx.opts.timestamp_format, offset);
            if (json) try w.print("\"timestamp\": \"{s}\", ", .{text}) else try w.print("[{s}] ", .{text});
        },
    }
}

fn formatTimestamp(buf: []u8, now_ns: i64, format: options_mod.TimestampFormat, offset_secs: i32) []const u8 {
    const epoch_secs: u64 = @intCast(@divTrunc(now_ns, std.time.ns_per_s) + offset_secs);
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = epoch_secs };
    const day = epoch_seconds.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_seconds.getDaySeconds();
    const year = year_day.year;
    const month = month_day.month.numeric();
    const dom = month_day.day_index + 1;
    const hour = day_secs.getHoursIntoDay();
    const minute = day_secs.getMinutesIntoHour();
    const second = day_secs.getSecondsIntoMinute();

    var w: Io.Writer = .fixed(buf);
    switch (format) {
        .ctime => {
            const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
            // Weekday from epoch day (1970-01-01 was a Thursday).
            const weekday_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
            const weekday = weekday_names[@intCast(day.day % 7)];
            w.print("{s} {s} {d:2} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{
                weekday, month_names[month - 1], dom, hour, minute, second, year,
            }) catch unreachable;
        },
        .iso => {
            const sign: u8 = if (offset_secs < 0) '-' else '+';
            const abs: u32 = @abs(offset_secs);
            w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}{d:0>2}", .{
                year, month, dom, hour, minute, second, sign, abs / 3600, (abs / 60) % 60,
            }) catch unreachable;
        },
        .rfc3339 => w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            year, month, dom, hour, minute, second,
        }) catch unreachable,
        .unix => unreachable,
    }
    return w.buffered();
}

fn printRecvExt(ctx: *Ctx, r: fping.ReplyInfo, per_recv: bool) !void {
    const opts = &ctx.opts;
    if (r.ts) |ts| {
        const local_ms: u64 = @intCast(@mod(@divTrunc(realNowNs(), std.time.ns_per_ms), std.time.ms_per_day));
        try ctx.out.print("{s} timestamps: Originate={d} Receive={d} Transmit={d} Localreceive={d}", .{
            if (opts.show_alive) "" else ",", ts.originate_ms, ts.receive_ms, ts.transmit_ms, local_ms,
        });
    }
    if (opts.print_tos) {
        if (r.tos) |tos| try ctx.out.print(" (TOS {d})", .{tos}) else try ctx.out.writeAll(" (TOS unknown)");
    }
    if (opts.print_ttl) {
        if (r.ttl) |ttl| try ctx.out.print(" (TTL {d})", .{ttl}) else try ctx.out.writeAll(" (TTL unknown)");
    }
    if (opts.elapsed and !per_recv) {
        try ctx.out.writeAll(" (");
        try fmtMs(ctx.out, r.rtt_ns);
        try ctx.out.writeAll(" ms)");
    }
}

fn printRecv(ctx: *Ctx, st: *TargetState, probe: u16, r: fping.ReplyInfo) !void {
    const stats = ctx.pinger.stats(targetIdOf(ctx, st));
    const avg = stats.avgNs() orelse r.rtt_ns;
    const loss = if (st.resolved > 0) ((st.resolved - st.recv_total) * 100) / st.resolved else 0;

    if (ctx.opts.json) {
        try ctx.out.writeAll("{\"resp\": {");
        try printTimestamp(ctx, ctx.out);
        try ctx.out.print("\"host\": \"{s}\", \"seq\": {d}, \"size\": {d}, \"rtt\": ", .{ st.name, probe, r.size });
        try fmtMs(ctx.out, r.rtt_ns);
        try printRecvExtJson(ctx, r);
        try ctx.out.writeAll("}}\n");
        try ctx.out.flush();
        return;
    }

    try printTimestamp(ctx, ctx.out);
    try printPaddedName(ctx, ctx.out, st.name);
    try ctx.out.print(" : [{d}], {d} bytes, ", .{ probe, r.size });
    try fmtMs(ctx.out, r.rtt_ns);
    try ctx.out.writeAll(" ms (");
    try fmtMs(ctx.out, avg);
    try ctx.out.print(" avg, {d}% loss)", .{loss});
    try printRecvExt(ctx, r, true);
    try ctx.out.writeAll("\n");
    try ctx.out.flush();
}

fn printRecvExtJson(ctx: *Ctx, r: fping.ReplyInfo) !void {
    const opts = &ctx.opts;
    if (r.ts) |ts| {
        const local_ms: u64 = @intCast(@mod(@divTrunc(realNowNs(), std.time.ns_per_ms), std.time.ms_per_day));
        try ctx.out.print(", \"timestamps\": {{\"originate\": {d}, \"receive\": {d}, \"transmit\": {d}, \"localreceive\": {d}}}", .{
            ts.originate_ms, ts.receive_ms, ts.transmit_ms, local_ms,
        });
    }
    if (opts.print_tos) {
        if (r.tos) |tos| try ctx.out.print(", \"tos\": {d}", .{tos}) else try ctx.out.writeAll(", \"tos\": -1");
    }
    if (opts.print_ttl) {
        if (r.ttl) |ttl| try ctx.out.print(", \"ttl\": {d}", .{ttl}) else try ctx.out.writeAll(", \"ttl\": -1");
    }
}

fn printTimeout(ctx: *Ctx, st: *TargetState, probe: u16) !void {
    if (ctx.opts.json) {
        try ctx.out.writeAll("{\"timeout\": {");
        try printTimestamp(ctx, ctx.out);
        try ctx.out.print("\"host\": \"{s}\", \"seq\": {d}}}}}\n", .{ st.name, probe });
        try ctx.out.flush();
        return;
    }
    try printTimestamp(ctx, ctx.out);
    try printPaddedName(ctx, ctx.out, st.name);
    try ctx.out.print(" : [{d}], timed out (", .{probe});
    const stats = ctx.pinger.stats(targetIdOf(ctx, st));
    if (stats.avgNs()) |avg| {
        try fmtMs(ctx.out, avg);
    } else {
        try ctx.out.writeAll("NaN");
    }
    const loss = if (st.resolved > 0) ((st.resolved - st.recv_total) * 100) / st.resolved else 0;
    try ctx.out.print(" avg, {d}% loss)\n", .{loss});
    try ctx.out.flush();
}

fn targetIdOf(ctx: *Ctx, st: *TargetState) fping.TargetId {
    const base = @intFromPtr(ctx.states.ptr);
    const offset = @intFromPtr(st) - base;
    return @intCast(offset / @sizeOf(TargetState));
}

// ---- Interval (-Q) reports -------------------------------------------------

fn printIntervalSplits(ctx: *Ctx) !void {
    const now = realNowNs();
    const now_s = @divTrunc(now, std.time.ns_per_s);
    const local_s = now_s + ctx.tz.offsetAt(now_s);
    const day_secs: u64 = @intCast(@mod(local_s, std.time.s_per_day));
    try ctx.err.print("[{d:0>2}:{d:0>2}:{d:0>2}]\n", .{
        day_secs / 3600, (day_secs / 60) % 60, day_secs % 60,
    });
    for (ctx.states) |*st| {
        try printPaddedName(ctx, ctx.err, st.name);
        try ctx.err.writeAll(" :");
        const loss = if (st.sent_i > 0) ((st.sent_i - st.recv_i) * 100) / st.sent_i else 0;
        try ctx.err.print(" xmt/rcv/%loss = {d}/{d}/{d}%", .{ st.sent_i, st.recv_i, loss });
        if (ctx.opts.outage) {
            const outage_ms = @as(u64, st.sent_i - st.recv_i) * (ctx.opts.period_ns / std.time.ns_per_ms);
            try ctx.err.print(", outage(ms) = {d}", .{outage_ms});
        }
        if (st.recv_i > 0) {
            try ctx.err.writeAll(", min/avg/max = ");
            try fmtMs(ctx.err, st.min_i);
            try ctx.err.writeAll("/");
            try fmtMs(ctx.err, st.total_i / st.recv_i);
            try ctx.err.writeAll("/");
            try fmtMs(ctx.err, st.max_i);
        }
        try ctx.err.writeAll("\n");
        if (!ctx.opts.cumulative) resetInterval(st);
    }
    try ctx.err.flush();
}

fn printIntervalJson(ctx: *Ctx) !void {
    const now_s = @divTrunc(realNowNs(), std.time.ns_per_s);
    for (ctx.states) |*st| {
        try ctx.out.print("{{\"intSum\": {{\"time\": {d},\"host\": \"{s}\", ", .{ now_s, st.name });
        const loss = if (st.sent_i > 0) ((st.sent_i - st.recv_i) * 100) / st.sent_i else 0;
        try ctx.out.print("\"xmt\": {d}, \"rcv\": {d}, \"loss\": {d}", .{ st.sent_i, st.recv_i, loss });
        if (ctx.opts.outage) {
            const outage_ms = @as(u64, st.sent_i - st.recv_i) * (ctx.opts.period_ns / std.time.ns_per_ms);
            try ctx.out.print(", \"outage(ms)\": {d}", .{outage_ms});
        }
        if (st.recv_i > 0) {
            try ctx.out.writeAll(", \"rttMin\": ");
            try fmtMs(ctx.out, st.min_i);
            try ctx.out.writeAll(", \"rttAvg\": ");
            try fmtMs(ctx.out, st.total_i / st.recv_i);
            try ctx.out.writeAll(", \"rttMax\": ");
            try fmtMs(ctx.out, st.max_i);
        }
        try ctx.out.writeAll("}}\n");
        if (!ctx.opts.cumulative) resetInterval(st);
    }
    try ctx.out.flush();
}

fn printNetdata(ctx: *Ctx) !void {
    // fping renders the chart interval with printf "%.0f" — round half to
    // even, not truncation (e.g. -Q 1.5 prints "2", -Q 0.5 prints "0").
    const ns = ctx.opts.squiet_ns orelse 0;
    var interval_s = ns / std.time.ns_per_s;
    const rem = ns % std.time.ns_per_s;
    const half = std.time.ns_per_s / 2;
    if (rem > half or (rem == half and interval_s % 2 == 1)) interval_s += 1;
    for (ctx.states) |*st| {
        if (!ctx.netdata_charts_sent) {
            try ctx.out.print("CHART fping.{s}_packets '' 'FPing Packets' packets '{s}' fping.packets line 110020 {d}\n", .{ st.netdata_id, st.name, interval_s });
            try ctx.out.writeAll("DIMENSION xmt sent absolute 1 1\nDIMENSION rcv received absolute 1 1\n");
        }
        try ctx.out.print("BEGIN fping.{s}_packets\nSET xmt = {d}\nSET rcv = {d}\nEND\n", .{ st.netdata_id, st.sent_i, st.recv_i });

        if (!ctx.netdata_charts_sent) {
            try ctx.out.print("CHART fping.{s}_quality '' 'FPing Quality' percentage '{s}' fping.quality area 110010 {d}\n", .{ st.netdata_id, st.name, interval_s });
            try ctx.out.writeAll("DIMENSION returned '' absolute 1 1\n");
        }
        const quality = if (st.sent_i > 0) (st.recv_i * 100) / st.sent_i else 0;
        try ctx.out.print("BEGIN fping.{s}_quality\nSET returned = {d}\nEND\n", .{ st.netdata_id, quality });

        if (!ctx.netdata_charts_sent) {
            try ctx.out.print("CHART fping.{s}_latency '' 'FPing Latency' ms '{s}' fping.latency area 110000 {d}\n", .{ st.netdata_id, st.name, interval_s });
            try ctx.out.writeAll("DIMENSION min minimum absolute 1 1000000\nDIMENSION max maximum absolute 1 1000000\nDIMENSION avg average absolute 1 1000000\n");
        }
        try ctx.out.print("BEGIN fping.{s}_latency\n", .{st.netdata_id});
        if (st.recv_i > 0) {
            try ctx.out.print("SET min = {d}\nSET avg = {d}\nSET max = {d}\n", .{
                st.min_i, st.total_i / st.recv_i, st.max_i,
            });
        }
        try ctx.out.writeAll("END\n");
        resetInterval(st);
    }
    ctx.netdata_charts_sent = true;
    try ctx.out.flush();
}

fn resetInterval(st: *TargetState) void {
    st.sent_i = 0;
    st.recv_i = 0;
    st.min_i = 0;
    st.max_i = 0;
    st.total_i = 0;
}
