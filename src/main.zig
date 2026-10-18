//! zfping — fping-compatible CLI front-end for the zig-fping library.
//!
//! Output formats, option semantics and exit codes mirror fping (see
//! src/output.c and src/fping.c in the fping distribution). Differences
//! that could not be implemented in 0.1.0 carry comments explaining why.
//!
//! This file holds CLI orchestration only: argument handling, target
//! resolution and the run loop. Shared state lives in cli/context.zig, the
//! per-probe/interval output in cli/output.zig, the final reports in
//! cli/stats.zig and signal handling in cli/signals.zig.

const std = @import("std");
const Io = std.Io;
const fping = @import("zig_fping");
const options_mod = @import("cli/options.zig");
const generate = @import("cli/generate.zig");
const context = @import("cli/context.zig");
const output = @import("cli/output.zig");
const stats = @import("cli/stats.zig");
const signals = @import("cli/signals.zig");

const Ctx = context.Ctx;
const TargetState = context.TargetState;
const realNowNs = context.realNowNs;
const exit_unreachable = context.exit_unreachable;
const exit_noaddress = context.exit_noaddress;
const exit_usage = context.exit_usage;
const exit_internal = context.exit_internal;

const version_string = "zfping 0.1.3 (Zig port of fping, https://fping.org)";

/// Program name for error prefixes — argv[0] as invoked, like fping's
/// global `prog`. Set early in main().
var prog: []const u8 = "zfping";

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

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 0) prog = args[0];

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const err = &stderr_writer.interface;

    var diag: options_mod.Diagnostic = .{};
    const parsed = options_mod.parse(arena, args[1..], &diag) catch |e| {
        // fping's optparse errors print "<argv0>: <msg> -- '<opt>'" plus a
        // hint line and exit 1; invalid option *values* go through usage(1),
        // which dumps the whole usage text to stderr. The hint names "fping"
        // literally (so does upstream regardless of argv[0]).
        switch (e) {
            error.UnknownOption, error.MissingValue => {
                const what: []const u8 = if (e == error.UnknownOption)
                    "invalid option"
                else
                    "option requires an argument";
                err.print("{s}: {s} -- '{s}'\n", .{ args[0], what, diag.text }) catch {};
                err.writeAll("see 'fping -h' for usage information\n") catch {};
                err.flush() catch {};
                std.process.exit(exit_usage);
            },
            error.InvalidValue => usageError(err),
            error.OutOfMemory => return e,
        }
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
    // fping treats file/generate/cmdline conflicts and bad -g arguments as
    // usage(1) errors (usage dump, exit 1).
    var raw_targets: std.ArrayList([]const u8) = .empty;
    if (opts.generate) {
        if (opts.file != null) usageError(err);
        switch (parsed.targets.items.len) {
            1 => generate.addCidr(arena, &raw_targets, parsed.targets.items[0]) catch
                usageError(err),
            2 => generate.addRange(arena, &raw_targets, parsed.targets.items[0], parsed.targets.items[1]) catch
                usageError(err),
            else => usageError(err),
        }
    } else if (opts.file) |path| {
        if (parsed.targets.items.len > 0) usageError(err);
        try readTargetFile(arena, init.io, &raw_targets, path, err);
    } else if (parsed.targets.items.len > 0) {
        try raw_targets.appendSlice(arena, parsed.targets.items);
    } else {
        // fping reads targets from stdin when none are given.
        try readTargetFile(arena, init.io, &raw_targets, "-", err);
    }
    if (raw_targets.items.len == 0) usageError(err);

    // ---- Engine configuration ------------------------------------------
    const count_mode = opts.count != null;
    const probes: u32 = opts.count orelse 1;
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
        .payload_size = @intCast(opts.size), // <= max_ping_data (validate)
        .random_payload = opts.random_data,
        .icmp_timestamp = opts.icmp_timestamp,
        .check_source = opts.check_source,
        .ttl = if (opts.ttl) |t| @intCast(t) else null, // <= 255 (validate)
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
            failUsage(err, "can't parse source address: {s}", .{src});
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
        const addrs = resolveTarget(init.io, name, family_filter, opts.all_addrs, &addrs_buf) catch |e| {
            // fping warns via print_warning (stderr, suppressed by -q) with
            // the gai_strerror text; map std lookup errors onto those.
            if (!opts.quiet) {
                const reason: []const u8 = switch (e) {
                    error.UnknownHostName, error.NoAddressReturned => "Name or service not known",
                    else => "Temporary failure in name resolution",
                };
                err.print("{s}: {s}\n", .{ name, reason }) catch {};
            }
            num_noaddress += 1;
            continue;
        };
        const numeric = if (fping.Addr.parse(name)) |_| true else |_| false;
        for (addrs) |addr| {
            _ = try pinger.addTargetAddr(addr);
            // Display name mirrors fping's add_name(): printname is the
            // target as typed, replaced by reverse DNS for -d (always) or
            // -n (numeric targets only); -A shows the numeric address, or
            // "printname (addr)" when combined with -n/-d. -m alone keeps
            // the printname for every resolved address.
            var printname = name;
            if (opts.rdns or (opts.name_lookup and numeric)) {
                var name_buf: [256]u8 = undefined;
                if (fping.rdns.lookupPtr(rdnsAddress(addr), &name_buf, .{})) |ptr_name| {
                    printname = try arena.dupe(u8, ptr_name);
                }
            }
            const display: []const u8 = if (opts.by_addr) blk: {
                const addr_str = try arena.print("{f}", .{addr});
                break :blk if (opts.name_lookup or opts.rdns)
                    try arena.print("{s} ({s})", .{ printname, addr_str })
                else
                    addr_str;
            } else printname;
            var st: TargetState = .{ .name = display };
            if (opts.netdata) {
                const id = try arena.dupe(u8, display);
                for (id) |*c| {
                    if (!std.ascii.isAlphanumeric(c.*)) c.* = '_';
                }
                st.netdata_id = id;
            }
            try states.append(arena, st);
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
        // -a/-u/-q/-x/-X and count/loop modes suppress it (-N and -J do
        // not on their own — they are gated by -l/-c upstream).
        .verbose = !(opts.show_alive or opts.show_unreach or opts.quiet or
            opts.reachable != null or count_mode or opts.loop),
        .num_noaddress = num_noaddress,
        .start_real_ns = realNowNs(),
    };
    for (ctx.states) |*st| ctx.name_pad = @max(ctx.name_pad, st.name.len);
    if (opts.report_all_rtts) {
        for (ctx.states) |*st| {
            st.vcount_rtts = try arena.alloc(?u64, probes);
            @memset(st.vcount_rtts, null);
        }
    }
    if (opts.squiet_ns) |q| ctx.next_report_ns = fping.monoNow() + @as(i64, @intCast(q));

    pinger.setResultCallback(&ctx, output.onOutcome);
    signals.installSignals(&pinger);

    pinger.run() catch |e| switch (e) {
        error.PermissionDenied => failInternal(err,
            \\cannot open ICMP socket: permission denied
            \\hint: allow unprivileged ping sockets:
            \\  sudo sysctl -w net.ipv4.ping_group_range="0 2147483647"
            \\or grant the binary raw-socket capability:
            \\  sudo setcap cap_net_raw+ep zfping
        , .{}),
        error.UnknownInterface => failUsage(err, "unknown interface '{s}'", .{opts.oiface orelse "?"}),
        error.InterfaceBind => failInternal(err, "cannot bind to interface (needs CAP_NET_RAW): {s}", .{opts.iface orelse "?"}),
        error.SourceAddressBind => failInternal(err, "cannot bind source address: {s}", .{opts.src_addr orelse "?"}),
        else => failInternal(err, "run failed: {s}", .{@errorName(e)}),
    };

    // ---- Final reports ---------------------------------------------------
    // Write errors here are almost always EPIPE (output piped into a closed
    // reader, e.g. `zfping ... | head`); die quietly like fping's SIGPIPE.
    stats.finish(&ctx) catch std.process.exit(0);
}

fn validate(opts: options_mod.Options, err: *Io.Writer) void {
    if (checkOptions(opts, std.os.linux.getuid() == 0)) |msg| {
        err.print("{s}: {f}\n", .{ prog, msg }) catch {};
        err.flush() catch {};
        std.process.exit(exit_usage);
    }
}

/// fping's MAX_PING_DATA: 65535 - 20 (IPv4 header) - 8 (ICMP header).
const max_ping_data = 65535 - 20 - 8;
/// fping's MIN/MAX_BACKOFF_FACTOR.
const min_backoff = 1.0;
const max_backoff = 5.0;
/// fping's MIN_PERHOST_INTERVAL_MS without --enable-safe-limits (the
/// default build), in ns. MIN_INTERVAL_MS is 0 there, and negative -i
/// values are already usage errors, so the -i check can never fire.
const min_perhost_interval_ns = 1000;

/// One failed post-parse option check; renders the text after "<prog>: ".
const OptionError = union(enum) {
    both_families,
    ttl_range: u32,
    alive_and_unreach,
    oiface_and_iface,
    count_and_loop,
    json_mode,
    perhost_interval,
    data_size: u32,
    backoff: f32,
    timestamp_size,
    timestamp_ipv6,

    pub fn format(self: OptionError, w: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .both_families => try w.writeAll("can't specify both -4 and -6"),
            .ttl_range => |t| try w.print("ttl {d} out of range", .{t}),
            .alive_and_unreach => try w.writeAll("specify only one of a, u"),
            .oiface_and_iface => try w.writeAll("specify only --oiface or -I, --iface"),
            .count_and_loop => try w.writeAll("specify only one of c, l"),
            .json_mode => try w.writeAll("option -J, --json requires -c, -C, or -l"),
            // fping prints (float)MIN_PERHOST_INTERVAL_MS with %g.
            .perhost_interval => try w.writeAll("-p must be >= 0.001"),
            .data_size => |n| try w.print("data size {d} not valid, must not be larger than {d}", .{ n, max_ping_data }),
            .backoff => |b| try w.print("backoff factor {d:.1} not valid, must be between 1.0 and 5.0", .{@as(f64, b)}),
            .timestamp_size => try w.writeAll("cannot change ICMP Timestamp size"),
            .timestamp_ipv6 => try w.writeAll("ICMP Timestamp is IPv4 only"),
        }
    }
};

/// fping's inline post-parse checks (fping.c main(), v5.5), in fping's
/// order. Messages go to stderr as "<prog>: <message>" with exit 1.
fn checkOptions(opts: options_mod.Options, is_root: bool) ?OptionError {
    // fping rejects -4 together with -6 while parsing, i.e. first.
    if (opts.ipv4_only and opts.ipv6_only) return .both_families;
    if (opts.ttl) |t| if (t > 255) return .{ .ttl_range = t };
    if (opts.show_alive and opts.show_unreach) return .alive_and_unreach;
    // Only on fping develop (with --oiface itself, see CHANGELOG); not in
    // v5.5.
    if (opts.oiface != null and opts.iface != null) return .oiface_and_iface;
    if (opts.loop and opts.count != null) return .count_and_loop;
    if (opts.json and !(opts.count != null or opts.loop)) return .json_mode;
    if (opts.period_ns < min_perhost_interval_ns and !is_root) return .perhost_interval;
    if (opts.size > max_ping_data) return .{ .data_size = opts.size };
    // NaN fails both comparisons and passes, exactly like fping's check;
    // the engine's backoff() then leaves the timeout unchanged.
    if (opts.backoff > max_backoff or opts.backoff < min_backoff) return .{ .backoff = opts.backoff };
    if (opts.icmp_timestamp and opts.size_set) return .timestamp_size;
    // fping checks this while parsing, so upstream it only fires when -4/-6
    // precede --icmp-timestamp; we check it order-independently.
    if (opts.icmp_timestamp and opts.ipv6_only) return .timestamp_ipv6;
    // NOTE: fping never validates -N (netdata) prerequisites; -N without
    // -l/-Q simply behaves like a normal run, so neither do we.
    return null;
}

/// fping's usage(1): dump the usage text to stderr and exit 1.
fn usageError(err: *Io.Writer) noreturn {
    err.writeAll(usage_text) catch {};
    err.flush() catch {};
    std.process.exit(exit_usage);
}

/// fping's inline "<prog>: <message>" + exit(1) error path.
fn failUsage(err: *Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    err.print("{s}: " ++ fmt ++ "\n", .{prog} ++ args) catch {};
    err.flush() catch {};
    std.process.exit(exit_usage);
}

fn failInternal(err: *Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    err.print("{s}: " ++ fmt ++ "\n", .{prog} ++ args) catch {};
    err.flush() catch {};
    std.process.exit(exit_internal);
}

fn rdnsAddress(addr: fping.Addr) fping.rdns.Address {
    return switch (addr) {
        .v4 => |sa| .{ .v4 = std.mem.toBytes(sa.addr) },
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

/// Drains `queue` until the producer closes it. Addresses beyond
/// `out_buf.len` are discarded, but still consumed so the producer never
/// blocks on a full queue. Returns the number of addresses stored.
fn collectAddresses(io: Io, queue: *Io.Queue(Io.net.HostName.LookupResult), out_buf: []fping.Addr) usize {
    var n: usize = 0;
    while (queue.getOne(io)) |result| {
        switch (result) {
            .address => |ip| if (n < out_buf.len) {
                out_buf[n] = fping.Addr.fromIpAddress(ip);
                n += 1;
            },
            .canonical_name => {},
        }
    } else |_| {}
    return n;
}

fn produceTestResults(io: Io, queue: *Io.Queue(Io.net.HostName.LookupResult), count: u8) Io.Cancelable!void {
    defer queue.close(io);
    var i: u8 = 0;
    while (i < count) : (i += 1) {
        queue.putOne(io, .{ .address = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, i }, .port = 0 } } }) catch return;
    }
}

test "collectAddresses drains more results than the queue holds" {
    const io = std.testing.io;
    var buf: [4]Io.net.HostName.LookupResult = undefined;
    var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&buf);
    var fut = try io.concurrent(produceTestResults, .{ io, &queue, @as(u8, 100) });
    var out: [64]fping.Addr = undefined;
    const n = collectAddresses(io, &queue, &out);
    try fut.await(io);
    // 100 produced, out_buf holds 64: the excess is dropped, not blocked on.
    try std.testing.expectEqual(@as(usize, 64), n);
    try std.testing.expectEqual(@as(u8, 63), std.mem.asBytes(&out[63].v4.addr)[3]);
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
    // std documents no upper bound on the number of results (every
    // /etc/hosts line and DNS record is one), and lookup() blocks once the
    // queue is full, so the queue must be drained while lookup runs. A
    // concurrent task is required; Io.async may run lookup inline.
    const lookup_opts: HostName.LookupOptions = .{ .port = 0, .family = family };
    const n = if (io.concurrent(HostName.lookup, .{ host, io, &queue, lookup_opts })) |future| blk: {
        var lookup_future = future;
        defer _ = lookup_future.cancel(io) catch {};
        const count = collectAddresses(io, &queue, out_buf);
        try lookup_future.await(io);
        break :blk count;
    } else |_| blk: {
        // No unit of concurrency (e.g. a single-threaded Io): look up inline
        // as before; only names with more results than the queue holds block.
        try HostName.lookup(host, io, &queue, lookup_opts);
        break :blk collectAddresses(io, &queue, out_buf);
    };
    if (n == 0) return error.UnknownHostName;
    // fping takes getaddrinfo results in order, which glibc sorts per
    // RFC 6724 (e.g. ::1 before 127.0.0.1 for "localhost"); std's lookup
    // returns /etc/hosts and DNS order, so sort here to match.
    fping.netutil.sortByDestinationPolicy(out_buf[0..n]);
    return if (all) out_buf[0..n] else out_buf[0..1];
}

fn expectOptionError(args: []const []const u8, is_root: bool, expected: ?[]const u8) !void {
    var diag: options_mod.Diagnostic = .{};
    var r = try options_mod.parse(std.testing.allocator, args, &diag);
    defer r.deinit(std.testing.allocator);
    const got = checkOptions(r.opts, is_root);
    if (expected) |text| {
        var buf: [128]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        try w.print("{f}", .{got orelse return error.TestExpectedError});
        try std.testing.expectEqualStrings(text, w.buffered());
    } else {
        try std.testing.expectEqual(@as(?OptionError, null), got);
    }
}

test "post-parse option checks mirror fping v5.5 messages" {
    try expectOptionError(&.{ "-c1", "h" }, false, null);
    try expectOptionError(&.{ "-H", "255", "-b", "65507", "-B", "5", "h" }, false, null);
    try expectOptionError(&.{ "-H", "300", "h" }, false, "ttl 300 out of range");
    try expectOptionError(&.{ "-a", "-u", "h" }, false, "specify only one of a, u");
    try expectOptionError(&.{ "-I", "lo", "--oiface=lo", "h" }, false, "specify only --oiface or -I, --iface");
    try expectOptionError(&.{ "-p", "0", "h" }, false, "-p must be >= 0.001");
    try expectOptionError(&.{ "-p", "0", "h" }, true, null);
    try expectOptionError(&.{ "-p", "0.001", "h" }, false, null);
    try expectOptionError(&.{ "-b", "65508", "h" }, false, "data size 65508 not valid, must not be larger than 65507");
    try expectOptionError(&.{ "-B", "6", "h" }, false, "backoff factor 6.0 not valid, must be between 1.0 and 5.0");
    try expectOptionError(&.{ "-B", "0.5", "h" }, false, "backoff factor 0.5 not valid, must be between 1.0 and 5.0");
    try expectOptionError(&.{ "-B", "nan", "h" }, false, null);
    try expectOptionError(&.{ "--icmp-timestamp", "-b", "12", "h" }, false, "cannot change ICMP Timestamp size");
    try expectOptionError(&.{ "--icmp-timestamp", "h" }, false, null);
}

test {
    _ = @import("cli/options.zig");
    _ = @import("cli/generate.zig");
    _ = @import("cli/context.zig");
    _ = @import("cli/output.zig");
    _ = @import("cli/stats.zig");
    _ = @import("cli/signals.zig");
}
