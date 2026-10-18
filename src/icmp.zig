//! ICMP echo packet construction and parsing for IPv4 and IPv6.
//!
//! All multi-byte header fields are written and read in network byte order.
//! The IPv6 checksum is left at zero: the kernel fills it in for both
//! SOCK_DGRAM and SOCK_RAW ICMPv6 sockets.

const std = @import("std");

/// Length of the ICMP echo header (type, code, checksum, id, seq).
pub const echo_header_len = 8;

pub const v4 = struct {
    pub const echo_reply: u8 = 0;
    pub const dest_unreachable: u8 = 3;
    pub const source_quench: u8 = 4;
    pub const redirect: u8 = 5;
    pub const echo_request: u8 = 8;
    pub const time_exceeded: u8 = 11;
    pub const param_problem: u8 = 12;
    pub const timestamp_request: u8 = 13;
    pub const timestamp_reply: u8 = 14;
};

/// ICMP Timestamp payload (RFC 792): milliseconds since midnight UT.
pub const TsData = struct {
    originate_ms: u32,
    receive_ms: u32,
    transmit_ms: u32,
};

/// Total length of an ICMP timestamp message (header + 3 timestamps).
pub const timestamp_msg_len = echo_header_len + 12;

pub const v6 = struct {
    pub const dest_unreachable: u8 = 1;
    pub const packet_too_big: u8 = 2;
    pub const time_exceeded: u8 = 3;
    pub const param_problem: u8 = 4;
    pub const echo_request: u8 = 128;
    pub const echo_reply: u8 = 129;
};

pub const Family = enum { v4, v6 };

/// RFC 1071 internet checksum over `data`, returned in host byte order.
/// Store the result big-endian into the packet.
pub fn checksum(data: []const u8) u16 {
    // u64: a u32 accumulator overflows past ~131 kB of data.
    var sum: u64 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u64, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) sum += @as(u64, data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @intCast(~sum & 0xffff);
}

/// Fill `buf` with an ICMP echo request. `buf.len` must be
/// `echo_header_len + payload_size`; payload bytes beyond the header are
/// expected to be pre-filled (pattern or zeroes) by the caller.
/// Returns error.BufferTooSmall when `buf` cannot hold the 8-byte header.
pub fn writeEchoRequest(family: Family, buf: []u8, ident: u16, seq: u16) error{BufferTooSmall}!void {
    if (buf.len < echo_header_len) return error.BufferTooSmall;
    buf[0] = switch (family) {
        .v4 => v4.echo_request,
        .v6 => v6.echo_request,
    };
    buf[1] = 0; // code
    buf[2] = 0; // checksum (filled below for v4)
    buf[3] = 0;
    std.mem.writeInt(u16, buf[4..6], ident, .big);
    std.mem.writeInt(u16, buf[6..8], seq, .big);
    if (family == .v4) {
        const sum = checksum(buf);
        std.mem.writeInt(u16, buf[2..4], sum, .big);
    }
}

/// Fill `buf` (>= timestamp_msg_len) with an ICMP timestamp request
/// (fping --icmp-timestamp; IPv4 only). Returns error.BufferTooSmall when
/// `buf` is shorter than timestamp_msg_len.
pub fn writeTimestampRequest(buf: []u8, ident: u16, seq: u16, originate_ms: u32) error{BufferTooSmall}!void {
    if (buf.len < timestamp_msg_len) return error.BufferTooSmall;
    buf[0] = v4.timestamp_request;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 0;
    std.mem.writeInt(u16, buf[4..6], ident, .big);
    std.mem.writeInt(u16, buf[6..8], seq, .big);
    std.mem.writeInt(u32, buf[8..12], originate_ms, .big);
    std.mem.writeInt(u32, buf[12..16], 0, .big);
    std.mem.writeInt(u32, buf[16..20], 0, .big);
    const sum = checksum(buf[0..timestamp_msg_len]);
    std.mem.writeInt(u16, buf[2..4], sum, .big);
}

pub const ErrorKind = enum {
    dest_unreachable,
    time_exceeded,
    packet_too_big,
    redirect,
    param_problem,
    other,
};

pub const Reply = union(enum) {
    /// Echo or timestamp reply addressed to us (id/seq in host byte order).
    /// `ts` is set for ICMP timestamp replies.
    echo_reply: struct { ident: u16, seq: u16, ts: ?TsData = null },
    /// ICMP error quoting an echo/timestamp request of ours.
    icmp_error: struct { kind: ErrorKind, icmp_type: u8, code: u8, orig_ident: u16, orig_seq: u16 },
    /// Anything else (not ours, malformed, uninteresting type).
    ignored,
};

/// Parse a packet read from an IPv4 ICMP socket. `strip_ip_header` must be
/// true for SOCK_RAW sockets, where the kernel prepends the IP header.
pub fn parseV4(packet: []const u8, strip_ip_header: bool) Reply {
    var buf = packet;
    if (strip_ip_header) {
        if (buf.len < 20) return .ignored;
        const ihl: usize = @as(usize, buf[0] & 0x0f) * 4;
        if (ihl < 20 or buf.len < ihl) return .ignored;
        buf = buf[ihl..];
    }
    if (buf.len < echo_header_len) return .ignored;

    switch (buf[0]) {
        v4.echo_reply => return .{ .echo_reply = .{
            .ident = std.mem.readInt(u16, buf[4..6], .big),
            .seq = std.mem.readInt(u16, buf[6..8], .big),
        } },
        v4.timestamp_reply => {
            if (buf.len < timestamp_msg_len) return .ignored;
            return .{ .echo_reply = .{
                .ident = std.mem.readInt(u16, buf[4..6], .big),
                .seq = std.mem.readInt(u16, buf[6..8], .big),
                .ts = .{
                    .originate_ms = std.mem.readInt(u32, buf[8..12], .big),
                    .receive_ms = std.mem.readInt(u32, buf[12..16], .big),
                    .transmit_ms = std.mem.readInt(u32, buf[16..20], .big),
                },
            } };
        },
        v4.dest_unreachable, v4.source_quench, v4.redirect, v4.time_exceeded, v4.param_problem => {
            // The error quotes the original IP header + >= 8 bytes of payload.
            const quoted = buf[echo_header_len..];
            if (quoted.len < 20) return .ignored;
            const qihl: usize = @as(usize, quoted[0] & 0x0f) * 4;
            if (qihl < 20 or quoted.len < qihl + echo_header_len) return .ignored;
            const orig = quoted[qihl..];
            if (orig[0] != v4.echo_request and orig[0] != v4.timestamp_request) return .ignored;
            return .{ .icmp_error = .{
                .kind = switch (buf[0]) {
                    v4.dest_unreachable => .dest_unreachable,
                    v4.time_exceeded => .time_exceeded,
                    v4.redirect => .redirect,
                    v4.param_problem => .param_problem,
                    else => .other,
                },
                .icmp_type = buf[0],
                .code = buf[1],
                .orig_ident = std.mem.readInt(u16, orig[4..6], .big),
                .orig_seq = std.mem.readInt(u16, orig[6..8], .big),
            } };
        },
        else => return .ignored,
    }
}

/// Parse a packet read from an IPv6 ICMP socket. ICMPv6 sockets never
/// deliver the IPv6 header.
pub fn parseV6(packet: []const u8) Reply {
    const buf = packet;
    if (buf.len < echo_header_len) return .ignored;

    switch (buf[0]) {
        v6.echo_reply => return .{ .echo_reply = .{
            .ident = std.mem.readInt(u16, buf[4..6], .big),
            .seq = std.mem.readInt(u16, buf[6..8], .big),
        } },
        v6.dest_unreachable, v6.packet_too_big, v6.time_exceeded, v6.param_problem => {
            // The error quotes the original IPv6 header (40 bytes) + payload.
            const quoted = buf[echo_header_len..];
            if (quoted.len < 40 + echo_header_len) return .ignored;
            if (quoted[6] != 58) return .ignored; // next header must be ICMPv6
            const orig = quoted[40..];
            if (orig[0] != v6.echo_request) return .ignored;
            return .{ .icmp_error = .{
                .kind = switch (buf[0]) {
                    v6.dest_unreachable => .dest_unreachable,
                    v6.packet_too_big => .packet_too_big,
                    v6.time_exceeded => .time_exceeded,
                    v6.param_problem => .param_problem,
                    else => .other,
                },
                .icmp_type = buf[0],
                .code = buf[1],
                .orig_ident = std.mem.readInt(u16, orig[4..6], .big),
                .orig_seq = std.mem.readInt(u16, orig[6..8], .big),
            } };
        },
        else => return .ignored,
    }
}

test "checksum of RFC 1071 example" {
    // Example from RFC 1071: bytes 00 01 f2 03 f4 f5 f6 f7 -> sum ddf2 -> cksum 220d
    const data = [_]u8{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
    try std.testing.expectEqual(@as(u16, 0x220d), checksum(&data));
}

test "checksum odd length" {
    const data = [_]u8{ 0xff, 0xff, 0x01 };
    // sum = 0xffff + 0x0100 = 0x100ff -> fold -> 0x0100; ~0x0100 = 0xfeff
    try std.testing.expectEqual(@as(u16, 0xfeff), checksum(&data));
}

test "checksum of a buffer past the old u32 accumulator limit" {
    // 70000 words of 0xffff sum to 4.59e9, beyond u32 (panic in safe modes,
    // wrong result in ReleaseFast). Ones'-complement folding gives 0xffff,
    // so the checksum is 0.
    const data: [140_000]u8 = @splat(0xff);
    try std.testing.expectEqual(@as(u16, 0), checksum(&data));
    // An odd trailing byte is its own high-order word.
    const odd: [140_001]u8 = @splat(0xff);
    try std.testing.expectEqual(@as(u16, 0x00ff), checksum(&odd));
}

test "echo request round-trip v4 dgram" {
    var buf: [echo_header_len + 8]u8 = @splat(0);
    try writeEchoRequest(.v4, &buf, 0xabcd, 42);
    // Packet checksum must verify (sum over whole packet == 0).
    try std.testing.expectEqual(@as(u16, 0), checksum(&buf));
    // A reply differs only in type; emulate kernel echo by flipping type.
    var reply = buf;
    reply[0] = v4.echo_reply;
    const parsed = parseV4(&reply, false);
    try std.testing.expectEqual(@as(u16, 0xabcd), parsed.echo_reply.ident);
    try std.testing.expectEqual(@as(u16, 42), parsed.echo_reply.seq);
}

test "echo reply v4 with raw IP header" {
    var pkt: [20 + echo_header_len]u8 = @splat(0);
    pkt[0] = 0x45; // IPv4, ihl=5
    pkt[20] = v4.echo_reply;
    std.mem.writeInt(u16, pkt[24..26], 7, .big);
    std.mem.writeInt(u16, pkt[26..28], 9, .big);
    const parsed = parseV4(&pkt, true);
    try std.testing.expectEqual(@as(u16, 7), parsed.echo_reply.ident);
    try std.testing.expectEqual(@as(u16, 9), parsed.echo_reply.seq);
}

test "icmp v4 dest unreachable quoting our echo" {
    var pkt: [echo_header_len + 20 + echo_header_len]u8 = @splat(0);
    pkt[0] = v4.dest_unreachable;
    pkt[1] = 1; // host unreachable
    pkt[8] = 0x45; // quoted IP header
    const orig = pkt[8 + 20 ..];
    orig[0] = v4.echo_request;
    std.mem.writeInt(u16, orig[4..6], 0x1234, .big);
    std.mem.writeInt(u16, orig[6..8], 77, .big);
    const parsed = parseV4(&pkt, false);
    try std.testing.expectEqual(ErrorKind.dest_unreachable, parsed.icmp_error.kind);
    try std.testing.expectEqual(@as(u16, 0x1234), parsed.icmp_error.orig_ident);
    try std.testing.expectEqual(@as(u16, 77), parsed.icmp_error.orig_seq);
}

test "echo reply v6" {
    var pkt: [echo_header_len]u8 = @splat(0);
    pkt[0] = v6.echo_reply;
    std.mem.writeInt(u16, pkt[4..6], 3, .big);
    std.mem.writeInt(u16, pkt[6..8], 4, .big);
    const parsed = parseV6(&pkt);
    try std.testing.expectEqual(@as(u16, 3), parsed.echo_reply.ident);
    try std.testing.expectEqual(@as(u16, 4), parsed.echo_reply.seq);
}

test "short and foreign packets are ignored" {
    try std.testing.expectEqual(Reply.ignored, parseV4(&.{ 1, 2, 3 }, false));
    try std.testing.expectEqual(Reply.ignored, parseV6(&.{}));
    var pkt: [echo_header_len]u8 = @splat(0);
    pkt[0] = 99;
    try std.testing.expectEqual(Reply.ignored, parseV4(&pkt, false));
}

test "comptime checksum" {
    // Zig-only: the wire checksum is evaluated at compile time, so this
    // "test" cannot even build if the algorithm regresses.
    comptime {
        const data = [_]u8{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
        std.debug.assert(checksum(&data) == 0x220d);
        var pkt: [echo_header_len + 4]u8 = @splat(0);
        try writeEchoRequest(.v4, &pkt, 0x1234, 7);
        std.debug.assert(checksum(&pkt) == 0); // packet must verify
    }
}

test "checksum property: inserting the checksum makes packets verify" {
    // Property test over random payloads — fping's C tree has no unit
    // tests at all (only a Perl end-to-end suite).
    var prng: std.Random.DefaultPrng = .init(0xdecafbad);
    const random = prng.random();
    var pkt: [echo_header_len + 56]u8 = undefined;
    for (0..1000) |_| {
        random.bytes(&pkt);
        try writeEchoRequest(.v4, &pkt, random.int(u16), random.int(u16));
        try std.testing.expectEqual(@as(u16, 0), checksum(&pkt));
    }
}

// ---- fuzzing ------------------------------------------------------------------
//
// The parsers read untrusted bytes straight from the network; safe build modes
// turn any out-of-bounds access into a caught panic. The harness is generic
// over its source of choices: `scripts/fuzz.sh` drives it from seeds
// (fuzz_driver.Rng), `zig build test --fuzz` (optional) from a Smith script.
// Uniform random octets almost never form a self-consistent packet, so half of
// every run mutates a real packet from `parser_seeds` instead.

const fuzz_driver = @import("fuzz_driver");

/// Real boundary inputs: v4/v6 echo replies and errors, the exact quoted-header
/// edge (27 octets of quote rejected, 28 accepted), timestamp messages, the
/// raw-socket form with its IP header, and foreign or truncated datagrams.
const parser_seeds = [_][]const u8{
    fuzz_driver.seedHex("00006DD895550001DBDE6D6A00000000F2B4020000000000101112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F3031323334353637"), // v4 echo reply
    fuzz_driver.seedHex("080065D895550001DBDE6D6A00000000F2B4020000000000101112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F3031323334353637"), // v4 echo request: ignored
    fuzz_driver.seedHex("45000054A9E100004001D2C57F0000017F000001" ++ "00006DD895550001DBDE6D6A00000000F2B4020000000000101112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F3031323334353637"), // the reply behind its IPv4 header: the SOCK_RAW path
    fuzz_driver.seedHex("03033D3A0000000045000021875740004011B5727F0000017F000001E1829C3F000DFE2068656C6C6F"), // v4 port-unreachable quoting UDP: not ours
    fuzz_driver.seedHex("03019D7D00000000" ++ "45" ++ fuzz_driver.rep("00", 19) ++ "080000001234004D"), // v4 host-unreachable quoting OUR echo request
    fuzz_driver.seedHex("0B00A26800000000" ++ "45" ++ fuzz_driver.rep("00", 19) ++ "0D00000000550042"), // v4 time-exceeded quoting our TIMESTAMP request
    fuzz_driver.seedHex("45000054A9E100004001D2C57F0000017F000001" ++ "03019D7D00000000" ++ "45" ++ fuzz_driver.rep("00", 19) ++ "080000001234004D"), // the host-unreachable behind its IPv4 header: the SOCK_RAW error path
    fuzz_driver.seedHex("0D00AF6E13570001000030390000000000000000"), // v4 timestamp request: ignored
    fuzz_driver.seedHex("0E0046471357000100003039028FB184028FB184"), // v4 timestamp reply: carries TsData
    fuzz_driver.seedHex("0B" ++ fuzz_driver.rep("00", 7) ++ "45" ++ fuzz_driver.rep("00", 19) ++ "08" ++ fuzz_driver.rep("00", 6)), // 27 octets of quote: one short, rejected
    fuzz_driver.seedHex("0B00A7FF00000000" ++ "45" ++ fuzz_driver.rep("00", 19) ++ "08" ++ fuzz_driver.rep("00", 7)), // 28 octets of quote: the exact accepting edge
    fuzz_driver.seedHex("81004D52955A0001DBDE6D6A0000000087B90C0000000000101112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F3031323334353637"), // v6 echo reply
    fuzz_driver.seedHex("80004E52955A0001DBDE6D6A0000000087B90C0000000000101112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F3031323334353637"), // v6 echo request: ignored
    fuzz_driver.seedHex("0104FF6E000000006002D283000E11400000000000000000000000000000000100000000000000000000000000000001DAC59C3F000E002168656C6C6F36"), // v6 port-unreachable quoting UDP: next header 17
    fuzz_driver.seedHex("01" ++ fuzz_driver.rep("00", 13) ++ "3A" ++ fuzz_driver.rep("00", 33) ++ "8000" ++ "0000" ++ "BEEF" ++ "0009"), // v6 dest-unreachable quoting OUR echo request
    fuzz_driver.seedHex("010203"), // shorter than any header
    fuzz_driver.seedHex("6300000000000000"), // header-sized packet of a type nobody handles
    fuzz_driver.seedHex(""), // the empty datagram
};

fn parsersHarness(comptime S: type, src: *S, gpa: std.mem.Allocator) anyerror!void {
    _ = gpa;
    // ONE `slice` draw for the raw packet (a `bytes` followed by a ranged
    // length draw reads length 0 under Smith's .in mode).
    var buf: [256]u8 = undefined;
    const len: usize = src.slice(&buf);
    if (len != 0) fuzz_driver.hit("raw_nonempty");
    try checkPacket(buf[0..len]);

    // A real packet with up to two octets changed, sometimes truncated.
    const body = fuzz_driver.frameOf(parser_seeds[src.index(parser_seeds.len)]);
    var pkt: [256]u8 = undefined;
    @memcpy(pkt[0..body.len], body);
    var plen = body.len;
    for (0..src.index(3)) |_| {
        if (plen == 0) break;
        pkt[src.index(plen)] = src.value(u8);
        fuzz_driver.hit("mutated");
    }
    if (plen > 0 and src.index(4) == 0) {
        plen = src.index(plen + 1);
        fuzz_driver.hit("truncated");
    }
    try checkPacket(pkt[0..plen]);
}

fn checkPacket(buf: []const u8) !void {
    const len = buf.len;
    const raw = parseV4(buf, false);
    const stripped = parseV4(buf, true);
    const raw6 = parseV6(buf);
    switch (raw) {
        .echo_reply => |r| {
            fuzz_driver.hit("v4_reply");
            try std.testing.expect(len >= echo_header_len);
            if (r.ts != null) {
                fuzz_driver.hit("v4_timestamp_reply");
                try std.testing.expect(len >= timestamp_msg_len and buf[0] == v4.timestamp_reply);
            }
        },
        .icmp_error => {
            fuzz_driver.hit("v4_error");
            // never for a packet too short to hold the quote it reports
            try std.testing.expect(len >= echo_header_len + 20 + echo_header_len);
        },
        .ignored => {},
    }
    switch (raw6) {
        .echo_reply => {
            fuzz_driver.hit("v6_reply");
            try std.testing.expect(len >= echo_header_len);
        },
        .icmp_error => {
            fuzz_driver.hit("v6_error");
            try std.testing.expect(len >= echo_header_len + 40 + echo_header_len);
        },
        .ignored => {},
    }
    switch (stripped) {
        .echo_reply => fuzz_driver.hit("strip_reply"),
        .icmp_error => fuzz_driver.hit("strip_error"),
        .ignored => {},
    }

    // The strip path is the plain path over what follows the IP header, and
    // nothing else; a bad or oversized header length is `.ignored`.
    if (len >= 20) {
        const ihl = @as(usize, buf[0] & 0x0f) * 4;
        if (ihl >= 20 and ihl <= len) {
            fuzz_driver.hit("strip_checked");
            try std.testing.expectEqual(parseV4(buf[ihl..], false), stripped);
        } else {
            try std.testing.expectEqual(Reply.ignored, stripped);
        }
    } else {
        try std.testing.expectEqual(Reply.ignored, stripped);
    }
}

test "fuzz: parsers never crash on arbitrary packets" {
    // Optional `zig build test --fuzz`; a plain run replays the corpus once.
    try std.testing.fuzz({}, fuzz_driver.smithEntry(parsersHarness, 512), .{ .corpus = &parser_seeds });
}

test "fuzz driver: icmp" {
    try fuzz_driver.run(parsersHarness, .{ .name = "icmp" });
}

test "fuzz harness: icmp reaches every branch in 500 seeds" {
    try fuzz_driver.expectReach(parsersHarness, "icmp", 500, &.{
        "raw_nonempty",
        "mutated",
        "truncated",
        "v4_reply",
        "v4_timestamp_reply",
        "v4_error",
        "v6_reply",
        "v6_error",
        "strip_reply",
        "strip_error",
        "strip_checked",
    });
}

test "fuzz corpus: icmp seeds classify as documented" {
    var replies4: usize = 0;
    var errors4: usize = 0;
    var replies6: usize = 0;
    var errors6: usize = 0;
    for (parser_seeds) |sd| {
        const p = fuzz_driver.frameOf(sd);
        switch (parseV4(p, false)) {
            .echo_reply => replies4 += 1,
            .icmp_error => errors4 += 1,
            .ignored => {},
        }
        if (parseV4(p, true) == .echo_reply) replies4 += 1;
        switch (parseV6(p)) {
            .echo_reply => replies6 += 1,
            .icmp_error => errors6 += 1,
            .ignored => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 3), replies4); // reply, timestamp reply, stripped raw reply
    try std.testing.expectEqual(@as(usize, 3), errors4);
    try std.testing.expectEqual(@as(usize, 1), replies6);
    try std.testing.expectEqual(@as(usize, 1), errors6);
}

test "echo request layout: v6 is type 128 with a zero checksum field, v4 is type 8" {
    var buf: [echo_header_len + 4]u8 = @splat(0xaa);
    try writeEchoRequest(.v6, &buf, 0x1234, 0x5678);
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 0, 0x12, 0x34, 0x56, 0x78 }, buf[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa, 0xaa, 0xaa }, buf[8..]); // payload untouched

    try writeEchoRequest(.v4, &buf, 0x1234, 0x5678);
    try std.testing.expectEqual(@as(u8, 8), buf[0]);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78 }, buf[4..8]);
}

test "timestamp request layout: originate is big-endian, the rest zero, checksum verifies" {
    var buf: [timestamp_msg_len]u8 = @splat(0xff);
    try writeTimestampRequest(&buf, 0x0102, 0x0304, 0x0a0b0c0d);
    try std.testing.expectEqualSlices(u8, &.{ 13, 0 }, buf[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03, 0x04 }, buf[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0x0a, 0x0b, 0x0c, 0x0d }, buf[8..12]);
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), buf[12..20]);
    try std.testing.expectEqual(@as(u16, 0), checksum(&buf));
}

test "timestamp reply: each of the three timestamps is read from its own field" {
    var pkt: [timestamp_msg_len]u8 = @splat(0);
    pkt[0] = v4.timestamp_reply;
    std.mem.writeInt(u16, pkt[4..6], 0x0a0b, .big);
    std.mem.writeInt(u16, pkt[6..8], 0x0c0d, .big);
    std.mem.writeInt(u32, pkt[8..12], 0x01020304, .big);
    std.mem.writeInt(u32, pkt[12..16], 0x11121314, .big);
    std.mem.writeInt(u32, pkt[16..20], 0x21222324, .big);
    const r = parseV4(&pkt, false).echo_reply;
    try std.testing.expectEqual(@as(u16, 0x0a0b), r.ident);
    try std.testing.expectEqual(@as(u16, 0x0c0d), r.seq);
    try std.testing.expectEqual(@as(u32, 0x01020304), r.ts.?.originate_ms);
    try std.testing.expectEqual(@as(u32, 0x11121314), r.ts.?.receive_ms);
    try std.testing.expectEqual(@as(u32, 0x21222324), r.ts.?.transmit_ms);
}

test "parseV4 follows the IP header lengths of the outer and the quoted header" {
    // Outer header with options (IHL 6) in front of an echo reply.
    var raw: [24 + echo_header_len]u8 = @splat(0);
    raw[0] = 0x46;
    raw[24] = v4.echo_reply;
    std.mem.writeInt(u16, raw[28..30], 0xbeef, .big);
    std.mem.writeInt(u16, raw[30..32], 0x0102, .big);
    const r = parseV4(&raw, true).echo_reply;
    try std.testing.expectEqual(@as(u16, 0xbeef), r.ident);
    try std.testing.expectEqual(@as(u16, 0x0102), r.seq);

    // Quoted header with options (IHL 6): the original request starts at 24.
    var pkt: [echo_header_len + 24 + echo_header_len]u8 = @splat(0);
    pkt[0] = v4.time_exceeded;
    pkt[1] = 1;
    pkt[8] = 0x46;
    pkt[8 + 24] = v4.echo_request;
    std.mem.writeInt(u16, pkt[8 + 24 + 4 ..][0..2], 0xcafe, .big);
    std.mem.writeInt(u16, pkt[8 + 24 + 6 ..][0..2], 0x0304, .big);
    const e = parseV4(&pkt, false).icmp_error;
    try std.testing.expectEqual(ErrorKind.time_exceeded, e.kind);
    try std.testing.expectEqual(@as(u16, 0xcafe), e.orig_ident);
    try std.testing.expectEqual(@as(u16, 0x0304), e.orig_seq);
}

test "parseV4 error kinds: redirect and parameter problem keep their own kind" {
    var pkt: [echo_header_len + 20 + echo_header_len]u8 = @splat(0);
    pkt[8] = 0x45;
    pkt[8 + 20] = v4.echo_request;
    pkt[0] = v4.redirect;
    try std.testing.expectEqual(ErrorKind.redirect, parseV4(&pkt, false).icmp_error.kind);
    pkt[0] = v4.param_problem;
    try std.testing.expectEqual(ErrorKind.param_problem, parseV4(&pkt, false).icmp_error.kind);
    pkt[0] = v4.source_quench;
    try std.testing.expectEqual(ErrorKind.other, parseV4(&pkt, false).icmp_error.kind);
}

test "parseV6 needs ICMPv6 as the quoted next header and an echo request behind it" {
    var pkt: [echo_header_len + 40 + echo_header_len]u8 = @splat(0);
    pkt[0] = v6.dest_unreachable;
    pkt[8 + 6] = 17; // UDP
    pkt[8 + 40] = v6.echo_request;
    try std.testing.expectEqual(Reply.ignored, parseV6(&pkt));

    pkt[8 + 6] = 58;
    std.mem.writeInt(u16, pkt[8 + 40 + 4 ..][0..2], 0xbeef, .big);
    std.mem.writeInt(u16, pkt[8 + 40 + 6 ..][0..2], 0x0102, .big);
    const e = parseV6(&pkt).icmp_error;
    try std.testing.expectEqual(@as(u16, 0xbeef), e.orig_ident);
    try std.testing.expectEqual(@as(u16, 0x0102), e.orig_seq);

    // ICMPv6 behind the header, but not an echo request of ours.
    pkt[8 + 40] = v6.echo_reply;
    try std.testing.expectEqual(Reply.ignored, parseV6(&pkt));

    pkt[8 + 40] = v6.echo_request;
    pkt[0] = v6.packet_too_big;
    try std.testing.expectEqual(ErrorKind.packet_too_big, parseV6(&pkt).icmp_error.kind);
}
