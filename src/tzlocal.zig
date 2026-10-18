//! Local timezone support without libc: parses /etc/localtime (TZif) via
//! std.tz and answers "UTC offset at timestamp" queries. Used by the CLI to
//! render fping's localtime()-based timestamps (-D, -Q headers).
//!
//! The POSIX TZ footer of TZif v2+ files ("CET-1CEST,M3.5.0,M10.5.0/3") is
//! applied for instants after the last listed transition (or when the file
//! has none), like glibc does. "Slim" zoneinfo files rely on it.
//!
//! Divergence from libc: the TZ environment variable is not consulted at all;
//! /etc/localtime is always used.

const std = @import("std");
const netutil = @import("netutil.zig");

const LocalTz = @This();

tz: ?std.tz.Tz = null,
/// Parsed TZif footer; null when absent or malformed.
rule: ?PosixTz = null,

/// Load the local timezone database. Never fails — falls back to UTC
/// (offset 0) when /etc/localtime is missing or unparsable.
pub fn load(gpa: std.mem.Allocator) LocalTz {
    var buf: [256 * 1024]u8 = undefined;
    const content = netutil.readFile("/etc/localtime", &buf) orelse return .{};
    return fromBytes(gpa, content);
}

/// Build from the bytes of a TZif file; UTC fallback when unparsable.
pub fn fromBytes(gpa: std.mem.Allocator, content: []const u8) LocalTz {
    var reader: std.Io.Reader = .fixed(content);
    const tz = std.tz.Tz.parse(gpa, &reader) catch return .{};
    const rule = if (tz.footer) |f| PosixTz.parse(f) else null;
    return .{ .tz = tz, .rule = rule };
}

/// A POSIX TZ string ("EST5EDT,M3.2.0,M11.1.0"), RFC 8536 section 3.3.
/// Offsets are seconds east of UTC (the opposite sign of the string).
pub const PosixTz = struct {
    std_off: i32,
    /// Null for zones without DST ("UTC0", "<+03>-3").
    dst: ?Dst = null,

    const Dst = struct {
        off: i32,
        start: Rule,
        end: Rule,
    };

    const Rule = struct {
        kind: enum { month_week_day, julian1, julian0 },
        /// month_week_day: month 1..12; julian: day number.
        a: u16,
        /// month_week_day: week 1..5.
        w: u8 = 0,
        /// month_week_day: weekday 0..6 (Sunday = 0).
        d: u8 = 0,
        /// Local wall-clock seconds after midnight; may be negative or > 24 h.
        time: i32 = 2 * 3600,
    };

    const Parser = struct {
        s: []const u8,
        i: usize = 0,

        fn peek(p: *const Parser) ?u8 {
            return if (p.i < p.s.len) p.s[p.i] else null;
        }

        fn name(p: *Parser) ?void {
            if (p.peek() == '<') {
                const end = std.mem.findScalarPos(u8, p.s, p.i + 1, '>') orelse return null;
                if (end == p.i + 1) return null;
                p.i = end + 1;
                return;
            }
            const start = p.i;
            while (p.peek()) |c| : (p.i += 1) {
                if (!std.ascii.isAlphabetic(c)) break;
            }
            if (p.i - start < 3) return null;
        }

        fn number(p: *Parser, max: u32) ?u32 {
            const start = p.i;
            var v: u32 = 0;
            while (p.peek()) |c| : (p.i += 1) {
                if (c < '0' or c > '9') break;
                v = v * 10 + (c - '0');
                if (v > max) return null;
            }
            return if (p.i == start) null else v;
        }

        /// [+-]hh[:mm[:ss]] in seconds, sign as written.
        fn hms(p: *Parser) ?i32 {
            var neg = false;
            if (p.peek()) |c| {
                if (c == '+' or c == '-') {
                    neg = c == '-';
                    p.i += 1;
                }
            }
            var secs: i32 = @intCast((p.number(167) orelse return null) * 3600);
            if (p.peek() == ':') {
                p.i += 1;
                secs += @intCast((p.number(59) orelse return null) * 60);
                if (p.peek() == ':') {
                    p.i += 1;
                    secs += @intCast(p.number(59) orelse return null);
                }
            }
            return if (neg) -secs else secs;
        }

        fn rule(p: *Parser) ?Rule {
            var r: Rule = undefined;
            switch (p.peek() orelse return null) {
                'M' => {
                    p.i += 1;
                    r = .{ .kind = .month_week_day, .a = @intCast(p.number(12) orelse return null) };
                    if (r.a < 1 or p.peek() != '.') return null;
                    p.i += 1;
                    r.w = @intCast(p.number(5) orelse return null);
                    if (r.w < 1 or p.peek() != '.') return null;
                    p.i += 1;
                    r.d = @intCast(p.number(6) orelse return null);
                },
                'J' => {
                    p.i += 1;
                    r = .{ .kind = .julian1, .a = @intCast(p.number(365) orelse return null) };
                    if (r.a < 1) return null;
                },
                else => r = .{ .kind = .julian0, .a = @intCast(p.number(365) orelse return null) },
            }
            if (p.peek() == '/') {
                p.i += 1;
                r.time = p.hms() orelse return null;
            }
            return r;
        }
    };

    /// Null when the string is malformed.
    pub fn parse(s: []const u8) ?PosixTz {
        var p: Parser = .{ .s = s };
        p.name() orelse return null;
        const std_off = -(p.hms() orelse return null);
        if (p.i == s.len) return .{ .std_off = std_off };
        p.name() orelse return null;
        var dst_off = std_off + 3600;
        if (p.peek()) |c| {
            if (c != ',') dst_off = -(p.hms() orelse return null);
        }
        // Without rules libc uses its "posixrules" defaults (US).
        var start: Rule = .{ .kind = .month_week_day, .a = 3, .w = 2, .d = 0 };
        var end: Rule = .{ .kind = .month_week_day, .a = 11, .w = 1, .d = 0 };
        if (p.i < s.len) {
            if (p.peek() != ',') return null;
            p.i += 1;
            start = p.rule() orelse return null;
            if (p.peek() != ',') return null;
            p.i += 1;
            end = p.rule() orelse return null;
            if (p.i != s.len) return null;
        }
        return .{ .std_off = std_off, .dst = .{ .off = dst_off, .start = start, .end = end } };
    }

    /// UTC offset in seconds at the given UTC epoch timestamp.
    pub fn offsetAt(self: PosixTz, utc_secs: i64) i32 {
        const dst = self.dst orelse return self.std_off;
        const year = yearOf(utc_secs + self.std_off);
        const start = ruleUtc(dst.start, year, self.std_off);
        const end = ruleUtc(dst.end, year, dst.off);
        const in_dst = if (start < end)
            utc_secs >= start and utc_secs < end
        else
            utc_secs >= start or utc_secs < end;
        return if (in_dst) dst.off else self.std_off;
    }

    /// UTC instant at which `r` fires in `year`, given the offset in force
    /// just before the switch.
    fn ruleUtc(r: Rule, year: i64, off: i32) i64 {
        const day: i64 = switch (r.kind) {
            .month_week_day => blk: {
                const first = daysFromCivil(year, r.a, 1);
                const wd1: i64 = @mod(first + 4, 7); // 1970-01-01 was a Thursday
                var dom: i64 = 1 + @mod(@as(i64, r.d) - wd1, 7) + (@as(i64, r.w) - 1) * 7;
                const dim = daysInMonth(year, r.a);
                while (dom > dim) dom -= 7;
                break :blk first + dom - 1;
            },
            .julian1 => daysFromCivil(year, 1, 1) + r.a - 1 +
                @intFromBool(isLeap(year) and r.a >= 60),
            .julian0 => daysFromCivil(year, 1, 1) + r.a,
        };
        return day * 86400 + r.time - off;
    }
};

fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

fn daysInMonth(y: i64, m: u16) i64 {
    return switch (m) {
        2 => if (isLeap(y)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Days since 1970-01-01 of a proleptic Gregorian date (H. Hinnant).
fn daysFromCivil(year: i64, m: u16, d: i64) i64 {
    const y = if (m <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Calendar year of a (local) epoch timestamp.
fn yearOf(secs: i64) i64 {
    const z = @divFloor(secs, 86400) + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const m = if (mp < 10) mp + 3 else mp - 9;
    return yoe + era * 400 + @intFromBool(m <= 2);
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
        if (self.rule) |r| return r.offsetAt(utc_secs);
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
    // Past the last transition the footer rule takes over (slim files).
    if (lo == transitions.len) {
        if (self.rule) |r| return r.offsetAt(utc_secs);
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

const TestTrans = struct { ts: i64, idx: u8 };

/// Hand-built TZif v2 file: type 0 = CET (+1h), type 1 = CEST (+2h, DST).
fn buildTzif(buf: []u8, trans: []const TestTrans, footer: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const chars = "CET\x00CEST\x00";
    // Legacy block: empty, skipped by the parser.
    w.writeAll("TZif2") catch unreachable;
    w.splatByteAll(0, 15 + 24) catch unreachable;
    w.writeAll("TZif2") catch unreachable;
    w.splatByteAll(0, 15) catch unreachable;
    for ([_]u32{ 0, 0, 0, @intCast(trans.len), 2, chars.len }) |c| w.writeInt(u32, c, .big) catch unreachable;
    for (trans) |t| w.writeInt(i64, t.ts, .big) catch unreachable;
    for (trans) |t| w.writeByte(t.idx) catch unreachable;
    w.writeInt(i32, 3600, .big) catch unreachable;
    w.writeAll(&.{ 0, 0 }) catch unreachable;
    w.writeInt(i32, 7200, .big) catch unreachable;
    w.writeAll(&.{ 1, 4 }) catch unreachable;
    w.writeAll(chars) catch unreachable;
    w.writeAll("\n") catch unreachable;
    w.writeAll(footer) catch unreachable;
    w.writeAll("\n") catch unreachable;
    return w.buffered();
}

test "slim file without transitions uses footer" {
    var buf: [512]u8 = undefined;
    const bytes = buildTzif(&buf, &.{}, "CET-1CEST,M3.5.0,M10.5.0/3");
    var l = LocalTz.fromBytes(std.testing.allocator, bytes);
    defer l.deinit();
    try std.testing.expect(l.rule != null);
    try std.testing.expectEqual(@as(i32, 7200), l.offsetAt(1910347200)); // 2030-07-15
    try std.testing.expectEqual(@as(i32, 3600), l.offsetAt(1894708800)); // 2030-01-15
    // Last Sunday of March 2030, 01:00 UTC.
    try std.testing.expectEqual(@as(i32, 3600), l.offsetAt(1901149200 - 1));
    try std.testing.expectEqual(@as(i32, 7200), l.offsetAt(1901149200));
    // Last Sunday of October 2030, 01:00 UTC.
    try std.testing.expectEqual(@as(i32, 7200), l.offsetAt(1919293200 - 1));
    try std.testing.expectEqual(@as(i32, 3600), l.offsetAt(1919293200));
}

test "table is used before the last transition, footer after" {
    var buf: [512]u8 = undefined;
    // Table says CEST from t=1000 on (deliberately contradicting the footer),
    // CET from t=2000 on.
    const bytes = buildTzif(&buf, &.{ .{ .ts = 1000, .idx = 1 }, .{ .ts = 2000, .idx = 0 } }, "CET-1CEST,M3.5.0,M10.5.0/3");
    var l = LocalTz.fromBytes(std.testing.allocator, bytes);
    defer l.deinit();
    try std.testing.expectEqual(@as(i32, 3600), l.offsetAt(500));
    try std.testing.expectEqual(@as(i32, 7200), l.offsetAt(1500));
    try std.testing.expectEqual(@as(i32, 3600), l.offsetAt(1999 + 1));
    // After the last transition: footer (July 2030 is DST).
    try std.testing.expectEqual(@as(i32, 7200), l.offsetAt(1910347200));
    // Malformed footer: last transition's offset.
    var buf2: [512]u8 = undefined;
    const bad = buildTzif(&buf2, &.{ .{ .ts = 1000, .idx = 1 }, .{ .ts = 2000, .idx = 0 } }, "CET-1CEST,M13.5.0,M10.5.0");
    var l2 = LocalTz.fromBytes(std.testing.allocator, bad);
    defer l2.deinit();
    try std.testing.expect(l2.rule == null);
    try std.testing.expectEqual(@as(i32, 3600), l2.offsetAt(1910347200));
}

test "southern hemisphere rule spans the year end" {
    const p = PosixTz.parse("AEST-10AEDT,M10.1.0,M4.1.0/3").?;
    try std.testing.expectEqual(@as(i32, 11 * 3600), p.offsetAt(1896134400)); // 2030-02-01
    try std.testing.expectEqual(@as(i32, 10 * 3600), p.offsetAt(1910347200)); // 2030-07-15
    try std.testing.expectEqual(@as(i32, 10 * 3600), p.offsetAt(1917446400 - 1));
    try std.testing.expectEqual(@as(i32, 11 * 3600), p.offsetAt(1917446400));
    try std.testing.expectEqual(@as(i32, 11 * 3600), p.offsetAt(1901721600 - 1));
    try std.testing.expectEqual(@as(i32, 10 * 3600), p.offsetAt(1901721600));
}

test "no-DST footers" {
    const a = PosixTz.parse("<+03>-3").?;
    try std.testing.expectEqual(@as(i32, 3 * 3600), a.offsetAt(1910347200));
    try std.testing.expect(a.dst == null);
    const b = PosixTz.parse("UTC0").?;
    try std.testing.expectEqual(@as(i32, 0), b.offsetAt(1894708800));
    const c = PosixTz.parse("<-0330>3:30").?;
    try std.testing.expectEqual(@as(i32, -(3 * 3600 + 1800)), c.offsetAt(0));
}

test "Julian and zero-based day rules, odd times" {
    // 2028 is a leap year. J60 = March 1 (Feb 29 never counted); 60 = Feb 29.
    const j = PosixTz.parse("XXX0YYY,J60/0,J300/-1").?;
    const mar1 = daysFromCivil(2028, 3, 1) * 86400;
    try std.testing.expectEqual(@as(i32, 3600), j.offsetAt(mar1));
    try std.testing.expectEqual(@as(i32, 0), j.offsetAt(mar1 - 1));
    // J300 is Oct 27 in any year (Feb 29 is skipped by J numbering); /-1 = 23:00 the day before, in DST offset.
    const end = daysFromCivil(2028, 10, 27) * 86400 - 3600 - 3600;
    try std.testing.expectEqual(@as(i32, 3600), j.offsetAt(end - 1));
    try std.testing.expectEqual(@as(i32, 0), j.offsetAt(end));

    const n = PosixTz.parse("XXX0YYY,59/0,300/25").?;
    const feb29 = daysFromCivil(2028, 2, 29) * 86400;
    try std.testing.expectEqual(@as(i32, 3600), n.offsetAt(feb29));
    try std.testing.expectEqual(@as(i32, 0), n.offsetAt(feb29 - 1));
    // Day 300 in a leap year = Oct 27; 25 h later in DST offset (1h).
    const nend = daysFromCivil(2028, 10, 27) * 86400 + 25 * 3600 - 3600;
    try std.testing.expectEqual(@as(i32, 3600), n.offsetAt(nend - 1));
    try std.testing.expectEqual(@as(i32, 0), n.offsetAt(nend));
}

test "malformed footers are rejected" {
    const bad = [_][]const u8{
        "",
        "CET",
        "CE-1",
        "CET-",
        "CET-1CEST,M3.5.0",
        "CET-1CEST,M3.5.0,M10.5.0,",
        "CET-1CEST,M0.5.0,M10.5.0",
        "CET-1CEST,M3.6.0,M10.5.0",
        "CET-1CEST,M3.5.7,M10.5.0",
        "CET-1CEST,J0,J100",
        "CET-1CEST,J366,J100",
        "CET-1CEST,M3.5.0/,M10.5.0",
        "<CET-1",
        "<>-1",
        "CET-1CEST,x,y",
        "CET-1:99",
    };
    for (bad) |s| try std.testing.expect(PosixTz.parse(s) == null);
    // Never panics on garbage.
    _ = PosixTz.parse("\xff\x00,,,//::");
}
