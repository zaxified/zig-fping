//! tcpdump-oracle ICMP error fixtures: every expected value in
//! tcpdump_fixtures.zig was read from tcpdump's own decoding of the packet,
//! not from code that built it. The parser must agree on what it exposes:
//! kind, type, code and the quoted request's identifier / sequence. (The
//! quoted source / destination addresses in the fixtures are not part of
//! `icmp.Reply`, so they are not compared.)

const std = @import("std");
const icmp = @import("../icmp.zig");
const fx = @import("tcpdump_fixtures.zig");

fn expectError(c: fx.Case, r: icmp.Reply) !void {
    const e = switch (r) {
        .icmp_error => |e| e,
        else => {
            std.debug.print("not parsed as an ICMP error: {s}\n", .{c.tcpdump});
            return error.TestUnexpectedResult;
        },
    };
    const want_kind = std.meta.stringToEnum(icmp.ErrorKind, c.kind).?;
    try std.testing.expectEqual(want_kind, e.kind);
    try std.testing.expectEqual(c.icmp[0], e.icmp_type);
    try std.testing.expectEqual(c.code, e.code);
    try std.testing.expectEqual(c.ident, e.orig_ident);
    try std.testing.expectEqual(c.seq, e.orig_seq);
}

test "tcpdump oracle: ICMP errors parse as tcpdump decodes them" {
    try std.testing.expect(fx.cases.len > 0);
    for (fx.cases) |c| switch (c.family) {
        .v4 => {
            // DGRAM sockets deliver the bare ICMP message, RAW sockets prepend
            // the IP header: both must agree.
            try expectError(c, icmp.parseV4(c.icmp, false));
            try expectError(c, icmp.parseV4(c.ip, true));
        },
        .v6 => try expectError(c, icmp.parseV6(c.icmp)),
    };
}
