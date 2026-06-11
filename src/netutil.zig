//! Small Linux helpers shared by the engine and CLI: interface name
//! resolution, raw (Io-less) file reading via direct syscalls, and
//! RFC 6724 destination-address ordering, so the library keeps working
//! without a std.Io instance.

const std = @import("std");
const linux = std.os.linux;
const Addr = @import("pinger.zig").Addr;

/// Resolve an interface name ("eth0") to its index, like if_nametoindex(3).
/// Uses ioctl(SIOCGIFINDEX) on a throwaway UDP socket (no privileges
/// needed).
pub fn ifNameToIndex(name: []const u8) ?u32 {
    if (name.len == 0 or name.len >= linux.IFNAMESIZE) return null;
    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);

    var req: linux.ifreq = std.mem.zeroes(linux.ifreq);
    @memcpy(req.ifrn.name[0..name.len], name);
    if (linux.errno(linux.ioctl(fd, linux.SIOCGIFINDEX, @intFromPtr(&req))) != .SUCCESS)
        return null;
    return @intCast(req.ifru.ivalue);
}

/// Read up to `buf.len` bytes of a file using raw syscalls.
pub fn readFile(path: [:0]const u8, buf: []u8) ?[]u8 {
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    const rc = linux.open(path, flags, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);

    var total: usize = 0;
    while (total < buf.len) {
        const n = linux.read(fd, buf.ptr + total, buf.len - total);
        if (linux.errno(n) != .SUCCESS) return null;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

/// RFC 6724 section 2.1 destination precedence (default policy table).
/// IPv4 addresses count as IPv4-mapped (::ffff:0:0/96).
fn policyPrecedence(addr: Addr) u8 {
    switch (addr) {
        .v4 => return 35,
        .v6 => |sa| {
            const b = sa.addr;
            const loopback = [_]u8{0} ** 15 ++ [_]u8{1};
            if (std.mem.eql(u8, &b, &loopback)) return 50; // ::1/128
            if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff)
                return 35; // ::ffff:0:0/96 (IPv4-mapped)
            if (b[0] == 0x20 and b[1] == 0x02) return 30; // 2002::/16 (6to4)
            if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0 and b[3] == 0)
                return 5; // 2001::/32 (Teredo)
            if ((b[0] & 0xfe) == 0xfc) return 3; // fc00::/7 (ULA)
            if (b[0] == 0xfe and (b[1] & 0xc0) == 0xc0) return 1; // fec0::/10
            if (std.mem.allEqual(u8, b[0..12], 0)) return 1; // ::/96
            return 40; // ::/0
        },
    }
}

/// Route-lookup probe: connect() on a UDP socket sends no packet but fails
/// with ENETUNREACH/EHOSTUNREACH when no route exists — the same trick
/// glibc's getaddrinfo uses for its RFC 6724 reachability rule.
fn destinationReachable(addr: Addr) bool {
    const fam: u32 = switch (addr) {
        .v4 => linux.AF.INET,
        .v6 => linux.AF.INET6,
    };
    const rc = linux.socket(fam, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return true; // cannot probe; assume usable
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);

    var probe = addr;
    const crc = switch (probe) {
        .v4 => |*sa| blk: {
            sa.port = std.mem.nativeToBig(u16, 9); // discard; any port works
            break :blk linux.connect(fd, @ptrCast(sa), @sizeOf(linux.sockaddr.in));
        },
        .v6 => |*sa| blk: {
            sa.port = std.mem.nativeToBig(u16, 9);
            break :blk linux.connect(fd, @ptrCast(sa), @sizeOf(linux.sockaddr.in6));
        },
    };
    return linux.errno(crc) == .SUCCESS;
}

/// Stable-sort addresses the way glibc's getaddrinfo orders results
/// (fping pings the first one): RFC 6724 rule 1 (reachable destinations
/// first, approximated by a route lookup) and rule 6 (higher precedence
/// first). Source-address selection rules are not implemented — they only
/// matter for multihomed corner cases.
pub fn sortByDestinationPolicy(addrs: []Addr) void {
    if (addrs.len < 2) return;
    var keys: [64]u16 = undefined;
    std.debug.assert(addrs.len <= keys.len);
    for (addrs, 0..) |a, i| {
        const reach: u16 = if (destinationReachable(a)) 1 else 0;
        keys[i] = reach << 8 | policyPrecedence(a);
    }
    // Insertion sort keeps it dependency-free and stable for equal keys.
    var i: usize = 1;
    while (i < addrs.len) : (i += 1) {
        const key = keys[i];
        const val = addrs[i];
        var j = i;
        while (j > 0 and keys[j - 1] < key) : (j -= 1) {
            keys[j] = keys[j - 1];
            addrs[j] = addrs[j - 1];
        }
        keys[j] = key;
        addrs[j] = val;
    }
}

test "policy precedence follows RFC 6724 table" {
    try std.testing.expectEqual(@as(u8, 50), policyPrecedence(try .parse("::1")));
    try std.testing.expectEqual(@as(u8, 40), policyPrecedence(try .parse("2606:4700::1111")));
    try std.testing.expectEqual(@as(u8, 35), policyPrecedence(try .parse("192.0.2.1")));
    try std.testing.expectEqual(@as(u8, 30), policyPrecedence(try .parse("2002::1")));
    try std.testing.expectEqual(@as(u8, 5), policyPrecedence(try .parse("2001:0::1")));
    try std.testing.expectEqual(@as(u8, 3), policyPrecedence(try .parse("fd00::1")));
}

test "destination policy prefers ::1 over 127.0.0.1 like glibc" {
    var addrs = [_]Addr{ try .parse("127.0.0.1"), try .parse("::1") };
    // Skip on hosts with IPv6 disabled (reachability then demotes ::1).
    if (!destinationReachable(addrs[1])) return;
    sortByDestinationPolicy(&addrs);
    try std.testing.expectEqual(Addr.parse("::1"), addrs[0]);
}

test "sort is stable for equal keys" {
    var addrs = [_]Addr{ try .parse("127.0.0.2"), try .parse("127.0.0.3") };
    sortByDestinationPolicy(&addrs);
    try std.testing.expectEqual(Addr.parse("127.0.0.2"), addrs[0]);
}

test "ifNameToIndex resolves lo" {
    // "lo" exists on every Linux system; index is usually 1.
    if (ifNameToIndex("lo")) |idx| {
        try std.testing.expect(idx > 0);
    }
    try std.testing.expectEqual(@as(?u32, null), ifNameToIndex("definitely-not-an-iface"));
    try std.testing.expectEqual(@as(?u32, null), ifNameToIndex(""));
}

test "readFile" {
    var buf: [4096]u8 = undefined;
    if (readFile("/proc/self/status", &buf)) |content| {
        try std.testing.expect(content.len > 0);
    }
    try std.testing.expectEqual(@as(?[]u8, null), readFile("/nonexistent-zfping-test", &buf));
}
