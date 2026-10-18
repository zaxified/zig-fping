//! Reverse DNS (PTR) lookups in pure Zig, no libc and no std.Io instance:
//! /etc/hosts first, then a minimal DNS client (UDP, RFC 1035) against up to
//! three nameservers from /etc/resolv.conf, with glibc-style failover:
//! attempts outside, servers inside; the next server on timeout, SERVFAIL,
//! NOTIMP, REFUSED or TC=1 (no TCP fallback); stop at once on NXDOMAIN or an
//! empty NOERROR. Responses must come from the connected server and echo the
//! question (RFC 5452).
//!
//! std.Io.net.HostName only implements forward lookups (A/AAAA/CNAME), so
//! fping's -n/-d (getnameinfo) needs this hand-rolled PTR client.

const std = @import("std");
const linux = std.os.linux;
const netutil = @import("netutil.zig");

pub const Address = union(enum) {
    v4: [4]u8,
    v6: [16]u8,
};

// Divergence from glibc (RES_TIMEOUT 5 s), see CHANGELOG "Known divergences":
// 3 servers x 2 attempts x 5 s would stall a large run on one dead resolver.
const default_timeout_ms = 2000;
const default_attempts = 2;

pub const Options = struct {
    /// Per-server wait. null: `options timeout:N` from resolv.conf, else 2 s.
    timeout_ms: ?u32 = null,
    /// Passes over the server list. null: `options attempts:N`, else 2.
    attempts: ?u8 = null,
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
    // A file larger than the buffer is cut at the last whole line.
    const content = wholeLines(netutil.readFile(path, &buf) orelse return null, buf.len);
    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    while (lines.next()) |line| {
        const uncommented = line[0 .. std.mem.findScalar(u8, line, '#') orelse line.len];
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

/// Decompress a DNS name starting at `start` (RFC 1035 4.1.4) into `out`
/// as dotted text. Returns the bytes consumed at `start` and the name.
///
/// std.Io.net.HostName.expand cannot be used here: it validates the result
/// as an RFC 1123 host name, so legal DNS owner names such as RFC 2317
/// classless delegations ("5.0/26.2.0.192.in-addr.arpa") or PTR targets
/// with underscores made the whole lookup fail, while fping's
/// getnameinfo() returns them.
fn expandName(packet: []const u8, start: usize, out: []u8) ?struct { usize, []const u8 } {
    var i = start;
    var len: usize = 0;
    var consumed: ?usize = null;
    // Every length byte read after a pointer jump must lie before that
    // pointer, so pointer positions strictly decrease: the walk terminates
    // and reference loops (or forward pointers, which RFC 1035 does not
    // allow: "a prior occurance") are rejected.
    var limit = packet.len;
    while (true) {
        if (i >= limit) return null;
        const c = packet[i];
        switch (c & 0xc0) {
            0xc0 => {
                if (i + 1 >= packet.len) return null;
                const target = (@as(usize, c & 0x3f) << 8) | packet[i + 1];
                if (consumed == null) consumed = i + 2 - start;
                limit = i;
                i = target;
            },
            0x00 => {
                if (c == 0) return .{ consumed orelse i + 1 - start, out[0..len] };
                const label_len: usize = c;
                if (i + 1 + label_len > packet.len) return null;
                const dot: usize = @intFromBool(len != 0);
                if (len + dot + label_len > out.len) return null;
                if (dot != 0) out[len] = '.';
                @memcpy(out[len + dot ..][0..label_len], packet[i + 1 ..][0..label_len]);
                len += dot + label_len;
                i += 1 + label_len;
            },
            else => return null, // 0x40/0x80: reserved label types
        }
    }
}

const rtype_cname = 5;

/// What a received packet means for the query in flight.
const Reply = union(enum) {
    /// PTR target for the query name (points into the caller's `out`).
    name: []const u8,
    /// Definitive "no name": NXDOMAIN, or NOERROR without a usable PTR.
    /// The caller stops at once (glibc: a negative answer is not retried).
    none,
    /// SERVFAIL, NOTIMP, REFUSED, any other error rcode, TC=1 (no TCP
    /// fallback here) or a malformed answer: try the next nameserver.
    next_server,
    /// Not an answer to our query (wrong id, not a response, question not
    /// echoed): drop it and keep waiting (RFC 5452).
    ignore,
};

/// Classify a DNS response to the PTR query `qname` (wire format) with
/// transaction `id`. Only PTR records owned by the query name are taken,
/// after following CNAMEs in packet order (RFC 2317 classless delegation
/// answers `CNAME -> 5.0/26.2.0.192.in-addr.arpa` plus a PTR for that
/// target, as glibc's getanswer does).
fn classify(packet: []const u8, id: u16, qname: []const u8, out: []u8) Reply {
    if (packet.len < 12) return .ignore;
    if (std.mem.readInt(u16, packet[0..2], .big) != id) return .ignore;
    if (packet[2] & 0x80 == 0) return .ignore; // not a response
    const rcode = packet[3] & 0x0f;
    const qdcount = std.mem.readInt(u16, packet[4..6], .big);
    const ancount = std.mem.readInt(u16, packet[6..8], .big);

    var i: usize = 12;
    switch (qdcount) {
        // Some servers send an error without echoing the question.
        0 => if (rcode == 0 or rcode == 3) return .ignore,
        1 => {
            if (packet.len < i + qname.len + 4) return .ignore;
            if (!std.ascii.eqlIgnoreCase(packet[i..][0..qname.len], qname)) return .ignore;
            i += qname.len;
            if (std.mem.readInt(u16, packet[i..][0..2], .big) != qtype_ptr) return .ignore;
            if (std.mem.readInt(u16, packet[i + 2 ..][0..2], .big) != qclass_in) return .ignore;
            i += 4;
        },
        else => return .ignore,
    }
    if (packet[2] & 0x02 != 0) return .next_server; // TC
    switch (rcode) {
        0 => {},
        3 => return .none, // NXDOMAIN
        else => return .next_server,
    }

    var want_buf: [max_name_len]u8 = undefined;
    var want: []const u8 = (expandName(packet, 12, &want_buf) orelse return .next_server)[1];
    var name_buf: [max_name_len]u8 = undefined;
    var tmp_buf: [max_name_len]u8 = undefined;

    var left = ancount;
    while (left > 0) : (left -= 1) {
        const consumed, const owner = expandName(packet, i, &name_buf) orelse return .next_server;
        i += consumed;
        if (i + 10 > packet.len) return .next_server;
        const rr_type = std.mem.readInt(u16, packet[i..][0..2], .big);
        const rdlength = std.mem.readInt(u16, packet[i + 8 ..][0..2], .big);
        i += 10;
        if (i + rdlength > packet.len) return .next_server;
        if (std.ascii.eqlIgnoreCase(owner, want)) {
            if (rr_type == qtype_ptr) {
                _, const host = expandName(packet, i, out) orelse return .next_server;
                if (host.len == 0) return .none; // root name: nothing to print
                return .{ .name = host };
            }
            if (rr_type == rtype_cname) {
                _, const target = expandName(packet, i, &tmp_buf) orelse return .next_server;
                @memcpy(want_buf[0..target.len], target);
                want = want_buf[0..target.len];
            }
        }
        i += rdlength;
    }
    return .none; // NOERROR without a PTR for the name
}

/// Longest dotted text of a wire-format name (255 octets on the wire).
const max_name_len = 254;

const Nameserver = union(enum) {
    v4: linux.sockaddr.in,
    v6: linux.sockaddr.in6,
};

// glibc limits (resolv.h): MAXNS, RES_MAXRETRANS, RES_MAXRETRY.
const max_nameservers = 3;
const max_timeout_s = 30;
const max_attempts = 5;

/// The parts of resolv.conf this client honours.
const ResolvConf = struct {
    servers: [max_nameservers]Nameserver = undefined,
    n_servers: usize = 0,
    /// `options timeout:N` (seconds), null when absent.
    timeout_s: ?u32 = null,
    /// `options attempts:N`, null when absent.
    attempts: ?u8 = null,
    // `options rotate` is not implemented: a process doing one lookup per
    // target gains nothing from rotating a list it walks once.

    fn serverList(self: *const ResolvConf) []const Nameserver {
        return self.servers[0..self.n_servers];
    }
};

/// Parse resolv.conf text: up to three `nameserver` lines (glibc MAXNS,
/// extras are ignored) and `options timeout:N attempts:N`. Like glibc a
/// later `options` value overrides an earlier one, timeout is capped at 30
/// and attempts at 5, and 0 is ignored.
fn parseResolvConf(content: []const u8) ResolvConf {
    var conf: ResolvConf = .{};
    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const key = words.next() orelse continue;
        if (std.mem.eql(u8, key, "nameserver")) {
            if (conf.n_servers == max_nameservers) continue;
            const ip_text = words.next() orelse continue;
            const ip = std.Io.net.IpAddress.parse(ip_text, dns_port) catch continue;
            conf.servers[conf.n_servers] = switch (ip) {
                .ip4 => |a| .{ .v4 = .{
                    .port = std.mem.nativeToBig(u16, dns_port),
                    .addr = std.mem.bytesToValue(u32, &a.bytes),
                } },
                .ip6 => |a| .{ .v6 = .{
                    .port = std.mem.nativeToBig(u16, dns_port),
                    .flowinfo = 0,
                    .addr = a.bytes,
                    .scope_id = 0,
                } },
            };
            conf.n_servers += 1;
        } else if (std.mem.eql(u8, key, "options")) {
            while (words.next()) |opt| {
                if (std.mem.startsWith(u8, opt, "timeout:")) {
                    const v = std.fmt.parseInt(u32, opt["timeout:".len..], 10) catch continue;
                    if (v != 0) conf.timeout_s = @min(v, max_timeout_s);
                } else if (std.mem.startsWith(u8, opt, "attempts:")) {
                    const v = std.fmt.parseInt(u8, opt["attempts:".len..], 10) catch continue;
                    if (v != 0) conf.attempts = @min(v, max_attempts);
                }
            }
        }
    }
    return conf;
}

/// Keep only whole lines of a file read into a buffer of `buf_len` bytes.
/// A file that filled the buffer was truncated; the cut-off partial last
/// line is dropped so it cannot be misread as a shorter, wrong entry.
fn wholeLines(content: []const u8, buf_len: usize) []const u8 {
    if (content.len < buf_len) return content;
    const nl = std.mem.findScalarLast(u8, content, '\n') orelse return content[0..0];
    return content[0 .. nl + 1];
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

/// Fresh transaction id from the kernel CSPRNG; clock/pid only if the
/// getrandom syscall fails.
fn randomId() u16 {
    var b: [2]u8 = undefined;
    const rc = linux.getrandom(&b, b.len, 0);
    if (linux.errno(rc) == .SUCCESS and rc == b.len) return std.mem.readInt(u16, &b, .little);
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @bitCast(@as(i64, ts.nsec) ^ (@as(i64, linux.getpid()) << 20));
    var prng: std.Random.DefaultPrng = .init(seed);
    return prng.random().int(u16);
}

/// Ask one nameserver. The UDP socket is connect(2)ed so the kernel drops
/// datagrams from any other source (RFC 5452). A timeout, ICMP refusal or
/// send error is `.next_server`.
fn queryOne(ns: Nameserver, query: []const u8, id: u16, qname: []const u8, timeout_ms: u32, out: []u8) Reply {
    const domain: u32 = switch (ns) {
        .v4 => linux.AF.INET,
        .v6 => linux.AF.INET6,
    };
    const rc = linux.socket(domain, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(rc) != .SUCCESS) return .next_server;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);

    const conn_rc = switch (ns) {
        .v4 => |*sa| linux.connect(fd, sa, @sizeOf(linux.sockaddr.in)),
        .v6 => |*sa| linux.connect(fd, sa, @sizeOf(linux.sockaddr.in6)),
    };
    if (linux.errno(conn_rc) != .SUCCESS) return .next_server;
    const send_rc = linux.sendto(fd, query.ptr, query.len, linux.MSG.NOSIGNAL, null, 0);
    if (linux.errno(send_rc) != .SUCCESS) return .next_server;

    const deadline = nowMs() + timeout_ms;
    while (true) {
        const remaining = deadline - nowMs();
        if (remaining <= 0) return .next_server;
        var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        var wait: linux.timespec = .{
            .sec = @intCast(@divTrunc(remaining, 1000)),
            .nsec = @as(isize, @intCast(@rem(remaining, 1000))) * std.time.ns_per_ms,
        };
        const poll_rc = linux.ppoll(&fds, 1, &wait, null);
        switch (linux.errno(poll_rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return .next_server,
        }
        if (poll_rc == 0) return .next_server;

        var response: [4096]u8 = undefined;
        const recv_rc = linux.recvfrom(fd, &response, response.len, 0, null, null);
        switch (linux.errno(recv_rc)) {
            .SUCCESS => {},
            .AGAIN, .INTR => continue,
            else => return .next_server, // e.g. ECONNREFUSED from ICMP
        }
        switch (classify(response[0..recv_rc], id, qname, out)) {
            .ignore => continue,
            else => |r| return r,
        }
    }
}

/// glibc res_send order: attempts outside, servers inside. Stops at the
/// first definitive answer (a name, or NXDOMAIN / empty NOERROR = null).
fn queryServers(
    servers: []const Nameserver,
    addr: Address,
    id: u16,
    attempts: u8,
    timeout_ms: u32,
    out: []u8,
) ?[]const u8 {
    var query: [512]u8 = undefined;
    const query_len = buildQuery(&query, id, addr);
    var qname_buf: [max_name_len + 2]u8 = undefined;
    const qname_len = writeQname(&qname_buf, addr);

    var attempt: u8 = 0;
    while (attempt < attempts) : (attempt += 1) {
        for (servers) |ns| {
            switch (queryOne(ns, query[0..query_len], id, qname_buf[0..qname_len], timeout_ms, out)) {
                .name => |n| return n,
                .none => return null,
                .next_server, .ignore => {},
            }
        }
    }
    return null;
}

fn lookupDns(addr: Address, out: []u8, opts: Options) ?[]const u8 {
    var buf: [16 * 1024]u8 = undefined;
    const content = netutil.readFile(opts.resolv_conf_path, &buf) orelse return null;
    const conf = parseResolvConf(wholeLines(content, buf.len));
    if (conf.n_servers == 0) return null;
    // Explicit caller values win; otherwise resolv.conf; otherwise the
    // library defaults (2 s, 2 attempts).
    const timeout_ms = opts.timeout_ms orelse if (conf.timeout_s) |t| t * 1000 else default_timeout_ms;
    const attempts = opts.attempts orelse conf.attempts orelse default_attempts;
    return queryServers(conf.serverList(), addr, randomId(), attempts, timeout_ms, out);
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

const test_addr: Address = .{ .v4 = .{ 192, 0, 2, 5 } };
const test_qname = "\x015\x012\x010\x03192\x07in-addr\x04arpa\x00";

const TestRr = struct { owner: []const u8, rtype: u16, rdata: []const u8 };

/// Build a response to the PTR query for `addr` with the given header bits
/// and answer records.
fn testResponse(buf: []u8, id: u16, addr: Address, rcode: u8, tc: bool, rrs: []const TestRr) []const u8 {
    var i = buildQuery(buf, id, addr);
    buf[2] |= 0x80; // QR
    if (tc) buf[2] |= 0x02;
    buf[3] = rcode;
    std.mem.writeInt(u16, buf[6..8], @intCast(rrs.len), .big);
    for (rrs) |rr| {
        @memcpy(buf[i..][0..rr.owner.len], rr.owner);
        i += rr.owner.len;
        std.mem.writeInt(u16, buf[i..][0..2], rr.rtype, .big);
        std.mem.writeInt(u16, buf[i + 2 ..][0..2], qclass_in, .big);
        std.mem.writeInt(u32, buf[i + 4 ..][0..4], 60, .big);
        std.mem.writeInt(u16, buf[i + 8 ..][0..2], @intCast(rr.rdata.len), .big);
        @memcpy(buf[i + 10 ..][0..rr.rdata.len], rr.rdata);
        i += 10 + rr.rdata.len;
    }
    return buf[0..i];
}

const ptr_rr: TestRr = .{ .owner = test_addr_owner, .rtype = qtype_ptr, .rdata = "\x09localhost\x00" };
const test_addr_owner = "\xc0\x0c"; // pointer to the question name

test "qname constant matches writeQname" {
    var buf: [128]u8 = undefined;
    const len = writeQname(&buf, test_addr);
    try std.testing.expectEqualSlices(u8, test_qname, buf[0..len]);
}

test "classify: PTR answer" {
    var buf: [512]u8 = undefined;
    var out: [256]u8 = undefined;
    const pkt = testResponse(&buf, 0xbeef, test_addr, 0, false, &.{ptr_rr});
    try std.testing.expectEqualStrings("localhost", classify(pkt, 0xbeef, test_qname, &out).name);
    // Wrong id and not-a-response are ignored, not answers.
    try std.testing.expect(classify(pkt, 0xbeee, test_qname, &out) == .ignore);
    buf[2] &= 0x7f;
    try std.testing.expect(classify(pkt, 0xbeef, test_qname, &out) == .ignore);
}

test "classify: rcode and TC actions" {
    var buf: [512]u8 = undefined;
    var out: [256]u8 = undefined;
    const nx = testResponse(&buf, 1, test_addr, 3, false, &.{});
    try std.testing.expect(classify(nx, 1, test_qname, &out) == .none);
    for ([_]u8{ 1, 2, 4, 5 }) |rc| { // FORMERR SERVFAIL NOTIMP REFUSED
        const r = testResponse(&buf, 1, test_addr, rc, false, &.{});
        try std.testing.expect(classify(r, 1, test_qname, &out) == .next_server);
    }
    const tc = testResponse(&buf, 1, test_addr, 0, true, &.{ptr_rr});
    try std.testing.expect(classify(tc, 1, test_qname, &out) == .next_server);
    const empty = testResponse(&buf, 1, test_addr, 0, false, &.{});
    try std.testing.expect(classify(empty, 1, test_qname, &out) == .none);
}

test "classify: spoofed question is rejected" {
    var buf: [512]u8 = undefined;
    var out: [256]u8 = undefined;
    // Valid response, but to a query for another address.
    const other = testResponse(&buf, 7, .{ .v4 = .{ 192, 0, 2, 6 } }, 0, false, &.{ptr_rr});
    try std.testing.expect(classify(other, 7, test_qname, &out) == .ignore);
    // Wrong qtype.
    const pkt = testResponse(&buf, 7, test_addr, 0, false, &.{ptr_rr});
    buf[12 + test_qname.len + 1] = 1; // A instead of PTR
    try std.testing.expect(classify(pkt, 7, test_qname, &out) == .ignore);
    // NXDOMAIN to a foreign question must not end the lookup either.
    const nx = testResponse(&buf, 7, .{ .v4 = .{ 192, 0, 2, 6 } }, 3, false, &.{});
    try std.testing.expect(classify(nx, 7, test_qname, &out) == .ignore);
}

test "classify: PTR with a foreign owner is ignored" {
    var buf: [512]u8 = undefined;
    var out: [256]u8 = undefined;
    const foreign: TestRr = .{ .owner = "\x017\x012\x010\x03192\x07in-addr\x04arpa\x00", .rtype = qtype_ptr, .rdata = "\x04evil\x00" };
    const pkt = testResponse(&buf, 9, test_addr, 0, false, &.{ foreign, ptr_rr });
    try std.testing.expectEqualStrings("localhost", classify(pkt, 9, test_qname, &out).name);
    const only = testResponse(&buf, 9, test_addr, 0, false, &.{foreign});
    try std.testing.expect(classify(only, 9, test_qname, &out) == .none);
}

test "classify: CNAME to a classless zone, then PTR (RFC 2317)" {
    var buf: [512]u8 = undefined;
    var out: [256]u8 = undefined;
    const target = classless_target;
    const cname: TestRr = .{ .owner = test_addr_owner, .rtype = rtype_cname, .rdata = target };
    // The PTR owner is the CNAME target; the PTR data has an underscore.
    const ptr: TestRr = .{ .owner = target, .rtype = qtype_ptr, .rdata = "\x07my_host\x07example\x00" };
    const pkt = testResponse(&buf, 0x1234, test_addr, 0, false, &.{ cname, ptr });
    try std.testing.expectEqualStrings("my_host.example", classify(pkt, 0x1234, test_qname, &out).name);
    // A PTR for the CNAME target without the CNAME is a foreign owner.
    const lone = testResponse(&buf, 0x1234, test_addr, 0, false, &.{ptr});
    try std.testing.expect(classify(lone, 0x1234, test_qname, &out) == .none);
}

test "resolv.conf: nameservers and options" {
    const conf = parseResolvConf(
        \\# comment
        \\search example.test
        \\nameserver 192.0.2.1
        \\nameserver 2001:db8::1
        \\nameserver notanip
        \\nameserver 192.0.2.2
        \\nameserver 192.0.2.3
        \\options ndots:2 timeout:3 attempts:4 rotate
        \\
    );
    try std.testing.expectEqual(@as(usize, 3), conf.n_servers); // MAXNS
    try std.testing.expect(conf.servers[1] == .v6);
    try std.testing.expectEqual(@as(?u32, 3), conf.timeout_s);
    try std.testing.expectEqual(@as(?u8, 4), conf.attempts);
    // Caps, zero ignored, later line overrides.
    const capped = parseResolvConf("options timeout:99 attempts:0\noptions attempts:9\n");
    try std.testing.expectEqual(@as(?u32, 30), capped.timeout_s);
    try std.testing.expectEqual(@as(?u8, 5), capped.attempts);
    const none = parseResolvConf("nameserver 192.0.2.1\n");
    try std.testing.expectEqual(@as(?u32, null), none.timeout_s);
    try std.testing.expectEqual(@as(?u8, null), none.attempts);
}

test "wholeLines drops a truncated last line" {
    try std.testing.expectEqualStrings("a\nb", wholeLines("a\nb", 16));
    try std.testing.expectEqualStrings("a\nb\n", wholeLines("a\nb\nc", 5));
    try std.testing.expectEqualStrings("", wholeLines("abcde", 5));
}

/// Loopback UDP DNS stub: answers the k-th request with script[k], a list
/// of packets (empty = stay silent); the query id is patched into each.
const Stub = struct {
    fd: i32,
    ns: Nameserver,
    script: []const []const []const u8,
    served: usize = 0,
    stop: std.atomic.Value(bool) = .init(false),

    fn open(script: []const []const []const u8) !Stub {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        var sa: linux.sockaddr.in = .{
            .port = 0,
            .addr = std.mem.bytesToValue(u32, &[4]u8{ 127, 0, 0, 1 }),
        };
        if (linux.errno(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) != .SUCCESS)
            return error.SkipZigTest;
        var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        if (linux.errno(linux.getsockname(fd, @ptrCast(&sa), &len)) != .SUCCESS)
            return error.SkipZigTest;
        return .{ .fd = fd, .ns = .{ .v4 = sa }, .script = script };
    }

    fn run(self: *Stub) void {
        for (self.script) |packets| {
            var fds = [_]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
            var waited: usize = 0;
            while (true) {
                if (self.stop.load(.acquire) or waited >= 250) return;
                var wait: linux.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
                const n = linux.ppoll(&fds, 1, &wait, null);
                if (linux.errno(n) == .SUCCESS and n > 0) break;
                waited += 1;
            }
            var req: [512]u8 = undefined;
            var src: linux.sockaddr.in = undefined;
            var src_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            const got = linux.recvfrom(self.fd, &req, req.len, 0, @ptrCast(&src), &src_len);
            if (linux.errno(got) != .SUCCESS or got < 12) return;
            self.served += 1;
            for (packets) |p| {
                var pkt: [512]u8 = undefined;
                @memcpy(pkt[0..p.len], p);
                pkt[0] = req[0];
                pkt[1] = req[1];
                _ = linux.sendto(self.fd, &pkt, p.len, linux.MSG.NOSIGNAL, @ptrCast(&src), src_len);
            }
        }
    }

    fn close(self: *Stub) void {
        _ = linux.close(self.fd);
    }
};

/// Run `queryServers` against stubs (one thread each) and return the result;
/// `out` receives the name.
fn runStubs(stubs: []Stub, out: []u8, attempts: u8, timeout_ms: u32) !?[]const u8 {
    var servers: [max_nameservers]Nameserver = undefined;
    var threads: [max_nameservers]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        for (stubs) |*s| s.stop.store(true, .release);
        for (threads[0..spawned]) |t| t.join();
    }
    for (stubs, 0..) |*s, k| {
        servers[k] = s.ns;
        threads[k] = std.Thread.spawn(.{}, Stub.run, .{s}) catch return error.SkipZigTest;
        spawned += 1;
    }
    return queryServers(servers[0..stubs.len], test_addr, 0x4242, attempts, timeout_ms, out);
}

const classless_target = "\x015\x040/26\x012\x010\x03192\x07in-addr\x04arpa\x00";

/// Canned replies (id patched by the stub), in static storage so the stub
/// threads can read them.
var reply_store: [7][512]u8 = undefined;
const Replies = struct { ptr: []const u8, servfail: []const u8, refused: []const u8, nxdomain: []const u8, tc: []const u8, cname: []const u8, spoof: []const u8 };

fn replies() Replies {
    const other: Address = .{ .v4 = .{ 192, 0, 2, 6 } };
    return .{
        .ptr = testResponse(&reply_store[0], 0, test_addr, 0, false, &.{ptr_rr}),
        .servfail = testResponse(&reply_store[1], 0, test_addr, 2, false, &.{}),
        .refused = testResponse(&reply_store[2], 0, test_addr, 5, false, &.{}),
        .nxdomain = testResponse(&reply_store[3], 0, test_addr, 3, false, &.{}),
        .tc = testResponse(&reply_store[4], 0, test_addr, 0, true, &.{}),
        .cname = testResponse(&reply_store[5], 0, test_addr, 0, false, &.{
            .{ .owner = test_addr_owner, .rtype = rtype_cname, .rdata = classless_target },
            .{ .owner = classless_target, .rtype = qtype_ptr, .rdata = "\x07my_host\x07example\x00" },
        }),
        .spoof = testResponse(&reply_store[6], 0, other, 0, false, &.{ptr_rr}),
    };
}

test "live: first server dead, second answers" {
    const r = replies();
    var stubs = [_]Stub{
        try Stub.open(&.{&.{}}), // silent: times out
        try Stub.open(&.{&.{r.ptr}}),
    };
    defer for (&stubs) |*s| s.close();
    var out: [256]u8 = undefined;
    const name = try runStubs(&stubs, &out, 2, 150);
    try std.testing.expectEqualStrings("localhost", name.?);
    try std.testing.expectEqual(@as(usize, 1), stubs[0].served);
    try std.testing.expectEqual(@as(usize, 1), stubs[1].served);
}

test "live: SERVFAIL, REFUSED and TC move on to the next server" {
    const r = replies();
    var stubs = [_]Stub{
        try Stub.open(&.{&.{r.servfail}}),
        try Stub.open(&.{&.{r.refused}}),
        try Stub.open(&.{&.{r.ptr}}),
    };
    defer for (&stubs) |*s| s.close();
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("localhost", (try runStubs(&stubs, &out, 2, 500)).?);

    var tc = [_]Stub{
        try Stub.open(&.{&.{r.tc}}),
        try Stub.open(&.{&.{r.ptr}}),
    };
    defer for (&tc) |*s| s.close();
    try std.testing.expectEqualStrings("localhost", (try runStubs(&tc, &out, 2, 500)).?);
}

test "live: NXDOMAIN ends the lookup without a retry" {
    const r = replies();
    var stubs = [_]Stub{
        try Stub.open(&.{ &.{r.nxdomain}, &.{r.nxdomain} }),
        try Stub.open(&.{&.{r.ptr}}),
    };
    defer for (&stubs) |*s| s.close();
    var out: [256]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), try runStubs(&stubs, &out, 2, 500));
    try std.testing.expectEqual(@as(usize, 1), stubs[0].served);
    try std.testing.expectEqual(@as(usize, 0), stubs[1].served);
}

test "live: attempts outside, servers inside" {
    const r = replies();
    // Both servers time out on the first pass; the second pass reaches
    // server 0 again (not server 1 twice in a row).
    var stubs = [_]Stub{
        try Stub.open(&.{ &.{}, &.{r.ptr} }),
        try Stub.open(&.{&.{}}),
    };
    defer for (&stubs) |*s| s.close();
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("localhost", (try runStubs(&stubs, &out, 2, 150)).?);
    try std.testing.expectEqual(@as(usize, 2), stubs[0].served);
    try std.testing.expectEqual(@as(usize, 1), stubs[1].served);
}

test "live: spoofed answer is skipped, the real one accepted" {
    const r = replies();
    var stubs = [_]Stub{try Stub.open(&.{&.{ r.spoof, r.ptr }})};
    defer stubs[0].close();
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("localhost", (try runStubs(&stubs, &out, 1, 500)).?);
}

test "live: CNAME to PTR (RFC 2317) resolves" {
    const r = replies();
    var stubs = [_]Stub{try Stub.open(&.{&.{r.cname}})};
    defer stubs[0].close();
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("my_host.example", (try runStubs(&stubs, &out, 1, 500)).?);
}

// ---- fuzzing ------------------------------------------------------------------
//
// `classify` and `expandName` parse bytes from the network. The harness is
// generic over its source of choices (fuzz_driver.Rng under scripts/fuzz.sh,
// a Smith script under the optional `zig build test --fuzz`). Uniform random
// octets almost never echo the question, so half of every run mutates one of
// the real responses below instead.

const fuzz_driver = @import("fuzz_driver");

const fz_header_ok = "\x12\x34\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00"; // id 0x1234, QR RD RA, qd=1 an=1
const fz_question = test_qname ++ "\x00\x0c\x00\x01"; // PTR IN
const fz_ptr_rr = "\xc0\x0c\x00\x0c\x00\x01\x00\x00\x00\x3c"; // owner = pointer to the question, PTR IN, ttl 60

/// Real responses for 5.2.0.192.in-addr.arpa (id 0x1234): a PTR with a
/// compression pointer for its owner, a PTR whose target is itself compressed,
/// RFC 2317 CNAME -> PTR (owner spelled out, and as a pointer into the CNAME's
/// rdata), the negative and failure rcodes, TC, a pointer loop, a foreign
/// owner, a wrong question, and packets cut at the header.
const dns_seeds = [_][]const u8{
    fuzz_driver.seed(fz_header_ok ++ fz_question ++ fz_ptr_rr ++ "\x00\x0b\x09localhost\x00"),
    fuzz_driver.seed(fz_header_ok ++ fz_question ++ fz_ptr_rr ++ "\x00\x07\x04host\xc0\x16"), // target ends in a pointer to "in-addr.arpa"
    fuzz_driver.seed("\x12\x34\x81\x80\x00\x01\x00\x02\x00\x00\x00\x00" ++ fz_question ++
        "\xc0\x0c\x00\x05\x00\x01\x00\x00\x00\x3c\x00\x1d" ++ classless_target ++
        classless_target ++ "\x00\x0c\x00\x01\x00\x00\x00\x3c\x00\x11\x07my_host\x07example\x00"), // RFC 2317
    fuzz_driver.seed("\x12\x34\x81\x80\x00\x01\x00\x02\x00\x00\x00\x00" ++ fz_question ++
        "\xc0\x0c\x00\x05\x00\x01\x00\x00\x00\x3c\x00\x1d" ++ classless_target ++
        "\xc0\x34\x00\x0c\x00\x01\x00\x00\x00\x3c\x00\x11\x07my_host\x07example\x00"), // RFC 2317, PTR owner = pointer into the CNAME rdata
    fuzz_driver.seed("\x12\x34\x81\x83\x00\x01\x00\x00\x00\x00\x00\x00" ++ fz_question), // NXDOMAIN
    fuzz_driver.seed("\x12\x34\x81\x82\x00\x01\x00\x00\x00\x00\x00\x00" ++ fz_question), // SERVFAIL
    fuzz_driver.seed("\x12\x34\x83\x80\x00\x01\x00\x01\x00\x00\x00\x00" ++ fz_question ++ fz_ptr_rr ++ "\x00\x0b\x09localhost\x00"), // TC=1
    fuzz_driver.seed("\x12\x34\x81\x80\x00\x01\x00\x00\x00\x00\x00\x00" ++ fz_question), // NOERROR, no answer
    fuzz_driver.seed("\x12\x34\x81\x82\x00\x00\x00\x00\x00\x00\x00\x00"), // SERVFAIL without the question
    fuzz_driver.seed(fz_header_ok ++ fz_question ++ "\xc0\x28\x00\x0c\x00\x01\x00\x00\x00\x3c\x00\x00"), // owner pointer to itself
    fuzz_driver.seed(fz_header_ok ++ fz_question ++ "\x01\x37\x01\x32\x01\x30\x03192\x07in-addr\x04arpa\x00\x00\x0c\x00\x01\x00\x00\x00\x3c\x00\x06\x04evil\x00"), // PTR for another address
    fuzz_driver.seed("\x00\x01\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00" ++ fz_question ++ fz_ptr_rr ++ "\x00\x0b\x09localhost\x00"), // wrong id
    fuzz_driver.seed("\x12\x34\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00" ++ test_qname ++ "\x00\x01\x00\x01" ++ fz_ptr_rr ++ "\x00\x0b\x09localhost\x00"), // question type A
    fuzz_driver.seed(fz_header_ok ++ fz_question ++ fz_ptr_rr ++ "\x00\x03\x40ab"), // reserved label type in the target
    fuzz_driver.seed(fz_header_ok), // header only
    fuzz_driver.seed("\x12\x34\x81\x80\x00\x01\x00"), // shorter than a header
};

fn dnsHarness(comptime S: type, src: *S, gpa: std.mem.Allocator) anyerror!void {
    _ = gpa;
    var buf: [512]u8 = undefined;
    const len: usize = src.slice(&buf);
    if (len != 0) fuzz_driver.hit("raw_nonempty");
    // Half the time the packet's own id, so the id gate is passed.
    const id: u16 = if (len >= 2 and src.index(2) == 0) std.mem.readInt(u16, buf[0..2], .big) else src.value(u16);
    try checkDns(buf[0..len], id, src.index(len + 2));

    const body = fuzz_driver.frameOf(dns_seeds[src.index(dns_seeds.len)]);
    var pkt: [512]u8 = undefined;
    @memcpy(pkt[0..body.len], body);
    var plen = body.len;
    for (0..src.index(4)) |_| {
        pkt[src.index(plen)] = src.value(u8);
        fuzz_driver.hit("mutated");
    }
    if (src.index(4) == 0) {
        plen = src.index(plen + 1);
        fuzz_driver.hit("truncated");
    }
    const seed_id: u16 = if (src.index(8) == 0) src.value(u16) else 0x1234;
    try checkDns(pkt[0..plen], seed_id, src.index(plen + 2));
}

fn checkDns(packet: []const u8, id: u16, start: usize) !void {
    var out: [256]u8 = undefined;
    switch (classify(packet, id, test_qname, &out)) {
        .name => |n| {
            fuzz_driver.hit("name");
            try std.testing.expect(n.len > 0 and n.len <= out.len);
            // the name lives in the caller's buffer
            try std.testing.expect(@intFromPtr(n.ptr) >= @intFromPtr(&out) and
                @intFromPtr(n.ptr) + n.len <= @intFromPtr(&out) + out.len);
            if (std.mem.startsWith(u8, n, "my_host")) fuzz_driver.hit("name_cname");
            if (std.mem.endsWith(u8, n, "in-addr.arpa")) fuzz_driver.hit("name_compressed");
        },
        .none => fuzz_driver.hit("none"),
        .next_server => fuzz_driver.hit("next_server"),
        .ignore => fuzz_driver.hit("ignore"),
    }
    if (packet.len < 12) try std.testing.expect(classify(packet, id, test_qname, &out) == .ignore);

    var name_out: [256]u8 = undefined;
    if (expandName(packet, start, &name_out)) |r| {
        fuzz_driver.hit("expand_ok");
        const consumed, const name = r;
        try std.testing.expect(consumed >= 1 and start + consumed <= packet.len);
        try std.testing.expect(name.len <= name_out.len);
    } else fuzz_driver.hit("expand_null");
}

test "fuzz: DNS response parser never crashes" {
    // Optional `zig build test --fuzz`; a plain run replays the corpus once.
    try std.testing.fuzz({}, fuzz_driver.smithEntry(dnsHarness, 1024), .{ .corpus = &dns_seeds });
}

test "fuzz driver: rdns" {
    try fuzz_driver.run(dnsHarness, .{ .name = "rdns" });
}

test "fuzz harness: rdns reaches every branch in 500 seeds" {
    try fuzz_driver.expectReach(dnsHarness, "rdns", 500, &.{
        "raw_nonempty",
        "mutated",
        "truncated",
        "name",
        "name_cname",
        "name_compressed",
        "none",
        "next_server",
        "ignore",
        "expand_ok",
        "expand_null",
    });
}

test "fuzz corpus: rdns seeds classify as documented" {
    var out: [256]u8 = undefined;
    // Indexes match dns_seeds. null = not a `.name`.
    const want = [_]?[]const u8{ "localhost", "host.in-addr.arpa", "my_host.example", "my_host.example", null, null, null, null, null, null, null, null, null, null, null, null };
    for (dns_seeds, want) |sd, w| {
        const r = classify(fuzz_driver.frameOf(sd), 0x1234, test_qname, &out);
        if (w) |name| {
            try std.testing.expectEqualStrings(name, r.name);
        } else try std.testing.expect(r != .name);
    }
    const f = fuzz_driver.frameOf;
    try std.testing.expect(classify(f(dns_seeds[4]), 0x1234, test_qname, &out) == .none);
    try std.testing.expect(classify(f(dns_seeds[5]), 0x1234, test_qname, &out) == .next_server);
    try std.testing.expect(classify(f(dns_seeds[6]), 0x1234, test_qname, &out) == .next_server);
    try std.testing.expect(classify(f(dns_seeds[7]), 0x1234, test_qname, &out) == .none);
    try std.testing.expect(classify(f(dns_seeds[8]), 0x1234, test_qname, &out) == .next_server);
    try std.testing.expect(classify(f(dns_seeds[9]), 0x1234, test_qname, &out) == .next_server);
    try std.testing.expect(classify(f(dns_seeds[10]), 0x1234, test_qname, &out) == .none);
    try std.testing.expect(classify(f(dns_seeds[11]), 0x1234, test_qname, &out) == .ignore);
    try std.testing.expect(classify(f(dns_seeds[12]), 0x1234, test_qname, &out) == .ignore);
    try std.testing.expect(classify(f(dns_seeds[13]), 0x1234, test_qname, &out) == .next_server);
}

test "name expansion rejects pointer loops and truncation" {
    var out: [256]u8 = undefined;
    // Self-pointer and forward pointer loops.
    try std.testing.expect(expandName(&.{ 0xc0, 0x00 }, 0, &out) == null);
    try std.testing.expect(expandName(&.{ 0xc0, 0x02, 0xc0, 0x00 }, 0, &out) == null);
    // Label running past the end.
    try std.testing.expect(expandName(&.{ 0x05, 'a', 'b' }, 0, &out) == null);
    // Pointer to an earlier name: consumed counts only the pointer.
    const pkt = [_]u8{ 0x01, 'a', 0x00, 0x01, 'b', 0xc0, 0x00 };
    const consumed, const name = expandName(&pkt, 3, &out).?;
    try std.testing.expectEqual(@as(usize, 4), consumed);
    try std.testing.expectEqualStrings("b.a", name);
}

test "hosts file lookup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const hosts_fixture =
        \\# comment line
        \\127.0.0.1   localhost.test loopback # trailing comment
        \\::1         ip6-localhost.test
        \\192.0.2.7   nodename.test
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hosts", .data = hosts_fixture });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(std.testing.io, "hosts", &path_buf);
    path_buf[n] = 0;
    const path: [:0]const u8 = path_buf[0..n :0];

    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("localhost.test", lookupHostsFile(.{ .v4 = .{ 127, 0, 0, 1 } }, &out, path).?);
    try std.testing.expectEqualStrings("nodename.test", lookupHostsFile(.{ .v4 = .{ 192, 0, 2, 7 } }, &out, path).?);
    var lo6: [16]u8 = @splat(0);
    lo6[15] = 1;
    try std.testing.expectEqualStrings("ip6-localhost.test", lookupHostsFile(.{ .v6 = lo6 }, &out, path).?);
    try std.testing.expectEqual(@as(?[]const u8, null), lookupHostsFile(.{ .v4 = .{ 192, 0, 2, 99 } }, &out, path));
}
