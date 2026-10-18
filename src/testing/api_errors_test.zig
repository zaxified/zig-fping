//! Public-API size/count violations are returned errors, not debug asserts
//! (asserts compile out in ReleaseFast and would turn into undefined
//! behaviour for a library caller).

const std = @import("std");
const icmp = @import("../icmp.zig");
const Socket = @import("../socket.zig");
const pinger = @import("../pinger.zig");
const rdns = @import("../rdns.zig");
const linux = std.os.linux;

/// A Socket that is never used for I/O: the checks under test run before any syscall.
fn dummySocket() Socket {
    return .{ .fd = -1, .family = .v4, .kind = .dgram, .ident = 1 };
}

test "icmp.writeEchoRequest rejects a buffer shorter than the header" {
    var buf: [icmp.echo_header_len]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, icmp.writeEchoRequest(.v4, buf[0 .. icmp.echo_header_len - 1], 1, 1));
    try std.testing.expectError(error.BufferTooSmall, icmp.writeEchoRequest(.v6, buf[0..0], 1, 1));
    try icmp.writeEchoRequest(.v6, &buf, 1, 1);
}

test "icmp.writeTimestampRequest rejects a buffer shorter than the message" {
    var buf: [icmp.timestamp_msg_len]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, icmp.writeTimestampRequest(buf[0 .. icmp.timestamp_msg_len - 1], 1, 1, 0));
    try icmp.writeTimestampRequest(&buf, 1, 1, 0);
}

test "Socket.sendMany rejects too many packets and mismatched lengths" {
    const s = dummySocket();
    var sa: linux.sockaddr.in = std.mem.zeroes(linux.sockaddr.in);
    const pkt: [8]u8 = @splat(0);
    var addrs: [Socket.batch_max + 1]*const linux.sockaddr = undefined;
    var packets: [Socket.batch_max + 1][]const u8 = undefined;
    for (&addrs, &packets) |*a, *p| {
        a.* = @ptrCast(&sa);
        p.* = &pkt;
    }
    try std.testing.expectError(
        error.TooManyPackets,
        s.sendMany(&addrs, @sizeOf(linux.sockaddr.in), &packets),
    );
    try std.testing.expectError(
        error.LengthMismatch,
        s.sendMany(addrs[0..2], @sizeOf(linux.sockaddr.in), packets[0..3]),
    );
}

test "Socket.recvBatch rejects a slab smaller than batch_max slots" {
    const s = dummySocket();
    var slab: [Socket.batch_max * 64 - 1]u8 = undefined;
    var b: Socket.RecvBatch = .{ .slab = &slab, .slot_size = 64 };
    try std.testing.expectError(error.BufferTooSmall, s.recvBatch(&b));
}

test "Pinger.init rejects a max_inflight the sequence space cannot hold" {
    try std.testing.expectError(error.MaxInflightTooLarge, pinger.Pinger.init(std.testing.allocator, .{ .max_inflight = 65536 }));
    try std.testing.expectError(error.MaxInflightTooLarge, pinger.Pinger.init(std.testing.allocator, .{ .max_inflight = std.math.maxInt(u32) }));
    var p = try pinger.Pinger.init(std.testing.allocator, .{ .max_inflight = 65535 });
    p.deinit();
}

test "rdns.lookupPtr rejects an output buffer under 256 bytes" {
    var small: [255]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, rdns.lookupPtr(.{ .v4 = .{ 127, 0, 0, 1 } }, &small, .{}));
}
