//! Test driver for the opt-in DGRAM ICMP error reporting
//! (`Config.icmp_errors_dgram`, IP_RECVERR / IPV6_RECVERR). The zfping CLI
//! does not expose that option, so test/functional.sh builds this program and
//! runs it against the "router" namespace that produces real ICMP errors.
//!
//!     recverr-driver [--off] TARGET...
//!
//! One probe per target on DGRAM sockets. Prints one `icmp_error` line per
//! reported error and one `summary` line per target. `--off` leaves the
//! option at its default to show that nothing is reported then.

const std = @import("std");
const Io = std.Io;
const zf = @import("zig_fping");

const Ctx = struct {
    out: *Io.Writer,
    addrs: []const zf.Addr,

    fn cb(ptr: ?*anyopaque, id: zf.TargetId, probe: u16, outcome: zf.Outcome) void {
        _ = probe;
        const self: *Ctx = @ptrCast(@alignCast(ptr.?));
        const e = switch (outcome) {
            .icmp_error => |e| e,
            else => return,
        };
        self.out.writeAll("icmp_error ") catch return;
        self.addrs[id].format(self.out) catch return;
        self.out.print(" type={d} code={d} from=", .{ e.icmp_type, e.code }) catch return;
        if (e.from) |f| f.format(self.out) catch return else self.out.writeAll("none") catch return;
        self.out.writeByte('\n') catch return;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var buf: [4096]u8 = undefined;
    var fw: Io.File.Writer = .init(.stdout(), init.io, &buf);
    const out = &fw.interface;

    var on = true;
    var addrs: std.ArrayList(zf.Addr) = .empty;
    defer addrs.deinit(gpa);
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--off")) {
            on = false;
        } else try addrs.append(gpa, try zf.Addr.parse(a));
    }

    var p = try zf.Pinger.init(gpa, .{
        .mode = .count,
        .count = 1,
        .retries = 0,
        .timeout_ns = 700 * std.time.ns_per_ms,
        .socket_mode = .dgram,
        .icmp_errors_dgram = on,
    });
    defer p.deinit();
    var ctx: Ctx = .{ .out = out, .addrs = addrs.items };
    p.setResultCallback(&ctx, Ctx.cb);
    for (addrs.items) |a| _ = try p.addTargetAddr(a);
    try p.run();

    for (addrs.items, 0..) |a, i| {
        const s = p.stats(@intCast(i));
        try out.writeAll("summary ");
        try a.format(out);
        try out.print(" sent={d} recv={d} icmp_errors={d}\n", .{ s.sent, s.recv, s.icmp_errors });
    }
    try out.flush();
}
