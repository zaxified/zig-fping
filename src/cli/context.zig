//! Shared CLI state and small rendering helpers used by both the per-probe
//! output (output.zig) and the final reports (stats.zig). Kept in one place
//! so those modules depend on this rather than on each other or on main.zig.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const fping = @import("zig_fping");
const options_mod = @import("options.zig");

/// fping exit codes: 0 all reachable, 1 some unreachable, 2 addresses not
/// found, 4 internal error. The man page documents exit 3 for invalid
/// arguments, but the binary calls usage(1)/exit(1) on every usage error;
/// we match the binary (verified against fping develop@780ec46).
pub const exit_unreachable = 1;
pub const exit_noaddress = 2;
pub const exit_usage = 1;
pub const exit_internal = 4;

/// Milliseconds rendering identical to fping's sprint_tm().
pub fn fmtMs(w: *Io.Writer, ns: u64) Io.Writer.Error!void {
    const t = @as(f64, @floatFromInt(ns)) / 1e6;
    if (t < 1.0) {
        try w.print("{d:.3}", .{t});
    } else if (t < 10.0) {
        try w.print("{d:.2}", .{t});
    } else if (t < 100.0) {
        try w.print("{d:.1}", .{t});
    } else if (t < 1000000.0) {
        try w.print("{d:.0}", .{t});
    } else {
        try w.print("{e:.3}", .{t});
    }
}

pub fn realNowNs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Per-target CLI bookkeeping on top of the engine statistics.
pub const TargetState = struct {
    /// Display name: the target as the user gave it, or its address with -A.
    name: []const u8,
    /// Netdata chart id (-N): display name with non-alphanumeric characters
    /// replaced by '_', like fping's add_addr() sanitization.
    netdata_id: []const u8 = "",
    /// Resolved counts (reply/timeout/error) — fping computes per-line loss
    /// from resolved probes only, not from packets already in flight.
    resolved: u32 = 0,
    recv_total: u32 = 0,
    alive_announced: bool = false,
    // Interval (-Q) counters, reset after each report unless cumulative.
    sent_i: u32 = 0,
    recv_i: u32 = 0,
    min_i: u64 = 0,
    max_i: u64 = 0,
    total_i: u64 = 0,
    /// Per-probe RTTs for -C report (null = lost).
    vcount_rtts: []?u64 = &.{},
};

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    opts: options_mod.Options,
    out: *Io.Writer,
    err: *Io.Writer,
    pinger: *fping.Pinger,
    states: []TargetState,
    name_pad: usize = 0,
    per_recv: bool,
    verbose: bool,
    // Global aggregates for -s.
    g_timeouts: u64 = 0,
    g_recv: u64 = 0,
    g_min: u64 = 0,
    g_max: u64 = 0,
    g_sum: u64 = 0,
    num_alive: u32 = 0,
    num_noaddress: u32 = 0,
    start_real_ns: i64 = 0,
    // -Q interval reporting.
    next_report_ns: i64 = 0,
    netdata_charts_sent: bool = false,
    /// Local timezone for -D/-Q rendering (fping uses localtime()).
    tz: *const fping.LocalTz,

    pub fn state(self: *Ctx, id: fping.TargetId) *TargetState {
        return &self.states[id];
    }
};

pub fn printPaddedName(ctx: *Ctx, w: *Io.Writer, name: []const u8) !void {
    try w.print("{s}", .{name});
    var pad = ctx.name_pad -| name.len;
    while (pad > 0) : (pad -= 1) try w.writeAll(" ");
}
