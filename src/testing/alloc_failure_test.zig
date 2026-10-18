//! Allocation-failure injection (std.testing.checkAllAllocationFailures):
//! every allocation of the library setup path fails once, and the call must
//! return error.OutOfMemory with nothing leaked and nothing corrupted.

const std = @import("std");
const pinger = @import("../pinger.zig");
const Pinger = pinger.Pinger;

fn initCase(gpa: std.mem.Allocator) !void {
    var p = try Pinger.init(gpa, .{});
    p.deinit();
}

fn initTimestampCase(gpa: std.mem.Allocator) !void {
    var p = try Pinger.init(gpa, .{ .icmp_timestamp = true, .payload_size = 1400 });
    p.deinit();
}

fn addTargetCase(gpa: std.mem.Allocator) !void {
    var p = try Pinger.init(gpa, .{});
    defer p.deinit();
    // Enough targets to force several growth reallocations.
    for (0..40) |i| {
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "10.0.{d}.{d}", .{ i / 200, i % 200 + 1 });
        _ = try p.addTarget(text);
    }
    _ = try p.addTargetAddr(try pinger.Addr.parse("2001:db8::1"));
    try std.testing.expectEqual(@as(usize, 41), p.targetCount());
}

fn prepareCase(gpa: std.mem.Allocator) !void {
    var p = try Pinger.init(gpa, .{ .jitter_ns = 1000, .subnet_gap_ns = 1000 });
    // Sockets are injected so prepare() does not touch the network; they are
    // detached again before deinit because their descriptors are not real.
    defer {
        p.sock4 = null;
        p.sock6 = null;
        p.deinit();
    }
    p.sock4 = .{ .fd = -1, .family = .v4, .kind = .dgram, .ident = 1 };
    p.sock6 = .{ .fd = -1, .family = .v6, .kind = .dgram, .ident = 2 };
    for (0..40) |i| {
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "10.0.0.{d}", .{i + 1});
        _ = try p.addTarget(text);
    }
    _ = try p.addTarget("2001:db8::1");
    try p.prepare();
    // A second round reuses the queues: still no failure may corrupt state.
    try p.prepare();
}

test "alloc failure: Pinger.init" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initCase, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initTimestampCase, .{});
}

test "alloc failure: Pinger.addTarget / addTargetAddr" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, addTargetCase, .{});
}

test "alloc failure: Pinger.prepare" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, prepareCase, .{});
}
