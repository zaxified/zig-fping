//! The ping engine: schedules probes across many targets with global and
//! per-subnet pacing, tracks timeouts and statistics.
//!
//! Design follows fping's main_loop (two time-ordered event queues plus a
//! global minimum send interval), with additions aimed at large monitoring
//! deployments (10k+ targets per cycle):
//!
//!  * binary heaps instead of linked lists for O(log n) scheduling,
//!  * a hard cap on in-flight probes,
//!  * optional per-subnet send spacing (/24 for IPv4, /64 for IPv6) so a
//!    cycle does not burst into one branch of the network,
//!  * optional random jitter on each target's first probe to decorrelate
//!    consecutive monitoring cycles.
//!
//! Concurrency lives in the 16-bit ICMP sequence space (single socket per
//! address family), not in file descriptors — so the loop waits with ppoll
//! on at most two sockets.
//!
//! Sequence slots are released when the probe resolves (reply or timeout);
//! fping instead keeps seqmap entries for --seqmap-timeout but discards
//! late replies anyway (fping issue #32), so observable behaviour matches.
//! Duplicate replies are counted while the answered slot is still queued
//! (i.e. until its timeout event is lazily purged).

const std = @import("std");
const linux = std.os.linux;
const icmp = @import("icmp.zig");
const netutil = @import("netutil.zig");
const SeqMap = @import("seqmap.zig");
const Socket = @import("socket.zig");

pub const TargetId = u32;

pub const Mode = enum {
    /// Stop probing a target after its first reply; retry on timeout up to
    /// `retries` times with timeout backoff (fping default mode).
    alive,
    /// Send exactly `count` probes per target for full RTT/loss statistics
    /// (fping -c/-C).
    count,
    /// Send probes forever until `stop()` is called (fping -l).
    loop,
};

pub const Config = struct {
    mode: Mode = .alive,
    /// Probes per target in .count mode.
    count: u16 = 1,
    /// Extra attempts after a timeout in .alive mode (fping -r, default 3).
    retries: u16 = 3,
    /// Minimum gap between any two transmitted packets (fping -i, global
    /// pacing — the primary anti-netstorm control).
    interval_ns: u64 = 10 * std.time.ns_per_ms,
    /// Minimum gap between two probes to the same target (fping -p).
    perhost_interval_ns: u64 = 1000 * std.time.ns_per_ms,
    /// Reply timeout for a single probe (fping -t).
    timeout_ns: u64 = 500 * std.time.ns_per_ms,
    /// Timeout multiplier applied on each retry in .alive mode (fping -B).
    backoff_factor: f32 = 1.5,
    /// Random extra delay in [0, jitter_ns) added to each target's first
    /// probe, spreading load across the cycle. 0 = off.
    jitter_ns: u64 = 0,
    /// Hard cap on outstanding probes. Must be < 65536 (sequence space).
    max_inflight: u32 = 4096,
    /// Minimum gap between sends into the same subnet (/24 IPv4, /64 IPv6).
    /// 0 = off.
    subnet_gap_ns: u64 = 0,
    /// ICMP payload bytes (fping -b). On-wire size adds 8B ICMP + IP header.
    payload_size: u16 = 56,
    /// Randomize payload on every send to defeat link compression (fping -R).
    random_payload: bool = false,
    /// Send ICMP Timestamp requests instead of Echo (fping --icmp-timestamp).
    /// IPv4 only; run() fails with IcmpTimestampRequiresIpv4 on v6 targets.
    icmp_timestamp: bool = false,
    /// Discard replies whose source address differs from the target
    /// (fping --check-source).
    check_source: bool = false,
    socket_mode: Socket.Mode = .auto,
    /// SO_RCVBUF for the ICMP sockets.
    recv_buf_size: u32 = 1 << 20,
    /// IP TTL / IPv6 unicast hops (fping -H).
    ttl: ?u8 = null,
    /// IP TOS / IPv6 traffic class (fping -O).
    tos: ?u8 = null,
    /// Set the Don't Fragment flag (fping -M).
    dont_fragment: bool = false,
    /// Routing mark (fping -k/--fwmark); requires CAP_NET_ADMIN.
    fwmark: ?u32 = null,
    /// Bind sockets to an interface (fping -I); requires CAP_NET_RAW.
    iface: ?[]const u8 = null,
    /// Send probes via a specific outgoing interface, receive from any
    /// (fping --oiface). No capability required.
    oiface: ?[]const u8 = null,
    /// Source address for IPv4 probes (fping -S).
    source4: ?Addr = null,
    /// Source address for IPv6 probes (fping -S).
    source6: ?Addr = null,
};

/// Reply details delivered with a successful probe.
pub const ReplyInfo = struct {
    rtt_ns: u64,
    /// Length of the received ICMP message (fping prints it as "N bytes").
    size: u16 = 0,
    /// Received TTL (v4) / hop limit (v6), when the kernel provided it.
    ttl: ?u8 = null,
    /// Received TOS (v4) / traffic class (v6).
    tos: ?u8 = null,
    /// ICMP Timestamp payload (icmp_timestamp mode only).
    ts: ?icmp.TsData = null,
};

pub const Outcome = union(enum) {
    reply: ReplyInfo,
    /// A further reply for an already-answered probe.
    duplicate: ReplyInfo,
    timeout,
    send_error: Socket.SendError,
    /// An ICMP error (unreachable, time exceeded, ...) quoting one of our
    /// probes. Informational: the probe itself still resolves via its
    /// timeout, like in fping. The CLI renders it as fping's warning line.
    icmp_error: IcmpError,
};

/// Details of an ICMP error received for one of our probes.
pub const IcmpError = struct {
    family: icmp.Family,
    /// Raw ICMP (v4) or ICMPv6 type of the error message.
    icmp_type: u8,
    code: u8,
    /// Address the error came from (usually a router, not the target);
    /// null when the kernel did not report one.
    from: ?Addr,
};

/// Per-probe callback. `probe` is the 0-based probe index within the target
/// (wraps at 65536 in loop mode).
pub const ResultFn = *const fn (ctx: ?*anyopaque, id: TargetId, probe: u16, outcome: Outcome) void;

pub const Stats = struct {
    sent: u32 = 0,
    recv: u32 = 0,
    send_errors: u32 = 0,
    /// Extra replies for probes that were already answered.
    duplicates: u32 = 0,
    /// Replies discarded because the source address did not match
    /// (check_source mode).
    source_mismatches: u32 = 0,
    /// ICMP errors (unreachable etc.) received for our probes. The probe
    /// itself still resolves via timeout, mirroring fping.
    icmp_errors: u32 = 0,
    min_ns: u64 = 0,
    max_ns: u64 = 0,
    total_ns: u64 = 0,
    last_ns: u64 = 0,

    pub fn alive(s: Stats) bool {
        return s.recv > 0;
    }

    pub fn lost(s: Stats) u32 {
        return s.sent - s.recv;
    }

    pub fn lossPermille(s: Stats) u32 {
        if (s.sent == 0) return 0;
        return @intCast((@as(u64, s.lost()) * 1000) / s.sent);
    }

    pub fn avgNs(s: Stats) ?u64 {
        if (s.recv == 0) return null;
        return s.total_ns / s.recv;
    }
};

pub const Addr = union(icmp.Family) {
    v4: linux.sockaddr.in,
    v6: linux.sockaddr.in6,

    pub const ParseError = error{InvalidAddress};

    /// Parse a numeric IPv4/IPv6 address (no DNS). IPv6 addresses may carry
    /// a scope id suffix — numeric ("%2") or an interface name ("%eth0"),
    /// resolved via ioctl(SIOCGIFINDEX) like getaddrinfo does.
    pub fn parse(text: []const u8) ParseError!Addr {
        if (std.mem.findScalar(u8, text, '%')) |percent| {
            const scope_text = text[percent + 1 ..];
            const scope = std.fmt.parseInt(u32, scope_text, 10) catch
                netutil.ifNameToIndex(scope_text) orelse return error.InvalidAddress;
            const ip = std.Io.net.IpAddress.parse(text[0..percent], 0) catch return error.InvalidAddress;
            var addr = fromIpAddress(ip);
            switch (addr) {
                .v6 => |*sa| sa.scope_id = scope,
                .v4 => return error.InvalidAddress, // scopes are IPv6-only
            }
            return addr;
        }
        const ip = std.Io.net.IpAddress.parse(text, 0) catch return error.InvalidAddress;
        return fromIpAddress(ip);
    }

    pub fn fromIpAddress(ip: std.Io.net.IpAddress) Addr {
        return switch (ip) {
            .ip4 => |a| .{ .v4 = .{
                .port = 0,
                .addr = std.mem.bytesToValue(u32, &a.bytes),
            } },
            .ip6 => |a| .{ .v6 = .{
                .port = 0,
                .flowinfo = a.flow,
                .addr = a.bytes,
                .scope_id = a.interface.index,
            } },
        };
    }

    pub fn family(self: Addr) icmp.Family {
        return @as(icmp.Family, self);
    }

    fn sockaddrPtr(self: *const Addr) *const linux.sockaddr {
        return switch (self.*) {
            .v4 => |*sa| @ptrCast(sa),
            .v6 => |*sa| @ptrCast(sa),
        };
    }

    fn sockaddrLen(self: *const Addr) linux.socklen_t {
        return switch (self.*) {
            .v4 => @sizeOf(linux.sockaddr.in),
            .v6 => @sizeOf(linux.sockaddr.in6),
        };
    }

    /// Address bytes equal (ports/scope ignored).
    pub fn sameHost(self: Addr, other: Addr) bool {
        return switch (self) {
            .v4 => |a| switch (other) {
                .v4 => |b| a.addr == b.addr,
                .v6 => false,
            },
            .v6 => |a| switch (other) {
                .v6 => |b| std.mem.eql(u8, &a.addr, &b.addr),
                .v4 => false,
            },
        };
    }

    /// Bucket key for subnet pacing: /24 for IPv4, /64 for IPv6.
    fn subnetKey(self: Addr) u64 {
        switch (self) {
            .v4 => |sa| {
                const bytes = std.mem.toBytes(sa.addr);
                const prefix = std.mem.readInt(u32, &bytes, .big) >> 8;
                return (1 << 32) | @as(u64, prefix);
            },
            .v6 => |sa| {
                return std.mem.readInt(u64, sa.addr[0..8], .big);
            },
        }
    }

    pub fn format(self: Addr, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .v4 => |sa| {
                const b = std.mem.toBytes(sa.addr);
                try w.print("{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] });
            },
            .v6 => |sa| {
                const ip6: std.Io.net.Ip6Address = .{ .port = 0, .bytes = sa.addr };
                var buf: [64]u8 = undefined;
                var fixed: std.Io.Writer = .fixed(&buf);
                ip6.format(&fixed) catch unreachable;
                var text = fixed.buffered();
                // Ip6Address.format renders "[addr]:port"; keep only addr.
                if (std.mem.findScalarLast(u8, text, ']')) |close| text = text[0..close];
                if (text.len > 0 and text[0] == '[') text = text[1..];
                try w.writeAll(text);
            },
        }
    }
};

const Target = struct {
    addr: Addr,
    stats: Stats = .{},
    /// Probes handed to sendto (including failed sends).
    attempts: u32 = 0,
    /// Probes currently awaiting reply or timeout.
    pending: u16 = 0,
    /// Current probe timeout (grows with backoff in .alive mode).
    timeout_ns: u64,
    done: bool = false,
};

const Event = struct {
    time: i64,
    target: TargetId,
    probe: u16,
    /// Sequence number, used by timeout events to validate against seqmap.
    seq: u16 = 0,
};

fn eventBefore(_: void, a: Event, b: Event) std.math.Order {
    return std.math.order(a.time, b.time);
}

const EventQueue = std.PriorityQueue(Event, void, eventBefore);

pub const RunError = error{
    OutOfMemory,
    /// More probes outstanding than the sequence space allows.
    SequenceSpaceExhausted,
    /// icmp_timestamp is set but a target is IPv6 (RFC 792 is IPv4 only).
    IcmpTimestampRequiresIpv4,
    /// Config.oiface does not name an existing interface.
    UnknownInterface,
} || Socket.OpenError;

pub const Pinger = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    targets: std.ArrayList(Target) = .empty,
    ping_q: EventQueue = .{ .items = &.{}, .cap = 0, .context = {} },
    timeout_q: EventQueue = .{ .items = &.{}, .cap = 0, .context = {} },
    seqmap: SeqMap,
    sock4: ?Socket = null,
    sock6: ?Socket = null,
    /// Monotonic time of the last transmitted packet; 0 = nothing sent yet
    /// (CLOCK_MONOTONIC is always far past any pacing interval at startup).
    last_send_ns: i64 = 0,
    inflight: u32 = 0,
    subnet_last: std.AutoHashMapUnmanaged(u64, i64) = .empty,
    prng: std.Random.DefaultPrng,
    /// Socket.batch_max packet slots for batched sends (slot 0 doubles as
    /// the single-send buffer).
    send_slab: []u8,
    /// Bytes per send_slab slot (= wire size of one probe).
    pkt_len: usize,
    recv_batch: Socket.RecvBatch,
    result_fn: ?ResultFn = null,
    result_ctx: ?*anyopaque = null,
    /// Set asynchronously (e.g. from a signal handler) to end run().
    stop_requested: std.atomic.Value(bool) = .init(false),

    /// Fails with error.MaxInflightTooLarge when `config.max_inflight` does
    /// not fit the 16-bit sequence space (must be < SeqMap.capacity).
    pub fn init(gpa: std.mem.Allocator, config: Config) (error{ OutOfMemory, MaxInflightTooLarge })!Pinger {
        if (config.max_inflight >= SeqMap.capacity) return error.MaxInflightTooLarge;
        const cfg = clampConfig(config);
        const pkt_len = if (cfg.icmp_timestamp)
            icmp.timestamp_msg_len
        else
            icmp.echo_header_len + @as(usize, cfg.payload_size);
        const send_slab = try gpa.alloc(u8, Socket.batch_max * pkt_len);
        errdefer gpa.free(send_slab);
        @memset(send_slab, 0);
        const recv_slot = @max(4096, pkt_len + 128);
        const recv_slab = try gpa.alloc(u8, Socket.batch_max * recv_slot);
        errdefer gpa.free(recv_slab);

        // Jitter only needs decorrelation, not cryptographic randomness.
        const seed: u64 = @bitCast(monoNow() ^ (@as(i64, linux.getpid()) << 32));

        return .{
            .gpa = gpa,
            .cfg = cfg,
            .seqmap = try SeqMap.init(gpa),
            .prng = .init(seed),
            .send_slab = send_slab,
            .pkt_len = pkt_len,
            .recv_batch = .{ .slab = recv_slab, .slot_size = recv_slot },
        };
    }

    pub fn deinit(self: *Pinger) void {
        if (self.sock4) |*s| s.close();
        if (self.sock6) |*s| s.close();
        self.targets.deinit(self.gpa);
        self.ping_q.deinit(self.gpa);
        self.timeout_q.deinit(self.gpa);
        self.seqmap.deinit(self.gpa);
        self.subnet_last.deinit(self.gpa);
        self.gpa.free(self.send_slab);
        self.gpa.free(self.recv_batch.slab);
        self.* = undefined;
    }

    pub fn setResultCallback(self: *Pinger, ctx: ?*anyopaque, f: ResultFn) void {
        self.result_fn = f;
        self.result_ctx = ctx;
    }

    /// Request run() to return as soon as possible. Async-signal-safe.
    pub fn stop(self: *Pinger) void {
        self.stop_requested.store(true, .monotonic);
    }

    /// Add a target by numeric address string.
    pub fn addTarget(self: *Pinger, text: []const u8) (Addr.ParseError || error{OutOfMemory})!TargetId {
        return self.addTargetAddr(try Addr.parse(text));
    }

    pub fn addTargetAddr(self: *Pinger, addr: Addr) error{OutOfMemory}!TargetId {
        const id: TargetId = @intCast(self.targets.items.len);
        try self.targets.append(self.gpa, .{ .addr = addr, .timeout_ns = self.cfg.timeout_ns });
        return id;
    }

    pub fn targetCount(self: *const Pinger) usize {
        return self.targets.items.len;
    }

    pub fn stats(self: *const Pinger, id: TargetId) Stats {
        return self.targets.items[id].stats;
    }

    pub fn targetAddr(self: *const Pinger, id: TargetId) Addr {
        return self.targets.items[id].addr;
    }

    fn ensureSockets(self: *Pinger) RunError!void {
        var need4 = false;
        var need6 = false;
        for (self.targets.items) |*t| switch (t.addr) {
            .v4 => need4 = true,
            .v6 => need6 = true,
        };
        const oiface_index: ?u32 = if (self.cfg.oiface) |name|
            netutil.ifNameToIndex(name) orelse return error.UnknownInterface
        else
            null;
        const base: Socket.Options = .{
            .recv_buf_size = self.cfg.recv_buf_size,
            .ttl = self.cfg.ttl,
            .tos = self.cfg.tos,
            .dont_fragment = self.cfg.dont_fragment,
            .fwmark = self.cfg.fwmark,
            .iface = self.cfg.iface,
            .oiface_index = oiface_index,
        };
        if (need4 and self.sock4 == null) {
            var opts = base;
            if (self.cfg.source4) |src| opts.source = .{ .v4 = src.v4 };
            self.sock4 = try Socket.open(.v4, self.cfg.socket_mode, opts);
        }
        if (need6 and self.sock6 == null) {
            var opts = base;
            if (self.cfg.source6) |src| opts.source = .{ .v6 = src.v6 };
            self.sock6 = try Socket.open(.v6, self.cfg.socket_mode, opts);
        }
    }

    fn socketFor(self: *Pinger, fam: icmp.Family) *Socket {
        return switch (fam) {
            .v4 => &self.sock4.?,
            .v6 => &self.sock6.?,
        };
    }

    fn emit(self: *Pinger, id: TargetId, probe: u16, outcome: Outcome) void {
        if (self.result_fn) |f| f(self.result_ctx, id, probe, outcome);
    }

    /// Prepare a probing round: open sockets, reset statistics from any
    /// previous round and schedule every target's first probe. Called by
    /// run(); use it directly together with step()/pollFds() when embedding
    /// the engine into an external event loop.
    pub fn prepare(self: *Pinger) RunError!void {
        if (self.cfg.icmp_timestamp) {
            for (self.targets.items) |*t| {
                if (t.addr.family() == .v6) return error.IcmpTimestampRequiresIpv4;
            }
        }
        try self.ensureSockets();

        self.ping_q.items.len = 0;
        self.timeout_q.items.len = 0;
        self.inflight = 0;
        // Slots may still be occupied when the previous round ended early
        // (stop(), or answered slots whose events were never purged).
        self.seqmap.clear();
        self.subnet_last.clearRetainingCapacity();
        self.stop_requested.store(false, .monotonic);
        for (self.targets.items) |*t| {
            t.stats = .{};
            t.attempts = 0;
            t.pending = 0;
            t.timeout_ns = self.cfg.timeout_ns;
            t.done = false;
        }

        const start = monoNow();
        const rng = self.prng.random();
        for (self.targets.items, 0..) |_, idx| {
            const jitter: i64 = if (self.cfg.jitter_ns > 0)
                @intCast(rng.uintLessThan(u64, self.cfg.jitter_ns))
            else
                0;
            try self.ping_q.push(self.gpa, .{
                .time = start + jitter,
                .target = @intCast(idx),
                .probe = 0,
            });
        }
    }

    /// Advance the engine without blocking: fire due timeouts, transmit
    /// whatever pacing allows right now and drain already-received replies.
    ///
    /// Returns the absolute CLOCK_MONOTONIC deadline (ns) of the next
    /// scheduled event — wait until the sockets from pollFds() become
    /// readable or the deadline passes, then call step() again. Returns
    /// null when the round is complete (or stop() was called).
    pub fn step(self: *Pinger) RunError!?i64 {
        if (self.stop_requested.load(.monotonic)) return null;
        var now = monoNow();

        // Timeout events never need to wait on pacing; drain due ones first.
        try self.fireTimeouts(now);

        // Transmit while the global gap, the in-flight cap and the subnet
        // buckets allow it; consecutive due sends (only possible with a
        // zero interval) go out as one sendmmsg batch.
        try self.dispatchDue();
        now = monoNow();

        // A probe whose timeout is already due (-t 0, e.g. fping's
        // `-p 0 -c 1` autotune) expires before its reply is read, as in
        // fping where the event queue is served ahead of the socket.
        try self.fireTimeouts(now);

        self.drainReplies();

        // All probes resolved and nothing left to send: the remaining
        // timeout events only guarded duplicate detection — like fping,
        // do not wait them out.
        if (self.ping_q.items.len == 0 and self.inflight == 0) return null;

        const wait = self.nextWaitNs(now) orelse return null;
        return now + wait;
    }

    /// Process every due timeout event. Events whose probe was already
    /// answered are purged lazily regardless of their time, so they neither
    /// extend the next wait nor keep the round alive (fping removes them
    /// eagerly on reply, which a binary heap cannot do cheaply). Duplicate
    /// replies are therefore only counted while the answered slot is still
    /// queued.
    fn fireTimeouts(self: *Pinger, now: i64) RunError!void {
        while (self.timeout_q.peek()) |ev| {
            if (self.seqmap.fetch(ev.seq)) |entry| {
                if (entry.target == ev.target and entry.probe == ev.probe) {
                    if (!entry.answered) {
                        if (ev.time > now) break;
                        _ = self.timeout_q.pop();
                        try self.handleTimeout(ev, now);
                        continue;
                    }
                    // Answered: this event owns the slot — release it.
                    self.seqmap.release(ev.seq);
                }
            }
            // Released, reused or just-released slot: drop the stale event.
            _ = self.timeout_q.pop();
        }
    }

    /// Fill `buf` with the sockets to poll for readability between step()
    /// calls (POLLIN; at most one per address family).
    pub fn pollFds(self: *const Pinger, buf: *[2]linux.pollfd) []linux.pollfd {
        var n: usize = 0;
        if (self.sock4) |s| {
            buf[n] = .{ .fd = s.fd, .events = linux.POLL.IN, .revents = 0 };
            n += 1;
        }
        if (self.sock6) |s| {
            buf[n] = .{ .fd = s.fd, .events = linux.POLL.IN, .revents = 0 };
            n += 1;
        }
        return buf[0..n];
    }

    /// Run all probes to completion (or until stop() in loop mode).
    /// Repeated runs reset statistics.
    pub fn run(self: *Pinger) RunError!void {
        try self.prepare();
        while (try self.step()) |deadline| {
            self.waitReadable(deadline - monoNow());
        }
    }

    /// Transmit every probe the pacing gates allow right now. With a
    /// non-zero global interval at most one packet may leave per gap, so
    /// batches only form when interval_ns == 0 — then consecutive due
    /// sends to the same address family share one sendmmsg syscall.
    fn dispatchDue(self: *Pinger) RunError!void {
        var now = monoNow();
        while (true) {
            // Collect a same-family batch of events allowed to send now.
            var events: [Socket.batch_max]Event = undefined;
            var seqs: [Socket.batch_max]u16 = undefined;
            var family: icmp.Family = undefined;
            var n: usize = 0;
            collect: while (n < Socket.batch_max) {
                const ev = self.ping_q.peek() orelse break :collect;
                if (ev.time > now) break :collect;
                if (self.inflight + n >= self.cfg.max_inflight) break :collect;
                if (n == 0) {
                    if (now - self.last_send_ns < @as(i64, @intCast(self.cfg.interval_ns)))
                        break :collect;
                } else if (self.cfg.interval_ns != 0) break :collect;
                const fam = self.targets.items[ev.target].addr.family();
                if (n == 0) family = fam else if (fam != family) break :collect;
                if (self.subnetReadyAt(ev, now)) |ready_at| {
                    // Subnet busy: push the event back to when its bucket
                    // frees up, then keep collecting other targets.
                    var deferred = self.ping_q.pop().?;
                    deferred.time = ready_at;
                    try self.ping_q.push(self.gpa, deferred);
                    continue :collect;
                }
                _ = self.ping_q.pop();
                seqs[n] = try self.prepareProbe(ev, now, self.sendSlot(n));
                events[n] = ev;
                n += 1;
            }
            if (n == 0) return;

            const sock = self.socketFor(family);
            const t0 = &self.targets.items[events[0].target];
            var accepted: usize = 0;
            if (n > 1) {
                var addrs: [Socket.batch_max]*const linux.sockaddr = undefined;
                var packets: [Socket.batch_max][]const u8 = undefined;
                for (events[0..n], 0..) |ev, i| {
                    addrs[i] = self.targets.items[ev.target].addr.sockaddrPtr();
                    packets[i] = self.sendSlot(i);
                }
                // n <= batch_max by construction; on error fall back to single sends.
                accepted = sock.sendMany(addrs[0..n], t0.addr.sockaddrLen(), packets[0..n]) catch 0;
            }
            for (events[0..n], seqs[0..n], 0..) |ev, seq, i| {
                if (i < accepted) {
                    try self.commitProbe(ev, seq, now);
                    continue;
                }
                // Single send, or the remainder of a short sendmmsg batch
                // (retried individually for an accurate per-packet errno).
                const t = &self.targets.items[ev.target];
                if (sock.sendTo(t.addr.sockaddrPtr(), t.addr.sockaddrLen(), self.sendSlot(i))) {
                    try self.commitProbe(ev, seq, now);
                } else |err| {
                    self.failProbe(ev, seq, err);
                }
            }
            now = monoNow();
        }
    }

    fn sendSlot(self: *Pinger, i: usize) []u8 {
        return self.send_slab[i * self.pkt_len ..][0..self.pkt_len];
    }

    /// Returns when the subnet bucket of `ev`'s target allows sending, or
    /// null if it may send now.
    fn subnetReadyAt(self: *Pinger, ev: Event, now: i64) ?i64 {
        if (self.cfg.subnet_gap_ns == 0) return null;
        const key = self.targets.items[ev.target].addr.subnetKey();
        const last = self.subnet_last.get(key) orelse return null;
        const ready = last + @as(i64, @intCast(self.cfg.subnet_gap_ns));
        return if (ready > now) ready else null;
    }

    fn nextWaitNs(self: *Pinger, now: i64) ?i64 {
        var wait: ?i64 = null;
        if (self.ping_q.peek()) |ev| {
            var t = ev.time;
            const pace = self.last_send_ns + @as(i64, @intCast(self.cfg.interval_ns));
            if (pace > t) t = pace;
            wait = t - now;
        }
        if (self.timeout_q.peek()) |ev| {
            const t = ev.time - now;
            if (wait == null or t < wait.?) wait = t;
        }
        const w = wait orelse return null;
        return @max(w, 0);
    }

    /// Write the wire packet for `ev` into `buf` and do all pre-send
    /// bookkeeping: seqmap slot, pacing stamps, statistics and the next
    /// probe of this target (fping cadence: scheduled relative to this
    /// event's nominal time, not the actual send time).
    fn prepareProbe(self: *Pinger, ev: Event, now: i64, buf: []u8) RunError!u16 {
        const t = &self.targets.items[ev.target];
        const sock = self.socketFor(t.addr.family());

        const seq = self.seqmap.add(ev.target, ev.probe, now) catch
            return error.SequenceSpaceExhausted;

        if (self.cfg.icmp_timestamp) {
            // Send slots are pkt_len bytes (sized in init): cannot be too small.
            icmp.writeTimestampRequest(buf, sock.ident, seq, originateMs()) catch unreachable;
        } else {
            if (self.cfg.random_payload)
                self.prng.random().bytes(buf[icmp.echo_header_len..]);
            icmp.writeEchoRequest(t.addr.family(), buf, sock.ident, seq) catch unreachable;
        }

        t.attempts += 1;
        self.last_send_ns = now;
        if (self.cfg.subnet_gap_ns > 0)
            try self.subnet_last.put(self.gpa, t.addr.subnetKey(), now);
        t.stats.sent += 1;

        const more = switch (self.cfg.mode) {
            .count => ev.probe + 1 < self.cfg.count,
            .loop => true,
            .alive => false,
        };
        if (more) {
            try self.ping_q.push(self.gpa, .{
                .time = ev.time + @as(i64, @intCast(self.cfg.perhost_interval_ns)),
                .target = ev.target,
                .probe = ev.probe +% 1,
            });
        }
        return seq;
    }

    /// Post-send bookkeeping for a probe the kernel accepted.
    fn commitProbe(self: *Pinger, ev: Event, seq: u16, now: i64) RunError!void {
        const t = &self.targets.items[ev.target];
        t.pending += 1;
        self.inflight += 1;
        try self.timeout_q.push(self.gpa, .{
            .time = now + @as(i64, @intCast(t.timeout_ns)),
            .target = ev.target,
            .probe = ev.probe,
            .seq = seq,
        });
    }

    /// Bookkeeping for a probe the kernel rejected.
    fn failProbe(self: *Pinger, ev: Event, seq: u16, err: Socket.SendError) void {
        const t = &self.targets.items[ev.target];
        self.seqmap.release(seq);
        t.stats.send_errors += 1;
        self.emit(ev.target, ev.probe, .{ .send_error = err });
        self.checkDone(t);
    }

    fn handleTimeout(self: *Pinger, ev: Event, now: i64) RunError!void {
        // The slot may have been reused; only a live entry that still
        // matches this event belongs to it.
        const entry = self.seqmap.fetch(ev.seq) orelse return;
        if (entry.target != ev.target or entry.probe != ev.probe) return;
        self.seqmap.release(ev.seq);

        // Probe already resolved by a reply; the slot was only kept for
        // duplicate detection.
        if (entry.answered) return;

        const t = &self.targets.items[ev.target];
        t.pending -= 1;
        self.inflight -= 1;
        self.emit(ev.target, ev.probe, .timeout);

        if (self.cfg.mode == .alive and !t.done and t.attempts <= @as(u32, self.cfg.retries)) {
            t.timeout_ns = backoff(t.timeout_ns, self.cfg.backoff_factor);
            try self.ping_q.push(self.gpa, .{
                .time = now,
                .target = ev.target,
                // Wraps like the 16-bit probe index everywhere else (-r 65535
                // makes 65536 attempts).
                .probe = ev.probe +% 1,
            });
        } else {
            self.checkDone(t);
        }
    }

    fn handleReply(self: *Pinger, fam: icmp.Family, info: Socket.RecvInfo, recv_mono_ns: i64) void {
        const sock = self.socketFor(fam);
        const parsed = switch (fam) {
            .v4 => icmp.parseV4(info.packet, sock.kind == .raw),
            .v6 => icmp.parseV6(info.packet),
        };
        switch (parsed) {
            .echo_reply => |r| {
                // RAW sockets see every echo reply on the host; DGRAM sockets
                // are already filtered by the kernel.
                if (sock.kind == .raw and r.ident != sock.ident) return;
                const entry = self.seqmap.fetchPtr(r.seq) orelse return;
                const t = &self.targets.items[entry.target];
                if (t.addr.family() != fam) return;

                if (self.cfg.check_source and !sourceMatches(info.src, t.addr)) {
                    t.stats.source_mismatches += 1;
                    return;
                }

                const rtt: u64 = @intCast(@max(recv_mono_ns - entry.sent_ns, 0));
                // Report the ICMP message length; RAW v4 sockets deliver the
                // IP header too, so strip its length.
                var icmp_len = info.packet.len;
                if (fam == .v4 and sock.kind == .raw and info.packet.len >= 20)
                    icmp_len -= @as(usize, info.packet[0] & 0x0f) * 4;
                const reply_info: ReplyInfo = .{
                    .rtt_ns = rtt,
                    .size = @intCast(@min(icmp_len, std.math.maxInt(u16))),
                    .ttl = info.ttl,
                    .tos = info.tos,
                    .ts = r.ts,
                };

                if (entry.answered) {
                    t.stats.duplicates += 1;
                    self.emit(entry.target, entry.probe, .{ .duplicate = reply_info });
                    return;
                }
                entry.answered = true;

                t.pending -= 1;
                self.inflight -= 1;

                const s = &t.stats;
                s.recv += 1;
                s.last_ns = rtt;
                s.total_ns += rtt;
                // recv was just incremented: 1 means this is the first sample
                // (a legitimate 0 ns RTT must not read as "unset").
                if (s.recv == 1 or rtt < s.min_ns) s.min_ns = rtt;
                if (rtt > s.max_ns) s.max_ns = rtt;

                self.emit(entry.target, entry.probe, .{ .reply = reply_info });

                if (self.cfg.mode == .alive) t.done = true else self.checkDone(t);
            },
            .icmp_error => |e| {
                if (e.orig_ident != sock.ident) return;
                const entry = self.seqmap.fetch(e.orig_seq) orelse return;
                // Informational only; the probe is resolved by its timeout
                // (fping semantics).
                self.targets.items[entry.target].stats.icmp_errors += 1;
                self.emit(entry.target, entry.probe, .{ .icmp_error = .{
                    .family = fam,
                    .icmp_type = e.icmp_type,
                    .code = e.code,
                    .from = switch (info.src) {
                        .none => null,
                        .v4 => |sa| .{ .v4 = sa },
                        .v6 => |sa| .{ .v6 = sa },
                    },
                } });
            },
            .ignored => {},
        }
    }

    fn checkDone(self: *Pinger, t: *Target) void {
        if (self.cfg.mode == .loop) return;
        if (t.pending > 0) return;
        t.done = true;
    }

    /// Block until a socket is readable or `wait_ns` elapses. EINTR (e.g.
    /// SIGINT setting stop_requested) ends the wait early so the run loop
    /// can observe it.
    fn waitReadable(self: *Pinger, wait_ns: i64) void {
        var buf: [2]linux.pollfd = undefined;
        const fds = self.pollFds(&buf);
        const clamped = @max(wait_ns, 0);
        var ts: linux.timespec = .{
            .sec = @intCast(@divTrunc(clamped, std.time.ns_per_s)),
            .nsec = @intCast(@mod(clamped, std.time.ns_per_s)),
        };
        _ = linux.ppoll(fds.ptr, fds.len, &ts, null);
    }

    /// Read and process every already-received reply (non-blocking).
    fn drainReplies(self: *Pinger) void {
        self.drainRepliesBounded(max_batches_per_drain);
    }

    fn drainRepliesBounded(self: *Pinger, max_batches: u32) void {
        // One realtime/monotonic pair converts kernel receive timestamps
        // (CLOCK_REALTIME) to the engine's monotonic clock.
        const mono_now = monoNow();
        const real_now = realNow();

        inline for (.{ .v4, .v6 }) |fam| {
            const maybe_sock = switch (@as(icmp.Family, fam)) {
                .v4 => self.sock4,
                .v6 => self.sock6,
            };
            if (maybe_sock != null) {
                const sock = self.socketFor(fam);
                // Bounded so a flood of ICMP on a RAW socket cannot starve
                // timeouts and the stop flag; the kernel keeps the rest and
                // ppoll reports the socket readable again.
                var batches: u32 = 0;
                while (batches < max_batches) : (batches += 1) {
                    // recv_slab is sized for batch_max slots in init.
                    const infos = sock.recvBatch(&self.recv_batch) catch break;
                    if (infos.len == 0) break;
                    for (infos) |info| {
                        const recv_mono = if (info.timestamp_real_ns) |ts_real|
                            mono_now - @max(real_now - ts_real, 0)
                        else
                            mono_now;
                        self.handleReply(fam, info, recv_mono);
                    }
                    // A short batch means the socket is drained.
                    if (infos.len < Socket.batch_max) break;
                }
            }
        }
    }
};

fn sourceMatches(src: Socket.RecvInfo.SrcAddr, target: Addr) bool {
    return switch (src) {
        .none => true, // no source info available; cannot verify
        .v4 => |sa| switch (target) {
            .v4 => |ta| sa.addr == ta.addr,
            .v6 => false,
        },
        .v6 => |sa| switch (target) {
            .v6 => |ta| std.mem.eql(u8, &sa.addr, &ta.addr),
            .v4 => false,
        },
    };
}

/// recvmmsg batches handled per socket and drainReplies() call.
const max_batches_per_drain = 64;

/// Upper bound for every nanosecond duration in Config. Durations are added
/// to the monotonic clock as i64; 2^62 ns (~146 years) leaves headroom so
/// the sum can never overflow, while being unreachable in practice.
const max_config_ns: u64 = 1 << 62;

/// Clamp out-of-range durations instead of panicking later in the run loop.
fn clampConfig(config: Config) Config {
    var cfg = config;
    cfg.interval_ns = @min(cfg.interval_ns, max_config_ns);
    cfg.perhost_interval_ns = @min(cfg.perhost_interval_ns, max_config_ns);
    cfg.timeout_ns = @min(cfg.timeout_ns, max_config_ns);
    cfg.jitter_ns = @min(cfg.jitter_ns, max_config_ns);
    cfg.subnet_gap_ns = @min(cfg.subnet_gap_ns, max_config_ns);
    return cfg;
}

test "config durations above i64 range are clamped" {
    const huge = std.math.maxInt(u64);
    const c = clampConfig(.{ .timeout_ns = huge, .interval_ns = huge, .perhost_interval_ns = huge, .jitter_ns = huge, .subnet_gap_ns = huge });
    try std.testing.expectEqual(max_config_ns, c.timeout_ns);
    try std.testing.expectEqual(max_config_ns, c.interval_ns);
    try std.testing.expectEqual(max_config_ns, c.perhost_interval_ns);
    try std.testing.expectEqual(max_config_ns, c.jitter_ns);
    try std.testing.expectEqual(max_config_ns, c.subnet_gap_ns);
    // The clamped value must survive the cast used by commitProbe.
    _ = @as(i64, @intCast(c.timeout_ns)) + 1_000_000_000_000_000_000;
    try std.testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), clampConfig(.{}).timeout_ns);
}

const max_backoff_timeout_ns: u64 = 1 << 53;

/// Scale a timeout by the backoff factor, saturating instead of letting
/// @intFromFloat panic (or invoke UB in ReleaseFast) on NaN, negative or
/// huge factors and on many retries. A NaN or sub-1 factor leaves the
/// timeout unchanged; the CLI already rejects factors outside 1.0..5.0
/// like fping, but Config is public API.
fn backoff(timeout_ns: u64, factor: f32) u64 {
    if (!(factor >= 1.0)) return timeout_ns;
    const scaled = @as(f64, @floatFromInt(timeout_ns)) * factor;
    if (!(scaled < @as(f64, @floatFromInt(max_backoff_timeout_ns)))) return @max(timeout_ns, max_backoff_timeout_ns);
    return @intFromFloat(scaled);
}

test "backoff scales and saturates instead of panicking" {
    try std.testing.expectEqual(@as(u64, 750), backoff(500, 1.5));
    try std.testing.expectEqual(@as(u64, 500), backoff(500, std.math.nan(f32)));
    try std.testing.expectEqual(@as(u64, 500), backoff(500, -1.0));
    try std.testing.expectEqual(max_backoff_timeout_ns, backoff(500, 1e30));
    try std.testing.expectEqual(max_backoff_timeout_ns, backoff(500, std.math.inf(f32)));
    var t: u64 = 500 * std.time.ns_per_ms;
    for (0..65535) |_| t = backoff(t, 5.0);
    try std.testing.expectEqual(max_backoff_timeout_ns, t);
}

pub fn monoNow() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn realNow() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Milliseconds since midnight UT, as required by RFC 792 timestamps.
fn originateMs() u32 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const ms_in_day = @mod(ts.sec, std.time.s_per_day) * std.time.ms_per_s +
        @divTrunc(ts.nsec, std.time.ns_per_ms);
    return @intCast(ms_in_day);
}

test "addr parse and subnet keys" {
    const a = try Addr.parse("192.168.1.17");
    const b = try Addr.parse("192.168.1.200");
    const c = try Addr.parse("192.168.2.1");
    try std.testing.expectEqual(a.subnetKey(), b.subnetKey());
    try std.testing.expect(a.subnetKey() != c.subnetKey());

    const x = try Addr.parse("2001:db8::1");
    const y = try Addr.parse("2001:db8::ffff");
    const z = try Addr.parse("2001:db8:1::1");
    try std.testing.expectEqual(x.subnetKey(), y.subnetKey());
    try std.testing.expect(x.subnetKey() != z.subnetKey());

    try std.testing.expectError(error.InvalidAddress, Addr.parse("not-an-ip"));
}

test "addr format and sameHost" {
    const a = try Addr.parse("10.0.0.1");
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try a.format(&w);
    try std.testing.expectEqualStrings("10.0.0.1", w.buffered());

    try std.testing.expect(a.sameHost(try Addr.parse("10.0.0.1")));
    try std.testing.expect(!a.sameHost(try Addr.parse("10.0.0.2")));
    try std.testing.expect(!a.sameHost(try Addr.parse("::1")));
}

test "stats helpers" {
    var s: Stats = .{ .sent = 4, .recv = 3, .total_ns = 3_000_000 };
    try std.testing.expect(s.alive());
    try std.testing.expectEqual(@as(u32, 1), s.lost());
    try std.testing.expectEqual(@as(u32, 250), s.lossPermille());
    try std.testing.expectEqual(@as(u64, 1_000_000), s.avgNs().?);
}

test "pinger init/deinit and target bookkeeping" {
    var p = try Pinger.init(std.testing.allocator, .{});
    defer p.deinit();
    const id = try p.addTarget("127.0.0.1");
    try std.testing.expectEqual(@as(TargetId, 0), id);
    try std.testing.expectEqual(@as(usize, 1), p.targetCount());
    try std.testing.expectEqual(@as(u32, 0), p.stats(id).sent);
}

test "icmp_timestamp rejects ipv6 targets" {
    var p = try Pinger.init(std.testing.allocator, .{ .icmp_timestamp = true });
    defer p.deinit();
    _ = try p.addTarget("::1");
    try std.testing.expectError(error.IcmpTimestampRequiresIpv4, p.run());
}

test "scheduling: global pacing shapes the next deadline" {
    // The scheduler is unit-testable without touching the network — the
    // C original's main_loop can only be exercised end-to-end.
    var p = try Pinger.init(std.testing.allocator, .{
        .interval_ns = 10 * std.time.ns_per_ms,
    });
    defer p.deinit();
    _ = try p.addTarget("192.0.2.1");

    const now = monoNow();
    try p.ping_q.push(p.gpa, .{ .time = now, .target = 0, .probe = 0 });

    // Nothing sent yet: the event is due immediately.
    try std.testing.expectEqual(@as(?i64, 0), p.nextWaitNs(now));

    // A packet just left: the same event must wait out the global gap.
    p.last_send_ns = now;
    try std.testing.expectEqual(@as(?i64, 10 * std.time.ns_per_ms), p.nextWaitNs(now));

    // A timeout due sooner takes precedence.
    try p.timeout_q.push(p.gpa, .{ .time = now + 3 * std.time.ns_per_ms, .target = 0, .probe = 0 });
    try std.testing.expectEqual(@as(?i64, 3 * std.time.ns_per_ms), p.nextWaitNs(now));
}

test "scheduling: subnet gap defers same-/24 sends" {
    var p = try Pinger.init(std.testing.allocator, .{
        .subnet_gap_ns = 5 * std.time.ns_per_ms,
    });
    defer p.deinit();
    const a = try p.addTarget("192.0.2.10");
    const b = try p.addTarget("192.0.2.20"); // same /24
    const c = try p.addTarget("192.0.3.10"); // different /24

    const now = monoNow();
    try p.subnet_last.put(p.gpa, p.targets.items[a].addr.subnetKey(), now);

    const ev_same: Event = .{ .time = now, .target = b, .probe = 0 };
    const ev_other: Event = .{ .time = now, .target = c, .probe = 0 };
    try std.testing.expectEqual(@as(?i64, now + 5 * std.time.ns_per_ms), p.subnetReadyAt(ev_same, now));
    try std.testing.expectEqual(@as(?i64, null), p.subnetReadyAt(ev_other, now));
}

test "embed API: prepare/step/pollFds round against loopback" {
    var p = try Pinger.init(std.testing.allocator, .{
        .retries = 0,
        .timeout_ns = 300 * std.time.ns_per_ms,
        .interval_ns = 0,
    });
    defer p.deinit();
    const id = try p.addTarget("127.0.0.1");

    p.prepare() catch |e| switch (e) {
        // No ICMP socket privileges in this environment (CI sandbox).
        error.PermissionDenied, error.AddressFamilyUnsupported => return error.SkipZigTest,
        else => return e,
    };

    var iterations: u32 = 0;
    while (try p.step()) |deadline| : (iterations += 1) {
        try std.testing.expect(iterations < 1000);
        var buf: [2]linux.pollfd = undefined;
        const fds = p.pollFds(&buf);
        try std.testing.expect(fds.len == 1);
        const wait = @max(deadline - monoNow(), 0);
        var ts: linux.timespec = .{
            .sec = @intCast(@divTrunc(wait, std.time.ns_per_s)),
            .nsec = @intCast(@mod(wait, std.time.ns_per_s)),
        };
        _ = linux.ppoll(fds.ptr, fds.len, &ts, null);
    }

    try std.testing.expect(p.stats(id).alive());
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).sent);
}

// ---- Socket-free engine tests ----------------------------------------------
//
// A Pinger is built without opening sockets: a Socket value with fd -1 is
// installed by hand (only its kind/ident/family are consulted), probes go
// through prepareProbe/commitProbe exactly like dispatchDue does (minus the
// syscall), and crafted packets are fed to handleReply / fireTimeouts.

const ms = std.time.ns_per_ms;

/// Records every callback the engine makes.
const Rec = struct {
    const Kind = enum { reply, duplicate, timeout, send_error, icmp_error };
    kinds: [32]Kind = undefined,
    ids: [32]TargetId = undefined,
    probes: [32]u16 = undefined,
    n: usize = 0,
    last_reply: ?ReplyInfo = null,
    last_icmp: ?IcmpError = null,

    fn cb(ctx: ?*anyopaque, id: TargetId, probe: u16, outcome: Outcome) void {
        const r: *Rec = @ptrCast(@alignCast(ctx.?));
        if (r.n < r.kinds.len) {
            r.kinds[r.n] = switch (outcome) {
                inline else => |_, tag| @field(Kind, @tagName(tag)),
            };
            r.ids[r.n] = id;
            r.probes[r.n] = probe;
        }
        r.n += 1;
        switch (outcome) {
            .reply => |ri| r.last_reply = ri,
            .icmp_error => |e| r.last_icmp = e,
            else => {},
        }
    }

    fn count(r: *const Rec, k: Kind) usize {
        var c: usize = 0;
        for (r.kinds[0..@min(r.n, r.kinds.len)]) |x| {
            if (x == k) c += 1;
        }
        return c;
    }
};

fn fakeSocket(family: Socket.Family, kind: Socket.Kind, ident: u16) Socket {
    return .{ .fd = -1, .family = family, .kind = kind, .ident = ident };
}

fn testPinger(rec: *Rec, cfg: Config) !Pinger {
    var p = try Pinger.init(std.testing.allocator, cfg);
    p.setResultCallback(rec, Rec.cb);
    p.sock4 = fakeSocket(.v4, .dgram, 0x1234);
    p.sock6 = fakeSocket(.v6, .dgram, 0x4321);
    return p;
}

/// Tear down without closing the fake descriptors.
fn testDeinit(p: *Pinger) void {
    p.sock4 = null;
    p.sock6 = null;
    p.deinit();
}

/// Everything dispatchDue does for one probe except the sendto syscall.
fn sendProbe(p: *Pinger, id: TargetId, probe: u16, now: i64) !u16 {
    const ev: Event = .{ .time = now, .target = id, .probe = probe };
    const seq = try p.prepareProbe(ev, now, p.sendSlot(0));
    try p.commitProbe(ev, seq, now);
    return seq;
}

fn echoReply(buf: *[icmp.echo_header_len]u8, ident: u16, seq: u16) []u8 {
    buf.* = @splat(0);
    std.mem.writeInt(u16, buf[4..6], ident, .big);
    std.mem.writeInt(u16, buf[6..8], seq, .big);
    return buf;
}

/// ICMPv4 error quoting an echo request (no outer IP header: DGRAM style).
fn errorV4(buf: *[icmp.echo_header_len + 20 + icmp.echo_header_len]u8, icmp_type: u8, code: u8, ident: u16, seq: u16) []u8 {
    buf.* = @splat(0);
    buf[0] = icmp_type;
    buf[1] = code;
    buf[8] = 0x45; // quoted IP header, IHL 5
    const orig = buf[8 + 20 ..];
    orig[0] = icmp.v4.echo_request;
    std.mem.writeInt(u16, orig[4..6], ident, .big);
    std.mem.writeInt(u16, orig[6..8], seq, .big);
    return buf;
}

fn errorV6(buf: *[icmp.echo_header_len + 40 + icmp.echo_header_len]u8, icmp_type: u8, code: u8, ident: u16, seq: u16) []u8 {
    buf.* = @splat(0);
    buf[0] = icmp_type;
    buf[1] = code;
    buf[8 + 6] = 58; // quoted IPv6 header: next header ICMPv6
    const orig = buf[8 + 40 ..];
    orig[0] = icmp.v6.echo_request;
    std.mem.writeInt(u16, orig[4..6], ident, .big);
    std.mem.writeInt(u16, orig[6..8], seq, .big);
    return buf;
}

fn srcV4(text: []const u8) Socket.RecvInfo.SrcAddr {
    return .{ .v4 = (Addr.parse(text) catch unreachable).v4 };
}

test "engine: -r 65535 neither overflows nor retries forever" {
    // `t.attempts < 1 + retries` used to add in u16 (panic), and attempts
    // itself wrapped at 65536 sends, which would retry a dead host forever.
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .mode = .alive, .retries = 65535 });
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    const t0 = monoNow();

    // First attempt timed out: a retry must be scheduled.
    const seq = try sendProbe(&p, id, 0, t0);
    try p.handleTimeout(.{ .time = t0, .target = id, .probe = 0, .seq = seq }, t0);
    try std.testing.expectEqual(@as(usize, 1), p.ping_q.items.len);
    try std.testing.expect(!p.targets.items[id].done);

    // 65536th attempt (the last one allowed) timed out, probe index 65535:
    // no retry, and the retry event's index must not overflow either.
    p.ping_q.items.len = 0;
    p.targets.items[id].attempts = 65535;
    const seq2 = try sendProbe(&p, id, 65535, t0);
    try std.testing.expectEqual(@as(u32, 65536), p.targets.items[id].attempts);
    try p.handleTimeout(.{ .time = t0, .target = id, .probe = 65535, .seq = seq2 }, t0);
    try std.testing.expectEqual(@as(usize, 0), p.ping_q.items.len);
    try std.testing.expect(p.targets.items[id].done);

    // One attempt earlier the probe index wraps to 0 for the retry.
    p.targets.items[id].done = false;
    p.targets.items[id].attempts = 65534;
    const seq3 = try sendProbe(&p, id, 65535, t0);
    try p.handleTimeout(.{ .time = t0, .target = id, .probe = 65535, .seq = seq3 }, t0);
    try std.testing.expectEqual(@as(u16, 0), p.ping_q.peek().?.probe);
}

test "engine: alive retries back off and stop after the configured count" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{
        .mode = .alive,
        .retries = 2,
        .timeout_ns = 100 * ms,
        .backoff_factor = 2.0,
        .interval_ns = 0,
    });
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    const t = &p.targets.items[id];

    // Attempt 1: timeout 100 ms.
    const t0 = monoNow();
    _ = try sendProbe(&p, id, 0, t0);
    try std.testing.expectEqual(t0 + 100 * ms, p.timeout_q.peek().?.time);
    try p.fireTimeouts(t0 + 100 * ms - 1);
    try std.testing.expectEqual(@as(usize, 0), rec.n); // not due yet
    try p.fireTimeouts(t0 + 100 * ms);
    try std.testing.expectEqual(@as(usize, 1), rec.count(.timeout));
    try std.testing.expectEqual(@as(u64, 200 * ms), t.timeout_ns);
    try std.testing.expectEqual(@as(u16, 1), p.ping_q.peek().?.probe);
    try std.testing.expectEqual(@as(u32, 0), p.inflight);
    try std.testing.expectEqual(@as(u16, 0), t.pending);

    // Attempt 2: timeout 200 ms.
    const t1 = t0 + 100 * ms;
    _ = p.ping_q.pop().?;
    _ = try sendProbe(&p, id, 1, t1);
    try std.testing.expectEqual(t1 + 200 * ms, p.timeout_q.peek().?.time);
    try p.fireTimeouts(t1 + 200 * ms);
    try std.testing.expectEqual(@as(u64, 400 * ms), t.timeout_ns);
    try std.testing.expectEqual(@as(u16, 2), p.ping_q.peek().?.probe);

    // Attempt 3 (= 1 + retries): timeout 400 ms, then the target is done.
    const t2 = t1 + 200 * ms;
    _ = p.ping_q.pop().?;
    _ = try sendProbe(&p, id, 2, t2);
    try std.testing.expectEqual(t2 + 400 * ms, p.timeout_q.peek().?.time);
    try p.fireTimeouts(t2 + 400 * ms);
    try std.testing.expectEqual(@as(usize, 0), p.ping_q.items.len);
    try std.testing.expect(t.done);
    try std.testing.expectEqual(@as(usize, 3), rec.count(.timeout));
    try std.testing.expectEqual(@as(u32, 3), t.stats.sent);
}

test "engine: reply, duplicate and late reply lifecycle of one slot" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .mode = .alive });
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    const t0 = monoNow();
    const seq = try sendProbe(&p, id, 0, t0);
    var buf: [icmp.echo_header_len]u8 = undefined;
    const pkt = echoReply(&buf, 0x1234, seq);

    p.handleReply(.v4, .{ .packet = pkt }, t0 + 3 * ms);
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).recv);
    try std.testing.expectEqual(@as(u64, 3 * ms), p.stats(id).last_ns);
    try std.testing.expectEqual(@as(u32, 0), p.inflight);
    try std.testing.expectEqual(@as(u16, 0), p.targets.items[id].pending);
    try std.testing.expect(p.targets.items[id].done);
    try std.testing.expect(p.seqmap.fetch(seq).?.answered);
    try std.testing.expectEqual(@as(usize, icmp.echo_header_len), rec.last_reply.?.size);

    // A second reply while the slot is still queued is a duplicate and must
    // not touch the in-flight accounting again.
    p.handleReply(.v4, .{ .packet = pkt }, t0 + 4 * ms);
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).recv);
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).duplicates);
    try std.testing.expectEqual(@as(usize, 1), rec.count(.duplicate));
    try std.testing.expectEqual(@as(u32, 0), p.inflight);

    // The timeout event of the answered slot releases it silently ...
    try p.fireTimeouts(t0 + 1000 * ms);
    try std.testing.expectEqual(@as(?SeqMap.Entry, null), p.seqmap.fetch(seq));
    try std.testing.expectEqual(@as(usize, 0), p.timeout_q.items.len);
    try std.testing.expectEqual(@as(usize, 0), rec.count(.timeout));

    // ... after which a late reply is ignored altogether.
    p.handleReply(.v4, .{ .packet = pkt }, t0 + 1001 * ms);
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).duplicates);
    try std.testing.expectEqual(@as(usize, 2), rec.n);
}

test "engine: a stale timeout event neither expires nor frees a reused slot" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{});
    defer testDeinit(&p);
    _ = try p.addTarget("192.0.2.1");
    const other = try p.addTarget("192.0.2.2");
    const t0 = monoNow();
    // Slot 0 now belongs to the other target; the queued event is for an
    // earlier (released) use of the same sequence number.
    const seq = try p.seqmap.add(other, 0, t0);
    p.targets.items[other].pending = 1;
    p.inflight = 1;
    try p.timeout_q.push(p.gpa, .{ .time = t0, .target = 0, .probe = 0, .seq = seq });
    // Same target but another probe index is just as foreign.
    try p.timeout_q.push(p.gpa, .{ .time = t0, .target = other, .probe = 9, .seq = seq });

    try p.fireTimeouts(t0 + 1000 * ms);
    try std.testing.expectEqual(@as(usize, 0), p.timeout_q.items.len);
    try std.testing.expect(p.seqmap.fetch(seq) != null);
    try std.testing.expectEqual(@as(usize, 0), rec.n);
    try std.testing.expectEqual(@as(u32, 1), p.inflight);
}

test "engine: zero timeout expires before a reply that is already queued" {
    // fping -p 0 -c 1 autotunes -t to 0: the probe times out even though
    // the reply is sitting in the socket.
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .mode = .count, .count = 1, .timeout_ns = 0, .retries = 0 });
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    const t0 = monoNow();
    const seq = try sendProbe(&p, id, 0, t0);
    try p.fireTimeouts(t0);
    try std.testing.expectEqual(@as(usize, 1), rec.count(.timeout));
    var buf: [icmp.echo_header_len]u8 = undefined;
    p.handleReply(.v4, .{ .packet = echoReply(&buf, 0x1234, seq) }, t0 + ms);
    try std.testing.expectEqual(@as(u32, 0), p.stats(id).recv);
}

test "engine: check-source accepts only the target's own address" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .check_source = true });
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    const t0 = monoNow();
    const seq = try sendProbe(&p, id, 0, t0);
    var buf: [icmp.echo_header_len]u8 = undefined;
    const pkt = echoReply(&buf, 0x1234, seq);

    p.handleReply(.v4, .{ .packet = pkt, .src = srcV4("192.0.2.99") }, t0 + ms);
    p.handleReply(.v4, .{ .packet = pkt, .src = .{ .v6 = (Addr.parse("2001:db8::1") catch unreachable).v6 } }, t0 + ms);
    try std.testing.expectEqual(@as(u32, 2), p.stats(id).source_mismatches);
    try std.testing.expectEqual(@as(u32, 0), p.stats(id).recv);
    try std.testing.expect(!p.seqmap.fetch(seq).?.answered);
    try std.testing.expectEqual(@as(u32, 1), p.inflight);

    p.handleReply(.v4, .{ .packet = pkt, .src = srcV4("192.0.2.1") }, t0 + 2 * ms);
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).recv);
    try std.testing.expectEqual(@as(u32, 2), p.stats(id).source_mismatches);

    // Without check-source a foreign source is accepted.
    p.cfg.check_source = false;
    const seq2 = try sendProbe(&p, id, 1, t0);
    p.handleReply(.v4, .{ .packet = echoReply(&buf, 0x1234, seq2), .src = srcV4("192.0.2.99") }, t0 + 3 * ms);
    try std.testing.expectEqual(@as(u32, 2), p.stats(id).recv);
}

test "engine: RAW sockets compare the whole ident, DGRAM sockets trust the kernel" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{});
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    p.sock4 = fakeSocket(.v4, .raw, 0x1234);
    const t0 = monoNow();
    const seq = try sendProbe(&p, id, 0, t0);

    // RAW delivers the IP header too.
    var pkt: [20 + icmp.echo_header_len]u8 = @splat(0);
    pkt[0] = 0x45;
    std.mem.writeInt(u16, pkt[26..28], seq, .big);
    var bit: u4 = 0;
    while (true) : (bit += 1) {
        std.mem.writeInt(u16, pkt[24..26], 0x1234 ^ (@as(u16, 1) << bit), .big);
        p.handleReply(.v4, .{ .packet = &pkt }, t0 + ms);
        if (bit == 15) break;
    }
    try std.testing.expectEqual(@as(u32, 0), p.stats(id).recv);

    std.mem.writeInt(u16, pkt[24..26], 0x1234, .big);
    p.handleReply(.v4, .{ .packet = &pkt }, t0 + ms);
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).recv);
    // The reported size excludes the IP header.
    try std.testing.expectEqual(@as(u16, icmp.echo_header_len), rec.last_reply.?.size);

    // DGRAM: the kernel rewrites/filters the ident, a mismatch is not ours
    // to judge.
    p.sock4 = fakeSocket(.v4, .dgram, 0x1234);
    const seq2 = try sendProbe(&p, id, 1, t0);
    var buf: [icmp.echo_header_len]u8 = undefined;
    p.handleReply(.v4, .{ .packet = echoReply(&buf, 0x7777, seq2) }, t0 + ms);
    try std.testing.expectEqual(@as(u32, 2), p.stats(id).recv);
}

test "engine: a reply for a target of the other family is ignored" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{});
    defer testDeinit(&p);
    const id = try p.addTarget("2001:db8::1");
    const seq = try sendProbe(&p, id, 0, monoNow());
    var buf: [icmp.echo_header_len]u8 = undefined;
    p.handleReply(.v4, .{ .packet = echoReply(&buf, 0x1234, seq) }, monoNow());
    try std.testing.expectEqual(@as(u32, 0), p.stats(id).recv);
    // The v6 socket does accept it (v6 echo reply type).
    buf[0] = icmp.v6.echo_reply;
    p.handleReply(.v6, .{ .packet = &buf }, monoNow());
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).recv);
}

test "engine: min RTT of 0 ns is a sample, not an unset marker" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .mode = .count, .count = 2 });
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    const t0 = monoNow();
    var buf: [icmp.echo_header_len]u8 = undefined;
    const s0 = try sendProbe(&p, id, 0, t0);
    p.handleReply(.v4, .{ .packet = echoReply(&buf, 0x1234, s0) }, t0); // rtt 0
    const s1 = try sendProbe(&p, id, 1, t0);
    p.handleReply(.v4, .{ .packet = echoReply(&buf, 0x1234, s1) }, t0 + 5 * ms);
    const s = p.stats(id);
    try std.testing.expectEqual(@as(u32, 2), s.recv);
    try std.testing.expectEqual(@as(u64, 0), s.min_ns);
    try std.testing.expectEqual(@as(u64, 5 * ms), s.max_ns);
    try std.testing.expectEqual(@as(u64, 5 * ms), s.total_ns);
}

test "engine: max_inflight blocks dispatch without touching the queue" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .max_inflight = 2, .interval_ns = 0 });
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    try p.ping_q.push(p.gpa, .{ .time = monoNow() - ms, .target = id, .probe = 0 });
    p.inflight = 2;
    try p.dispatchDue();
    try std.testing.expectEqual(@as(usize, 1), p.ping_q.items.len);
    try std.testing.expectEqual(@as(u32, 0), p.stats(id).sent);
    try std.testing.expectEqual(@as(usize, 0), rec.n);
}

test "engine: ICMP error for a live probe is reported, the probe stays pending" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{});
    defer testDeinit(&p);
    const id = try p.addTarget("10.9.9.77");
    const t0 = monoNow();
    const seq = try sendProbe(&p, id, 0, t0);
    var buf: [icmp.echo_header_len + 20 + icmp.echo_header_len]u8 = undefined;

    p.handleReply(.v4, .{ .packet = errorV4(&buf, 3, 13, 0x1234, seq), .src = srcV4("198.51.100.1") }, t0 + ms);
    try std.testing.expectEqual(@as(usize, 1), rec.count(.icmp_error));
    const e = rec.last_icmp.?;
    try std.testing.expectEqual(icmp.Family.v4, e.family);
    try std.testing.expectEqual(@as(u8, 3), e.icmp_type);
    try std.testing.expectEqual(@as(u8, 13), e.code);
    try std.testing.expect(e.from.?.sameHost(try Addr.parse("198.51.100.1")));
    try std.testing.expectEqual(id, rec.ids[0]);
    try std.testing.expectEqual(@as(u16, 0), rec.probes[0]);
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).icmp_errors);
    // Informational only: still in flight, resolved later by its timeout.
    try std.testing.expectEqual(@as(u32, 1), p.inflight);
    try std.testing.expect(!p.targets.items[id].done);

    // The raw ICMP type survives (source quench has no ErrorKind of its own).
    p.handleReply(.v4, .{ .packet = errorV4(&buf, 4, 0, 0x1234, seq) }, t0 + ms);
    try std.testing.expectEqual(@as(u8, 4), rec.last_icmp.?.icmp_type);
    try std.testing.expectEqual(@as(?Addr, null), rec.last_icmp.?.from);

    // Not ours: wrong ident, or no live seqmap entry.
    const before = rec.n;
    p.handleReply(.v4, .{ .packet = errorV4(&buf, 3, 1, 0x1235, seq) }, t0 + ms);
    p.handleReply(.v4, .{ .packet = errorV4(&buf, 3, 1, 0x1234, seq +% 1) }, t0 + ms);
    try std.testing.expectEqual(before, rec.n);
    try std.testing.expectEqual(@as(u32, 2), p.stats(id).icmp_errors);

    // Once the slot is released the error is stale.
    try p.fireTimeouts(t0 + 1000 * ms);
    p.handleReply(.v4, .{ .packet = errorV4(&buf, 3, 1, 0x1234, seq) }, t0 + 1001 * ms);
    try std.testing.expectEqual(before + 1, rec.n); // +1: the timeout
    try std.testing.expectEqual(@as(u32, 2), p.stats(id).icmp_errors);
}

test "engine: ICMPv6 error for a live probe is reported" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{});
    defer testDeinit(&p);
    const id = try p.addTarget("2001:db8::77");
    const seq = try sendProbe(&p, id, 0, monoNow());
    var buf: [icmp.echo_header_len + 40 + icmp.echo_header_len]u8 = undefined;
    const router: Socket.RecvInfo.SrcAddr = .{ .v6 = (Addr.parse("2001:db8::1") catch unreachable).v6 };
    p.handleReply(.v6, .{ .packet = errorV6(&buf, 3, 1, 0x4321, seq), .src = router }, monoNow());
    const e = rec.last_icmp.?;
    try std.testing.expectEqual(icmp.Family.v6, e.family);
    try std.testing.expectEqual(@as(u8, 3), e.icmp_type);
    try std.testing.expectEqual(@as(u8, 1), e.code);
    try std.testing.expect(e.from.?.sameHost(try Addr.parse("2001:db8::1")));
    // Wrong ident: not ours.
    p.handleReply(.v6, .{ .packet = errorV6(&buf, 3, 1, 0x4322, seq) }, monoNow());
    try std.testing.expectEqual(@as(usize, 1), rec.count(.icmp_error));
}

test "engine: one drain handles a bounded number of recvmmsg batches" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{});
    defer testDeinit(&p);

    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK, 0, &fds)) != .SUCCESS)
        return error.SkipZigTest;
    defer {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
    }
    p.sock4 = .{ .fd = fds[0], .family = .v4, .kind = .dgram, .ident = 0x1234 };

    // Queue more than two batches (the unix queue limit may cap it).
    const junk: [icmp.echo_header_len]u8 = @splat(0);
    var queued: usize = 0;
    while (queued < 3 * Socket.batch_max) : (queued += 1) {
        const rc = linux.sendto(fds[1], &junk, junk.len, 0, null, 0);
        if (linux.errno(rc) != .SUCCESS) break;
    }
    if (queued <= 2 * Socket.batch_max) return error.SkipZigTest;

    p.drainRepliesBounded(2);
    var left: usize = 0;
    while (true) {
        const infos = try p.sock4.?.recvBatch(&p.recv_batch);
        left += infos.len;
        if (infos.len == 0) break;
    }
    try std.testing.expectEqual(queued - 2 * Socket.batch_max, left);

    // The default bound is 64 batches; everything queued here fits.
    for (0..queued) |_| _ = linux.sendto(fds[1], &junk, junk.len, 0, null, 0);
    p.drainReplies();
    try std.testing.expectEqual(@as(usize, 0), (try p.sock4.?.recvBatch(&p.recv_batch)).len);
}

test "embed API: -t 0 times out even on loopback (fping -p 0 -c 1)" {
    var rec: Rec = .{};
    var p = try Pinger.init(std.testing.allocator, .{
        .mode = .count,
        .count = 1,
        .retries = 0,
        .timeout_ns = 0,
        .perhost_interval_ns = 0,
        .interval_ns = 0,
    });
    defer p.deinit();
    p.setResultCallback(&rec, Rec.cb);
    const id = try p.addTarget("127.0.0.1");
    p.prepare() catch |e| switch (e) {
        error.PermissionDenied, error.AddressFamilyUnsupported => return error.SkipZigTest,
        else => return e,
    };
    var iterations: u32 = 0;
    while (try p.step()) |deadline| : (iterations += 1) {
        try std.testing.expect(iterations < 1000);
        p.waitReadable(deadline - monoNow());
    }
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).sent);
    try std.testing.expectEqual(@as(u32, 0), p.stats(id).recv);
    try std.testing.expectEqual(@as(usize, 1), rec.count(.timeout));
}

// ---- Tests added from a mutation-testing pass ---------------------------------
//
// Each of these pins down behaviour that the suite above only exercised
// through a redundant guard (fireTimeouts and handleTimeout both check slot
// ownership) or not at all (dispatchDue gates, failProbe, prepare() resets).

test "engine: fireTimeouts purges an answered slot before its deadline" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{});
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    const t0 = monoNow();
    const seq = try sendProbe(&p, id, 0, t0);
    var buf: [icmp.echo_header_len]u8 = undefined;
    p.handleReply(.v4, .{ .packet = echoReply(&buf, 0x1234, seq) }, t0 + ms);

    // The event is 500 ms away; an answered slot is purged regardless.
    try p.fireTimeouts(t0 + 2 * ms);
    try std.testing.expectEqual(@as(?SeqMap.Entry, null), p.seqmap.fetch(seq));
    try std.testing.expectEqual(@as(usize, 0), p.timeout_q.items.len);
}

test "engine: a stale timeout never releases an answered slot that was reused" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{});
    defer testDeinit(&p);
    _ = try p.addTarget("192.0.2.1");
    const other = try p.addTarget("192.0.2.2");
    const t0 = monoNow();
    const seq = try p.seqmap.add(other, 0, t0);
    p.seqmap.fetchPtr(seq).?.answered = true;
    // Foreign target, same probe index; and same target, foreign probe index.
    try p.timeout_q.push(p.gpa, .{ .time = t0, .target = 0, .probe = 0, .seq = seq });
    try p.timeout_q.push(p.gpa, .{ .time = t0, .target = other, .probe = 9, .seq = seq });

    try p.fireTimeouts(t0 + 1000 * ms);
    try std.testing.expectEqual(@as(usize, 0), p.timeout_q.items.len);
    try std.testing.expect(p.seqmap.fetch(seq) != null);
    try std.testing.expectEqual(@as(usize, 0), rec.n);
}

test "engine: handleTimeout on its own ignores a foreign slot and silently frees an answered one" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{});
    defer testDeinit(&p);
    const mine = try p.addTarget("192.0.2.1");
    const other = try p.addTarget("192.0.2.2");
    const t0 = monoNow();
    const seq = try p.seqmap.add(other, 0, t0);
    p.targets.items[other].pending = 1;
    p.inflight = 1;

    try p.handleTimeout(.{ .time = t0, .target = mine, .probe = 0, .seq = seq }, t0);
    try p.handleTimeout(.{ .time = t0, .target = other, .probe = 9, .seq = seq }, t0);
    try std.testing.expect(p.seqmap.fetch(seq) != null);
    try std.testing.expectEqual(@as(usize, 0), rec.n);
    try std.testing.expectEqual(@as(u32, 1), p.inflight);

    p.seqmap.fetchPtr(seq).?.answered = true;
    try p.handleTimeout(.{ .time = t0, .target = other, .probe = 0, .seq = seq }, t0);
    try std.testing.expectEqual(@as(?SeqMap.Entry, null), p.seqmap.fetch(seq));
    try std.testing.expectEqual(@as(usize, 0), rec.n);
    try std.testing.expectEqual(@as(u32, 1), p.inflight);
    try std.testing.expectEqual(@as(u16, 1), p.targets.items[other].pending);
}

test "engine: a target that already answered is not retried when a sibling probe times out" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .mode = .alive, .retries = 3 });
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    const t0 = monoNow();
    const s0 = try sendProbe(&p, id, 0, t0);
    const s1 = try sendProbe(&p, id, 1, t0);
    var buf: [icmp.echo_header_len]u8 = undefined;
    p.handleReply(.v4, .{ .packet = echoReply(&buf, 0x1234, s0) }, t0 + ms);
    try std.testing.expect(p.targets.items[id].done);

    try p.handleTimeout(.{ .time = t0 + 500 * ms, .target = id, .probe = 1, .seq = s1 }, t0 + 500 * ms);
    try std.testing.expectEqual(@as(usize, 0), p.ping_q.items.len);
    try std.testing.expectEqual(@as(u64, 500 * ms), p.targets.items[id].timeout_ns);
}

test "engine: an alive retry is due at the moment the timeout fired" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .mode = .alive, .retries = 1, .timeout_ns = 100 * ms });
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    const t0 = monoNow();
    const seq = try sendProbe(&p, id, 0, t0);
    try p.handleTimeout(.{ .time = t0 + 100 * ms, .target = id, .probe = 0, .seq = seq }, t0 + 107 * ms);
    try std.testing.expectEqual(t0 + 107 * ms, p.ping_q.peek().?.time);
}

test "engine: a reply stamped before its probe clamps the RTT to zero" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{});
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    const t0 = monoNow();
    const seq = try sendProbe(&p, id, 0, t0);
    var buf: [icmp.echo_header_len]u8 = undefined;
    p.handleReply(.v4, .{ .packet = echoReply(&buf, 0x1234, seq) }, t0 - 5 * ms);
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).recv);
    try std.testing.expectEqual(@as(u64, 0), p.stats(id).last_ns);
    try std.testing.expectEqual(@as(u64, 0), p.stats(id).max_ns);
}

test "engine: ttl, tos and the ICMP timestamp payload reach the reply callback" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{});
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    const t0 = monoNow();
    const seq = try sendProbe(&p, id, 0, t0);
    var pkt: [icmp.timestamp_msg_len]u8 = @splat(0);
    pkt[0] = icmp.v4.timestamp_reply;
    std.mem.writeInt(u16, pkt[4..6], 0x1234, .big);
    std.mem.writeInt(u16, pkt[6..8], seq, .big);
    std.mem.writeInt(u32, pkt[8..12], 111, .big);
    std.mem.writeInt(u32, pkt[12..16], 222, .big);
    std.mem.writeInt(u32, pkt[16..20], 333, .big);
    p.handleReply(.v4, .{ .packet = &pkt, .ttl = 61, .tos = 0xb8 }, t0 + ms);
    const ri = rec.last_reply.?;
    try std.testing.expectEqual(@as(?u8, 61), ri.ttl);
    try std.testing.expectEqual(@as(?u8, 0xb8), ri.tos);
    try std.testing.expectEqual(@as(u16, icmp.timestamp_msg_len), ri.size);
    try std.testing.expectEqual(@as(u32, 111), ri.ts.?.originate_ms);
    try std.testing.expectEqual(@as(u32, 222), ri.ts.?.receive_ms);
    try std.testing.expectEqual(@as(u32, 333), ri.ts.?.transmit_ms);
}

test "engine: loop targets never finish and count targets wait for every probe" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .mode = .loop });
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    const t0 = monoNow();
    var buf: [icmp.echo_header_len]u8 = undefined;
    const s0 = try sendProbe(&p, id, 0, t0);
    p.handleReply(.v4, .{ .packet = echoReply(&buf, 0x1234, s0) }, t0 + ms);
    try std.testing.expectEqual(@as(u16, 0), p.targets.items[id].pending);
    try std.testing.expect(!p.targets.items[id].done);

    p.cfg.mode = .count;
    p.cfg.count = 3;
    const s1 = try sendProbe(&p, id, 1, t0);
    const s2 = try sendProbe(&p, id, 2, t0);
    p.handleReply(.v4, .{ .packet = echoReply(&buf, 0x1234, s1) }, t0 + ms);
    try std.testing.expectEqual(@as(u16, 1), p.targets.items[id].pending);
    try std.testing.expect(!p.targets.items[id].done);
    p.handleReply(.v4, .{ .packet = echoReply(&buf, 0x1234, s2) }, t0 + ms);
    try std.testing.expect(p.targets.items[id].done);
}

test "engine: check-source compares IPv6 sources address by address" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .check_source = true });
    defer testDeinit(&p);
    const id = try p.addTarget("2001:db8::1");
    const t0 = monoNow();
    const seq = try sendProbe(&p, id, 0, t0);
    var buf: [icmp.echo_header_len]u8 = undefined;
    const pkt = echoReply(&buf, 0x4321, seq);
    pkt[0] = icmp.v6.echo_reply;

    const wrong: Socket.RecvInfo.SrcAddr = .{ .v6 = (Addr.parse("2001:db8::2") catch unreachable).v6 };
    p.handleReply(.v6, .{ .packet = pkt, .src = wrong }, t0 + ms);
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).source_mismatches);
    try std.testing.expectEqual(@as(u32, 0), p.stats(id).recv);

    const right: Socket.RecvInfo.SrcAddr = .{ .v6 = (Addr.parse("2001:db8::1") catch unreachable).v6 };
    p.handleReply(.v6, .{ .packet = pkt, .src = right }, t0 + 2 * ms);
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).recv);
}

test "engine: min and max RTT follow the samples, the first one included" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .mode = .count, .count = 3 });
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    const t0 = monoNow();
    var buf: [icmp.echo_header_len]u8 = undefined;
    const rtts = [_]i64{ 8, 5, 9 };
    for (rtts, 0..) |rtt, i| {
        const seq = try sendProbe(&p, id, @intCast(i), t0);
        p.handleReply(.v4, .{ .packet = echoReply(&buf, 0x1234, seq) }, t0 + rtt * ms);
    }
    const s = p.stats(id);
    try std.testing.expectEqual(@as(u64, 5 * ms), s.min_ns);
    try std.testing.expectEqual(@as(u64, 9 * ms), s.max_ns);
    try std.testing.expectEqual(@as(u64, 22 * ms), s.total_ns);
    try std.testing.expectEqual(@as(u64, 9 * ms), s.last_ns);
}

test "engine: dispatchDue holds back an event that is not due yet" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .interval_ns = 0 });
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    try p.ping_q.push(p.gpa, .{ .time = monoNow() + 10_000 * ms, .target = id, .probe = 0 });
    try p.dispatchDue();
    try std.testing.expectEqual(@as(usize, 1), p.ping_q.items.len);
    try std.testing.expectEqual(@as(u32, 0), p.stats(id).sent);
}

test "engine: dispatchDue lets one packet per global gap leave" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .interval_ns = 10_000 * ms });
    defer testDeinit(&p);
    const a = try p.addTarget("192.0.2.1");
    const b = try p.addTarget("192.0.2.2");
    const due = monoNow() - ms;
    try p.ping_q.push(p.gpa, .{ .time = due, .target = a, .probe = 0 });
    try p.ping_q.push(p.gpa, .{ .time = due, .target = b, .probe = 0 });

    // A packet left just now: nothing may go out.
    p.last_send_ns = monoNow();
    try p.dispatchDue();
    try std.testing.expectEqual(@as(usize, 2), p.ping_q.items.len);

    // Gap elapsed: exactly one goes out, the gap restarts, the other waits.
    p.last_send_ns = 0;
    try p.dispatchDue();
    try std.testing.expectEqual(@as(u32, 1), p.stats(a).sent + p.stats(b).sent);
    try std.testing.expectEqual(@as(usize, 1), p.ping_q.items.len);
}

test "engine: dispatchDue never mixes address families in one batch" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .interval_ns = 0 });
    defer testDeinit(&p);
    const a = try p.addTarget("192.0.2.1");
    const b = try p.addTarget("2001:db8::1");
    const now = monoNow();
    try p.ping_q.push(p.gpa, .{ .time = now - 2 * ms, .target = a, .probe = 0 });
    try p.ping_q.push(p.gpa, .{ .time = now - ms, .target = b, .probe = 0 });
    try p.dispatchDue();
    try std.testing.expectEqual(@as(u32, 1), p.stats(a).sent);
    try std.testing.expectEqual(@as(u32, 1), p.stats(b).sent);
    // The v6 probe took slot 0 of its own batch; slot 1 was never written.
    try std.testing.expectEqual(icmp.v6.echo_request, p.sendSlot(0)[0]);
    try std.testing.expectEqual(@as(u8, 0), p.sendSlot(1)[0]);
}

test "engine: dispatchDue defers a same-subnet event to the bucket's release time" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .interval_ns = 0, .subnet_gap_ns = 50 * ms });
    defer testDeinit(&p);
    const a = try p.addTarget("192.0.2.10");
    const b = try p.addTarget("192.0.2.20");
    const now = monoNow();
    try p.ping_q.push(p.gpa, .{ .time = now - 2 * ms, .target = a, .probe = 0 });
    try p.ping_q.push(p.gpa, .{ .time = now - ms, .target = b, .probe = 0 });
    try p.dispatchDue();
    try std.testing.expectEqual(@as(u32, 1), p.stats(a).sent);
    try std.testing.expectEqual(@as(u32, 0), p.stats(b).sent);
    const stamped = p.subnet_last.get(p.targets.items[a].addr.subnetKey()).?;
    try std.testing.expectEqual(@as(usize, 1), p.ping_q.items.len);
    try std.testing.expectEqual(stamped + 50 * ms, p.ping_q.peek().?.time);
}

test "engine: a rejected send frees the slot, is counted and finishes the target" {
    var rec: Rec = .{};
    // The fake socket has descriptor -1, so every send fails.
    var p = try testPinger(&rec, .{ .mode = .count, .count = 1, .interval_ns = 0 });
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    try p.ping_q.push(p.gpa, .{ .time = monoNow() - ms, .target = id, .probe = 0 });
    try p.dispatchDue();
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).sent);
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).send_errors);
    try std.testing.expectEqual(@as(usize, 1), rec.count(.send_error));
    try std.testing.expectEqual(@as(?SeqMap.Entry, null), p.seqmap.fetch(0));
    try std.testing.expectEqual(@as(u32, 0), p.inflight);
    try std.testing.expect(p.targets.items[id].done);
}

test "engine: max_inflight caps the batch being collected, not just the running total" {
    var rec: Rec = .{};
    var p = try Pinger.init(std.testing.allocator, .{ .max_inflight = 2, .interval_ns = 0 });
    defer p.deinit();
    p.setResultCallback(&rec, Rec.cb);
    p.sock4 = Socket.open(.v4, .auto, .{}) catch |e| switch (e) {
        error.PermissionDenied, error.AddressFamilyUnsupported => return error.SkipZigTest,
        else => return e,
    };
    const now = monoNow();
    for (0..3) |_| {
        const id = try p.addTarget("127.0.0.1");
        try p.ping_q.push(p.gpa, .{ .time = now - ms, .target = id, .probe = 0 });
    }
    try p.dispatchDue();
    try std.testing.expectEqual(@as(u32, 2), p.inflight);
    try std.testing.expectEqual(@as(usize, 1), p.ping_q.items.len);
    try std.testing.expectEqual(@as(usize, 0), rec.count(.send_error));
}

test "subnet keys: v4 and v6 never collide and v6 groups by /64" {
    const v4 = try Addr.parse("192.0.2.5");
    // First 8 octets 0:0:c0:2 equal the v4 key without its marker bit.
    // (The marker bit is bit 32, so v6 prefixes 0:1:x:y still collide with
    // a v4 /24; that range is reserved space and never routed.)
    const v6 = try Addr.parse("0:0:c0:2::1");
    try std.testing.expect(v4.subnetKey() != v6.subnetKey());

    const same_a = try Addr.parse("2001:db8:0:1::1");
    const same_b = try Addr.parse("2001:db8:0:1:ffff::2");
    const other = try Addr.parse("2001:db8:0:2::1");
    try std.testing.expectEqual(same_a.subnetKey(), same_b.subnetKey());
    try std.testing.expect(same_a.subnetKey() != other.subnetKey());
}

test "scheduling: an overdue event waits zero, never a negative time" {
    var p = try Pinger.init(std.testing.allocator, .{ .interval_ns = 0 });
    defer p.deinit();
    const id = try p.addTarget("192.0.2.1");
    const now = monoNow();
    try p.ping_q.push(p.gpa, .{ .time = now - 5 * ms, .target = id, .probe = 0 });
    try std.testing.expectEqual(@as(?i64, 0), p.nextWaitNs(now));
}

test "engine: prepareProbe schedules the next probe from the nominal time and stamps the pacing state" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .mode = .count, .count = 3, .perhost_interval_ns = 100 * ms, .subnet_gap_ns = 50 * ms });
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    const now = monoNow();
    const ev: Event = .{ .time = now - 5 * ms, .target = id, .probe = 0 };
    _ = try p.prepareProbe(ev, now, p.sendSlot(0));

    const next = p.ping_q.peek().?;
    try std.testing.expectEqual(now - 5 * ms + 100 * ms, next.time);
    try std.testing.expectEqual(@as(u16, 1), next.probe);
    try std.testing.expectEqual(id, next.target);
    try std.testing.expectEqual(now, p.last_send_ns);
    try std.testing.expectEqual(@as(?i64, now), p.subnet_last.get(p.targets.items[id].addr.subnetKey()));
    try std.testing.expectEqual(@as(u32, 1), p.stats(id).sent);
    try std.testing.expectEqual(@as(u32, 1), p.targets.items[id].attempts);

    // The last probe of the round schedules nothing further.
    p.ping_q.items.len = 0;
    _ = try p.prepareProbe(.{ .time = now, .target = id, .probe = 2 }, now, p.sendSlot(0));
    try std.testing.expectEqual(@as(usize, 0), p.ping_q.items.len);
}

test "engine: prepare spreads first probes over the jitter window and resets the round state" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .jitter_ns = 1000 * ms, .timeout_ns = 700 * ms });
    defer testDeinit(&p);
    for (0..64) |_| _ = try p.addTarget("192.0.2.1");

    // Leftovers of a previous round.
    _ = try p.seqmap.add(3, 0, 1);
    p.inflight = 5;
    try p.ping_q.push(p.gpa, .{ .time = 1, .target = 0, .probe = 7 });
    const t1 = &p.targets.items[1];
    t1.timeout_ns = 9999;
    t1.done = true;
    t1.pending = 2;
    t1.attempts = 3;
    t1.stats.sent = 4;

    const before = monoNow();
    try p.prepare();
    const after = monoNow();

    try std.testing.expectEqual(@as(?SeqMap.Entry, null), p.seqmap.fetch(0));
    try std.testing.expectEqual(@as(u32, 0), p.inflight);
    try std.testing.expectEqual(@as(usize, 64), p.ping_q.items.len);
    try std.testing.expectEqual(@as(u64, 700 * ms), t1.timeout_ns);
    try std.testing.expect(!t1.done);
    try std.testing.expectEqual(@as(u16, 0), t1.pending);
    try std.testing.expectEqual(@as(u32, 0), t1.attempts);
    try std.testing.expectEqual(@as(u32, 0), t1.stats.sent);

    var lo: i64 = std.math.maxInt(i64);
    var hi: i64 = std.math.minInt(i64);
    for (p.ping_q.items) |ev| {
        lo = @min(lo, ev.time);
        hi = @max(hi, ev.time);
    }
    try std.testing.expect(lo >= before);
    try std.testing.expect(hi < after + 1000 * ms);
    try std.testing.expect(hi > lo); // 64 draws from a 1 s window are not all equal
}

test "engine: step keeps waiting while a probe is in flight and ends when nothing is" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{ .timeout_ns = 500 * ms });
    defer testDeinit(&p);
    const id = try p.addTarget("192.0.2.1");
    _ = try sendProbe(&p, id, 0, monoNow());
    try std.testing.expect((try p.step()) != null);

    // Only answered-slot events left (inflight 0): the round is over.
    p.inflight = 0;
    try std.testing.expectEqual(@as(?i64, null), try p.step());
}

test "engine: the kernel receive timestamp dates a reply, not the moment it is drained" {
    var rec: Rec = .{};
    var p = try testPinger(&rec, .{});
    defer testDeinit(&p);

    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK, 0, &fds)) != .SUCCESS)
        return error.SkipZigTest;
    defer {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
    }
    const on: u32 = 1;
    if (linux.errno(linux.setsockopt(fds[0], linux.SOL.SOCKET, linux.SO.TIMESTAMPNS_OLD, @ptrCast(&on), @sizeOf(u32))) != .SUCCESS)
        return error.SkipZigTest;
    p.sock4 = .{ .fd = fds[0], .family = .v4, .kind = .dgram, .ident = 0x1234 };

    const id = try p.addTarget("192.0.2.1");
    const seq = try sendProbe(&p, id, 0, monoNow());
    var buf: [icmp.echo_header_len]u8 = undefined;
    const pkt = echoReply(&buf, 0x1234, seq);
    try std.testing.expect(linux.errno(linux.sendto(fds[1], pkt.ptr, pkt.len, 0, null, 0)) == .SUCCESS);

    // The reply sits in the socket for 40 ms before the engine looks.
    var nap: linux.timespec = .{ .sec = 0, .nsec = 40 * ms };
    var no_fds: [1]linux.pollfd = undefined;
    _ = linux.ppoll(&no_fds, 0, &nap, null);
    p.drainReplies();

    try std.testing.expectEqual(@as(u32, 1), p.stats(id).recv);
    try std.testing.expect(p.stats(id).last_ns < 20 * ms);
}
