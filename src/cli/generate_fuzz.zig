//! Fuzz harness for `-g` target generation (test-only; see scripts/fuzz.sh).
//!
//! The harness is generic over its source of choices (fuzz_driver.Rng under
//! scripts/fuzz.sh, a Smith script under the optional `zig build test --fuzz`).
//! Per run: the raw bytes as a CIDR and as a range, a real spec with a few
//! octets changed, and four generated cases (v4/v6 CIDR and range) with a
//! model of the expected count, first and last address or the exact error.
//! Generated sizes stay small (at most ~64 targets: the debug allocator makes
//! a big list slow) except for the over-limit cases, which fail before allocating.

const std = @import("std");
const fuzz_driver = @import("fuzz_driver");
const generate = @import("generate.zig");

const Error = generate.Error;
const List = std.ArrayList([]const u8);

fn freeList(gpa: std.mem.Allocator, list: *List) void {
    for (list.items) |t| gpa.free(t);
    list.deinit(gpa);
}

/// Real specs: CIDRs at the /30, /31, /32 and v6 edges, ranges, scopes, mixed
/// families, over-limit and malformed ones. A space separates a range's ends.
const spec_seeds = [_][]const u8{
    fuzz_driver.seed("192.168.1.0/30"),
    fuzz_driver.seed("10.0.0.0/31"),
    fuzz_driver.seed("10.0.0.7/32"),
    fuzz_driver.seed("2001:db8::/126"),
    fuzz_driver.seed("2001:db8::/64"),
    fuzz_driver.seed("fe80::%2/127"),
    fuzz_driver.seed("10.0.0.250 10.0.1.2"),
    fuzz_driver.seed("fe80::1%eth0 fe80::2%eth0"),
    fuzz_driver.seed("fe80::1%eth0 fe80::2%eth1"),
    fuzz_driver.seed("10.0.0.1 ::1"),
    fuzz_driver.seed("10.0.0.0 10.2.0.1"),
    fuzz_driver.seed("2001:db8::1 2001:db8:0:1::1"),
    fuzz_driver.seed("10.0.0.0/0"),
    fuzz_driver.seed("10.0.0.0/33"),
    fuzz_driver.seed("/24"),
    fuzz_driver.seed("1.2.3.4/"),
    fuzz_driver.seed("10.0.0.2 10.0.0.1"),
    fuzz_driver.seed(""),
};

fn note(e: Error) !void {
    switch (e) {
        error.InvalidAddress => fuzz_driver.hit("err_addr"),
        error.InvalidMask => fuzz_driver.hit("err_mask"),
        error.TooManyTargets => fuzz_driver.hit("err_toomany"),
        error.MixedFamilies => fuzz_driver.hit("err_mixed"),
        error.ScopeMismatch, error.InvalidScope => fuzz_driver.hit("err_scope"),
        error.RangeTooWide => fuzz_driver.hit("err_toowide"),
        error.OutOfMemory => return e,
    }
}

fn generateHarness(comptime S: type, src: *S, gpa: std.mem.Allocator) anyerror!void {
    var buf: [96]u8 = undefined;
    const len: usize = src.slice(&buf);
    if (len != 0) fuzz_driver.hit("raw_nonempty");
    try checkRaw(gpa, buf[0..len], src.index(len + 1));

    const body = fuzz_driver.frameOf(spec_seeds[src.index(spec_seeds.len)]);
    var mut: [96]u8 = undefined;
    @memcpy(mut[0..body.len], body);
    if (body.len > 0) for (0..src.index(3)) |_| {
        mut[src.index(body.len)] = src.value(u8);
        fuzz_driver.hit("mutated");
    };
    try checkRaw(gpa, mut[0..body.len], src.index(body.len + 1));

    try cidr4(S, src, gpa);
    try cidr6(S, src, gpa);
    try range4(S, src, gpa);
    try range6(S, src, gpa);
}

/// No oracle beyond "no crash, no leak, a known error": the text is a CIDR as
/// a whole, and a range split at its first space (else at `split_hint`).
fn checkRaw(gpa: std.mem.Allocator, text: []const u8, split_hint: usize) !void {
    var list: List = .empty;
    defer freeList(gpa, &list);
    generate.addCidr(gpa, &list, text) catch |e| try note(e);
    var list2: List = .empty;
    defer freeList(gpa, &list2);
    const at = std.mem.findScalar(u8, text, ' ');
    const first = text[0 .. at orelse split_hint];
    const second = text[if (at) |a| a + 1 else split_hint..];
    generate.addRange(gpa, &list2, first, second) catch |e| try note(e);
}

fn expectOutcome(result: Error!void, want: ?Error) !void {
    if (want) |w| {
        try std.testing.expectError(w, result);
        try note(w);
    } else try result;
}

fn fmtV4(buf: []u8, a: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a >> 24, (a >> 16) & 0xff, (a >> 8) & 0xff, a & 0xff }) catch unreachable;
}

fn fmtV6(buf: []u8, a: u128) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (0..8) |i| {
        if (i != 0) w.writeByte(':') catch unreachable;
        w.print("{x}", .{@as(u16, @truncate(a >> @intCast((7 - i) * 16)))}) catch unreachable;
    }
    return w.buffered();
}

fn v6Of(text: []const u8) !u128 {
    const bare = text[0 .. std.mem.findScalar(u8, text, '%') orelse text.len];
    const ip = try std.Io.net.IpAddress.parse(bare, 0);
    return std.mem.readInt(u128, &ip.ip6.bytes, .big);
}

const scopes = [_][]const u8{ "", "", "", "%2", "%eth0" };

fn cidr4(comptime S: type, src: *S, gpa: std.mem.Allocator) !void {
    const masks = [_]u8{ 0, 1, 8, 14, 26, 27, 28, 29, 30, 31, 32, 33, 255 };
    const addr: u32 = switch (src.index(4)) {
        0 => src.value(u32),
        1 => 0,
        2 => 0xffff_ffff,
        else => 0x0a00_0000 | @as(u32, src.value(u16)),
    };
    const mask = masks[src.index(masks.len)];
    const scope = if (src.index(8) == 0) "%eth0" else "";
    var ab: [16]u8 = undefined;
    var tb: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&tb, "{s}{s}/{d}", .{ fmtV4(&ab, addr), scope, mask }) catch unreachable;

    var list: List = .empty;
    defer freeList(gpa, &list);
    const result = generate.addCidr(gpa, &list, text);
    // The order of checks in addCidr: scope, then mask range, then the limit.
    const host_bits: u6 = if (mask >= 1 and mask <= 32) @intCast(32 - mask) else 0;
    const count: u64 = (@as(u64, 1) << host_bits) -| @as(u64, if (mask < 31) 2 else 0);
    const want: ?Error = if (scope.len != 0) error.InvalidScope else if (mask < 1 or mask > 32) error.InvalidMask else if (count > generate.max_generate) error.TooManyTargets else null;
    try expectOutcome(result, want);
    if (want != null) return;

    fuzz_driver.hit("cidr4_ok");
    if (mask >= 31) fuzz_driver.hit("cidr4_31_32");
    try std.testing.expectEqual(@as(usize, @intCast(count)), list.items.len);
    const net: u32 = if (mask == 32) addr else addr & ~((@as(u32, 1) << @intCast(32 - mask)) - 1);
    const first = if (mask < 31) net + 1 else net;
    var eb: [16]u8 = undefined;
    try std.testing.expectEqualStrings(fmtV4(&eb, first), list.items[0]);
    try std.testing.expectEqualStrings(fmtV4(&eb, first + @as(u32, @intCast(count - 1))), list.items[list.items.len - 1]);
}

fn cidr6(comptime S: type, src: *S, gpa: std.mem.Allocator) !void {
    const masks = [_]u8{ 128, 127, 126, 125, 124, 123, 100, 65, 64, 129, 0 };
    const upper: u64 = if (src.index(2) == 0) 0x2001_0db8_0000_0000 else src.value(u64);
    const addr: u128 = @as(u128, upper) << 64 | src.value(u64);
    const mask = masks[src.index(masks.len)];
    const scope = scopes[src.index(scopes.len)];
    var ab: [48]u8 = undefined;
    var tb: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&tb, "{s}{s}/{d}", .{ fmtV6(&ab, addr), scope, mask }) catch unreachable;

    var list: List = .empty;
    defer freeList(gpa, &list);
    const result = generate.addCidr(gpa, &list, text);
    const host_bits: u7 = if (mask >= 65 and mask <= 128) @intCast(128 - mask) else 0;
    const want: ?Error = if (mask < 65 or mask > 128) error.InvalidMask else if (host_bits >= 17) error.TooManyTargets else null;
    try expectOutcome(result, want);
    if (want != null) return;

    fuzz_driver.hit("cidr6_ok");
    if (scope.len != 0) fuzz_driver.hit("scoped_ok");
    const count = @as(usize, 1) << @intCast(host_bits);
    try std.testing.expectEqual(count, list.items.len);
    const span: u128 = (@as(u128, 1) << host_bits) - 1;
    const first = addr & ~span;
    try std.testing.expectEqual(first, try v6Of(list.items[0]));
    try std.testing.expectEqual(first + span, try v6Of(list.items[list.items.len - 1]));
    try std.testing.expect(std.mem.endsWith(u8, list.items[0], scope));
}

fn range4(comptime S: type, src: *S, gpa: std.mem.Allocator) !void {
    const deltas = [_]u32{ 0, 1, 9, 40, 131_072, 4_000_000 };
    var start: u32 = switch (src.index(3)) {
        0 => src.value(u32),
        1 => 0xffff_ff00,
        else => 0x0a00_0000 | @as(u32, src.value(u16)),
    };
    var end: u32 = start +| deltas[src.index(deltas.len)];
    const reversed = src.index(6) == 0;
    if (reversed) {
        if (start == 0) start = 5;
        const back: u32 = @intCast(src.index(@min(@as(usize, start), 3)));
        end = start - 1 - back;
    }
    const mix = src.index(8) == 0;
    const scope_mode = src.index(8); // 0: same scope, 1: mismatch, else none
    var sb: [16]u8 = undefined;
    var eb: [16]u8 = undefined;
    var s_text_buf: [32]u8 = undefined;
    var e_text_buf: [32]u8 = undefined;
    const s_scope = if (scope_mode <= 1) "%eth0" else "";
    const e_scope = if (scope_mode == 0) "%eth0" else if (scope_mode == 1) "%eth1" else "";
    const s_text = std.fmt.bufPrint(&s_text_buf, "{s}{s}", .{ fmtV4(&sb, start), s_scope }) catch unreachable;
    const e_text = if (mix) "::1" else std.fmt.bufPrint(&e_text_buf, "{s}{s}", .{ fmtV4(&eb, end), e_scope }) catch unreachable;

    var list: List = .empty;
    defer freeList(gpa, &list);
    const result = generate.addRange(gpa, &list, s_text, e_text);
    const count: u64 = if (end >= start) @as(u64, end) - start + 1 else 0;
    const want: ?Error = if (scope_mode == 1 and !mix) error.ScopeMismatch else if (mix) (if (scope_mode == 1) error.ScopeMismatch else if (scope_mode == 0) error.ScopeMismatch else error.MixedFamilies) else if (scope_mode == 0) error.InvalidScope else if (end < start) error.InvalidAddress else if (count > generate.max_generate) error.TooManyTargets else null;
    try expectOutcome(result, want);
    if (want != null) return;

    fuzz_driver.hit("range4_ok");
    try std.testing.expectEqual(@as(usize, @intCast(count)), list.items.len);
    var cb: [16]u8 = undefined;
    try std.testing.expectEqualStrings(fmtV4(&cb, start), list.items[0]);
    try std.testing.expectEqualStrings(fmtV4(&cb, end), list.items[list.items.len - 1]);
}

fn range6(comptime S: type, src: *S, gpa: std.mem.Allocator) !void {
    const deltas = [_]u64{ 0, 1, 9, 40, 131_072, 1 << 40 };
    const upper: u64 = if (src.index(2) == 0) 0x2001_0db8_0000_0000 else src.value(u64);
    const low: u64 = if (src.index(4) == 0) std.math.maxInt(u64) - 3 else src.value(u64);
    const start: u128 = @as(u128, upper) << 64 | low;
    var end: u128 = start +| deltas[src.index(deltas.len)];
    if (src.index(6) == 0) end = start -| (1 + src.index(3));
    const mix = src.index(8) == 0;
    const scope_mode = src.index(6); // 0: same scope, 1: mismatch, else none
    var sb: [48]u8 = undefined;
    var eb: [48]u8 = undefined;
    var s_text_buf: [64]u8 = undefined;
    var e_text_buf: [64]u8 = undefined;
    const s_scope = if (scope_mode <= 1) "%eth0" else "";
    const e_scope = if (scope_mode == 0) "%eth0" else if (scope_mode == 1) "%eth1" else "";
    const s_text = std.fmt.bufPrint(&s_text_buf, "{s}{s}", .{ fmtV6(&sb, start), s_scope }) catch unreachable;
    const e_text = if (mix) "10.0.0.1" else std.fmt.bufPrint(&e_text_buf, "{s}{s}", .{ fmtV6(&eb, end), e_scope }) catch unreachable;

    var list: List = .empty;
    defer freeList(gpa, &list);
    const result = generate.addRange(gpa, &list, s_text, e_text);
    const too_wide = (start >> 64) != (end >> 64);
    const want: ?Error = if (scope_mode == 1) error.ScopeMismatch else if (mix) (if (scope_mode == 0) error.ScopeMismatch else error.MixedFamilies) else if (too_wide) error.RangeTooWide else if (end < start) error.InvalidAddress else if (end - start + 1 > generate.max_generate) error.TooManyTargets else null;
    try expectOutcome(result, want);
    if (want != null) return;

    fuzz_driver.hit("range6_ok");
    if (scope_mode == 0) fuzz_driver.hit("scoped_ok");
    try std.testing.expectEqual(@as(usize, @intCast(end - start + 1)), list.items.len);
    try std.testing.expectEqual(start, try v6Of(list.items[0]));
    try std.testing.expectEqual(end, try v6Of(list.items[list.items.len - 1]));
}

test "fuzz: target generation never crashes" {
    // Optional `zig build test --fuzz`; a plain run replays the corpus once.
    try std.testing.fuzz({}, fuzz_driver.smithEntry(generateHarness, 512), .{ .corpus = &spec_seeds });
}

test "fuzz driver: generate" {
    try fuzz_driver.run(generateHarness, .{ .name = "generate" });
}

test "fuzz harness: generate reaches every branch in 500 seeds" {
    try fuzz_driver.expectReach(generateHarness, "generate", 500, &.{
        "raw_nonempty",
        "mutated",
        "cidr4_ok",
        "cidr4_31_32",
        "cidr6_ok",
        "range4_ok",
        "range6_ok",
        "scoped_ok",
        "err_addr",
        "err_mask",
        "err_toomany",
        "err_mixed",
        "err_scope",
        "err_toowide",
    });
}
