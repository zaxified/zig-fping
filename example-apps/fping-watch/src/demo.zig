//! Sample data for the public demo (`--demo`).
//!
//! A fresh demo has no history, and a real one rarely shows anything worth
//! looking at. So every full hour the monitor replaces everything older than
//! the last hour of real probing with sample data: one scenario per target
//! (`"demo"` in the target list), scaled to the target's real latency, so the
//! sample past joins the live data. The page marks the sample part.
//!
//! Every cycle is drawn from a PRNG seeded with the target and the time, so
//! the noise stays put across refills. Time-of-day scenarios run on UTC (no
//! time zones without libc) and stay put too; the others are placed relative
//! to the start of the real data, so they never fall into it, and move on
//! with it every hour.

const std = @import("std");

pub const Scenario = enum {
    /// Nothing happens: small noise, a rare spike.
    steady,
    /// Congested uplink 18-22 UTC: latency and jitter climb, a little loss.
    evening_congestion,
    /// A route change: a latency plateau for three hours, 18 to 15 hours ago.
    route_change,
    /// Bursts of partial loss all day, an 8-minute outage 6 hours ago.
    flapping,
    /// 20 minutes of warning signs (latency, jitter, loss), then 45 minutes
    /// DOWN, recovered 3 hours ago.
    outage,
    /// The same warning signs, then DOWN from 25 minutes before the real
    /// data on: for a target that never answers, so it stays DOWN live.
    down,
    /// A nightly backup 01:00-02:30 UTC saturates the link: a sawtooth of
    /// queueing delay.
    bufferbloat,
    /// A distant host: high base, more jitter, busier 10-14 UTC.
    long_haul,
};

/// Round-trip times (µs) of the replies to `out.len` probes, in reply
/// order; returns how many replied. `base_ms` is the target's real median,
/// `t` the cycle start and `live_from` the start of the real data (unix s).
pub fn probes(s: Scenario, id: u32, t: i64, base_ms: f64, live_from: i64, out: []u32) usize {
    var prng: std.Random.DefaultPrng = .init(@as(u64, id) *% 0x9e3779b97f4a7c15 +% @as(u64, @bitCast(t)));
    const r = prng.random();
    const b = base_ms;
    const day_h = @as(f64, @floatFromInt(@mod(t, 86400))) / 3600; // UTC hour of day
    const ago_h = @as(f64, @floatFromInt(live_from - t)) / 3600; // hours before the real data
    const calm: Draw = .{ .base = b, .spread = 0.03 * b + 0.3, .spike_p = 0.01, .spike = @max(b, 10), .loss = 0.0005 };

    const d: Draw = switch (s) {
        .steady => calm,
        .evening_congestion => if (day_h >= 18 and day_h < 22) blk: {
            const x = @sin(std.math.pi * (day_h - 18) / 4); // 0..1..0
            const rise = 1.2 * @max(b, 15) * x;
            break :blk .{ .base = b + rise, .spread = calm.spread + 0.3 * rise, .loss = 0.03 * x };
        } else calm,
        .route_change => if (ago_h >= 15 and ago_h < 18) .{ .base = b + @max(0.45 * b, 5), .spread = calm.spread, .loss = calm.loss } else calm,
        .flapping => if (ago_h >= 6 and ago_h < 6 + 8.0 / 60.0)
            .{ .base = b, .spread = calm.spread, .loss = 1 }
        else if (@mod(@divFloor(t, 60 * 37), 9) == 0)
            .{ .base = b, .spread = 0.1 * b + 1, .loss = 0.25 }
        else
            .{ .base = b, .spread = 0.05 * b + 0.5, .loss = 0.004 },
        .outage => outage(calm, ago_h, 3, 3.75),
        .down => outage(calm, ago_h, -1e9, 25.0 / 60.0),
        .bufferbloat => if (day_h >= 1 and day_h < 2.5) blk: {
            const saw = @mod((day_h - 1) * 60, 12) / 12; // a 12-minute sawtooth
            break :blk .{ .base = b + 4 + 36 * saw, .spread = 3 + 6 * saw, .loss = 0.01 };
        } else calm,
        .long_haul => blk: {
            const load = if (day_h >= 10 and day_h < 14) @sin(std.math.pi * (day_h - 10) / 4) else 0;
            break :blk .{ .base = b * (1 + 0.08 * load), .spread = 0.015 * b + 5 * load, .spike_p = 0.02, .spike = 0.5 * b, .loss = 0.002 + 0.01 * load };
        },
    };

    var n: usize = 0;
    for (out) |_| {
        var ms = d.base + @abs(r.floatNorm(f64)) * d.spread;
        if (r.float(f64) < d.spike_p) ms += (0.3 + 0.7 * r.float(f64)) * d.spike;
        if (r.float(f64) < d.loss) continue;
        out[n] = @intFromFloat(@max(0.02, ms) * 1000);
        n += 1;
    }
    return n;
}

/// DOWN from `from_h` to `to_h` hours before the real data, preceded by 20
/// minutes of rising latency, jitter and loss.
fn outage(calm: Draw, ago_h: f64, from_h: f64, to_h: f64) Draw {
    const warn_h = 20.0 / 60.0;
    if (ago_h >= from_h and ago_h < to_h) return .{ .base = calm.base, .spread = calm.spread, .loss = 1 };
    if (ago_h < to_h or ago_h >= to_h + warn_h) return calm;
    const x = (to_h + warn_h - ago_h) / warn_h; // 0..1 towards the outage
    const b = @max(calm.base, 20);
    return .{ .base = calm.base + 5 * b * x * x, .spread = calm.spread + b * x, .loss = 0.05 + 0.6 * x };
}

const Draw = struct {
    base: f64,
    spread: f64,
    spike_p: f64 = 0,
    spike: f64 = 0,
    /// Probability that a probe gets no reply.
    loss: f64,
};

const testing = std.testing;

test "the same minute draws the same probes" {
    var a: [5]u32 = undefined;
    var b: [5]u32 = undefined;
    const na = probes(.flapping, 3, 1_700_000_040, 20, 1_700_100_000, &a);
    const nb = probes(.flapping, 3, 1_700_000_040, 20, 1_700_100_000, &b);
    try testing.expectEqualSlices(u32, a[0..na], b[0..nb]);
}

test "scenarios happen where they are placed" {
    const live: i64 = 1_700_006_400; // 00:00 UTC
    var out: [5]u32 = undefined;
    // outage: DOWN 3 to 3.75 hours before the real data, fine afterwards.
    try testing.expectEqual(0, probes(.outage, 1, live - 3 * 3600 - 600, 30, live, &out));
    // down: DOWN right up to the real data, fine a day before.
    try testing.expectEqual(0, probes(.down, 1, live - 60, 30, live, &out));
    try testing.expectEqual(0, probes(.down, 1, live - 20 * 60, 30, live, &out));
    try testing.expect(probes(.down, 1, live - 20 * 3600, 30, live, &out) > 0);
    // route change: a plateau 18 to 15 hours before.
    var plateau: u64 = 0;
    var normal: u64 = 0;
    for (0..30) |i| {
        const k: i64 = @intCast(i);
        if (probes(.route_change, 1, live - 16 * 3600 - 60 * k, 30, live, &out) > 0) plateau += out[0];
        if (probes(.route_change, 1, live - 3600 - 60 * k, 30, live, &out) > 0) normal += out[0];
    }
    try testing.expect(plateau > normal + 30 * 10_000); // +13.5 ms on a 30 ms base
    // evening congestion at 20:00 UTC, the worst of it.
    var evening: u64 = 0;
    for (0..30) |i| {
        if (probes(.evening_congestion, 1, live - 4 * 3600 - 60 * @as(i64, @intCast(i)), 15, live, &out) > 0) evening += out[0];
    }
    try testing.expect(evening / 30 > 30_000);
}
