//! Local timezone support without libc: parses /etc/localtime (TZif) via
//! std.tz and answers "UTC offset at timestamp" queries. Used by the CLI to
//! render fping's localtime()-based timestamps (-D, -Q headers).
//!
//! Divergence from libc: the TZ environment variable's POSIX rule strings
//! ("CET-1CEST,M3.5.0,...") are not interpreted; TZ may only name a TZif
//! file. Without TZ, /etc/localtime is used like libc does.

const std = @import("std");
const netutil = @import("netutil.zig");

const LocalTz = @This();

tz: ?std.tz.Tz = null,

/// Load the local timezone database. Never fails — falls back to UTC
/// (offset 0) when /etc/localtime is missing or unparsable.
pub fn load(gpa: std.mem.Allocator) LocalTz {
    var buf: [256 * 1024]u8 = undefined;
    const content = netutil.readFile("/etc/localtime", &buf) orelse return .{};
    var reader: std.Io.Reader = .fixed(content);
    const tz = std.tz.Tz.parse(gpa, &reader) catch return .{};
    return .{ .tz = tz };
}

pub fn deinit(self: *LocalTz) void {
    if (self.tz) |*tz| tz.deinit();
    self.* = .{};
}

/// UTC offset in seconds at the given UTC epoch timestamp.
pub fn offsetAt(self: *const LocalTz, utc_secs: i64) i32 {
    const tz = &(self.tz orelse return 0);
    const transitions = tz.transitions;
    if (transitions.len == 0) {
        return if (tz.timetypes.len > 0) tz.timetypes[0].offset else 0;
    }
    // Binary search: latest transition with ts <= utc_secs.
    var lo: usize = 0;
    var hi: usize = transitions.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (transitions[mid].ts <= utc_secs) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) {
        // Before the first transition: use the first standard time type.
        for (tz.timetypes) |*tt| {
            if (!tt.isDst()) return tt.offset;
        }
        return tz.timetypes[0].offset;
    }
    return transitions[lo - 1].timetype.offset;
}

test "load and query local timezone" {
    var local = LocalTz.load(std.testing.allocator);
    defer local.deinit();
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    // Whatever the host timezone, the offset must be sane (within ±14 h).
    const offset = local.offsetAt(ts.sec);
    try std.testing.expect(offset >= -14 * 3600 and offset <= 14 * 3600);
}

test "UTC fallback" {
    var local: LocalTz = .{};
    try std.testing.expectEqual(@as(i32, 0), local.offsetAt(0));
}
