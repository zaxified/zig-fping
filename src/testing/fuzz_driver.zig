// SPDX-License-Identifier: MIT
// Trimmed from zig-libs `modules/testkit/src/fuzz_driver.zig` and `fuzz.zig`
// (Copyright (c) 2026 zig-libs contributors, MIT License). Test-only: it is
// imported only from `test` blocks, never from library or CLI code.
//
//! The deterministic fuzz driver: a verdict in seconds, from seeds.
//!
//! `zig build --fuzz` explores, but for a verdict it is blind: no progress, exit
//! 0 on a crash, no limit per input. This runs the SAME harness over inputs
//! drawn from seeds, in the ordinary ReleaseSafe test binary:
//!
//!     ZFPING_FUZZ=<runs>[,<first seed>]  run, else the driver test is skipped
//!     ZFPING_FUZZ_SECS=<n>               also stop after n seconds
//!     ZFPING_FUZZ_ONLY=<substring>       only harnesses whose name contains it
//!     ZFPING_FUZZ_MS=<limit per input>   default 2000
//!     ZFPING_FUZZ_SEEDFILE=<path>        the current seed, for a panic
//!     ZFPING_FUZZ_INPUT=<path>           replay one saved `--fuzz` input
//!
//! A hang is `HANG <name> seed=N` and exit 124; a failing input is
//! `FAIL <name> seed=N: <error>`; a panic leaves its seed in the seed file. Any
//! seed replays with `ZFPING_FUZZ=1,N`. One job per core, each with a disjoint
//! seed range, is the caller's runner (`scripts/fuzz.sh`).
//!
//! ## The harness is generic over its source of choices
//!
//!     fn harness(comptime S: type, src: *S, gpa: std.mem.Allocator) anyerror!void
//!
//! using only `valueRangeAtMost`, `value`, `index` and `slice`. The driver
//! hands it a `*Rng`; `std.testing.fuzz` (the optional `--fuzz` mode) a `*Script`
//! built from ONE `Smith.slice` draw.
//! Never `Smith{ .in = random bytes }` as the driver's source: in `.in` mode
//! Smith answers the range's MINIMUM for anything outside it, which for random
//! bytes is almost always, and the harness silently tests nothing.
//!
//! ## Reach before verdict
//!
//! `hit("label")` counts how often a run got somewhere; `expectReach` fails a
//! plain `zig build test` when a label of a fixed seed range is never reached,
//! so a harness that degenerates fails the suite. The driver prints
//! `REACH <name> <label>=<n>` when it is done.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

/// The driver calls the kernel directly (clock, sleep, open) and keeps 64-bit
/// atomics: Linux with a 64-bit `usize`. Elsewhere (32-bit lanes) `run` skips.
pub const supported = builtin.os.tag == .linux and @bitSizeOf(usize) == 64;

/// `std.testing.Smith`'s drawing methods, from a PRNG.
pub const Rng = struct {
    r: std.Random,

    pub fn valueRangeAtMost(self: *Rng, comptime T: type, at_least: T, at_most: T) T {
        return self.r.intRangeAtMost(T, at_least, at_most);
    }
    pub fn value(self: *Rng, comptime T: type) T {
        return switch (@typeInfo(T)) {
            .bool => self.r.boolean(),
            else => self.r.int(T),
        };
    }
    pub fn index(self: *Rng, len: usize) usize {
        return self.r.uintLessThan(usize, len);
    }
    /// A length in `0..buf.len` and that many random bytes. Half the draws on
    /// a buffer over 64 bytes are taken from the first 64: short inputs are
    /// where the length checks live.
    pub fn slice(self: *Rng, buf: []u8) u32 {
        const cap: usize = if (buf.len > 64 and self.r.boolean()) 64 else buf.len;
        const n = self.r.uintAtMost(usize, cap);
        self.r.bytes(buf[0..n]);
        return @intCast(n);
    }
};

/// `testing.fuzz`'s source: `slice` hands back the ONE drawn byte string
/// (a corpus entry verbatim), every other choice is read from it by a
/// cursor. A bare `Smith` would answer the minimum for every ranged draw
/// after the first short read.
pub const Script = struct {
    data: []const u8,
    at: usize = 0,

    fn byte(self: *Script) u8 {
        if (self.data.len == 0) return 0;
        const b = self.data[self.at % self.data.len];
        self.at += 1;
        return b;
    }
    fn ranged(self: *Script, at_least: u64, at_most: u64) u64 {
        const span = at_most - at_least +% 1;
        var v: u64 = 0;
        for (0..8) |_| v = v << 8 | self.byte();
        return if (span == 0) v else at_least + v % span;
    }

    pub fn slice(self: *Script, buf: []u8) u32 {
        const n = @min(buf.len, self.data.len);
        @memcpy(buf[0..n], self.data[0..n]);
        return @intCast(n);
    }
    pub fn index(self: *Script, len: usize) usize {
        return @intCast(self.ranged(0, len - 1));
    }
    pub fn valueRangeAtMost(self: *Script, comptime T: type, at_least: T, at_most: T) T {
        return @intCast(self.ranged(@intCast(at_least), @intCast(at_most)));
    }
    pub fn value(self: *Script, comptime T: type) T {
        return switch (@typeInfo(T)) {
            .bool => self.byte() & 1 == 1,
            else => @truncate(self.ranged(0, std.math.maxInt(u64))),
        };
    }
};

/// The `testing.fuzz` entry point for a generic harness: the first and only
/// `Smith.slice` draw becomes the script of the harness.
pub fn smithEntry(comptime harness: anytype, comptime script_len: usize) fn (void, *std.testing.Smith) anyerror!void {
    return struct {
        fn entry(_: void, smith: *std.testing.Smith) anyerror!void {
            var script: [script_len]u8 = undefined;
            const n = smith.slice(&script);
            var src: Script = .{ .data = script[0..n] };
            return harness(Script, &src, std.testing.allocator);
        }
    }.entry;
}

/// A corpus entry carrying `frame` verbatim: the 4-octet little-endian length
/// `Smith.slice` reads, then the bytes.
pub fn seed(comptime frame: []const u8) []const u8 {
    return &struct {
        const bytes = std.mem.toBytes(@as(u32, @intCast(frame.len))) ++ frame[0..frame.len].*;
    }.bytes;
}

/// `s` repeated `n` times, at comptime (array `**` is gone in Zig 0.17).
pub fn rep(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    return &struct {
        const v: [s.len * n]u8 = blk: {
            var o: [s.len * n]u8 = undefined;
            for (0..n) |i| @memcpy(o[i * s.len ..][0..s.len], s);
            break :blk o;
        };
    }.v;
}

/// The same as `seed`, from a hex literal: a packet quoted from a capture or a
/// spec reads more reviewably as hex. A bad literal is a compile error.
pub fn seedHex(comptime h: []const u8) []const u8 {
    return &struct {
        const frame = blk: {
            if (h.len % 2 != 0) @compileError("odd-length hex seed: " ++ h);
            @setEvalBranchQuota(@max(1000, 40 * h.len));
            var out: [h.len / 2]u8 = undefined;
            _ = std.fmt.hexToBytes(&out, h) catch @compileError("bad hex seed: " ++ h);
            break :blk out;
        };
        const bytes = std.mem.toBytes(@as(u32, @intCast(frame.len))) ++ frame;
    }.bytes;
}

/// The frame of a `seed()` entry (what its `slice` draw yields).
pub fn frameOf(entry: []const u8) []const u8 {
    return entry[4..];
}

// ---- reach counters -----------------------------------------------------------

const max_labels = 48;
var labels: [max_labels][]const u8 = undefined;
var counts: [max_labels]u64 = @splat(0);
var label_count: usize = 0;

/// Count one arrival at `label`.
pub fn hit(comptime label: []const u8) void {
    const l: []const u8 = label;
    for (labels[0..label_count], 0..) |known, i| {
        if (known.ptr == l.ptr or std.mem.eql(u8, known, l)) {
            counts[i] += 1;
            return;
        }
    }
    if (label_count == max_labels) return;
    labels[label_count] = l;
    counts[label_count] = 1;
    label_count += 1;
}

pub fn resetReach() void {
    label_count = 0;
    counts = @splat(0);
}

pub fn reached(label: []const u8) u64 {
    for (labels[0..label_count], counts[0..label_count]) |l, c| {
        if (std.mem.eql(u8, l, label)) return c;
    }
    return 0;
}

fn reportReach(name: []const u8) void {
    for (labels[0..label_count], counts[0..label_count]) |l, c|
        std.debug.print("REACH {s} {s}={d}\n", .{ name, l, c });
    resetReach();
}

/// Set only by the driver's own negative test: a passing test that writes to
/// stderr is shown by the build runner as a "failed command".
var quiet_reach = false;

/// Run `harness` over seeds `0..seeds` in-process and fail unless every label
/// in `required` was reached. Runs in every plain `zig build test`.
pub fn expectReach(comptime harness: anytype, name: []const u8, seeds: u64, required: []const []const u8) !void {
    resetReach();
    defer resetReach();
    var seed_n: u64 = 0;
    while (seed_n < seeds) : (seed_n += 1) {
        var prng = std.Random.DefaultPrng.init(seed_n);
        var rng: Rng = .{ .r = prng.random() };
        harness(Rng, &rng, std.testing.allocator) catch |e| {
            std.debug.print("fuzz harness {s}: seed {d}: {t}\n", .{ name, seed_n, e });
            return e;
        };
    }
    var missing = false;
    for (required) |l| if (reached(l) == 0) {
        if (!quiet_reach) std.debug.print("fuzz harness {s}: label \"{s}\" never reached in {d} seeds\n", .{ name, l, seeds });
        missing = true;
    };
    if (missing) return error.HarnessDoesNotReach;
}

// ---- the watchdog ---------------------------------------------------------------

var current_seed = std.atomic.Value(u64).init(0);
var current_limit = std.atomic.Value(u64).init(0);
var current_name: []const u8 = "";
/// Bumped at every harness entry; `busy` while a harness runs. The watchdog
/// samples both every 50 ms: the same generation still busy for longer than
/// the limit is a hang. No clock is read per input.
var dog_gen = std.atomic.Value(u64).init(0);
var dog_busy = std.atomic.Value(bool).init(false);
var dog_running = false;

fn enter(seed_n: u64) void {
    current_seed.store(seed_n, .release);
    dog_gen.store(dog_gen.load(.monotonic) +% 1, .release);
    dog_busy.store(true, .release);
}

fn leave() void {
    dog_busy.store(false, .release);
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Whether the watchdog, at `now`, holding the generation it last saw change
/// (`seen`, at `since`), must call a hang. Pure, for the tests.
fn hung(busy: bool, gen: u64, seen: *u64, since: *u64, now: u64, limit: u64) bool {
    if (!busy or gen != seen.*) {
        seen.* = gen;
        since.* = now;
        return false;
    }
    return now -| since.* > limit;
}

fn watchdog() void {
    var seen: u64 = 0;
    var since: u64 = nowNs();
    while (true) {
        const req: linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = linux.nanosleep(&req, null);
        const limit = current_limit.load(.acquire);
        if (hung(dog_busy.load(.acquire), dog_gen.load(.acquire), &seen, &since, nowNs(), limit)) {
            std.debug.print("HANG {s} seed={d} (over {d} ms)\n", .{ current_name, current_seed.load(.acquire), limit / std.time.ns_per_ms });
            std.process.exit(124);
        }
    }
}

fn armWatchdog(name: []const u8, limit_ms: u64) !void {
    current_name = name;
    current_limit.store(limit_ms * std.time.ns_per_ms, .release);
    if (dog_running) return;
    const dog = try std.Thread.spawn(.{}, watchdog, .{});
    dog.detach();
    dog_running = true;
}

// ---- the driver -------------------------------------------------------------------

pub const Options = struct {
    /// This harness's name: what `FAIL`/`HANG` print and `_ONLY` selects by.
    name: []const u8,
    default_limit_ms: u64 = 2000,
};

const prefix = "ZFPING_FUZZ";
/// Size of the `Script` buffer of a `--fuzz` replay (`_INPUT`).
const replay_script_len = 1024;

fn env(buf: []u8, suffix: []const u8) ?[]const u8 {
    const key = std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, suffix }) catch return null;
    return std.testing.environ.getPosix(key);
}

fn openZ(path: []const u8, flags: linux.O, mode: linux.mode_t) ?i32 {
    var pb: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= pb.len) return null;
    @memcpy(pb[0..path.len], path);
    pb[path.len] = 0;
    const rc = linux.open(pb[0..path.len :0], flags, mode);
    return if (linux.errno(rc) == .SUCCESS) @intCast(rc) else null;
}

pub const Spec = struct { runs: u64, first: u64 };

pub fn parseSpec(spec: []const u8) error{ InvalidCharacter, Overflow }!Spec {
    var parts = std.mem.splitScalar(u8, spec, ',');
    const runs = @max(1, try std.fmt.parseInt(u64, parts.next().?, 10));
    const first = if (parts.next()) |f| try std.fmt.parseInt(u64, f, 10) else 0;
    return .{ .runs = runs, .first = first };
}

/// Run `harness` over seeds as the environment says, or skip. Its allocator
/// is a `DebugAllocator` that still finds leaks but records no stack traces.
pub fn run(comptime harness: anytype, opts: Options) !void {
    if (comptime supported) return runHere(harness, opts) else return error.SkipZigTest;
}

fn runHere(comptime harness: anytype, opts: Options) !void {
    var kb: [96]u8 = undefined;
    if (env(&kb, "_ONLY")) |only| {
        if (std.mem.find(u8, opts.name, only) == null) return error.SkipZigTest;
    }
    const limit_ms = if (env(&kb, "_MS")) |m| try std.fmt.parseInt(u64, m, 10) else opts.default_limit_ms;

    var da: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    const gpa = da.allocator();
    defer if (da.deinit() == .leak) @panic("fuzz driver: leak");

    if (env(&kb, "_INPUT")) |path| {
        const fd = openZ(path, .{ .ACCMODE = .RDONLY }, 0) orelse return error.FileNotFound;
        defer _ = linux.close(fd);
        var buf: [1 << 16]u8 = undefined;
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.InputOutput;
        try armWatchdog(opts.name, limit_ms);
        enter(0);
        var smith: std.testing.Smith = .{ .in = buf[0..n] };
        try smithEntry(harness, replay_script_len)({}, &smith);
        leave();
        std.debug.print("REPLAY {s} ok ({d} bytes)\n", .{ opts.name, n });
        return;
    }

    const spec = try parseSpec(env(&kb, "") orelse return error.SkipZigTest);
    const secs: u64 = if (env(&kb, "_SECS")) |s| try std.fmt.parseInt(u64, s, 10) else std.math.maxInt(u32);
    const seed_fd: ?i32 = if (env(&kb, "_SEEDFILE")) |path|
        openZ(path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644)
    else
        null;
    defer if (seed_fd) |fd| {
        _ = linux.close(fd);
    };

    try armWatchdog(opts.name, limit_ms);
    return runSeeds(harness, opts.name, spec, secs, gpa, seed_fd);
}

/// The seed file holds `<name> <seed, 20 digits>\n`, rewritten before every
/// seed through a shared mapping: the mapped page is the page cache, so a
/// crashing process cannot lose the text, and a store is a `memcpy`.
const SeedFile = struct {
    map: ?[]align(std.heap.page_size_min) u8,
    fd: i32,
    head: usize,
    text: [96]u8 = undefined,

    const map_len = 4096;
    const digits = 20;

    fn open(fd: i32, name: []const u8) SeedFile {
        var sf: SeedFile = .{ .fd = fd, .map = null, .head = @min(name.len, 64) };
        @memcpy(sf.text[0..sf.head], name[0..sf.head]);
        sf.text[sf.head] = ' ';
        sf.head += 1;
        const total = sf.head + digits + 1;
        _ = linux.ftruncate(fd, @intCast(total));
        sf.map = std.posix.mmap(null, map_len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch null;
        return sf;
    }

    fn set(sf: *SeedFile, seed_n: u64) void {
        var v = seed_n;
        var i: usize = digits;
        while (i > 0) {
            i -= 1;
            sf.text[sf.head + i] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
        }
        sf.text[sf.head + digits] = '\n';
        const len = sf.head + digits + 1;
        if (sf.map) |m| {
            @memcpy(m[0..len], sf.text[0..len]);
        } else {
            _ = linux.pwrite(sf.fd, &sf.text, len, 0);
        }
    }

    fn close(sf: *SeedFile) void {
        if (sf.map) |m| std.posix.munmap(m);
    }
};

/// The seed loop: every seed in `spec`, in order, each with a fresh `Rng`; the
/// first failure is printed with its seed and RETURNED, so the test fails.
fn runSeeds(comptime harness: anytype, name: []const u8, spec: Spec, secs: u64, gpa: std.mem.Allocator, seed_fd: ?i32) !void {
    resetReach();
    var seed_file: ?SeedFile = if (seed_fd) |fd| .open(fd, name) else null;
    defer if (seed_file) |*sf| sf.close();
    const t0 = nowNs();
    var last_report = t0;
    var seed_n = spec.first;
    var done: u64 = 0;
    while (done < spec.runs) : ({
        seed_n += 1;
        done += 1;
    }) {
        var prng = std.Random.DefaultPrng.init(seed_n);
        var rng: Rng = .{ .r = prng.random() };
        if (seed_file) |*sf| sf.set(seed_n);
        enter(seed_n);
        harness(Rng, &rng, gpa) catch |e| {
            leave();
            std.debug.print("FAIL {s} seed={d}: {t}\n", .{ name, seed_n, e });
            return e;
        };
        leave();
        // The clock, for the progress line and the time cap, every 256 seeds.
        if (done % 256 == 255) {
            const now = nowNs();
            if (now - t0 >= secs * std.time.ns_per_s) {
                done += 1;
                break;
            }
            if (now - last_report > std.time.ns_per_s) {
                last_report = now;
                std.debug.print("runs {s} {d} ({d}/s)\n", .{ name, done + 1, (done + 1) * std.time.ns_per_s / (now - t0) });
            }
        }
    }
    const ms = @max(1, (nowNs() - t0) / std.time.ns_per_ms);
    std.debug.print("DONE {s} runs={d} in {d} ms ({d}/s)\n", .{ name, done, ms, done * 1000 / ms });
    reportReach(name);
}

// ---- tests ------------------------------------------------------------------------

const testing = std.testing;

test "Rng: draws stay inside what was asked for, both ends of a range occur" {
    var prng = std.Random.DefaultPrng.init(7);
    var rng: Rng = .{ .r = prng.random() };
    var lo = false;
    var hi = false;
    var short = false;
    var long = false;
    for (0..2000) |_| {
        const v = rng.valueRangeAtMost(u8, 3, 6);
        try testing.expect(v >= 3 and v <= 6);
        lo = lo or v == 3;
        hi = hi or v == 6;
        try testing.expect(rng.index(7) < 7);
        var buf: [300]u8 = undefined;
        const n = rng.slice(&buf);
        short = short or n < 8;
        long = long or n > 200;
    }
    try testing.expect(lo and hi and short and long);
}

test "Script: slice is the whole entry, other draws come from the same bytes" {
    var s: Script = .{ .data = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } };
    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(u32, 4), s.slice(&buf));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &buf);
    for (0..100) |_| {
        try testing.expect(s.index(5) < 5);
        const v = s.valueRangeAtMost(u16, 10, 20);
        try testing.expect(v >= 10 and v <= 20);
    }
    var empty: Script = .{ .data = "" };
    try testing.expectEqual(@as(usize, 0), empty.index(3));
}

test "seed: the frame Smith.slice reads" {
    var smith: std.testing.Smith = .{ .in = seed("abc") };
    var buf: [8]u8 = undefined;
    const n = smith.slice(&buf);
    try testing.expectEqualStrings("abc", buf[0..n]);
    try testing.expectEqualStrings("abc", frameOf(seed("abc")));
}

test "hit and expectReach: a label that is never reached fails" {
    const h = struct {
        fn f(comptime S: type, src: *S, _: std.mem.Allocator) anyerror!void {
            if (src.index(2) == 0) hit("a");
            hit("b");
        }
    }.f;
    try expectReach(h, "t", 50, &.{ "a", "b" });
    quiet_reach = true;
    defer quiet_reach = false;
    try testing.expectError(error.HarnessDoesNotReach, expectReach(h, "t", 50, &.{ "a", "nope" }));
}

test "hung: a hang is the same generation, busy, past the limit" {
    var seen: u64 = 0;
    var since: u64 = 0;
    try testing.expect(!hung(true, 1, &seen, &since, 100, 50));
    try testing.expect(!hung(true, 1, &seen, &since, 150, 50));
    try testing.expect(hung(true, 1, &seen, &since, 151, 50));
    try testing.expect(!hung(true, 2, &seen, &since, 1000, 50));
    try testing.expect(!hung(false, 2, &seen, &since, 5000, 50));
}

test "parseSpec: runs and first seed" {
    try testing.expectEqual(Spec{ .runs = 100, .first = 0 }, try parseSpec("100"));
    try testing.expectEqual(Spec{ .runs = 100, .first = 42 }, try parseSpec("100,42"));
    try testing.expectError(error.InvalidCharacter, parseSpec("x"));
}
