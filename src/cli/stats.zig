//! Final reports for the CLI: per-target unreachable lines, the per-system
//! summary (-c/-l and -C), and the global statistics block (-s), in plain and
//! JSON form. Layout and exit codes mirror fping's print_per_system_stats /
//! print_global_stats.

const std = @import("std");
const Io = std.Io;
const fping = @import("zig_fping");
const context = @import("context.zig");

const Ctx = context.Ctx;
const fmtMs = context.fmtMs;
const realNowNs = context.realNowNs;
const printPaddedName = context.printPaddedName;
const exit_unreachable = context.exit_unreachable;
const exit_noaddress = context.exit_noaddress;

pub fn finish(ctx: *Ctx) !void {
    const opts = &ctx.opts;
    var num_unreachable: u32 = 0;

    var id: fping.TargetId = 0;
    while (id < ctx.pinger.targetCount()) : (id += 1) {
        const st = ctx.state(id);
        const stats = ctx.pinger.stats(id);
        if (!stats.alive()) {
            num_unreachable += 1;
            if (ctx.verbose or opts.show_unreach) {
                try ctx.out.print("{s}", .{st.name});
                if (ctx.verbose) try ctx.out.writeAll(" is unreachable");
                try ctx.out.writeAll("\n");
            }
        }
    }
    try ctx.out.flush();

    const count_mode = opts.count != null;
    if (count_mode or opts.loop) {
        if (opts.json) try printPerSystemJson(ctx) else try printPerSystem(ctx);
    }
    if (opts.stats) {
        if (opts.json) try printGlobalStatsJson(ctx) else try printGlobalStats(ctx);
    }

    if (opts.reachable) |required| {
        const reachable = ctx.pinger.targetCount() - num_unreachable;
        if (reachable >= required) {
            try ctx.out.print("Enough hosts reachable (required: {d}, reachable: {d})\n", .{ required, reachable });
            try ctx.out.flush();
            return;
        }
        try ctx.out.print("Not enough hosts reachable (required: {d}, reachable: {d})\n", .{ required, reachable });
        try ctx.out.flush();
        std.process.exit(exit_unreachable);
    }

    if (ctx.num_noaddress > 0) std.process.exit(exit_noaddress);
    if (num_unreachable > 0) std.process.exit(exit_unreachable);
}

fn printPerSystem(ctx: *Ctx) !void {
    if (ctx.verbose or ctx.per_recv) try ctx.err.writeAll("\n");
    var id: fping.TargetId = 0;
    while (id < ctx.pinger.targetCount()) : (id += 1) {
        const st = ctx.state(id);
        const stats = ctx.pinger.stats(id);
        try printPaddedName(ctx, ctx.err, st.name);
        try ctx.err.writeAll(" :");

        if (ctx.opts.report_all_rtts) {
            for (st.vcount_rtts) |maybe_rtt| {
                if (maybe_rtt) |rtt| {
                    try ctx.err.writeAll(" ");
                    try fmtMs(ctx.err, rtt);
                } else {
                    try ctx.err.writeAll(" -");
                }
            }
            try ctx.err.writeAll("\n");
            continue;
        }

        const loss = if (stats.sent > 0) ((stats.sent - stats.recv) * 100) / stats.sent else 0;
        try ctx.err.print(" xmt/rcv/%loss = {d}/{d}/{d}%", .{ stats.sent, stats.recv, loss });
        if (ctx.opts.outage) {
            const outage_ms = @as(u64, stats.lost()) * (ctx.opts.period_ns / std.time.ns_per_ms);
            try ctx.err.print(", outage(ms) = {d}", .{outage_ms});
        }
        if (stats.recv > 0) {
            try ctx.err.writeAll(", min/avg/max = ");
            try fmtMs(ctx.err, stats.min_ns);
            try ctx.err.writeAll("/");
            try fmtMs(ctx.err, stats.avgNs().?);
            try ctx.err.writeAll("/");
            try fmtMs(ctx.err, stats.max_ns);
        }
        try ctx.err.writeAll("\n");
    }
    try ctx.err.flush();
}

fn printPerSystemJson(ctx: *Ctx) !void {
    var id: fping.TargetId = 0;
    while (id < ctx.pinger.targetCount()) : (id += 1) {
        const st = ctx.state(id);
        const stats = ctx.pinger.stats(id);

        if (ctx.opts.report_all_rtts) {
            try ctx.out.print("{{\"vSum\": {{\"host\": \"{s}\", \"values\": [", .{st.name});
            for (st.vcount_rtts, 0..) |maybe_rtt, j| {
                if (j > 0) try ctx.out.writeAll(", ");
                if (maybe_rtt) |rtt| try fmtMs(ctx.out, rtt) else try ctx.out.writeAll("null");
            }
            try ctx.out.writeAll("]}}\n");
            continue;
        }

        try ctx.out.print("{{\"summary\": {{\"host\": \"{s}\", ", .{st.name});
        const loss = if (stats.sent > 0) ((stats.sent - stats.recv) * 100) / stats.sent else 0;
        try ctx.out.print("\"xmt\": {d}, \"rcv\": {d}, \"loss\": {d}", .{ stats.sent, stats.recv, loss });
        if (ctx.opts.outage) {
            const outage_ms = @as(u64, stats.lost()) * (ctx.opts.period_ns / std.time.ns_per_ms);
            try ctx.out.print(", \"outage(ms)\": {d}", .{outage_ms});
        }
        if (stats.recv > 0) {
            try ctx.out.writeAll(", \"rttMin\": ");
            try fmtMs(ctx.out, stats.min_ns);
            try ctx.out.writeAll(", \"rttAvg\": ");
            try fmtMs(ctx.out, stats.avgNs().?);
            try ctx.out.writeAll(", \"rttMax\": ");
            try fmtMs(ctx.out, stats.max_ns);
        }
        try ctx.out.writeAll("}}\n");
    }
    try ctx.out.flush();
}

fn globalCounters(ctx: *Ctx) struct { sent: u64, other: u64 } {
    var sent: u64 = 0;
    var other: u64 = 0;
    var id: fping.TargetId = 0;
    while (id < ctx.pinger.targetCount()) : (id += 1) {
        const stats = ctx.pinger.stats(id);
        sent += stats.sent;
        other += stats.icmp_errors;
    }
    return .{ .sent = sent, .other = other };
}

fn printGlobalStats(ctx: *Ctx) !void {
    const totals = globalCounters(ctx);
    const targets = ctx.pinger.targetCount();
    const unreachable_count = targets - ctx.num_alive;
    const elapsed_s = @as(f64, @floatFromInt(realNowNs() - ctx.start_real_ns)) / 1e9;
    const avg = if (ctx.g_recv > 0) ctx.g_sum / ctx.g_recv else 0;

    try ctx.err.writeAll("\n");
    try ctx.err.print(" {d:7} targets\n", .{targets});
    try ctx.err.print(" {d:7} alive\n", .{ctx.num_alive});
    try ctx.err.print(" {d:7} unreachable\n", .{unreachable_count});
    try ctx.err.print(" {d:7} unknown addresses\n", .{ctx.num_noaddress});
    try ctx.err.writeAll("\n");
    try ctx.err.print(" {d:7} timeouts (waiting for response)\n", .{ctx.g_timeouts});
    try ctx.err.print(" {d:7} ICMP Echos sent\n", .{totals.sent});
    try ctx.err.print(" {d:7} ICMP Echo Replies received\n", .{ctx.g_recv});
    try ctx.err.print(" {d:7} other ICMP received\n", .{totals.other});
    try ctx.err.writeAll("\n ");
    try fmtMs(ctx.err, ctx.g_min);
    try ctx.err.writeAll(" ms (min round trip time)\n ");
    try fmtMs(ctx.err, avg);
    try ctx.err.writeAll(" ms (avg round trip time)\n ");
    try fmtMs(ctx.err, ctx.g_max);
    try ctx.err.writeAll(" ms (max round trip time)\n");
    try ctx.err.print(" {d:12.3} sec (elapsed real time)\n\n", .{elapsed_s});
    try ctx.err.flush();
}

fn printGlobalStatsJson(ctx: *Ctx) !void {
    const totals = globalCounters(ctx);
    const targets = ctx.pinger.targetCount();
    const unreachable_count = targets - ctx.num_alive;
    const elapsed_s = @as(f64, @floatFromInt(realNowNs() - ctx.start_real_ns)) / 1e9;
    const avg = if (ctx.g_recv > 0) ctx.g_sum / ctx.g_recv else 0;

    try ctx.out.print("{{\"stats\": {{\"targets\": {d}, \"alive\": {d}, \"unreachable\": {d}, \"unknownAddresses\": {d}, ", .{
        targets, ctx.num_alive, unreachable_count, ctx.num_noaddress,
    });
    try ctx.out.print("\"timeouts\": {d}, \"icmpEchosSent\": {d}, \"icmpEchoRepliesReceived\": {d}, \"otherIcmpReceived\": {d}, ", .{
        ctx.g_timeouts, totals.sent, ctx.g_recv, totals.other,
    });
    try ctx.out.writeAll("\"rttMin\": ");
    try fmtMs(ctx.out, ctx.g_min);
    try ctx.out.writeAll(", \"rttAvg\": ");
    try fmtMs(ctx.out, avg);
    try ctx.out.writeAll(", \"rttMax\": ");
    try fmtMs(ctx.out, ctx.g_max);
    try ctx.out.print(", \"elapsed\": {d:.3}}}}}\n", .{elapsed_s});
    try ctx.out.flush();
}
