//! Target list generation for fping -g (CIDR or start/end range),
//! mirroring add_cidr/add_range from fping.c.

const std = @import("std");

/// Maximum number of targets -g may generate (fping MAX_GENERATE).
pub const max_generate = 131072;

pub const Error = error{
    InvalidAddress,
    InvalidMask,
    TooManyTargets,
    MixedFamilies,
    /// Range start/end carry different scope ids (fping rejects this too).
    ScopeMismatch,
    /// Scope id on an IPv4 address, or scope given after the prefix length.
    InvalidScope,
    /// Range upper 64 bits differ (fping limits v6 ranges the same way).
    RangeTooWide,
    OutOfMemory,
};

const Parsed = union(enum) {
    v4: u32,
    v6: u128,
};

/// Optional "%scope" suffix split off the address text; the suffix is
/// re-appended verbatim to every generated target and resolved later by
/// Addr.parse (numeric or interface name).
fn splitScope(text: []const u8) struct { []const u8, []const u8 } {
    const percent = std.mem.indexOfScalar(u8, text, '%') orelse return .{ text, "" };
    return .{ text[0..percent], text[percent..] };
}

fn parseAddr(text: []const u8) Error!Parsed {
    const ip = std.Io.net.IpAddress.parse(text, 0) catch return error.InvalidAddress;
    return switch (ip) {
        .ip4 => |a| .{ .v4 = std.mem.readInt(u32, &a.bytes, .big) },
        .ip6 => |a| .{ .v6 = std.mem.readInt(u128, &a.bytes, .big) },
    };
}

fn appendV4(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8), value: u32) Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    const text = try std.fmt.allocPrint(gpa, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
    try list.append(gpa, text);
}

fn appendV6(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8), value: u128, scope: []const u8) Error!void {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, value, .big);
    const ip6: std.Io.net.Ip6Address = .{ .port = 0, .bytes = bytes };
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    ip6.format(&w) catch unreachable;
    var text = w.buffered();
    // Ip6Address.format renders "[addr]:port"; keep only addr.
    if (std.mem.lastIndexOfScalar(u8, text, ']')) |close| text = text[0..close];
    if (text.len > 0 and text[0] == '[') text = text[1..];
    const full = try std.fmt.allocPrint(gpa, "{s}{s}", .{ text, scope });
    try list.append(gpa, full);
}

fn rangeV4(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8), start: u32, end: u32) Error!void {
    if (end < start) return error.InvalidAddress;
    if (@as(u64, end) - start + 1 > max_generate) return error.TooManyTargets;
    var cur = start;
    while (true) {
        try appendV4(gpa, list, cur);
        if (cur == end) break;
        cur += 1;
    }
}

fn rangeV6(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8), start: u128, end: u128, scope: []const u8) Error!void {
    if (end < start) return error.InvalidAddress;
    if (end - start + 1 > max_generate) return error.TooManyTargets;
    var cur = start;
    while (true) {
        try appendV6(gpa, list, cur, scope);
        if (cur == end) break;
        cur += 1;
    }
}

/// "192.168.1.0/24" or "2001:db8::/120". IPv4 prefixes shorter than /31
/// exclude the network and broadcast addresses (fping behaviour). IPv6
/// masks are limited to 65..128 like fping.
pub fn addCidr(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8), spec: []const u8) Error!void {
    const slash = std.mem.lastIndexOfScalar(u8, spec, '/') orelse return error.InvalidAddress;
    const mask = std.fmt.parseInt(u8, spec[slash + 1 ..], 10) catch return error.InvalidMask;
    // fping: "address scope must precede prefix length".
    const addr_text, const scope = splitScope(spec[0..slash]);

    switch (try parseAddr(addr_text)) {
        .v4 => |addr| {
            if (scope.len > 0) return error.InvalidScope;
            if (mask < 1 or mask > 32) return error.InvalidMask;
            const host_bits: u5 = @intCast(32 - mask);
            const bitmask: u32 = if (mask == 32) ~@as(u32, 0) else ~((@as(u32, 1) << host_bits) - 1);
            var first = addr & bitmask;
            var last = first + ((@as(u32, 1) << host_bits) - 1);
            if (mask < 31) {
                first += 1;
                last -= 1;
            }
            try rangeV4(gpa, list, first, last);
        },
        .v6 => |addr| {
            if (mask < 65 or mask > 128) return error.InvalidMask;
            const host_bits: u7 = @intCast(128 - mask);
            const span: u128 = (@as(u128, 1) << host_bits) - 1;
            const first = addr & ~span;
            try rangeV6(gpa, list, first, first + span, scope);
        },
    }
}

/// "start end" address pair, both from the same family.
pub fn addRange(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8), start: []const u8, end: []const u8) Error!void {
    const start_text, const start_scope = splitScope(start);
    const end_text, const end_scope = splitScope(end);
    // fping rejects ranges whose start/end scopes differ.
    if (!std.mem.eql(u8, start_scope, end_scope)) return error.ScopeMismatch;

    const s = try parseAddr(start_text);
    const e = try parseAddr(end_text);
    switch (s) {
        .v4 => |sv| switch (e) {
            .v4 => |evv| {
                if (start_scope.len > 0) return error.InvalidScope;
                try rangeV4(gpa, list, sv, evv);
            },
            .v6 => return error.MixedFamilies,
        },
        .v6 => |sv| switch (e) {
            .v6 => |evv| {
                // fping requires the upper 64 bits to match.
                if ((sv >> 64) != (evv >> 64)) return error.RangeTooWide;
                try rangeV6(gpa, list, sv, evv, start_scope);
            },
            .v4 => return error.MixedFamilies,
        },
    }
}

fn freeList(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |t| gpa.free(t);
    list.deinit(gpa);
}

test "cidr v4 /30 excludes network and broadcast" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    defer freeList(gpa, &list);
    try addCidr(gpa, &list, "192.168.1.0/30");
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("192.168.1.1", list.items[0]);
    try std.testing.expectEqualStrings("192.168.1.2", list.items[1]);
}

test "cidr v4 /31 and /32 include all addresses" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    defer freeList(gpa, &list);
    try addCidr(gpa, &list, "10.0.0.0/31");
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try addCidr(gpa, &list, "10.0.0.7/32");
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqualStrings("10.0.0.7", list.items[2]);
}

test "cidr v6" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    defer freeList(gpa, &list);
    try addCidr(gpa, &list, "2001:db8::/126");
    try std.testing.expectEqual(@as(usize, 4), list.items.len);
    try std.testing.expectEqualStrings("2001:db8::", list.items[0]);
    try std.testing.expectEqualStrings("2001:db8::3", list.items[3]);
    try std.testing.expectError(error.InvalidMask, addCidr(gpa, &list, "2001:db8::/64"));
}

test "range v4 and limits" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    defer freeList(gpa, &list);
    try addRange(gpa, &list, "10.0.0.250", "10.0.1.2");
    try std.testing.expectEqual(@as(usize, 9), list.items.len);
    try std.testing.expectEqualStrings("10.0.0.255", list.items[5]);
    try std.testing.expectEqualStrings("10.0.1.0", list.items[6]);
    try std.testing.expectError(error.MixedFamilies, addRange(gpa, &list, "10.0.0.1", "::1"));
    try std.testing.expectError(error.TooManyTargets, addRange(gpa, &list, "10.0.0.0", "10.2.0.1"));
}

test "v6 range and cidr carry scope suffix" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    defer freeList(gpa, &list);
    try addRange(gpa, &list, "fe80::1%eth0", "fe80::2%eth0");
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("fe80::1%eth0", list.items[0]);
    try std.testing.expectEqualStrings("fe80::2%eth0", list.items[1]);

    try addCidr(gpa, &list, "fe80::%2/127");
    try std.testing.expectEqualStrings("fe80::%2", list.items[2]);
    try std.testing.expectEqualStrings("fe80::1%2", list.items[3]);

    try std.testing.expectError(error.ScopeMismatch, addRange(gpa, &list, "fe80::1%eth0", "fe80::2%eth1"));
    try std.testing.expectError(error.InvalidScope, addRange(gpa, &list, "10.0.0.1%eth0", "10.0.0.2%eth0"));
}

test "fuzz: target generation never crashes" {
    // Runs as a smoke test under `zig build test`; becomes a real fuzz
    // target with `zig build test --fuzz` (see scripts/fuzz.sh).
    try std.testing.fuzz({}, fuzzGenerate, .{});
}

fn fuzzGenerate(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var buf: [64]u8 = undefined;
    smith.bytes(&buf);
    const len: usize = smith.valueRangeAtMost(u8, 0, buf.len);
    const split: usize = smith.valueRangeAtMost(u8, 0, @intCast(len));

    var list: std.ArrayList([]const u8) = .empty;
    defer freeList(gpa, &list);
    addCidr(gpa, &list, buf[0..len]) catch {};
    addRange(gpa, &list, buf[0..split], buf[split..len]) catch {};
}
