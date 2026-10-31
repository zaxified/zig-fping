//! The monitor: a list of targets, one probing cycle per minute, and the last
//! 24 hours of results per target.
//!
//! Every cycle sends a few echo requests to each active target through one
//! `zig_fping.Pinger` (so global pacing and in-flight limits apply across all
//! targets) and stores one `Sample` per target: probes sent, replies received,
//! the median round-trip time and the jitter.
//!
//! Locking: `mutex` guards `targets` and everything inside them. Probing runs
//! without the lock, on a copy of the target list, so the web UI never waits
//! for a cycle to finish.

const std = @import("std");
const Io = std.Io;
const fping = @import("zig_fping");
const demo = @import("demo.zig");

const log = std.log.scoped(.monitor);

/// Samples kept per target: 24 hours of one-minute cycles.
pub const history_len = 24 * 60;
/// Echo requests per target per cycle.
pub const probes_per_cycle = 5;
/// An acknowledgement clears itself after this many cycles in a row that
/// were not DOWN, so the next outage is reported again.
pub const ack_clear_after = 5;

/// One cycle of one target. `t == 0` marks an empty slot (paused, not yet
/// probed, or the daemon was not running).
pub const Sample = struct {
    /// Unix time (seconds) of the cycle start.
    t: i64 = 0,
    sent: u8 = 0,
    recv: u8 = 0,
    /// Median round-trip time of the replies, microseconds.
    rtt_us: u32 = 0,
    /// Mean difference between consecutive replies' round-trip times,
    /// microseconds; 0 with fewer than two replies.
    jitter_us: u32 = 0,
};

pub const Status = enum {
    /// No sample yet.
    pending,
    /// Every probe answered.
    up,
    /// Some probes lost.
    degraded,
    /// Every probe lost (or the name did not resolve).
    down,
    paused,
};

pub const Target = struct {
    id: u32,
    name: []u8,
    host: []u8,
    /// Lowercase, unique, at most `max_tags`; the page filters by them.
    tags: [][]u8 = &.{},
    paused: bool = false,
    acked: bool = false,
    /// Consecutive cycles that were not DOWN while acknowledged.
    ok_streak: u8 = 0,
    /// Why the last cycle could not probe (static string), if it could not.
    last_error: ?[]const u8 = null,
    /// Sample-data scenario for `Monitor.demo`.
    scenario: ?demo.Scenario = null,
    last: Sample = .{},
    /// Ring buffer indexed by cycle number, see `slot()`.
    history: [history_len]Sample = @splat(.{}),

    pub fn status(t: *const Target) Status {
        if (t.paused) return .paused;
        if (t.last.t == 0) return .pending;
        if (t.last.recv == 0) return .down;
        if (t.last.recv < t.last.sent) return .degraded;
        return .up;
    }
};

pub const Error = error{ InvalidName, InvalidHost, InvalidTags, InvalidScenario, TooManyTargets, UnknownTarget, NotDown };

/// Identifies one version of the web state; the HTTP layer turns it into
/// an ETag, so a viewer polling between cycles gets `304 Not Modified`.
pub const StateTag = struct {
    version: u64,
    /// Start (unix seconds) of the newest cycle in the series.
    end: i64,
};

/// Upper bound on targets: this is a small demo, not a monitoring system.
pub const max_targets = 64;
/// Tags per target, and bytes per tag.
pub const max_tags = 8;
pub const max_tag_len = 32;

pub const Monitor = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    targets: std.ArrayList(*Target) = .empty,
    next_id: u32 = 1,
    cycle_s: i64 = 60,
    /// Target list (JSON). Rewritten on every change unless `read_only`.
    config_path: []const u8,
    /// History snapshot (JSON), rewritten after every cycle; null = keep
    /// history in memory only.
    history_path: ?[]const u8 = null,
    read_only: bool = false,
    /// Public demo: every full hour, history older than the last hour of
    /// real probing is replaced with sample data (see demo.zig).
    demo: bool = false,
    /// Start (unix s) of the real data; older samples are sample data. 0 until
    /// the first fill.
    demo_from: i64 = 0,
    /// The first cycle of this run, and the hour of the last fill.
    demo_since: i64 = 0,
    demo_hour: i64 = 0,
    /// Bumped on every change the web page would show; with the cycle start
    /// it identifies one `stateJson` result (see `StateTag`).
    version: u64 = 0,
    /// The last `stateJson` result and its tag, shared by every viewer.
    state_cache: std.ArrayList(u8) = .empty,
    cache_tag: ?StateTag = null,
    /// For `health()`, read without the lock: when `loop` started, when the
    /// last cycle finished (0: none yet), and whether its probing worked.
    started_at: std.atomic.Value(i64) = .init(0),
    cycle_done_at: std.atomic.Value(i64) = .init(0),
    probing_ok: std.atomic.Value(bool) = .init(true),

    pub fn deinit(m: *Monitor) void {
        for (m.targets.items) |t| m.freeTarget(t);
        m.targets.deinit(m.gpa);
        m.state_cache.deinit(m.gpa);
    }

    fn freeTarget(m: *Monitor, t: *Target) void {
        m.gpa.free(t.name);
        m.gpa.free(t.host);
        freeTags(m.gpa, t.tags);
        m.gpa.destroy(t);
    }

    fn slot(m: *const Monitor, t: i64) usize {
        return @intCast(@mod(@divFloor(t, m.cycle_s), history_len));
    }

    fn find(m: *Monitor, id: u32) ?usize {
        for (m.targets.items, 0..) |t, i| if (t.id == id) return i;
        return null;
    }

    // ----- target management (caller holds no lock) -------------------------

    pub fn add(m: *Monitor, name: []const u8, host: []const u8, tags: []const []const u8) (Error || error{OutOfMemory})!u32 {
        try validateName(name);
        try validateHost(host);
        try validateTags(tags);
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const id = try m.addLocked(m.next_id, name, host, tags);
        m.version += 1;
        m.saveConfigLocked();
        return id;
    }

    /// `tags` must have passed `validateTags`.
    fn addLocked(m: *Monitor, id: u32, name: []const u8, host: []const u8, tags: []const []const u8) (Error || error{OutOfMemory})!u32 {
        if (m.targets.items.len >= max_targets) return error.TooManyTargets;
        const t = try m.gpa.create(Target);
        errdefer m.gpa.destroy(t);
        const name_copy = try m.gpa.dupe(u8, name);
        errdefer m.gpa.free(name_copy);
        const host_copy = try m.gpa.dupe(u8, host);
        errdefer m.gpa.free(host_copy);
        const tags_copy = try dupeTags(m.gpa, tags);
        errdefer freeTags(m.gpa, tags_copy);
        t.* = .{ .id = id, .name = name_copy, .host = host_copy, .tags = tags_copy };
        try m.targets.append(m.gpa, t);
        m.next_id = @max(m.next_id, id + 1);
        return id;
    }

    pub fn remove(m: *Monitor, id: u32) Error!void {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const i = m.find(id) orelse return error.UnknownTarget;
        m.freeTarget(m.targets.orderedRemove(i));
        m.version += 1;
        m.saveConfigLocked();
    }

    /// Replaces the target's tags.
    pub fn setTags(m: *Monitor, id: u32, tags: []const []const u8) (Error || error{OutOfMemory})!void {
        try validateTags(tags);
        const copy = try dupeTags(m.gpa, tags);
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const t = m.targets.items[
            m.find(id) orelse {
                freeTags(m.gpa, copy);
                return error.UnknownTarget;
            }
        ];
        freeTags(m.gpa, t.tags);
        t.tags = copy;
        m.version += 1;
        m.saveConfigLocked();
    }

    /// Renames the target and/or moves it to another host (null: keep). A new
    /// host keeps the history but not the current status: the target is
    /// PENDING until the next cycle, and an acknowledgement is dropped (it was
    /// for the old host).
    pub fn edit(m: *Monitor, id: u32, name: ?[]const u8, host: ?[]const u8) (Error || error{OutOfMemory})!void {
        if (name) |n| try validateName(n);
        if (host) |h| try validateHost(h);
        const name_copy = if (name) |n| try m.gpa.dupe(u8, n) else null;
        errdefer if (name_copy) |n| m.gpa.free(n);
        const host_copy = if (host) |h| try m.gpa.dupe(u8, h) else null;
        errdefer if (host_copy) |h| m.gpa.free(h);
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const t = m.targets.items[m.find(id) orelse return error.UnknownTarget];
        if (name_copy) |n| {
            m.gpa.free(t.name);
            t.name = n;
        }
        if (host_copy) |h| {
            if (std.mem.eql(u8, h, t.host)) {
                m.gpa.free(h);
            } else {
                m.gpa.free(t.host);
                t.host = h;
                t.last = .{};
                t.last_error = null;
                t.acked = false;
                t.ok_streak = 0;
            }
        }
        m.version += 1;
        m.saveConfigLocked();
    }

    pub const Action = enum { pause, resume_, ack, unack };

    pub fn apply(m: *Monitor, id: u32, action: Action) Error!void {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const t = m.targets.items[m.find(id) orelse return error.UnknownTarget];
        switch (action) {
            .pause => t.paused = true,
            .resume_ => {
                t.paused = false;
                // The last sample predates the pause; do not show it as now.
                t.last = .{};
            },
            // Like a Nagios acknowledgement: only a problem can be acknowledged.
            .ack => {
                if (t.status() != .down) return error.NotDown;
                t.acked = true;
                t.ok_streak = 0;
            },
            .unack => t.acked = false,
        }
        m.version += 1;
        m.saveConfigLocked();
    }

    // ----- probing ------------------------------------------------------------

    /// Probe forever, one cycle per `cycle_s`, aligned to the wall clock.
    pub fn loop(m: *Monitor) Io.Cancelable!void {
        m.started_at.store(Io.Clock.real.now(m.io).toSeconds(), .monotonic);
        while (true) {
            const now = Io.Clock.real.now(m.io).toSeconds();
            const start = now - @mod(now, m.cycle_s);
            m.runCycle(start);
            const after = Io.Clock.real.now(m.io).toSeconds();
            m.cycle_done_at.store(after, .monotonic);
            try m.io.sleep(.fromSeconds(@max(1, start + m.cycle_s - after)), .awake);
        }
    }

    pub const Health = struct { ok: bool, probing_ok: bool, last_cycle: i64 };

    /// Healthy while cycles keep finishing (at most `3 * cycle_s` apart,
    /// counted from the start before the first one) and the last one could
    /// open its ICMP socket. Unreachable targets do not make it unhealthy.
    pub fn health(m: *Monitor, now: i64) Health {
        const done = m.cycle_done_at.load(.monotonic);
        const since = if (done == 0) m.started_at.load(.monotonic) else done;
        const probing_ok = m.probing_ok.load(.monotonic);
        return .{ .ok = probing_ok and now - since <= 3 * m.cycle_s, .probing_ok = probing_ok, .last_cycle = done };
    }

    /// One probing cycle. `t` is the cycle's start (unix seconds).
    pub fn runCycle(m: *Monitor, t: i64) void {
        var arena_state: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // 1. Snapshot the active targets, so probing runs without the lock.
        const jobs = blk: {
            m.mutex.lockUncancelable(m.io);
            defer m.mutex.unlock(m.io);
            var list: std.ArrayList(Job) = .empty;
            for (m.targets.items) |target| {
                if (target.paused) continue;
                const host = arena.dupe(u8, target.host) catch return;
                list.append(arena, .{ .id = target.id, .host = host }) catch return;
            }
            break :blk list.items;
        };
        if (jobs.len == 0) {
            if (m.demo) {
                m.mutex.lockUncancelable(m.io);
                defer m.mutex.unlock(m.io);
                m.demoFillLocked(t);
                m.version += 1;
            }
            return;
        }

        // 2. Resolve names (numeric addresses skip DNS).
        for (jobs) |*job| {
            job.addr = resolve(m.io, job.host) catch {
                job.err = "name does not resolve";
                continue;
            };
        }

        // 3. Ping every resolved target in one paced round.
        if (probe(m.gpa, jobs)) {
            m.probing_ok.store(true, .monotonic);
        } else |err| {
            log.err("probing failed: {t}", .{err});
            m.probing_ok.store(false, .monotonic);
            for (jobs) |*job| if (job.err == null) {
                job.err = "cannot open ICMP socket";
            };
        }

        // 4. Record the results; a target may have been removed meanwhile.
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        for (jobs) |*job| {
            const i = m.find(job.id) orelse continue;
            m.recordLocked(m.targets.items[i], t, job);
        }
        if (m.demo) m.demoFillLocked(t);
        m.version += 1;
        m.saveHistoryLocked();
    }

    fn recordLocked(m: *Monitor, target: *Target, t: i64, job: *Job) void {
        if (target.paused) return; // paused while this cycle ran
        if (!std.mem.eql(u8, target.host, job.host)) return; // moved to another host meanwhile
        var sample: Sample = .{ .t = t, .sent = probes_per_cycle };
        if (job.err == null) {
            sample.sent = job.sent;
            summarize(&sample, job.rtts[0..job.replies]);
        }
        target.last_error = job.err;
        target.last = sample;
        target.history[m.slot(t)] = sample;

        if (target.acked) {
            if (target.status() == .down) {
                target.ok_streak = 0;
            } else {
                target.ok_streak += 1;
                if (target.ok_streak >= ack_clear_after) {
                    target.acked = false;
                    target.ok_streak = 0;
                    m.saveConfigLocked();
                }
            }
        }
    }

    /// Once per hour (and after the first cycle of a run): everything older
    /// than the last hour of real data, or than this run, becomes sample data.
    fn demoFillLocked(m: *Monitor, t: i64) void {
        if (m.demo_since == 0) m.demo_since = t;
        const hour = t - @mod(t, 3600);
        if (hour == m.demo_hour) return;
        m.demo_hour = hour;
        // On a cycle boundary (`t` and `demo_since` are), so the real
        // samples are found below whatever `cycle_s` is.
        const hour_ago = hour - 3600 + @mod(-(hour - 3600), m.cycle_s);
        const live_from = @max(hour_ago, m.demo_since);
        m.demo_from = live_from;
        const oldest = t - (history_len - 1) * m.cycle_s;
        for (m.targets.items) |target| {
            const scenario = target.scenario orelse continue;
            // The sample past is scaled to the target's real median latency.
            var real: [history_len]u32 = undefined;
            var n: usize = 0;
            var at = live_from;
            while (at <= t) : (at += m.cycle_s) {
                const s = target.history[m.slot(at)];
                if (s.t == at and s.recv > 0) {
                    real[n] = s.rtt_us;
                    n += 1;
                }
            }
            const base_ms: f64 = if (n > 0) @as(f64, @floatFromInt(median(real[0..n]))) / 1000 else 20;

            var when = live_from - m.cycle_s;
            while (when >= oldest) : (when -= m.cycle_s) {
                var rtts: [probes_per_cycle]u32 = undefined;
                const replies = demo.probes(scenario, target.id, when, base_ms, live_from, &rtts);
                var sample: Sample = .{ .t = when, .sent = probes_per_cycle };
                summarize(&sample, rtts[0..replies]);
                target.history[m.slot(when)] = sample;
            }
        }
    }

    // ----- persistence ----------------------------------------------------------

    /// The on-disk target list. Hand-written files may omit everything but
    /// `name` and `host`; a file from 1.0.0 has no `tags`.
    const ConfigFile = struct {
        targets: []const struct {
            id: u32 = 0,
            name: []const u8,
            host: []const u8,
            tags: []const []const u8 = &.{},
            paused: bool = false,
            acked: bool = false,
            /// A `demo.Scenario` name, used with `--demo`.
            demo: ?[]const u8 = null,
        },
    };

    pub fn loadConfig(m: *Monitor) !void {
        const bytes = Io.Dir.cwd().readFileAlloc(m.io, m.config_path, m.gpa, .limited(1 << 20)) catch |err| switch (err) {
            // A writable instance starts empty and writes the file on the
            // first change; a read-only one would show nothing, forever.
            error.FileNotFound => if (m.read_only) return err else return,
            else => return err,
        };
        defer m.gpa.free(bytes);
        const parsed = try std.json.parseFromSlice(ConfigFile, m.gpa, bytes, .{});
        defer parsed.deinit();
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        for (parsed.value.targets) |entry| {
            try validateName(entry.name);
            try validateHost(entry.host);
            try validateTags(entry.tags);
            const id = if (entry.id != 0 and m.find(entry.id) == null) entry.id else m.next_id;
            _ = try m.addLocked(id, entry.name, entry.host, entry.tags);
            const t = m.targets.items[m.targets.items.len - 1];
            t.paused = entry.paused;
            t.acked = entry.acked;
            if (entry.demo) |name| t.scenario = std.meta.stringToEnum(demo.Scenario, name) orelse return error.InvalidScenario;
        }
    }

    fn saveConfigLocked(m: *Monitor) void {
        if (m.read_only) return;
        var aw: Io.Writer.Allocating = .init(m.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("{\n  \"targets\": [") catch return;
        for (m.targets.items, 0..) |t, i| {
            w.print("{s}\n    {{ \"id\": {d}, \"name\": {f}, \"host\": {f}, \"paused\": {}, \"acked\": {}", .{
                if (i == 0) "" else ",", t.id, std.json.fmt(t.name, .{}), std.json.fmt(t.host, .{}), t.paused, t.acked,
            }) catch return;
            if (t.tags.len > 0) writeTags(w, t.tags, ", \"tags\": ") catch return;
            if (t.scenario) |sc| w.print(", \"demo\": \"{t}\"", .{sc}) catch return;
            w.writeAll(" }") catch return;
        }
        w.writeAll("\n  ]\n}\n") catch return;
        writeFileAtomic(m.io, m.config_path, aw.written()) catch |err|
            log.err("cannot write {s}: {t}", .{ m.config_path, err });
    }

    /// History file: per target id, the non-empty samples as
    /// `[t, sent, recv, rtt_us, jitter_us]`; files from 1.0.0 lack `jitter_us`.
    const HistoryFile = struct {
        cycle_s: i64,
        targets: []const struct { id: u32, samples: []const []const i64 },
    };

    pub fn loadHistory(m: *Monitor) !void {
        const path = m.history_path orelse return;
        const bytes = Io.Dir.cwd().readFileAlloc(m.io, path, m.gpa, .limited(64 << 20)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer m.gpa.free(bytes);
        // The history is only nice to have: an unreadable file is moved
        // aside rather than keeping the daemon from starting (a restart
        // loop under systemd until someone notices).
        const parsed = std.json.parseFromSlice(HistoryFile, m.gpa, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                var bad_buf: [Io.Dir.max_path_bytes]u8 = undefined;
                const bad = try std.mem.print(&bad_buf, "{s}.bad", .{path});
                try Io.Dir.rename(.cwd(), path, .cwd(), bad, m.io);
                log.warn("{s} is not a valid history ({t}), moved to {s}; starting without history", .{ path, err, bad });
                return;
            },
        };
        defer parsed.deinit();
        if (parsed.value.cycle_s != m.cycle_s) return; // slots would not line up
        const oldest = Io.Clock.real.now(m.io).toSeconds() - history_len * m.cycle_s;
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        for (parsed.value.targets) |entry| {
            const t = m.targets.items[m.find(entry.id) orelse continue];
            for (entry.samples) |s| {
                if (s.len != 4 and s.len != 5) continue;
                if (s[0] <= oldest) continue;
                const sample: Sample = .{
                    .t = s[0],
                    .sent = std.math.cast(u8, s[1]) orelse continue,
                    .recv = std.math.cast(u8, s[2]) orelse continue,
                    .rtt_us = std.math.cast(u32, s[3]) orelse continue,
                    .jitter_us = if (s.len == 5) std.math.cast(u32, s[4]) orelse continue else 0,
                };
                // writeSeries computes `sent - recv`.
                if (sample.sent > probes_per_cycle or sample.recv > sample.sent) continue;
                t.history[m.slot(sample.t)] = sample;
                if (sample.t > t.last.t) t.last = sample;
            }
        }
    }

    fn saveHistoryLocked(m: *Monitor) void {
        const path = m.history_path orelse return;
        var aw: Io.Writer.Allocating = .init(m.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.print("{{\"cycle_s\":{d},\"targets\":[", .{m.cycle_s}) catch return;
        for (m.targets.items, 0..) |t, i| {
            w.print("{s}{{\"id\":{d},\"samples\":[", .{ if (i == 0) "" else ",", t.id }) catch return;
            var first = true;
            // Sample data is regenerated, never kept: a history file must
            // not hand made-up outages to an instance without --demo.
            const sample_before = if (m.demo and t.scenario != null) m.demo_from else 0;
            for (t.history) |s| {
                if (s.t == 0 or s.t < sample_before) continue;
                w.print("{s}[{d},{d},{d},{d},{d}]", .{ if (first) "" else ",", s.t, s.sent, s.recv, s.rtt_us, s.jitter_us }) catch return;
                first = false;
            }
            w.writeAll("]}") catch return;
        }
        w.writeAll("]}\n") catch return;
        writeFileAtomic(m.io, path, aw.written()) catch |err|
            log.err("cannot write {s}: {t}", .{ path, err });
    }

    // ----- web API --------------------------------------------------------------

    /// The tag of the current state: it changes when a cycle is recorded,
    /// a target changes or a new cycle starts (the series shift by one), and
    /// at no other time.
    pub fn stateTag(m: *Monitor) StateTag {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        return m.stateTagLocked();
    }

    fn stateTagLocked(m: *Monitor) StateTag {
        const now = Io.Clock.real.now(m.io).toSeconds();
        return .{ .version = m.version, .end = now - @mod(now, m.cycle_s) };
    }

    /// Everything the page shows, as JSON (see `writeStateLocked`), copied
    /// into `arena`. Built once per tag and then served from `state_cache`,
    /// so any number of viewers costs one serialization per change.
    pub fn stateJson(m: *Monitor, arena: std.mem.Allocator) error{OutOfMemory}!struct { tag: StateTag, json: []u8 } {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const tag = m.stateTagLocked();
        if (!std.meta.eql(m.cache_tag, tag)) {
            m.cache_tag = null;
            m.state_cache.clearRetainingCapacity();
            var aw: Io.Writer.Allocating = .fromArrayList(m.gpa, &m.state_cache);
            defer m.state_cache = aw.toArrayList();
            m.writeStateLocked(&aw.writer, tag.end) catch return error.OutOfMemory;
            m.cache_tag = tag;
        }
        return .{ .tag = tag, .json = try arena.dupe(u8, m.state_cache.items) };
    }

    /// Per target, `rtt` (ms), `jitter` (ms) and `loss` (%) hold one entry per cycle of the
    /// last 24 hours, oldest first, the newest at cycle start `newest`;
    /// `null` where there is no sample.
    fn writeStateLocked(m: *Monitor, w: *Io.Writer, newest: i64) Io.Writer.Error!void {
        try w.print(
            "{{\"read_only\":{},\"demo_from\":{d},\"cycle_s\":{d},\"probes\":{d},\"ack_clear_after\":{d},\"end\":{d},\"targets\":[",
            .{ m.read_only, m.demo_from, m.cycle_s, probes_per_cycle, ack_clear_after, newest },
        );
        for (m.targets.items, 0..) |t, i| {
            try w.print(
                "{s}{{\"id\":{d},\"name\":{f},\"host\":{f},\"status\":\"{t}\",\"paused\":{},\"acked\":{},\"ok_streak\":{d},\"error\":{f},\"sample\":{}",
                .{
                    if (i == 0) "" else ",",         t.id,
                    std.json.fmt(t.name, .{}),       std.json.fmt(t.host, .{}),
                    t.status(),                      t.paused,
                    t.acked,                         t.ok_streak,
                    std.json.fmt(t.last_error, .{}), m.demo and t.scenario != null,
                },
            );
            try writeTags(w, t.tags, ",\"tags\":");
            try w.writeAll(",\"rtt\":[");
            try m.writeSeries(w, t, newest, .rtt);
            try w.writeAll("],\"jitter\":[");
            try m.writeSeries(w, t, newest, .jitter);
            try w.writeAll("],\"loss\":[");
            try m.writeSeries(w, t, newest, .loss);
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
    }

    fn writeSeries(m: *Monitor, w: *Io.Writer, t: *const Target, newest: i64, comptime what: enum { rtt, jitter, loss }) Io.Writer.Error!void {
        var k: i64 = history_len - 1;
        while (k >= 0) : (k -= 1) {
            const at = newest - k * m.cycle_s;
            const s = t.history[m.slot(at)];
            if (k != history_len - 1) try w.writeByte(',');
            if (s.t != at or s.sent == 0) {
                try w.writeAll("null");
            } else switch (what) {
                .rtt => if (s.recv == 0) try w.writeAll("null") else try writeMs(w, s.rtt_us),
                .jitter => if (s.recv < 2) try w.writeAll("null") else try writeMs(w, s.jitter_us),
                .loss => try w.print("{d}", .{@as(u32, s.sent - s.recv) * 100 / s.sent}),
            }
        }
    }
};

// ----- helpers ------------------------------------------------------------------

/// Milliseconds, two decimals below 10 ms (LAN targets) and one above.
fn writeMs(w: *Io.Writer, us: u32) Io.Writer.Error!void {
    const v = @as(f64, @floatFromInt(us)) / 1000;
    if (us < 10_000) try w.print("{d:.2}", .{v}) else try w.print("{d:.1}", .{v});
}

/// Sorts `v` (not empty) and returns its median.
fn median(v: []u32) u32 {
    std.mem.sortUnstable(u32, v, {}, std.sort.asc(u32));
    return v[v.len / 2];
}

/// Fills `sample.recv`, `rtt_us` (median) and `jitter_us` from the replies'
/// round-trip times, given in reply order (sorted here).
fn summarize(sample: *Sample, rtts: []u32) void {
    sample.recv = @intCast(rtts.len);
    if (rtts.len == 0) return;
    sample.jitter_us = jitter(rtts);
    sample.rtt_us = median(rtts);
}

/// Mean absolute difference between consecutive round-trip times, in reply
/// order (the usual "jitter" of ping tools); 0 with fewer than two.
fn jitter(rtts: []const u32) u32 {
    if (rtts.len < 2) return 0;
    var sum: u64 = 0;
    for (rtts[1..], rtts[0 .. rtts.len - 1]) |b, a| sum += @max(a, b) - @min(a, b);
    return @intCast(sum / (rtts.len - 1));
}

fn writeTags(w: *Io.Writer, tags: []const []const u8, prefix: []const u8) Io.Writer.Error!void {
    try w.writeAll(prefix);
    try w.writeByte('[');
    for (tags, 0..) |tag, i| try w.print("{s}{f}", .{ if (i == 0) "" else ",", std.json.fmt(tag, .{}) });
    try w.writeByte(']');
}

/// At most `max_tags` tags of 1 to `max_tag_len` bytes, no control
/// characters, spaces or commas (the page splits its input on them).
fn validateTags(tags: []const []const u8) Error!void {
    if (tags.len > max_tags) return error.InvalidTags;
    for (tags) |tag| {
        if (tag.len == 0 or tag.len > max_tag_len) return error.InvalidTags;
        for (tag) |c| if (c <= 0x20 or c == 0x7f or c == ',') return error.InvalidTags;
    }
}

/// A copy of validated `tags`, ASCII-lowercased and without duplicates.
fn dupeTags(gpa: std.mem.Allocator, tags: []const []const u8) error{OutOfMemory}![][]u8 {
    var list: std.ArrayList([]u8) = try .initCapacity(gpa, tags.len);
    errdefer freeTags(gpa, list.items);
    outer: for (tags) |tag| {
        for (list.items) |have| if (std.ascii.eqlIgnoreCase(have, tag)) continue :outer;
        const copy = try gpa.dupe(u8, tag);
        list.appendAssumeCapacity(std.ascii.lowerString(copy, tag));
    }
    return list.toOwnedSlice(gpa);
}

fn freeTags(gpa: std.mem.Allocator, tags: [][]u8) void {
    for (tags) |tag| gpa.free(tag);
    gpa.free(tags);
}

fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > 64) return error.InvalidName;
    for (name) |c| if (c < 0x20 or c == 0x7f) return error.InvalidName;
}

/// A numeric address, or a host name valid for DNS.
fn validateHost(host: []const u8) Error!void {
    if (fping.Addr.parse(host)) |_| return else |_| {}
    _ = Io.net.HostName.init(host) catch return error.InvalidHost;
}

/// A temporary file next to `path`, synced to disk before it is renamed
/// over `path`: a crash or power loss leaves the old or the new content,
/// never an empty or truncated file.
fn writeFileAtomic(io: Io, path: []const u8, data: []const u8) !void {
    var file = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, data);
    try file.file.sync(io);
    try file.replace(io);
}

/// First address of `host`; numeric addresses skip DNS.
fn resolve(io: Io, host: []const u8) !fping.Addr {
    if (fping.Addr.parse(host)) |addr| return addr else |_| {}
    const HostName = Io.net.HostName;
    var buf: [16]HostName.LookupResult = undefined;
    var queue: Io.Queue(HostName.LookupResult) = .init(&buf);
    // lookup() blocks while the queue is full, so drain it concurrently.
    var future = try io.concurrent(HostName.lookup, .{ try HostName.init(host), io, &queue, .{ .port = 0 } });
    defer _ = future.cancel(io) catch {};
    var found: ?fping.Addr = null;
    while (queue.getOne(io)) |result| switch (result) {
        .address => |ip| {
            if (found == null) found = fping.Addr.fromIpAddress(ip);
        },
        .canonical_name => {},
    } else |_| {}
    try future.await(io);
    return found orelse error.UnknownHostName;
}

/// One target's share of a cycle.
const Job = struct {
    id: u32,
    host: []const u8,
    addr: ?fping.Addr = null,
    err: ?[]const u8 = null,
    rtts: [probes_per_cycle]u32 = undefined,
    replies: u8 = 0,
    sent: u8 = 0,
};

/// Ping every job that has an address, `probes_per_cycle` times, in one round.
fn probe(gpa: std.mem.Allocator, jobs: []Job) !void {
    var pinger = try fping.Pinger.init(gpa, .{
        .mode = .count,
        .count = probes_per_cycle,
        // Spread the probes: 20 ms between any two packets, 1 s between
        // probes to the same host, 1 s to answer, and a random start offset
        // within 500 ms so consecutive cycles do not line up.
        .interval_ns = 20 * std.time.ns_per_ms,
        .perhost_interval_ns = std.time.ns_per_s,
        .timeout_ns = std.time.ns_per_s,
        .jitter_ns = 500 * std.time.ns_per_ms,
        // Several Pinger instances in one process must not share replies.
        .raw_ident = .unique,
    });
    defer pinger.deinit();

    // Pinger target ids are dense indexes; map them back to jobs.
    var index: [max_targets]*Job = undefined;
    var n: usize = 0;
    for (jobs) |*job| {
        const addr = job.addr orelse continue;
        _ = try pinger.addTargetAddr(addr);
        index[n] = job;
        n += 1;
    }
    if (n == 0) return;

    const Collect = struct {
        fn onResult(ctx: ?*anyopaque, id: fping.TargetId, _: u16, outcome: fping.Outcome) void {
            const map: *[max_targets]*Job = @ptrCast(@alignCast(ctx.?));
            const job = map[id];
            switch (outcome) {
                .reply => |r| if (job.replies < probes_per_cycle) {
                    job.rtts[job.replies] = @intCast(@min(r.rtt_ns / std.time.ns_per_us, std.math.maxInt(u32)));
                    job.replies += 1;
                },
                else => {},
            }
        }
    };
    pinger.setResultCallback(&index, Collect.onResult);
    try pinger.run();
    for (index[0..n], 0..) |job, id| job.sent = @intCast(pinger.stats(@intCast(id)).sent);
}

// ----- tests ----------------------------------------------------------------------

const testing = std.testing;

fn testMonitor() Monitor {
    return .{ .gpa = testing.allocator, .io = testing.io, .config_path = "unused", .read_only = true };
}

fn fakeCycle(m: *Monitor, id: u32, t: i64, recv: u8) void {
    m.mutex.lockUncancelable(m.io);
    defer m.mutex.unlock(m.io);
    const target = m.targets.items[m.find(id).?];
    var job: Job = .{ .id = id, .host = target.host, .sent = probes_per_cycle, .replies = recv };
    for (0..recv) |i| job.rtts[i] = @intCast(1000 * (i + 1));
    m.recordLocked(target, t, &job);
}

test "status follows the last sample" {
    var m = testMonitor();
    defer m.deinit();
    const id = try m.add("a", "192.0.2.1", &.{});
    const t = m.targets.items[0];
    try testing.expectEqual(.pending, t.status());
    fakeCycle(&m, id, 60, 5);
    try testing.expectEqual(.up, t.status());
    try testing.expectEqual(@as(u32, 3000), t.last.rtt_us); // median of 1..5 ms
    try testing.expectEqual(@as(u32, 1000), t.last.jitter_us); // 1 ms steps
    fakeCycle(&m, id, 120, 2);
    try testing.expectEqual(.degraded, t.status());
    fakeCycle(&m, id, 180, 0);
    try testing.expectEqual(.down, t.status());
    try m.apply(id, .pause);
    try testing.expectEqual(.paused, t.status());
}

test "acknowledgement needs DOWN and clears after five good cycles" {
    var m = testMonitor();
    defer m.deinit();
    const id = try m.add("a", "192.0.2.1", &.{});
    fakeCycle(&m, id, 60, 5);
    try testing.expectError(error.NotDown, m.apply(id, .ack));
    fakeCycle(&m, id, 120, 0);
    try m.apply(id, .ack);
    const t = m.targets.items[0];
    // A relapse resets the streak.
    for (0..4) |i| fakeCycle(&m, id, 180 + 60 * @as(i64, @intCast(i)), 5);
    fakeCycle(&m, id, 420, 0);
    try testing.expect(t.acked);
    for (0..ack_clear_after - 1) |i| fakeCycle(&m, id, 480 + 60 * @as(i64, @intCast(i)), 3);
    try testing.expect(t.acked);
    fakeCycle(&m, id, 480 + 60 * (ack_clear_after - 1), 5);
    try testing.expect(!t.acked);
}

test "history keeps 24 hours and reports gaps as null" {
    var m = testMonitor();
    defer m.deinit();
    const id = try m.add("a", "192.0.2.1", &.{});
    const t0: i64 = 1_700_000_040; // a cycle boundary
    fakeCycle(&m, id, t0, 5);
    fakeCycle(&m, id, t0 + history_len * 60, 4); // same slot, a day later
    const t = m.targets.items[0];
    try testing.expectEqual(t0 + history_len * 60, t.history[m.slot(t0)].t);
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try m.writeSeries(&aw.writer, t, t0 + history_len * 60, .loss);
    try testing.expect(std.mem.endsWith(u8, aw.written(), "null,null,20"));
}

test "the state is built once per change and shared" {
    var m = testMonitor();
    defer m.deinit();
    m.cycle_s = 1 << 30; // no cycle boundary (which changes the tag) during the test
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const id = try m.add("a", "192.0.2.1", &.{});
    const first = try m.stateJson(arena);
    try testing.expectEqual(first.tag, m.stateTag());
    try m.apply(id, .pause);
    try testing.expect(m.stateTag().version != first.tag.version);
    // Rebuilt from the cache only when the tag changed: corrupt the cache to see.
    m.state_cache.items[0] = 'X';
    const second = try m.stateJson(arena);
    try testing.expect(std.mem.find(u8, second.json, "\"paused\":true") != null);
    try testing.expectEqual('{', second.json[0]);
    m.state_cache.items[0] = 'X';
    try testing.expectEqual('X', (try m.stateJson(arena)).json[0]);
}

test "health: cycles must keep finishing and probing must work" {
    var m = testMonitor();
    defer m.deinit();
    m.started_at.store(1000, .monotonic);
    try testing.expect(m.health(1000 + 3 * 60).ok); // first cycle still running
    try testing.expect(!m.health(1001 + 3 * 60).ok); // ... for too long
    m.cycle_done_at.store(2000, .monotonic);
    try testing.expect(m.health(2000 + 3 * 60).ok);
    try testing.expect(!m.health(2001 + 3 * 60).ok);
    m.probing_ok.store(false, .monotonic);
    try testing.expect(!m.health(2000).ok);
}

test "persistence: missing target list, unusable history, atomic writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [3][128]u8 = undefined;
    const dir = try std.mem.print(&buf[0], ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const config = try std.mem.print(&buf[1], "{s}/targets.json", .{dir});
    const history = try std.mem.print(&buf[2], "{s}/history.json", .{dir});

    // No target list: a writable instance starts empty, a read-only one fails.
    var m: Monitor = .{ .gpa = testing.allocator, .io = testing.io, .config_path = config, .history_path = history };
    defer m.deinit();
    try m.loadConfig();
    try testing.expectEqual(0, m.targets.items.len);
    m.read_only = true;
    try testing.expectError(error.FileNotFound, m.loadConfig());
    m.read_only = false;

    // The first change writes the list (through a synced temporary file).
    const id = try m.add("a", "192.0.2.1", &.{});
    const saved = try tmp.dir.readFileAlloc(testing.io, "targets.json", testing.allocator, .limited(4096));
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.find(u8, saved, "\"host\": \"192.0.2.1\"") != null);

    // Garbage is moved aside (with a warning, muted here), the daemon starts
    // without history.
    testing.log_level = .err;
    defer testing.log_level = .warn;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "history.json", .data = "{\"cycle_s\":60,\"tar" });
    try m.loadHistory();
    _ = try tmp.dir.statFile(testing.io, "history.json.bad", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "history.json", .{}));

    // An impossible sample (more replies than probes) is skipped, not served.
    const now = Io.Clock.real.now(testing.io).toSeconds();
    const t = now - @mod(now, 60);
    var json: [256]u8 = undefined;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "history.json", .data = try std.mem.print(
        &json,
        "{{\"cycle_s\":60,\"targets\":[{{\"id\":{d},\"samples\":[[{d},2,5,1000],[{d},5,4,1000],[{d},5,5,900,70],[{d},5]]}}]}}",
        .{ id, t - 180, t - 120, t - 60, t },
    ) });
    try m.loadHistory();
    const target = m.targets.items[0];
    try testing.expectEqual(0, target.history[m.slot(t - 180)].t);
    // A 1.0.0 sample (no jitter) and a current one load; a short one does not.
    try testing.expectEqual(4, target.history[m.slot(t - 120)].recv);
    try testing.expectEqual(0, target.history[m.slot(t - 120)].jitter_us);
    try testing.expectEqual(70, target.history[m.slot(t - 60)].jitter_us);
    try testing.expectEqual(0, target.history[m.slot(t)].t);
}

test "jitter is the mean step between consecutive replies" {
    try testing.expectEqual(0, jitter(&.{}));
    try testing.expectEqual(0, jitter(&.{1000}));
    try testing.expectEqual(0, jitter(&.{ 500, 500, 500 }));
    try testing.expectEqual(1500, jitter(&.{ 1000, 3000, 2000 })); // (2000 + 1000) / 2
}

test "demo: sample data before the real hour, real data kept" {
    var m = testMonitor();
    defer m.deinit();
    m.demo = true;
    const id = try m.add("a", "192.0.2.1", &.{});
    const t = m.targets.items[0];
    t.scenario = .outage;
    const hour: i64 = 1_700_006_400;
    // First run: everything before the first cycle becomes sample data.
    fakeCycle(&m, id, hour + 600, 5); // real: median 3 ms
    m.demoFillLocked(hour + 600);
    try testing.expectEqual(hour + 600, m.demo_from);
    try testing.expectEqual(hour + 540, t.history[m.slot(hour + 540)].t);
    try testing.expectEqual(hour + 600 - (history_len - 1) * 60, t.history[m.slot(hour + 660)].t);
    // The outage 3-3.75 h before the real data is in it, scaled to the real 3 ms.
    try testing.expectEqual(0, t.history[m.slot(hour + 600 - 3 * 3600 - 600)].recv);
    const calm = t.history[m.slot(hour + 600 - 3600)];
    try testing.expect(calm.recv > 0 and calm.rtt_us >= 3000 and calm.rtt_us < 10_000);
    // Later fills keep the last full hour of real data, and this run's.
    for (11..70) |i| fakeCycle(&m, id, hour + 60 * @as(i64, @intCast(i)), 4);
    m.demoFillLocked(hour + 3600 + 540);
    try testing.expectEqual(hour + 600, m.demo_from); // max(hour, first cycle)
    try testing.expectEqual(4, t.history[m.slot(hour + 660)].recv); // real
    for (70..2 * 60 + 10) |i| fakeCycle(&m, id, hour + 60 * @as(i64, @intCast(i)), 4);
    m.demoFillLocked(hour + 2 * 3600 + 540);
    try testing.expectEqual(hour + 3600, m.demo_from);
    try testing.expectEqual(4, t.history[m.slot(hour + 3600)].recv); // real
    // A cycle that does not divide the hour still finds the real samples.
    m.cycle_s = 7;
    const base: i64 = 7 * 242_858_000; // cycle starts are multiples of cycle_s
    m.demo_since = base;
    m.demo_hour = 0;
    const now = base + 7 * 1000; // two hour boundaries later
    for (0..1001) |i| fakeCycle(&m, id, base + 7 * @as(i64, @intCast(i)), 5);
    m.demoFillLocked(now);
    try testing.expectEqual(0, @mod(m.demo_from, 7));
    const calm7 = t.history[m.slot(m.demo_from - 7 * 300)];
    try testing.expect(calm7.recv > 0 and calm7.rtt_us >= 3000 and calm7.rtt_us < 10_000);
}

test "tags: validated, normalized, saved, loaded and served" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [2][128]u8 = undefined;
    const dir = try std.mem.print(&buf[0], ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const config = try std.mem.print(&buf[1], "{s}/targets.json", .{dir});

    var m: Monitor = .{ .gpa = testing.allocator, .io = testing.io, .config_path = config };
    defer m.deinit();
    try testing.expectError(error.InvalidTags, m.add("a", "192.0.2.1", &.{"two words"}));
    try testing.expectError(error.InvalidTags, m.add("a", "192.0.2.1", &.{"a,b"}));
    try testing.expectError(error.InvalidTags, m.add("a", "192.0.2.1", &.{""}));
    const long: [max_tag_len + 1]u8 = @splat('x');
    try testing.expectError(error.InvalidTags, m.add("a", "192.0.2.1", &.{&long}));
    const many: [max_tags + 1][]const u8 = @splat("t");
    try testing.expectError(error.InvalidTags, m.add("a", "192.0.2.1", &many));
    try testing.expectEqual(0, m.targets.items.len);

    const id = try m.add("a", "192.0.2.1", &.{ "DNS", "praha-1", "dns" });
    const t = m.targets.items[0];
    try testing.expectEqual(2, t.tags.len);
    try testing.expectEqualStrings("dns", t.tags[0]);
    try testing.expectEqualStrings("praha-1", t.tags[1]);

    try testing.expectError(error.UnknownTarget, m.setTags(id + 1, &.{"x"}));
    try testing.expectError(error.InvalidTags, m.setTags(id, &.{"a b"}));
    try testing.expectEqual(2, t.tags.len); // unchanged
    const before = m.version;
    try m.setTags(id, &.{ "ipv6", "Core" });
    try testing.expect(m.version != before);
    _ = try m.add("b", "192.0.2.2", &.{});

    // Saved with the list (only when there are any), loaded back.
    const saved = try tmp.dir.readFileAlloc(testing.io, "targets.json", testing.allocator, .limited(4096));
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.find(u8, saved, "\"tags\": [\"ipv6\",\"core\"]") != null);
    try testing.expectEqual(1, std.mem.count(u8, saved, "\"tags\""));
    var m2: Monitor = .{ .gpa = testing.allocator, .io = testing.io, .config_path = config };
    defer m2.deinit();
    try m2.loadConfig();
    try testing.expectEqualStrings("core", m2.targets.items[0].tags[1]);
    try testing.expectEqual(0, m2.targets.items[1].tags.len);

    // Served in the state, an empty list included.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const state = try m2.stateJson(arena_state.allocator());
    try testing.expect(std.mem.find(u8, state.json, "\"tags\":[\"ipv6\",\"core\"]") != null);
    try testing.expect(std.mem.find(u8, state.json, "\"tags\":[]") != null);

    // A hand-written list with a bad tag is refused, like a bad host.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "targets.json", .data = "{\"targets\":[{\"name\":\"a\",\"host\":\"192.0.2.1\",\"tags\":[\"a b\"]}]}" });
    var m3: Monitor = .{ .gpa = testing.allocator, .io = testing.io, .config_path = config };
    defer m3.deinit();
    try testing.expectError(error.InvalidTags, m3.loadConfig());
}

test "edit: rename, move to another host, refuse bad input" {
    var m = testMonitor();
    defer m.deinit();
    const id = try m.add("a", "192.0.2.1", &.{});
    const t = m.targets.items[0];
    fakeCycle(&m, id, 60, 0);
    try m.apply(id, .ack);

    try testing.expectError(error.InvalidName, m.edit(id, "", null));
    try testing.expectError(error.InvalidHost, m.edit(id, null, "not a host"));
    try testing.expectError(error.UnknownTarget, m.edit(id + 1, "b", null));
    try testing.expectEqualStrings("a", t.name);

    // A new name keeps everything else.
    try m.edit(id, "router", null);
    try testing.expectEqualStrings("router", t.name);
    try testing.expect(t.acked);
    try testing.expectEqual(.down, t.status());
    // The same host again changes nothing.
    try m.edit(id, null, "192.0.2.1");
    try testing.expect(t.acked);

    // A new host: history kept, status and acknowledgement not.
    try m.edit(id, null, "192.0.2.2");
    try testing.expectEqualStrings("192.0.2.2", t.host);
    try testing.expectEqual(.pending, t.status());
    try testing.expect(!t.acked);
    try testing.expectEqual(60, t.history[m.slot(60)].t);

    // A cycle that probed the old host does not land on the new one.
    m.mutex.lockUncancelable(m.io);
    var job: Job = .{ .id = id, .host = "192.0.2.1", .sent = probes_per_cycle, .replies = 5 };
    m.recordLocked(t, 120, &job);
    m.mutex.unlock(m.io);
    try testing.expectEqual(.pending, t.status());
    try testing.expectEqual(0, t.history[m.slot(120)].t);
}

test "names and hosts are validated" {
    var m = testMonitor();
    defer m.deinit();
    try testing.expectError(error.InvalidName, m.add("", "192.0.2.1", &.{}));
    try testing.expectError(error.InvalidName, m.add("a\nb", "192.0.2.1", &.{}));
    try testing.expectError(error.InvalidHost, m.add("a", "not a host", &.{}));
    _ = try m.add("v6", "2001:db8::1", &.{});
    _ = try m.add("dns", "example.com", &.{});
}
