//! Reverse DNS (PTR) lookups in pure Zig, no libc and no std.Io instance:
//! /etc/hosts first, then a minimal DNS client (UDP, RFC 1035) against the
//! first nameserver from /etc/resolv.conf.
//!
//! std.Io.net.HostName only implements forward lookups (A/AAAA/CNAME), so
//! fping's -n/-d (getnameinfo) needs this hand-rolled PTR client.

const std = @import("std");
const linux = std.os.linux;
const netutil = @import("netutil.zig");
const HostName = std.Io.net.HostName;

pub const Address = union(enum) {
    v4: [4]u8,
    v6: [16]u8,
};

pub const Options = struct {
    timeout_ms: u32 = 2000,
    attempts: u8 = 2,
    hosts_path: [:0]const u8 = "/etc/hosts",
    resolv_conf_path: [:0]const u8 = "/etc/resolv.conf",
};

/// Resolve `addr` to a host name. `out` must be at least 256 bytes.
/// Returns null when no name could be found.
pub fn lookupPtr(addr: Address, out: []u8, opts: Options) ?[]const u8 {
    std.debug.assert(out.len >= 256);
    if (lookupHostsFile(addr, out, opts.hosts_path)) |name| return name;
    return lookupDns(addr, out, opts);
}

// ---- /etc/hosts -----------------------------------------------------------

fn lookupHostsFile(addr: Address, out: []u8, path: [:0]const u8) ?[]const u8 {
    var buf: [64 * 1024]u8 = undefined;
    const content = netutil.readFile(path, &buf) orelse return null;
    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    while (lines.next()) |line| {
        const uncommented = line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len];
        var words = std.mem.tokenizeAny(u8, uncommented, " \t");
        const ip_text = words.next() orelse continue;
        const ip = std.Io.net.IpAddress.parse(ip_text, 0) catch continue;
        const matches = switch (ip) {
            .ip4 => |a| switch (addr) {
                .v4 => |b| std.mem.eql(u8, &a.bytes, &b),
                .v6 => false,
            },
            .ip6 => |a| switch (addr) {
                .v6 => |b| std.mem.eql(u8, &a.bytes, &b),
                .v4 => false,
            },
        };
        if (!matches) continue;
        const name = words.next() orelse continue;
        if (name.len > out.len) continue;
        @memcpy(out[0..name.len], name);
        return out[0..name.len];
    }
    return null;
}

// ---- DNS PTR query ----------------------------------------------------------

const dns_port = 53;
const qtype_ptr = 12;
const qclass_in = 1;

/// Encode the PTR QNAME for `addr` ("4.3.2.1.in-addr.arpa" /
/// "...nibbles...ip6.arpa") into `buf` in DNS wire format (length-prefixed
/// labels, zero terminated). Returns the encoded length.
fn writeQname(buf: []u8, addr: Address) usize {
    var w: std.Io.Writer = .fixed(buf);
    switch (addr) {
        .v4 => |b| {
            var i: usize = 4;
            while (i > 0) {
                i -= 1;
                var label_buf: [3]u8 = undefined;
                var label: std.Io.Writer = .fixed(&label_buf);
                label.print("{d}", .{b[i]}) catch unreachable;
                w.writeByte(@intCast(label.buffered().len)) catch unreachable;
                w.writeAll(label.buffered()) catch unreachable;
            }
            for ([_][]const u8{ "in-addr", "arpa" }) |part| {
                w.writeByte(@intCast(part.len)) catch unreachable;
                w.writeAll(part) catch unreachable;
            }
        },
        .v6 => |b| {
            const hex = "0123456789abcdef";
            var i: usize = 16;
            while (i > 0) {
                i -= 1;
                w.writeByte(1) catch unreachable;
                w.writeByte(hex[b[i] & 0xf]) catch unreachable;
                w.writeByte(1) catch unreachable;
                w.writeByte(hex[b[i] >> 4]) catch unreachable;
            }
            for ([_][]const u8{ "ip6", "arpa" }) |part| {
                w.writeByte(@intCast(part.len)) catch unreachable;
                w.writeAll(part) catch unreachable;
            }
        },
    }
    w.writeByte(0) catch unreachable;
    return w.buffered().len;
}

fn buildQuery(buf: []u8, id: u16, addr: Address) usize {
    @memset(buf[0..12], 0);
    std.mem.writeInt(u16, buf[0..2], id, .big);
    buf[2] = 0x01; // RD
    std.mem.writeInt(u16, buf[4..6], 1, .big); // QDCOUNT
    const qname_len = writeQname(buf[12..], addr);
    const end = 12 + qname_len;
    std.mem.writeInt(u16, buf[end..][0..2], qtype_ptr, .big);
    std.mem.writeInt(u16, buf[end + 2 ..][0..2], qclass_in, .big);
    return end + 4;
}

/// Parse a DNS response, returning the first PTR answer name.
fn parseResponse(packet: []const u8, id: u16, out: []u8) ?[]const u8 {
    if (packet.len < 12) return null;
    if (std.mem.readInt(u16, packet[0..2], .big) != id) return null;
    if (packet[2] & 0x80 == 0) return null; // not a response
    if (packet[3] & 0x0f != 0) return null; // RCODE != NOERROR
    const qdcount = std.mem.readInt(u16, packet[4..6], .big);
    var ancount = std.mem.readInt(u16, packet[6..8], .big);

    var i: usize = 12;
    var name_buf: [HostName.max_len]u8 = undefined;

    var q: u16 = 0;
    while (q < qdcount) : (q += 1) {
        const consumed, _ = HostName.expand(packet, i, &name_buf) catch return null;
        i += consumed + 4; // skip QNAME + QTYPE + QCLASS
    }

    while (ancount > 0) : (ancount -= 1) {
        const consumed, _ = HostName.expand(packet, i, &name_buf) catch return null;
        i += consumed;
        if (i + 10 > packet.len) return null;
        const rr_type = std.mem.readInt(u16, packet[i..][0..2], .big);
        const rdlength = std.mem.readInt(u16, packet[i + 8 ..][0..2], .big);
        i += 10;
        if (i + rdlength > packet.len) return null;
        if (rr_type == qtype_ptr) {
            _, const host = HostName.expand(packet, i, &name_buf) catch return null;
            if (host.bytes.len > out.len) return null;
            @memcpy(out[0..host.bytes.len], host.bytes);
            return out[0..host.bytes.len];
        }
        i += rdlength;
    }
    return null;
}

const Nameserver = union(enum) {
    v4: linux.sockaddr.in,
    v6: linux.sockaddr.in6,
};

fn firstNameserver(path: [:0]const u8) ?Nameserver {
    var buf: [16 * 1024]u8 = undefined;
    const content = netutil.readFile(path, &buf) orelse return null;
    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const key = words.next() orelse continue;
        if (!std.mem.eql(u8, key, "nameserver")) continue;
        const ip_text = words.next() orelse continue;
        const ip = std.Io.net.IpAddress.parse(ip_text, dns_port) catch continue;
        return switch (ip) {
            .ip4 => |a| .{ .v4 = .{
                .port = std.mem.nativeToBig(u16, dns_port),
                .addr = @bitCast(a.bytes),
            } },
            .ip6 => |a| .{ .v6 = .{
                .port = std.mem.nativeToBig(u16, dns_port),
                .flowinfo = 0,
                .addr = a.bytes,
                .scope_id = 0,
            } },
        };
    }
    return null;
}

fn lookupDns(addr: Address, out: []u8, opts: Options) ?[]const u8 {
    const ns = firstNameserver(opts.resolv_conf_path) orelse return null;
    const domain: u32 = switch (ns) {
        .v4 => linux.AF.INET,
        .v6 => linux.AF.INET6,
    };
    const rc = linux.socket(domain, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);

    var seed: u64 = undefined;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    seed = @bitCast(@as(i64, ts.nsec) ^ (@as(i64, linux.getpid()) << 20));
    var prng: std.Random.DefaultPrng = .init(seed);
    const id = prng.random().int(u16);

    var query: [512]u8 = undefined;
    const query_len = buildQuery(&query, id, addr);

    var attempt: u8 = 0;
    while (attempt < opts.attempts) : (attempt += 1) {
        const send_rc = switch (ns) {
            .v4 => |*sa| linux.sendto(fd, &query, query_len, linux.MSG.NOSIGNAL, @ptrCast(sa), @sizeOf(linux.sockaddr.in)),
            .v6 => |*sa| linux.sendto(fd, &query, query_len, linux.MSG.NOSIGNAL, @ptrCast(sa), @sizeOf(linux.sockaddr.in6)),
        };
        if (linux.errno(send_rc) != .SUCCESS) return null;

        var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        var wait: linux.timespec = .{
            .sec = opts.timeout_ms / 1000,
            .nsec = @as(isize, opts.timeout_ms % 1000) * std.time.ns_per_ms,
        };
        const poll_rc = linux.ppoll(&fds, 1, &wait, null);
        if (linux.errno(poll_rc) != .SUCCESS or poll_rc == 0) continue;

        var response: [4096]u8 = undefined;
        const recv_rc = linux.recvfrom(fd, &response, response.len, 0, null, null);
        if (linux.errno(recv_rc) != .SUCCESS) continue;
        if (parseResponse(response[0..recv_rc], id, out)) |name| return name;
    }
    return null;
}

// ---- Tests --------------------------------------------------------------------

test "qname encoding v4" {
    var buf: [128]u8 = undefined;
    const len = writeQname(&buf, .{ .v4 = .{ 192, 0, 2, 5 } });
    // "5" "2" "0" "192" "in-addr" "arpa" -> 1+1 +1+1 +1+1 +1+3 +1+7 +1+4 +1
    try std.testing.expectEqual(@as(usize, 24), len);
    try std.testing.expectEqualSlices(u8, "\x015\x012\x010\x03192\x07in-addr\x04arpa\x00", buf[0..len]);
}

test "qname encoding v6" {
    var buf: [128]u8 = undefined;
    var addr: [16]u8 = @splat(0);
    addr[0] = 0x20;
    addr[1] = 0x01;
    addr[15] = 0x01;
    const len = writeQname(&buf, .{ .v6 = addr });
    // 32 nibble labels (2 bytes each) + "ip6" + "arpa" + terminator
    try std.testing.expectEqual(@as(usize, 32 * 2 + 4 + 5 + 1), len);
    try std.testing.expectEqualSlices(u8, "\x011\x010", buf[0..4]); // last byte 0x01 -> "1","0"
    try std.testing.expect(std.mem.endsWith(u8, buf[0..len], "\x03ip6\x04arpa\x00"));
}

test "response parsing" {
    var query: [512]u8 = undefined;
    const qlen = buildQuery(&query, 0xbeef, .{ .v4 = .{ 127, 0, 0, 1 } });

    // Synthesize a response: copy of query with QR bit, one PTR answer
    // pointing at the question name via compression (0xc00c).
    var resp: [512]u8 = undefined;
    @memcpy(resp[0..qlen], query[0..qlen]);
    resp[2] |= 0x80; // QR
    std.mem.writeInt(u16, resp[6..8], 1, .big); // ANCOUNT
    var i = qlen;
    resp[i] = 0xc0;
    resp[i + 1] = 0x0c; // name: pointer to question
    std.mem.writeInt(u16, resp[i + 2 ..][0..2], qtype_ptr, .big);
    std.mem.writeInt(u16, resp[i + 4 ..][0..2], qclass_in, .big);
    std.mem.writeInt(u32, resp[i + 6 ..][0..4], 60, .big); // TTL
    const rdata = "\x09localhost\x00";
    std.mem.writeInt(u16, resp[i + 10 ..][0..2], rdata.len, .big);
    @memcpy(resp[i + 12 ..][0..rdata.len], rdata);
    i += 12 + rdata.len;

    var out: [256]u8 = undefined;
    const name = parseResponse(resp[0..i], 0xbeef, &out).?;
    try std.testing.expectEqualStrings("localhost", name);

    // Wrong id is rejected.
    try std.testing.expectEqual(@as(?[]const u8, null), parseResponse(resp[0..i], 0xbeee, &out));
}

test "hosts file lookup" {
    var out: [256]u8 = undefined;
    // Most systems map 127.0.0.1 in /etc/hosts; tolerate absence.
    _ = lookupHostsFile(.{ .v4 = .{ 127, 0, 0, 1 } }, &out, "/etc/hosts");
}

test "fuzz: DNS response parser never crashes" {
    try std.testing.fuzz({}, fuzzParse, .{});
}

fn fuzzParse(_: void, smith: *std.testing.Smith) !void {
    var packet: [512]u8 = undefined;
    smith.bytes(&packet);
    const len: usize = smith.valueRangeAtMost(u16, 0, packet.len);
    const id = smith.value(u16);
    var out: [256]u8 = undefined;
    _ = parseResponse(packet[0..len], id, &out);
}
