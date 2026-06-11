//! Small Linux helpers shared by the engine and CLI: interface name
//! resolution and raw (Io-less) file reading via direct syscalls, so the
//! library keeps working without a std.Io instance.

const std = @import("std");
const linux = std.os.linux;

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
