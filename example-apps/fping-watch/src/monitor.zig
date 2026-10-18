//! The monitor: a list of targets, one probing cycle per minute, and the last
//! 24 hours of results per target.
//!
//! Every cycle sends a few echo requests to each active target through one
//! `zig_fping.Pinger` (so global pacing and in-flight limits apply across all
//! targets) and stores one `Sample` per target: probes sent, replies received
//! and the median round-trip time.
//!
//! Locking: `mutex` guards `targets` and everything inside them. Probing runs
//! without the lock, on a copy of the target list, so the web UI never waits
//! for a cycle to finish.

const std = @import("std");
const Io = std.Io;
const fping = @import("zig_fping");

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
    paused: bool = false,
    acked: bool = false,
    /// Consecutive cycles that were not DOWN while acknowledged.
    ok_streak: u8 = 0,
    /// Why the last cycle could not probe (static string), if it could not.
    last_error: ?[]const u8 = null,
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

pub const Error = error{ InvalidName, InvalidHost, TooManyTargets, UnknownTarget, NotDown };

/// Upper bound on targets: this is a small demo, not a monitoring system.
pub const max_targets = 64;

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

    pub fn deinit(m: *Monitor) void {
        for (m.targets.items) |t| m.freeTarget(t);
        m.targets.deinit(m.gpa);
    }

    fn freeTarget(m: *Monitor, t: *Target) void {
        m.gpa.free(t.name);
        m.gpa.free(t.host);
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

    pub fn add(m: *Monitor, name: []const u8, host: []const u8) (Error || error{OutOfMemory})!u32 {
        try validateName(name);
        try validateHost(host);
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const id = try m.addLocked(m.next_id, name, host);
        m.saveConfigLocked();
        return id;
    }

    fn addLocked(m: *Monitor, id: u32, name: []const u8, host: []const u8) (Error || error{OutOfMemory})!u32 {
        if (m.targets.items.len >= max_targets) return error.TooManyTargets;
        const t = try m.gpa.create(Target);
        errdefer m.gpa.destroy(t);
        const name_copy = try m.gpa.dupe(u8, name);
        errdefer m.gpa.free(name_copy);
        const host_copy = try m.gpa.dupe(u8, host);
        errdefer m.gpa.free(host_copy);
        t.* = .{ .id = id, .name = name_copy, .host = host_copy };
        try m.targets.append(m.gpa, t);
        m.next_id = @max(m.next_id, id + 1);
        return id;
    }

    pub fn remove(m: *Monitor, id: u32) Error!void {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const i = m.find(id) orelse return error.UnknownTarget;
        m.freeTarget(m.targets.orderedRemove(i));
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
        m.saveConfigLocked();
    }

    // ----- probing ------------------------------------------------------------

    /// Probe forever, one cycle per `cycle_s`, aligned to the wall clock.
    pub fn loop(m: *Monitor) Io.Cancelable!void {
        while (true) {
            const now = Io.Clock.real.now(m.io).toSeconds();
            const start = now - @mod(now, m.cycle_s);
            m.runCycle(start);
            const after = Io.Clock.real.now(m.io).toSeconds();
            try m.io.sleep(.fromSeconds(@max(1, start + m.cycle_s - after)), .awake);
        }
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
        if (jobs.len == 0) return;

        // 2. Resolve names (numeric addresses skip DNS).
        for (jobs) |*job| {
            job.addr = resolve(m.io, job.host) catch {
                job.err = "name does not resolve";
                continue;
            };
        }

        // 3. Ping every resolved target in one paced round.
        probe(m.gpa, jobs) catch |err| {
            log.err("probing failed: {t}", .{err});
            for (jobs) |*job| if (job.err == null) {
                job.err = "cannot open ICMP socket";
            };
        };

        // 4. Record the results; a target may have been removed meanwhile.
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        for (jobs) |*job| {
            const i = m.find(job.id) orelse continue;
            m.recordLocked(m.targets.items[i], t, job);
        }
        m.saveHistoryLocked();
    }

    fn recordLocked(m: *Monitor, target: *Target, t: i64, job: *Job) void {
        if (target.paused) return; // paused while this cycle ran
        var sample: Sample = .{ .t = t, .sent = probes_per_cycle };
        if (job.err == null) {
            sample.sent = job.sent;
            sample.recv = job.replies;
            if (job.replies > 0) {
                const r = job.rtts[0..job.replies];
                std.mem.sortUnstable(u32, r, {}, std.sort.asc(u32));
                sample.rtt_us = r[r.len / 2];
            }
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

    // ----- persistence ----------------------------------------------------------

    /// The on-disk target list. Hand-written files may omit everything but
    /// `name` and `host`.
    const ConfigFile = struct {
        targets: []const struct {
            id: u32 = 0,
            name: []const u8,
            host: []const u8,
            paused: bool = false,
            acked: bool = false,
        },
    };

    pub fn loadConfig(m: *Monitor) !void {
        const bytes = try Io.Dir.cwd().readFileAlloc(m.io, m.config_path, m.gpa, .limited(1 << 20));
        defer m.gpa.free(bytes);
        const parsed = try std.json.parseFromSlice(ConfigFile, m.gpa, bytes, .{});
        defer parsed.deinit();
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        for (parsed.value.targets) |entry| {
            try validateName(entry.name);
            try validateHost(entry.host);
            const id = if (entry.id != 0 and m.find(entry.id) == null) entry.id else m.next_id;
            _ = try m.addLocked(id, entry.name, entry.host);
            const t = m.targets.items[m.targets.items.len - 1];
            t.paused = entry.paused;
            t.acked = entry.acked;
        }
    }

    fn saveConfigLocked(m: *Monitor) void {
        if (m.read_only) return;
        var aw: Io.Writer.Allocating = .init(m.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("{\n  \"targets\": [") catch return;
        for (m.targets.items, 0..) |t, i| {
            w.print("{s}\n    {{ \"id\": {d}, \"name\": {f}, \"host\": {f}, \"paused\": {}, \"acked\": {} }}", .{
                if (i == 0) "" else ",", t.id, std.json.fmt(t.name, .{}), std.json.fmt(t.host, .{}), t.paused, t.acked,
            }) catch return;
        }
        w.writeAll("\n  ]\n}\n") catch return;
        writeFileAtomic(m.io, m.config_path, aw.written()) catch |err|
            log.err("cannot write {s}: {t}", .{ m.config_path, err });
    }

    /// History file: per target id, the non-empty samples as
    /// `[t, sent, recv, rtt_us]`.
    const HistoryFile = struct {
        cycle_s: i64,
        targets: []const struct { id: u32, samples: []const [4]i64 },
    };

    pub fn loadHistory(m: *Monitor) !void {
        const path = m.history_path orelse return;
        const bytes = Io.Dir.cwd().readFileAlloc(m.io, path, m.gpa, .limited(64 << 20)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer m.gpa.free(bytes);
        const parsed = try std.json.parseFromSlice(HistoryFile, m.gpa, bytes, .{});
        defer parsed.deinit();
        if (parsed.value.cycle_s != m.cycle_s) return; // slots would not line up
        const oldest = Io.Clock.real.now(m.io).toSeconds() - history_len * m.cycle_s;
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        for (parsed.value.targets) |entry| {
            const t = m.targets.items[m.find(entry.id) orelse continue];
            for (entry.samples) |s| {
                if (s[0] <= oldest) continue;
                const sample: Sample = .{
                    .t = s[0],
                    .sent = std.math.cast(u8, s[1]) orelse continue,
                    .recv = std.math.cast(u8, s[2]) orelse continue,
                    .rtt_us = std.math.cast(u32, s[3]) orelse continue,
                };
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
            for (t.history) |s| {
                if (s.t == 0) continue;
                w.print("{s}[{d},{d},{d},{d}]", .{ if (first) "" else ",", s.t, s.sent, s.recv, s.rtt_us }) catch return;
                first = false;
            }
            w.writeAll("]}") catch return;
        }
        w.writeAll("]}\n") catch return;
        writeFileAtomic(m.io, path, aw.written()) catch |err|
            log.err("cannot write {s}: {t}", .{ path, err });
    }

    // ----- web API --------------------------------------------------------------

    /// Everything the page shows, as JSON. Per target, `rtt` (ms) and `loss`
    /// (%) hold one entry per cycle of the last 24 hours, oldest first;
    /// `null` where there is no sample.
    pub fn writeState(m: *Monitor, w: *Io.Writer) Io.Writer.Error!void {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const now = Io.Clock.real.now(m.io).toSeconds();
        const newest = now - @mod(now, m.cycle_s);
        try w.print(
            "{{\"read_only\":{},\"cycle_s\":{d},\"probes\":{d},\"ack_clear_after\":{d},\"end\":{d},\"targets\":[",
            .{ m.read_only, m.cycle_s, probes_per_cycle, ack_clear_after, newest },
        );
        for (m.targets.items, 0..) |t, i| {
            try w.print(
                "{s}{{\"id\":{d},\"name\":{f},\"host\":{f},\"status\":\"{t}\",\"paused\":{},\"acked\":{},\"ok_streak\":{d},\"error\":{f}",
                .{
                    if (i == 0) "" else ",",         t.id,
                    std.json.fmt(t.name, .{}),       std.json.fmt(t.host, .{}),
                    t.status(),                      t.paused,
                    t.acked,                         t.ok_streak,
                    std.json.fmt(t.last_error, .{}),
                },
            );
            try w.writeAll(",\"rtt\":[");
            try m.writeSeries(w, t, newest, .rtt);
            try w.writeAll("],\"loss\":[");
            try m.writeSeries(w, t, newest, .loss);
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
    }

    fn writeSeries(m: *Monitor, w: *Io.Writer, t: *const Target, newest: i64, comptime what: enum { rtt, loss }) Io.Writer.Error!void {
        var k: i64 = history_len - 1;
        while (k >= 0) : (k -= 1) {
            const at = newest - k * m.cycle_s;
            const s = t.history[m.slot(at)];
            if (k != history_len - 1) try w.writeByte(',');
            if (s.t != at or s.sent == 0) {
                try w.writeAll("null");
            } else switch (what) {
                .rtt => if (s.recv == 0) try w.writeAll("null") else try w.print("{d:.1}", .{@as(f64, @floatFromInt(s.rtt_us)) / 1000}),
                .loss => try w.print("{d}", .{@as(u32, s.sent - s.recv) * 100 / s.sent}),
            }
        }
    }
};

// ----- helpers ------------------------------------------------------------------

fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > 64) return error.InvalidName;
    for (name) |c| if (c < 0x20 or c == 0x7f) return error.InvalidName;
}

/// A numeric address, or a host name valid for DNS.
fn validateHost(host: []const u8) Error!void {
    if (fping.Addr.parse(host)) |_| return else |_| {}
    _ = Io.net.HostName.init(host) catch return error.InvalidHost;
}

fn writeFileAtomic(io: Io, path: []const u8, data: []const u8) !void {
    var tmp_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const tmp = try std.mem.print(&tmp_buf, "{s}.tmp", .{path});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data });
    try Io.Dir.rename(.cwd(), tmp, .cwd(), path, io);
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
    var job: Job = .{ .id = id, .host = "", .sent = probes_per_cycle, .replies = recv };
    for (0..recv) |i| job.rtts[i] = @intCast(1000 * (i + 1));
    m.recordLocked(m.targets.items[m.find(id).?], t, &job);
}

test "status follows the last sample" {
    var m = testMonitor();
    defer m.deinit();
    const id = try m.add("a", "192.0.2.1");
    const t = m.targets.items[0];
    try testing.expectEqual(.pending, t.status());
    fakeCycle(&m, id, 60, 5);
    try testing.expectEqual(.up, t.status());
    try testing.expectEqual(@as(u32, 3000), t.last.rtt_us); // median of 1..5 ms
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
    const id = try m.add("a", "192.0.2.1");
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
    const id = try m.add("a", "192.0.2.1");
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

test "names and hosts are validated" {
    var m = testMonitor();
    defer m.deinit();
    try testing.expectError(error.InvalidName, m.add("", "192.0.2.1"));
    try testing.expectError(error.InvalidName, m.add("a\nb", "192.0.2.1"));
    try testing.expectError(error.InvalidHost, m.add("a", "not a host"));
    _ = try m.add("v6", "2001:db8::1");
    _ = try m.add("dns", "example.com");
}
