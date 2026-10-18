//! RFC 6724 oracle replay: glibc's getaddrinfo destination order (recorded in
//! rfc6724_vectors.zig, taken from zig-libs) replayed against
//! netutil.sortWithReachability with a deterministic reachability stub.
//!
//! zig-fping implements only rule 1 (reachable first) and rule 6 (higher
//! precedence first). A pair is therefore replayed strictly only when no
//! other rule can decide it, judged from the sources glibc recorded:
//!   * "reach" pairs: exactly one destination is usable (has a source), so
//!     rule 1 decides; the stub reports usable == "has a recorded source".
//!   * "precedence" pairs: both usable, rules 2 (scope match) and 5 (label
//!     match) tie, and the precedences differ, so rule 6 decides.
//! Every other pair involves source selection or rules 8/9 and is only
//! counted. Pairs where zig-fping and glibc disagree inside the subset are
//! findings.

const std = @import("std");
const netutil = @import("../netutil.zig");
const Addr = @import("../pinger.zig").Addr;
const vectors = @import("rfc6724_vectors.zig");

/// The address as 16 bytes; IPv4 as ::ffff:a.b.c.d.
fn bytes16(a: Addr) [16]u8 {
    switch (a) {
        .v4 => |sa| {
            var out: [16]u8 = @splat(0);
            out[10] = 0xff;
            out[11] = 0xff;
            @memcpy(out[12..16], std.mem.asBytes(&sa.addr));
            return out;
        },
        .v6 => |sa| return sa.addr,
    }
}

fn isMapped(b: [16]u8) bool {
    return std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff;
}

/// RFC 6724 section 3.1 scope. An IPv4-mapped address counts as global, as
/// glibc ranks it (RFC 6724 would give 127/8 and 169.254/16 link-local).
fn scope(a: Addr) u8 {
    const b = bytes16(a);
    if (a == .v4) {
        if (b[12] == 127 or (b[12] == 169 and b[13] == 254)) return 2;
        return 14;
    }
    if (isMapped(b)) return 14;
    if (b[0] == 0xff) return b[1] & 0xf;
    if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return 2;
    if (b[0] == 0xfe and (b[1] & 0xc0) == 0xc0) return 5;
    if (std.mem.allEqual(u8, b[0..15], 0) and b[15] == 1) return 2;
    return 14;
}

/// RFC 6724 section 2.1 label of the default policy table.
fn label(a: Addr) u8 {
    const b = bytes16(a);
    if (std.mem.allEqual(u8, b[0..15], 0) and b[15] == 1) return 0;
    if (isMapped(b)) return 4;
    if (b[0] == 0x20 and b[1] == 0x02) return 2;
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0 and b[3] == 0) return 5;
    if ((b[0] & 0xfe) == 0xfc) return 13;
    if (b[0] == 0xfe and (b[1] & 0xc0) == 0xc0) return 11;
    if (b[0] == 0x3f and b[1] == 0xfe) return 12;
    if (std.mem.allEqual(u8, b[0..12], 0)) return 3;
    return 1;
}

const Stub = struct {
    world: *const vectors.World,

    fn reachable(self: Stub, a: Addr) bool {
        const want = bytes16(a);
        for (self.world.entries) |e| {
            const d = Addr.parse(e.dst) catch unreachable;
            if (std.mem.eql(u8, &bytes16(d), &want)) return e.src != null;
        }
        unreachable; // every sorted address comes from the world
    }
};

fn stubReachable(s: Stub, a: Addr) bool {
    return s.reachable(a);
}

const Class = enum { reach, precedence, other };

fn classify(a: vectors.Entry, b: vectors.Entry) Class {
    if ((a.src == null) != (b.src == null)) return .reach;
    if (a.src == null) return .other;
    const da = Addr.parse(a.dst) catch unreachable;
    const db = Addr.parse(b.dst) catch unreachable;
    const sa = Addr.parse(a.src.?) catch unreachable;
    const sb = Addr.parse(b.src.?) catch unreachable;
    const rule2_a = scope(da) == scope(sa);
    const rule2_b = scope(db) == scope(sb);
    const rule5_a = label(da) == label(sa);
    const rule5_b = label(db) == label(sb);
    if (rule2_a != rule2_b or rule5_a != rule5_b) return .other;
    if (precedenceOf(da) == precedenceOf(db)) return .other;
    return .precedence;
}

/// Precedence via the sort itself would be circular; this restates the RFC
/// 6724 section 2.1 table independently of netutil.policyPrecedence.
fn precedenceOf(a: Addr) u8 {
    const b = bytes16(a);
    if (std.mem.allEqual(u8, b[0..15], 0) and b[15] == 1) return 50;
    if (isMapped(b)) return 35;
    if (b[0] == 0x20 and b[1] == 0x02) return 30;
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0 and b[3] == 0) return 5;
    if ((b[0] & 0xfe) == 0xfc) return 3;
    if (b[0] == 0xfe and (b[1] & 0xc0) == 0xc0) return 1;
    if (std.mem.allEqual(u8, b[0..12], 0)) return 1;
    if (b[0] == 0x3f and b[1] == 0xfe) return 1;
    return 40;
}

test "rfc6724 oracle: destination-only pairs sort as glibc orders them" {
    var counts: [3]usize = @splat(0);
    var disagree: usize = 0;
    for (&vectors.worlds, 0..) |*w, wi| {
        const n = w.entries.len;
        try std.testing.expectEqual(n * (n - 1), w.pairs.len);
        const stub: Stub = .{ .world = w };
        var k: usize = 0;
        for (0..n) |i| for (0..n) |j| {
            if (i == j) continue;
            defer k += 1;
            const class = classify(w.entries[i], w.entries[j]);
            counts[@backingInt(class)] += 1;
            if (class == .other) continue;
            const first_idx = if (w.pairs[k] == '1') j else i;
            var pair = [2]Addr{
                try Addr.parse(w.entries[i].dst),
                try Addr.parse(w.entries[j].dst),
            };
            try netutil.sortWithReachability(&pair, stub, stubReachable);
            const want = try Addr.parse(w.entries[first_idx].dst);
            if (!std.mem.eql(u8, &bytes16(pair[0]), &bytes16(want))) {
                disagree += 1;
                if (disagree <= 20) std.debug.print(
                    "world {d} ({s}): glibc puts {s} (src {?s}) first of ({s}, {s}); zig-fping does not\n",
                    .{ wi, @tagName(class), w.entries[first_idx].dst, w.entries[first_idx].src, w.entries[i].dst, w.entries[j].dst },
                );
            }
        };
    }
    if (disagree != 0) std.debug.print("rfc6724 replay: {d} reach, {d} precedence pairs checked, {d} other skipped, {d} disagree\n", .{
        counts[0], counts[1], counts[2], disagree,
    });
    try std.testing.expect(counts[0] + counts[1] >= 200);
    try std.testing.expectEqual(@as(usize, 0), disagree);
}

test "sortWithReachability refuses more than max_sort_addrs" {
    var addrs: [netutil.max_sort_addrs + 1]Addr = @splat(try Addr.parse("192.0.2.1"));
    try std.testing.expectError(error.TooManyAddresses, netutil.sortByDestinationPolicy(&addrs));
    try std.testing.expectError(error.TooManyAddresses, netutil.sortWithReachability(&addrs, {}, struct {
        fn f(_: void, _: Addr) bool {
            return true;
        }
    }.f));
}
