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
            if (st.min_i == 0 or r.rtt_ns < st.min_i) st.min_i = r.rtt_ns;
            if (r.rtt_ns > st.max_i) st.max_i = r.rtt_ns;
            ctx.g_recv += 1;
            ctx.g_sum += r.rtt_ns;
            if (ctx.g_min == 0 or r.rtt_ns < ctx.g_min) ctx.g_min = r.rtt_ns;
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
            const weekday = weekday_names[day.day % 7];
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
