//! SIGINT/SIGQUIT handling for the CLI. The state lives here (not in main.zig)
//! so output.zig can read `snapshot_requested` without importing the entry
//! point.

const std = @import("std");
const linux = std.os.linux;
const fping = @import("zig_fping");

var global_pinger: ?*fping.Pinger = null;
/// Set by SIGQUIT; the next processed probe outcome prints a status
/// snapshot (fping's status_snapshot behaviour).
pub var snapshot_requested: std.atomic.Value(bool) = .init(false);

fn handleSigint(_: linux.SIG) callconv(.c) void {
    if (global_pinger) |p| p.stop();
}

fn handleSigquit(_: linux.SIG) callconv(.c) void {
    snapshot_requested.store(true, .monotonic);
}

pub fn installSignals(pinger: *fping.Pinger) void {
    global_pinger = pinger;
    var act: linux.Sigaction = .{
        .handler = .{ .handler = handleSigint },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.INT, &act, null);
    var quit_act: linux.Sigaction = .{
        .handler = .{ .handler = handleSigquit },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.QUIT, &quit_act, null);
}
