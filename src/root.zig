//! zig-fping — fping reimplemented as a reusable Zig library.
//!
//! High-volume ICMP echo probing with global pacing, per-subnet spacing,
//! in-flight caps and jitter, designed for monitoring systems that run
//! thousands of host checks per cycle.
//!
//! Basic usage:
//!
//! ```zig
//! const fping = @import("fping");
//!
//! var pinger = try fping.Pinger.init(allocator, .{
//!     .mode = .count,
//!     .count = 3,
//!     .interval_ns = 5 * std.time.ns_per_ms,
//! });
//! defer pinger.deinit();
//!
//! const id = try pinger.addTarget("192.0.2.1");
//! try pinger.run();
//! const st = pinger.stats(id);
//! ```

const pinger = @import("pinger.zig");

pub const Pinger = pinger.Pinger;
pub const Config = pinger.Config;
pub const Mode = pinger.Mode;
pub const Stats = pinger.Stats;
pub const ReplyInfo = pinger.ReplyInfo;
pub const Addr = pinger.Addr;
pub const Outcome = pinger.Outcome;
pub const IcmpError = pinger.IcmpError;
pub const ResultFn = pinger.ResultFn;
pub const TargetId = pinger.TargetId;
pub const monoNow = pinger.monoNow;

pub const icmp = @import("icmp.zig");
pub const SeqMap = @import("seqmap.zig");
pub const Socket = @import("socket.zig");
pub const netutil = @import("netutil.zig");
/// Reverse-DNS (PTR) client — standalone, also useful outside of pinging.
pub const rdns = @import("rdns.zig");
/// Local timezone offsets from /etc/localtime — standalone helper.
pub const LocalTz = @import("tzlocal.zig");

test {
    @import("std").testing.refAllDecls(@This());
    // Test-only files (oracle fixtures, error and allocation-failure checks).
    _ = @import("testing/api_errors_test.zig");
    _ = @import("testing/icmp_tcpdump_test.zig");
    _ = @import("testing/alloc_failure_test.zig");
    _ = @import("testing/rfc6724_test.zig");
}
