//! zfping — fping-compatible CLI front-end for the zig-fping library.
//!
//! Output formats, option semantics and exit codes mirror fping (see
//! src/output.c and src/fping.c in the fping distribution). Differences
//! that could not be implemented in 0.1.0 carry comments explaining why.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const fping = @import("zig_fping");
const options_mod = @import("cli/options.zig");
const generate = @import("cli/generate.zig");

const version_string = "zfping 0.1.0 (Zig port of fping, https://fping.org)";

const usage_text =
    \\Usage: zfping [options] [targets...]
    \\
    \\Probing options:
    \\   -4, --ipv4         only ping IPv4 addresses
    \\   -6, --ipv6         only ping IPv6 addresses
    \\   -b, --size=BYTES   amount of ping data to send, in bytes (default: 56)
    \\   -B, --backoff=N    set exponential backoff factor to N (default: 1.5)
    \\   -c, --count=N      count mode: send N pings to each target and report stats
    \\   -f, --file=FILE    read list of targets from a file ( - means stdin)
    \\   -g, --generate     generate target list (only if no -f specified)
    \\                      (give start and end IP in the target list, or a CIDR address)
    \\                      (ex. zfping -g 192.168.1.0 192.168.1.255 or zfping -g 192.168.1.0/24)
    \\   -H, --ttl=N        set the IP TTL value (Time To Live hops)
    \\   -i, --interval=MSEC  interval between sending ping packets (default: 10 ms)
    \\   -I, --iface=IFACE  bind to a particular interface
    \\       --oiface=IFACE  send pings via a specific outgoing interface (receive from any)
    \\   -k, --fwmark=FWMARK set the routing mark
    \\   -l, --loop         loop mode: send pings forever
    \\   -m, --all          use all IPs of provided hostnames (e.g. IPv4 and IPv6), use with -A
    \\   -M, --dontfrag     set the Don't Fragment flag
    \\   -O, --tos=N        set the type of service (tos) flag on the ICMP packets
    \\   -p, --period=MSEC  interval between ping packets to one target (in ms)
    \\                      (in loop and count modes, default: 1000 ms)
    \\   -r, --retry=N      number of retries (default: 3)
    \\   -R, --random       random packet data (to foil link data compression)
    \\   -S, --src=IP       set source address
    \\       --seqmap-timeout=MSEC accepted for fping compatibility (no observable effect, see docs)
    \\   -t, --timeout=MSEC individual target initial timeout (default: 500 ms,
    \\                      except with -l/-c/-C, where it's the -p period up to 2000 ms)
    \\       --check-source discard replies not from target address
    \\       --icmp-timestamp use ICMP Timestamp instead of ICMP Echo
    \\
    \\Output options:
    \\   -a, --alive        show targets that are alive
    \\   -A, --addr         show targets by address
    \\   -C, --vcount=N     same as -c, report results (not stats) in verbose format
    \\   -d, --rdns         show targets by name (force reverse-DNS lookup)
    \\   -D, --timestamp    print timestamp before each output line
    \\       --timestamp-format=FORMAT  show timestamp in the given format (-D required): ctime|iso|rfc3339
    \\   -e, --elapsed      show elapsed time on return packets
    \\   -J, --json         output in JSON format (-c, -C, or -l required)
    \\   -n, --name         show targets by name (reverse-DNS lookup for target IPs)
    \\   -N, --netdata      output compatible for netdata (-l -Q are required)
    \\   -o, --outage       show the accumulated outage time (lost packets * packet interval)
    \\   -q, --quiet        quiet (don't show per-target/per-ping results)
    \\   -Q, --squiet=SECS[,cumulative]  same as -q, but add interval summary every SECS seconds,
    \\                                   with 'cumulative', print stats since beginning
    \\   -s, --stats        print final stats
    \\   -u, --unreach      show targets that are unreachable
    \\   -v, --version      show version
    \\   -x, --reachable=N  shows if >=N hosts are reachable or not
    \\   -X, --fast-reachable=N exits true immediately when N hosts are found
    \\       --print-tos    show received TOS value
    \\       --print-ttl    show IP TTL value
    \\   -h, --help         show this help
    \\
;

/// fping exit codes: 0 all reachable, 1 some unreachable, 2 addresses not
/// found, 3 invalid arguments, 4 internal error.
const exit_unreachable = 1;
const exit_noaddress = 2;
const exit_usage = 3;
const exit_internal = 4;

/// Milliseconds rendering identical to fping's sprint_tm().
fn fmtMs(w: *Io.Writer, ns: u64) Io.Writer.Error!void {
    const t = @as(f64, @floatFromInt(ns)) / 1e6;
    if (t < 1.0) {
        try w.print("{d:.3}", .{t});
    } else if (t < 10.0) {
        try w.print("{d:.2}", .{t});
    } else if (t < 100.0) {
        try w.print("{d:.1}", .{t});
    } else if (t < 1000000.0) {
        try w.print("{d:.0}", .{t});
    } else {
        try w.print("{e:.3}", .{t});
    }
}

fn realNowNs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Per-target CLI bookkeeping on top of the engine statistics.
const TargetState = struct {
    /// Display name: the target as the user gave it, or its address with -A.
    name: []const u8,
    /// Resolved counts (reply/timeout/error) — fping computes per-line loss
    /// from resolved probes only, not from packets already in flight.
    resolved: u32 = 0,
    recv_total: u32 = 0,
    alive_announced: bool = false,
    // Interval (-Q) counters, reset after each report unless cumulative.
    sent_i: u32 = 0,
    recv_i: u32 = 0,
    min_i: u64 = 0,
    max_i: u64 = 0,
    total_i: u64 = 0,
    /// Per-probe RTTs for -C report (null = lost).
    vcount_rtts: []?u64 = &.{},
};

const Ctx = struct {
    gpa: std.mem.Allocator,
    opts: options_mod.Options,
    out: *Io.Writer,
    err: *Io.Writer,
    pinger: *fping.Pinger,
    states: []TargetState,
    name_pad: usize = 0,
    per_recv: bool,
    verbose: bool,
    // Global aggregates for -s.
    g_timeouts: u64 = 0,
    g_recv: u64 = 0,
    g_min: u64 = 0,
    g_max: u64 = 0,
    g_sum: u64 = 0,
    num_alive: u32 = 0,
    num_noaddress: u32 = 0,
    start_real_ns: i64 = 0,
    // -Q interval reporting.
    next_report_ns: i64 = 0,
    netdata_charts_sent: bool = false,
    /// Local timezone for -D/-Q rendering (fping uses localtime()).
    tz: *const fping.LocalTz,

    fn state(self: *Ctx, id: fping.TargetId) *TargetState {
        return &self.states[id];
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const err = &stderr_writer.interface;

    var diag: options_mod.Diagnostic = .{};
    const parsed = options_mod.parse(arena, args[1..], &diag) catch |e| {
        const what: []const u8 = switch (e) {
            error.UnknownOption => "unknown option",
            error.MissingValue => "missing value for option",
            error.InvalidValue => "invalid value",
            error.OutOfMemory => return e,
        };
        err.print("zfping: {s}: {s}\n", .{ what, diag.text }) catch {};
        err.flush() catch {};
        std.process.exit(exit_usage);
    };
    const opts = parsed.opts;

    if (opts.help) {
        try out.writeAll(usage_text);
        try out.flush();
        return;
    }
    if (opts.version) {
        try out.print("{s}\n", .{version_string});
        try out.flush();
        return;
    }

    validate(opts, err);

    // ---- Build the raw target list ------------------------------------
    var raw_targets: std.ArrayList([]const u8) = .empty;
    if (opts.generate) {
        if (opts.file != null) failUsage(err, "-g and -f are mutually exclusive", .{});
        switch (parsed.targets.items.len) {
            1 => generate.addCidr(arena, &raw_targets, parsed.targets.items[0]) catch |e|
                failUsage(err, "-g: {s}", .{@errorName(e)}),
            2 => generate.addRange(arena, &raw_targets, parsed.targets.items[0], parsed.targets.items[1]) catch |e|
                failUsage(err, "-g: {s}", .{@errorName(e)}),
            else => failUsage(err, "-g requires a CIDR or a start/end address pair", .{}),
        }
    } else if (opts.file) |path| {
        if (parsed.targets.items.len > 0) failUsage(err, "-f and target list are mutually exclusive", .{});
        try readTargetFile(arena, init.io, &raw_targets, path, err);
    } else if (parsed.targets.items.len > 0) {
        try raw_targets.appendSlice(arena, parsed.targets.items);
    } else {
        // fping reads targets from stdin when none are given.
        try readTargetFile(arena, init.io, &raw_targets, "-", err);
    }
    if (raw_targets.items.len == 0) {
        err.writeAll(usage_text) catch {};
        err.flush() catch {};
        std.process.exit(exit_usage);
    }

    // ---- Engine configuration ------------------------------------------
    const count_mode = opts.count != null or opts.vcount != null;
    const probes: u32 = opts.vcount orelse (opts.count orelse 1);
    // fping auto-tunes the timeout in count/loop modes: period capped at 2 s.
    const timeout_ns = opts.timeout_ns orelse if (count_mode or opts.loop)
        @min(opts.period_ns, 2000 * std.time.ns_per_ms)
    else
        500 * std.time.ns_per_ms;

    var cfg: fping.Config = .{
        .mode = if (opts.loop) .loop else if (count_mode) .count else .alive,
        .count = @intCast(@min(probes, std.math.maxInt(u16))),
        .retries = opts.retries,
        .interval_ns = opts.interval_ns,
        .perhost_interval_ns = opts.period_ns,
        .timeout_ns = timeout_ns,
        .backoff_factor = opts.backoff,
        .payload_size = opts.size,
        .random_payload = opts.random_data,
        .icmp_timestamp = opts.icmp_timestamp,
        .check_source = opts.check_source,
        .ttl = opts.ttl,
        .tos = opts.tos,
        .dont_fragment = opts.dont_frag,
        .fwmark = opts.fwmark,
        .iface = opts.iface,
        .oiface = opts.oiface,
    };
    // Linux DGRAM ping sockets only transmit ICMP_ECHO; timestamp requests
    // need a raw socket (CAP_NET_RAW), same as fping under the hood.
    if (opts.icmp_timestamp) cfg.socket_mode = .raw;
    if (opts.src_addr) |src| {
        const addr = fping.Addr.parse(src) catch
            failUsage(err, "invalid source address: {s}", .{src});
        switch (addr) {
            .v4 => cfg.source4 = addr,
            .v6 => cfg.source6 = addr,
        }
    }

    var pinger = fping.Pinger.init(arena, cfg) catch |e|
        failInternal(err, "cannot initialize pinger: {s}", .{@errorName(e)});
    defer pinger.deinit();

    // ---- Resolve targets -------------------------------------------------
    var states: std.ArrayList(TargetState) = .empty;
    var num_noaddress: u32 = 0;
    for (raw_targets.items) |name| {
        const family_filter: ?Io.net.IpAddress.Family =
            if (opts.ipv4_only) .ip4 else if (opts.ipv6_only) .ip6 else null;
        var addrs_buf: [32]fping.Addr = undefined;
        const addrs = resolveTarget(init.io, name, family_filter, opts.all_addrs, &addrs_buf) catch {
            err.print("{s}: Name or service not known\n", .{name}) catch {};
            num_noaddress += 1;
            continue;
        };
        const numeric = if (fping.Addr.parse(name)) |_| true else |_| false;
        for (addrs) |addr| {
            _ = try pinger.addTargetAddr(addr);
            // Display-name precedence mirrors fping: reverse DNS (-d always;
            // -n only for numeric targets), then -A/-m numeric address,
            // then the target as the user typed it.
            var display: []const u8 = if (opts.by_addr or opts.all_addrs)
                try std.fmt.allocPrint(arena, "{f}", .{addr})
            else
                name;
            if (opts.rdns or (opts.name_lookup and numeric)) {
                var name_buf: [256]u8 = undefined;
                if (fping.rdns.lookupPtr(rdnsAddress(addr), &name_buf, .{})) |ptr_name| {
                    display = try arena.dupe(u8, ptr_name);
                }
            }
            try states.append(arena, .{ .name = display });
        }
    }
    if (pinger.targetCount() == 0) {
        err.flush() catch {};
        std.process.exit(exit_noaddress);
    }

    var local_tz = fping.LocalTz.load(arena);
    defer local_tz.deinit();

    var ctx: Ctx = .{
        .gpa = arena,
        .opts = opts,
        .out = out,
        .err = err,
        .pinger = &pinger,
        .states = states.items,
        .tz = &local_tz,
        .per_recv = (count_mode or opts.loop) and !opts.quiet,
        // fping prints "is alive"/"is unreachable" verbosity by default;
        // -a/-u/-q and count/loop modes suppress it.
        .verbose = !(opts.show_alive or opts.show_unreach or opts.quiet or
            opts.json or opts.netdata or count_mode or opts.loop),
        .num_noaddress = num_noaddress,
        .start_real_ns = realNowNs(),
    };
    for (ctx.states) |*st| ctx.name_pad = @max(ctx.name_pad, st.name.len);
    if (opts.vcount != null) {
        for (ctx.states) |*st| {
            st.vcount_rtts = try arena.alloc(?u64, probes);
            @memset(st.vcount_rtts, null);
        }
    }
    if (opts.squiet_ns) |q| ctx.next_report_ns = fping.monoNow() + @as(i64, @intCast(q));

    pinger.setResultCallback(&ctx, onOutcome);
    installSignals(&pinger);

    pinger.run() catch |e| switch (e) {
        error.PermissionDenied => failInternal(err,
            \\cannot open ICMP socket: permission denied
            \\hint: allow unprivileged ping sockets:
            \\  sudo sysctl -w net.ipv4.ping_group_range="0 2147483647"
            \\or grant the binary raw-socket capability:
            \\  sudo setcap cap_net_raw+ep zfping
        , .{}),
        error.UnknownInterface => failUsage(err, "unknown interface: {s}", .{opts.oiface orelse "?"}),
        error.InterfaceBind => failInternal(err, "cannot bind to interface (needs CAP_NET_RAW): {s}", .{opts.iface orelse "?"}),
        error.SourceAddressBind => failInternal(err, "cannot bind source address: {s}", .{opts.src_addr orelse "?"}),
        else => failInternal(err, "run failed: {s}", .{@errorName(e)}),
    };

    // ---- Final reports ---------------------------------------------------
    // Write errors here are almost always EPIPE (output piped into a closed
    // reader, e.g. `zfping ... | head`); die quietly like fping's SIGPIPE.
    finish(&ctx) catch std.process.exit(0);
}

fn validate(opts: options_mod.Options, err: *Io.Writer) void {
    if (opts.ipv4_only and opts.ipv6_only)
        failUsage(err, "-4 and -6 are mutually exclusive", .{});
    if (opts.count != null and opts.vcount != null)
        failUsage(err, "-c and -C are mutually exclusive", .{});
    if (opts.loop and (opts.count != null or opts.vcount != null))
        failUsage(err, "-l and -c/-C are mutually exclusive", .{});
    if (opts.json and !(opts.count != null or opts.vcount != null or opts.loop))
        failUsage(err, "-J requires -c, -C or -l", .{});
    if (opts.netdata and !(opts.loop and opts.squiet_ns != null))
        failUsage(err, "-N requires -l and -Q", .{});
    if (opts.icmp_timestamp and opts.ipv6_only)
        failUsage(err, "--icmp-timestamp works with IPv4 only", .{});
}

fn failUsage(err: *Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    err.print("zfping: " ++ fmt ++ "\n", args) catch {};
    err.flush() catch {};
    std.process.exit(exit_usage);
}

fn failInternal(err: *Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    err.print("zfping: " ++ fmt ++ "\n", args) catch {};
    err.flush() catch {};
    std.process.exit(exit_internal);
}

fn rdnsAddress(addr: fping.Addr) fping.rdns.Address {
    return switch (addr) {
        .v4 => |sa| .{ .v4 = @bitCast(sa.addr) },
        .v6 => |sa| .{ .v6 = sa.addr },
    };
}

// ---- Target sources -----------------------------------------------------

fn readTargetFile(
    gpa: std.mem.Allocator,
    io: Io,
    list: *std.ArrayList([]const u8),
    path: []const u8,
    err: *Io.Writer,
) !void {
    const max_size = 16 * 1024 * 1024;
    const content = blk: {
        if (std.mem.eql(u8, path, "-")) {
            var buf: [4096]u8 = undefined;
            var reader: Io.File.Reader = .init(.stdin(), io, &buf);
            break :blk reader.interface.allocRemaining(gpa, .limited(max_size)) catch
                failInternal(err, "cannot read stdin", .{});
        }
        const file = Io.Dir.cwd().openFile(io, path, .{}) catch
            failInternal(err, "cannot open target file: {s}", .{path});
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var reader = file.reader(io, &buf);
        break :blk reader.interface.allocRemaining(gpa, .limited(max_size)) catch
            failInternal(err, "cannot read target file: {s}", .{path});
    };
    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const first = words.next() orelse continue;
        if (first[0] == '#') continue;
        try list.append(gpa, first);
    }
}

fn resolveTarget(
    io: Io,
    name: []const u8,
    family: ?Io.net.IpAddress.Family,
    all: bool,
    out_buf: []fping.Addr,
) ![]fping.Addr {
    // Numeric fast path (no DNS).
    if (fping.Addr.parse(name)) |addr| {
        if (family) |f| {
            const matches = switch (addr) {
                .v4 => f == .ip4,
                .v6 => f == .ip6,
            };
            if (!matches) return error.UnknownHostName;
        }
        out_buf[0] = addr;
        return out_buf[0..1];
    } else |_| {}

    const HostName = Io.net.HostName;
    const host = HostName.init(name) catch return error.UnknownHostName;
    var results_buf: [32]HostName.LookupResult = undefined;
    var queue: Io.Queue(HostName.LookupResult) = .init(&results_buf);
    try host.lookup(io, &queue, .{ .port = 0, .family = family });

    var n: usize = 0;
    while (n < out_buf.len) {
        const result = queue.getOne(io) catch break;
        switch (result) {
            .address => |ip| {
                out_buf[n] = fping.Addr.fromIpAddress(ip);
                n += 1;
                if (!all) break;
            },
            .canonical_name => {},
        }
    }
    if (n == 0) return error.UnknownHostName;
    return out_buf[0..n];
}

// ---- Signal handling ------------------------------------------------------

var global_pinger: ?*fping.Pinger = null;
/// Set by SIGQUIT; the next processed probe outcome prints a status
/// snapshot (fping's status_snapshot behaviour).
var snapshot_requested: std.atomic.Value(bool) = .init(false);

fn handleSigint(_: linux.SIG) callconv(.c) void {
    if (global_pinger) |p| p.stop();
}

fn handleSigquit(_: linux.SIG) callconv(.c) void {
    snapshot_requested.store(true, .monotonic);
}

fn installSignals(pinger: *fping.Pinger) void {
    global_pinger = pinger;
    var act: linux.Sigaction = .{
        .handler = .{ .handler = handleSigint },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.INT, &act, null);
    var quit_act: linux.Sigaction = .{
        .handler = .{ .handler = handleSigquit },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.QUIT, &quit_act, null);
}

// ---- Per-probe output -----------------------------------------------------

fn onOutcome(ctx_ptr: ?*anyopaque, id: fping.TargetId, probe: u16, outcome: fping.Outcome) void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr.?));
    outcomeImpl(ctx, id, probe, outcome) catch {};
}

fn outcomeImpl(ctx: *Ctx, id: fping.TargetId, probe: u16, outcome: fping.Outcome) !void {
    const st = ctx.state(id);
    const opts = &ctx.opts;

    switch (outcome) {
        .reply => |r| {
            st.resolved += 1;
            st.recv_total += 1;
            st.sent_i += 1;
            st.recv_i += 1;
            st.total_i += r.rtt_ns;
            if (st.min_i == 0 or r.rtt_ns < st.min_i) st.min_i = r.rtt_ns;
            if (r.rtt_ns > st.max_i) st.max_i = r.rtt_ns;
            ctx.g_recv += 1;
            ctx.g_sum += r.rtt_ns;
            if (ctx.g_min == 0 or r.rtt_ns < ctx.g_min) ctx.g_min = r.rtt_ns;
            if (r.rtt_ns > ctx.g_max) ctx.g_max = r.rtt_ns;
            if (probe < st.vcount_rtts.len) st.vcount_rtts[probe] = r.rtt_ns;

            if (!st.alive_announced) {
                st.alive_announced = true;
                ctx.num_alive += 1;
                // -X: stop as soon as enough hosts are alive.
                if (opts.fast_reachable and opts.reachable != null and
                    ctx.num_alive >= opts.reachable.?)
                    ctx.pinger.stop();

                if (ctx.verbose or opts.show_alive) {
                    try ctx.out.print("{s}", .{st.name});
                    if (ctx.verbose) try ctx.out.writeAll(" is alive");
                    try printRecvExt(ctx, r, false);
                    try ctx.out.writeAll("\n");
                    try ctx.out.flush();
                }
            }

            if (ctx.per_recv) try printRecv(ctx, st, probe, r);
        },
        .duplicate => |r| {
            // fping prints duplicates to stderr outside of per-recv mode.
            if (!ctx.per_recv) {
                try ctx.err.print("{s} : duplicate for [{d}], {d} bytes, ", .{ st.name, probe, r.size });
                try fmtMs(ctx.err, r.rtt_ns);
                try ctx.err.writeAll(" ms\n");
                try ctx.err.flush();
            }
        },
        .timeout => {
            st.resolved += 1;
            st.sent_i += 1;
            ctx.g_timeouts += 1;
            if (ctx.per_recv) try printTimeout(ctx, st, probe);
        },
        .send_error => {
            st.resolved += 1;
            st.sent_i += 1;
        },
    }

    if (snapshot_requested.swap(false, .monotonic)) {
        if (opts.json) try printIntervalJson(ctx) else try printIntervalSplits(ctx);
    }

    if (opts.squiet_ns) |interval| {
        const now = fping.monoNow();
        if (now >= ctx.next_report_ns) {
            while (ctx.next_report_ns <= now) ctx.next_report_ns += @intCast(interval);
            if (opts.netdata) {
                try printNetdata(ctx);
            } else if (opts.json) {
                try printIntervalJson(ctx);
            } else {
                try printIntervalSplits(ctx);
            }
        }
    }
}

fn printTimestamp(ctx: *Ctx, w: *Io.Writer) !void {
    if (!ctx.opts.timestamp) return;
    const now = realNowNs();
    const json = ctx.opts.json;
    switch (ctx.opts.timestamp_format) {
        .unix => {
            const secs = @as(f64, @floatFromInt(now)) / 1e9;
            if (json) try w.print("\"timestamp\": \"{d:.5}\", ", .{secs}) else try w.print("[{d:.5}] ", .{secs});
        },
        // Rendered in local time like fping's localtime(), using
        // /etc/localtime via std.tz (TZ env rule strings are not
        // interpreted — see src/tzlocal.zig).
        .ctime, .iso, .rfc3339 => {
            var buf: [64]u8 = undefined;
            const offset = ctx.tz.offsetAt(@divTrunc(now, std.time.ns_per_s));
            const text = formatTimestamp(&buf, now, ctx.opts.timestamp_format, offset);
            if (json) try w.print("\"timestamp\": \"{s}\", ", .{text}) else try w.print("[{s}] ", .{text});
        },
    }
}

fn formatTimestamp(buf: []u8, now_ns: i64, format: options_mod.TimestampFormat, offset_secs: i32) []const u8 {
    const epoch_secs: u64 = @intCast(@divTrunc(now_ns, std.time.ns_per_s) + offset_secs);
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = epoch_secs };
    const day = epoch_seconds.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_seconds.getDaySeconds();
    const year = year_day.year;
    const month = month_day.month.numeric();
    const dom = month_day.day_index + 1;
    const hour = day_secs.getHoursIntoDay();
    const minute = day_secs.getMinutesIntoHour();
    const second = day_secs.getSecondsIntoMinute();

    var w: Io.Writer = .fixed(buf);
    switch (format) {
        .ctime => {
            const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
            // Weekday from epoch day (1970-01-01 was a Thursday).
            const weekday_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
            const weekday = weekday_names[day.day % 7];
            w.print("{s} {s} {d:2} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{
                weekday, month_names[month - 1], dom, hour, minute, second, year,
            }) catch unreachable;
        },
        .iso => {
            const sign: u8 = if (offset_secs < 0) '-' else '+';
            const abs: u32 = @abs(offset_secs);
            w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}{d:0>2}", .{
                year, month, dom, hour, minute, second, sign, abs / 3600, (abs / 60) % 60,
            }) catch unreachable;
        },
        .rfc3339 => w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            year, month, dom, hour, minute, second,
        }) catch unreachable,
        .unix => unreachable,
    }
    return w.buffered();
}

fn printPaddedName(ctx: *Ctx, w: *Io.Writer, name: []const u8) !void {
    try w.print("{s}", .{name});
    var pad = ctx.name_pad -| name.len;
    while (pad > 0) : (pad -= 1) try w.writeAll(" ");
}

fn printRecvExt(ctx: *Ctx, r: fping.ReplyInfo, per_recv: bool) !void {
    const opts = &ctx.opts;
    if (r.ts) |ts| {
        const local_ms: u64 = @intCast(@mod(@divTrunc(realNowNs(), std.time.ns_per_ms), std.time.ms_per_day));
        try ctx.out.print("{s} timestamps: Originate={d} Receive={d} Transmit={d} Localreceive={d}", .{
            if (opts.show_alive) "" else ",", ts.originate_ms, ts.receive_ms, ts.transmit_ms, local_ms,
        });
    }
    if (opts.print_tos) {
        if (r.tos) |tos| try ctx.out.print(" (TOS {d})", .{tos}) else try ctx.out.writeAll(" (TOS unknown)");
    }
    if (opts.print_ttl) {
        if (r.ttl) |ttl| try ctx.out.print(" (TTL {d})", .{ttl}) else try ctx.out.writeAll(" (TTL unknown)");
    }
    if (opts.elapsed and !per_recv) {
        try ctx.out.writeAll(" (");
        try fmtMs(ctx.out, r.rtt_ns);
        try ctx.out.writeAll(" ms)");
    }
}

fn printRecv(ctx: *Ctx, st: *TargetState, probe: u16, r: fping.ReplyInfo) !void {
    const stats = ctx.pinger.stats(targetIdOf(ctx, st));
    const avg = stats.avgNs() orelse r.rtt_ns;
    const loss = if (st.resolved > 0) ((st.resolved - st.recv_total) * 100) / st.resolved else 0;

    if (ctx.opts.json) {
        try ctx.out.writeAll("{\"resp\": {");
        try printTimestamp(ctx, ctx.out);
        try ctx.out.print("\"host\": \"{s}\", \"seq\": {d}, \"size\": {d}, \"rtt\": ", .{ st.name, probe, r.size });
        try fmtMs(ctx.out, r.rtt_ns);
        try printRecvExtJson(ctx, r);
        try ctx.out.writeAll("}}\n");
        try ctx.out.flush();
        return;
    }

    try printTimestamp(ctx, ctx.out);
    try printPaddedName(ctx, ctx.out, st.name);
    try ctx.out.print(" : [{d}], {d} bytes, ", .{ probe, r.size });
    try fmtMs(ctx.out, r.rtt_ns);
    try ctx.out.writeAll(" ms (");
    try fmtMs(ctx.out, avg);
    try ctx.out.print(" avg, {d}% loss)", .{loss});
    try printRecvExt(ctx, r, true);
    try ctx.out.writeAll("\n");
    try ctx.out.flush();
}

fn printRecvExtJson(ctx: *Ctx, r: fping.ReplyInfo) !void {
    const opts = &ctx.opts;
    if (r.ts) |ts| {
        const local_ms: u64 = @intCast(@mod(@divTrunc(realNowNs(), std.time.ns_per_ms), std.time.ms_per_day));
        try ctx.out.print(", \"timestamps\": {{\"originate\": {d}, \"receive\": {d}, \"transmit\": {d}, \"localreceive\": {d}}}", .{
            ts.originate_ms, ts.receive_ms, ts.transmit_ms, local_ms,
        });
    }
    if (opts.print_tos) {
        if (r.tos) |tos| try ctx.out.print(", \"tos\": {d}", .{tos}) else try ctx.out.writeAll(", \"tos\": -1");
    }
    if (opts.print_ttl) {
        if (r.ttl) |ttl| try ctx.out.print(", \"ttl\": {d}", .{ttl}) else try ctx.out.writeAll(", \"ttl\": -1");
    }
}

fn printTimeout(ctx: *Ctx, st: *TargetState, probe: u16) !void {
    if (ctx.opts.json) {
        try ctx.out.writeAll("{\"timeout\": {");
        try printTimestamp(ctx, ctx.out);
        try ctx.out.print("\"host\": \"{s}\", \"seq\": {d}}}}}\n", .{ st.name, probe });
        try ctx.out.flush();
        return;
    }
    try printTimestamp(ctx, ctx.out);
    try printPaddedName(ctx, ctx.out, st.name);
    try ctx.out.print(" : [{d}], timed out (", .{probe});
    const stats = ctx.pinger.stats(targetIdOf(ctx, st));
    if (stats.avgNs()) |avg| {
        try fmtMs(ctx.out, avg);
    } else {
        try ctx.out.writeAll("NaN");
    }
    const loss = if (st.resolved > 0) ((st.resolved - st.recv_total) * 100) / st.resolved else 0;
    try ctx.out.print(" avg, {d}% loss)\n", .{loss});
    try ctx.out.flush();
}

fn targetIdOf(ctx: *Ctx, st: *TargetState) fping.TargetId {
    const base = @intFromPtr(ctx.states.ptr);
    const offset = @intFromPtr(st) - base;
    return @intCast(offset / @sizeOf(TargetState));
}

// ---- Interval (-Q) reports -------------------------------------------------

fn printIntervalSplits(ctx: *Ctx) !void {
    const now = realNowNs();
    const now_s = @divTrunc(now, std.time.ns_per_s);
    const local_s = now_s + ctx.tz.offsetAt(now_s);
    const day_secs: u64 = @intCast(@mod(local_s, std.time.s_per_day));
    try ctx.err.print("[{d:0>2}:{d:0>2}:{d:0>2}]\n", .{
        day_secs / 3600, (day_secs / 60) % 60, day_secs % 60,
    });
    for (ctx.states) |*st| {
        try printPaddedName(ctx, ctx.err, st.name);
        try ctx.err.writeAll(" :");
        const loss = if (st.sent_i > 0) ((st.sent_i - st.recv_i) * 100) / st.sent_i else 0;
        try ctx.err.print(" xmt/rcv/%loss = {d}/{d}/{d}%", .{ st.sent_i, st.recv_i, loss });
        if (ctx.opts.outage) {
            const outage_ms = @as(u64, st.sent_i - st.recv_i) * (ctx.opts.period_ns / std.time.ns_per_ms);
            try ctx.err.print(", outage(ms) = {d}", .{outage_ms});
        }
        if (st.recv_i > 0) {
            try ctx.err.writeAll(", min/avg/max = ");
            try fmtMs(ctx.err, st.min_i);
            try ctx.err.writeAll("/");
            try fmtMs(ctx.err, st.total_i / st.recv_i);
            try ctx.err.writeAll("/");
            try fmtMs(ctx.err, st.max_i);
        }
        try ctx.err.writeAll("\n");
        if (!ctx.opts.cumulative) resetInterval(st);
    }
    try ctx.err.flush();
}

fn printIntervalJson(ctx: *Ctx) !void {
    const now_s = @divTrunc(realNowNs(), std.time.ns_per_s);
    for (ctx.states) |*st| {
        try ctx.out.print("{{\"intSum\": {{\"time\": {d},\"host\": \"{s}\", ", .{ now_s, st.name });
        const loss = if (st.sent_i > 0) ((st.sent_i - st.recv_i) * 100) / st.sent_i else 0;
        try ctx.out.print("\"xmt\": {d}, \"rcv\": {d}, \"loss\": {d}", .{ st.sent_i, st.recv_i, loss });
        if (ctx.opts.outage) {
            const outage_ms = @as(u64, st.sent_i - st.recv_i) * (ctx.opts.period_ns / std.time.ns_per_ms);
            try ctx.out.print(", \"outage(ms)\": {d}", .{outage_ms});
        }
        if (st.recv_i > 0) {
            try ctx.out.writeAll(", \"rttMin\": ");
            try fmtMs(ctx.out, st.min_i);
            try ctx.out.writeAll(", \"rttAvg\": ");
            try fmtMs(ctx.out, st.total_i / st.recv_i);
            try ctx.out.writeAll(", \"rttMax\": ");
            try fmtMs(ctx.out, st.max_i);
        }
        try ctx.out.writeAll("}}\n");
        if (!ctx.opts.cumulative) resetInterval(st);
    }
    try ctx.out.flush();
}

fn printNetdata(ctx: *Ctx) !void {
    const interval_s = (ctx.opts.squiet_ns orelse 0) / std.time.ns_per_s;
    for (ctx.states) |*st| {
        if (!ctx.netdata_charts_sent) {
            try ctx.out.print("CHART fping.{s}_packets '' 'FPing Packets' packets '{s}' fping.packets line 110020 {d}\n", .{ st.name, st.name, interval_s });
            try ctx.out.writeAll("DIMENSION xmt sent absolute 1 1\nDIMENSION rcv received absolute 1 1\n");
        }
        try ctx.out.print("BEGIN fping.{s}_packets\nSET xmt = {d}\nSET rcv = {d}\nEND\n", .{ st.name, st.sent_i, st.recv_i });

        if (!ctx.netdata_charts_sent) {
            try ctx.out.print("CHART fping.{s}_quality '' 'FPing Quality' percentage '{s}' fping.quality area 110010 {d}\n", .{ st.name, st.name, interval_s });
            try ctx.out.writeAll("DIMENSION returned '' absolute 1 1\n");
        }
        const quality = if (st.sent_i > 0) (st.recv_i * 100) / st.sent_i else 0;
        try ctx.out.print("BEGIN fping.{s}_quality\nSET returned = {d}\nEND\n", .{ st.name, quality });

        if (!ctx.netdata_charts_sent) {
            try ctx.out.print("CHART fping.{s}_latency '' 'FPing Latency' ms '{s}' fping.latency area 110000 {d}\n", .{ st.name, st.name, interval_s });
            try ctx.out.writeAll("DIMENSION min minimum absolute 1 1000000\nDIMENSION max maximum absolute 1 1000000\nDIMENSION avg average absolute 1 1000000\n");
        }
        try ctx.out.print("BEGIN fping.{s}_latency\n", .{st.name});
        if (st.recv_i > 0) {
            try ctx.out.print("SET min = {d}\nSET avg = {d}\nSET max = {d}\n", .{
                st.min_i, st.total_i / st.recv_i, st.max_i,
            });
        }
        try ctx.out.writeAll("END\n");
        resetInterval(st);
    }
    ctx.netdata_charts_sent = true;
    try ctx.out.flush();
}

fn resetInterval(st: *TargetState) void {
    st.sent_i = 0;
    st.recv_i = 0;
    st.min_i = 0;
    st.max_i = 0;
    st.total_i = 0;
}

// ---- Final reports ----------------------------------------------------------

fn finish(ctx: *Ctx) !void {
    const opts = &ctx.opts;
    var num_unreachable: u32 = 0;

    var id: fping.TargetId = 0;
    while (id < ctx.pinger.targetCount()) : (id += 1) {
        const st = ctx.state(id);
        const stats = ctx.pinger.stats(id);
        if (!stats.alive()) {
            num_unreachable += 1;
            if (ctx.verbose or opts.show_unreach) {
                try ctx.out.print("{s}", .{st.name});
                if (ctx.verbose) try ctx.out.writeAll(" is unreachable");
                try ctx.out.writeAll("\n");
            }
        }
    }
    try ctx.out.flush();

    const count_mode = opts.count != null or opts.vcount != null;
    if (count_mode or opts.loop) {
        if (opts.json) try printPerSystemJson(ctx) else try printPerSystem(ctx);
    }
    if (opts.stats) {
        if (opts.json) try printGlobalStatsJson(ctx) else try printGlobalStats(ctx);
    }

    if (opts.reachable) |required| {
        const reachable = ctx.pinger.targetCount() - num_unreachable;
        if (reachable >= required) {
            try ctx.out.print("Enough hosts reachable (required: {d}, reachable: {d})\n", .{ required, reachable });
            try ctx.out.flush();
            return;
        }
        try ctx.out.print("Not enough hosts reachable (required: {d}, reachable: {d})\n", .{ required, reachable });
        try ctx.out.flush();
        std.process.exit(exit_unreachable);
    }

    if (ctx.num_noaddress > 0) std.process.exit(exit_noaddress);
    if (num_unreachable > 0) std.process.exit(exit_unreachable);
}

fn printPerSystem(ctx: *Ctx) !void {
    if (ctx.verbose or ctx.per_recv) try ctx.err.writeAll("\n");
    var id: fping.TargetId = 0;
    while (id < ctx.pinger.targetCount()) : (id += 1) {
        const st = ctx.state(id);
        const stats = ctx.pinger.stats(id);
        try printPaddedName(ctx, ctx.err, st.name);
        try ctx.err.writeAll(" :");

        if (ctx.opts.vcount != null) {
            for (st.vcount_rtts) |maybe_rtt| {
                if (maybe_rtt) |rtt| {
                    try ctx.err.writeAll(" ");
                    try fmtMs(ctx.err, rtt);
                } else {
                    try ctx.err.writeAll(" -");
                }
            }
            try ctx.err.writeAll("\n");
            continue;
        }

        const loss = if (stats.sent > 0) ((stats.sent - stats.recv) * 100) / stats.sent else 0;
        try ctx.err.print(" xmt/rcv/%loss = {d}/{d}/{d}%", .{ stats.sent, stats.recv, loss });
        if (ctx.opts.outage) {
            const outage_ms = @as(u64, stats.lost()) * (ctx.opts.period_ns / std.time.ns_per_ms);
            try ctx.err.print(", outage(ms) = {d}", .{outage_ms});
        }
        if (stats.recv > 0) {
            try ctx.err.writeAll(", min/avg/max = ");
            try fmtMs(ctx.err, stats.min_ns);
            try ctx.err.writeAll("/");
            try fmtMs(ctx.err, stats.avgNs().?);
            try ctx.err.writeAll("/");
            try fmtMs(ctx.err, stats.max_ns);
        }
        try ctx.err.writeAll("\n");
    }
    try ctx.err.flush();
}

fn printPerSystemJson(ctx: *Ctx) !void {
    var id: fping.TargetId = 0;
    while (id < ctx.pinger.targetCount()) : (id += 1) {
        const st = ctx.state(id);
        const stats = ctx.pinger.stats(id);

        if (ctx.opts.vcount != null) {
            try ctx.out.print("{{\"vSum\": {{\"host\": \"{s}\", \"values\": [", .{st.name});
            for (st.vcount_rtts, 0..) |maybe_rtt, j| {
                if (j > 0) try ctx.out.writeAll(", ");
                if (maybe_rtt) |rtt| try fmtMs(ctx.out, rtt) else try ctx.out.writeAll("null");
            }
            try ctx.out.writeAll("]}}\n");
            continue;
        }

        try ctx.out.print("{{\"summary\": {{\"host\": \"{s}\", ", .{st.name});
        const loss = if (stats.sent > 0) ((stats.sent - stats.recv) * 100) / stats.sent else 0;
        try ctx.out.print("\"xmt\": {d}, \"rcv\": {d}, \"loss\": {d}", .{ stats.sent, stats.recv, loss });
        if (ctx.opts.outage) {
            const outage_ms = @as(u64, stats.lost()) * (ctx.opts.period_ns / std.time.ns_per_ms);
            try ctx.out.print(", \"outage(ms)\": {d}", .{outage_ms});
        }
        if (stats.recv > 0) {
            try ctx.out.writeAll(", \"rttMin\": ");
            try fmtMs(ctx.out, stats.min_ns);
            try ctx.out.writeAll(", \"rttAvg\": ");
            try fmtMs(ctx.out, stats.avgNs().?);
            try ctx.out.writeAll(", \"rttMax\": ");
            try fmtMs(ctx.out, stats.max_ns);
        }
        try ctx.out.writeAll("}}\n");
    }
    try ctx.out.flush();
}

fn globalCounters(ctx: *Ctx) struct { sent: u64, other: u64 } {
    var sent: u64 = 0;
    var other: u64 = 0;
    var id: fping.TargetId = 0;
    while (id < ctx.pinger.targetCount()) : (id += 1) {
        const stats = ctx.pinger.stats(id);
        sent += stats.sent;
        other += stats.icmp_errors;
    }
    return .{ .sent = sent, .other = other };
}

fn printGlobalStats(ctx: *Ctx) !void {
    const totals = globalCounters(ctx);
    const targets = ctx.pinger.targetCount();
    const unreachable_count = targets - ctx.num_alive;
    const elapsed_s = @as(f64, @floatFromInt(realNowNs() - ctx.start_real_ns)) / 1e9;
    const avg = if (ctx.g_recv > 0) ctx.g_sum / ctx.g_recv else 0;

    try ctx.err.writeAll("\n");
    try ctx.err.print(" {d:7} targets\n", .{targets});
    try ctx.err.print(" {d:7} alive\n", .{ctx.num_alive});
    try ctx.err.print(" {d:7} unreachable\n", .{unreachable_count});
    try ctx.err.print(" {d:7} unknown addresses\n", .{ctx.num_noaddress});
    try ctx.err.writeAll("\n");
    try ctx.err.print(" {d:7} timeouts (waiting for response)\n", .{ctx.g_timeouts});
    try ctx.err.print(" {d:7} ICMP Echos sent\n", .{totals.sent});
    try ctx.err.print(" {d:7} ICMP Echo Replies received\n", .{ctx.g_recv});
    try ctx.err.print(" {d:7} other ICMP received\n", .{totals.other});
    try ctx.err.writeAll("\n ");
    try fmtMs(ctx.err, ctx.g_min);
    try ctx.err.writeAll(" ms (min round trip time)\n ");
    try fmtMs(ctx.err, avg);
    try ctx.err.writeAll(" ms (avg round trip time)\n ");
    try fmtMs(ctx.err, ctx.g_max);
    try ctx.err.writeAll(" ms (max round trip time)\n");
    try ctx.err.print(" {d:12.3} sec (elapsed real time)\n\n", .{elapsed_s});
    try ctx.err.flush();
}

fn printGlobalStatsJson(ctx: *Ctx) !void {
    const totals = globalCounters(ctx);
    const targets = ctx.pinger.targetCount();
    const unreachable_count = targets - ctx.num_alive;
    const elapsed_s = @as(f64, @floatFromInt(realNowNs() - ctx.start_real_ns)) / 1e9;
    const avg = if (ctx.g_recv > 0) ctx.g_sum / ctx.g_recv else 0;

    try ctx.out.print("{{\"stats\": {{\"targets\": {d}, \"alive\": {d}, \"unreachable\": {d}, \"unknownAddresses\": {d}, ", .{
        targets, ctx.num_alive, unreachable_count, ctx.num_noaddress,
    });
    try ctx.out.print("\"timeouts\": {d}, \"icmpEchosSent\": {d}, \"icmpEchoRepliesReceived\": {d}, \"otherIcmpReceived\": {d}, ", .{
        ctx.g_timeouts, totals.sent, ctx.g_recv, totals.other,
    });
    try ctx.out.writeAll("\"rttMin\": ");
    try fmtMs(ctx.out, ctx.g_min);
    try ctx.out.writeAll(", \"rttAvg\": ");
    try fmtMs(ctx.out, avg);
    try ctx.out.writeAll(", \"rttMax\": ");
    try fmtMs(ctx.out, ctx.g_max);
    try ctx.out.print(", \"elapsed\": {d:.3}}}}}\n", .{elapsed_s});
    try ctx.out.flush();
}

test {
    _ = @import("cli/options.zig");
    _ = @import("cli/generate.zig");
}
