//! fping-compatible command line parsing: clustered short options
//! ("-aq", "-c3", "-c 3") and GNU-style long options ("--count=3",
//! "--count 3"), mirroring fping's optparse usage.

const std = @import("std");

pub const TimestampFormat = enum { unix, ctime, iso, rfc3339 };

pub const Options = struct {
    // Probing
    ipv4_only: bool = false, // -4
    ipv6_only: bool = false, // -6
    size: u16 = 56, // -b
    backoff: f32 = 1.5, // -B
    count: ?u32 = null, // -c / -C (fping: both set opt_count, last one wins)
    report_all_rtts: bool = false, // -C (verbose per-probe RTT table)
    file: ?[]const u8 = null, // -f ("-" = stdin)
    generate: bool = false, // -g
    ttl: ?u8 = null, // -H
    interval_ns: u64 = 10 * std.time.ns_per_ms, // -i
    iface: ?[]const u8 = null, // -I
    oiface: ?[]const u8 = null, // --oiface
    fwmark: ?u32 = null, // -k
    loop: bool = false, // -l
    all_addrs: bool = false, // -m
    dont_frag: bool = false, // -M
    tos: ?u8 = null, // -O
    period_ns: u64 = 1000 * std.time.ns_per_ms, // -p
    retries: u16 = 3, // -r
    random_data: bool = false, // -R
    src_addr: ?[]const u8 = null, // -S
    timeout_ns: ?u64 = null, // -t (null = fping auto-tuning)
    check_source: bool = false, // --check-source
    icmp_timestamp: bool = false, // --icmp-timestamp

    // Output
    show_alive: bool = false, // -a
    show_unreach: bool = false, // -u
    by_addr: bool = false, // -A
    rdns: bool = false, // -d
    name_lookup: bool = false, // -n
    timestamp: bool = false, // -D
    timestamp_format: TimestampFormat = .unix, // --timestamp-format
    elapsed: bool = false, // -e
    json: bool = false, // -J
    netdata: bool = false, // -N
    outage: bool = false, // -o
    quiet: bool = false, // -q
    squiet_ns: ?u64 = null, // -Q
    cumulative: bool = false, // -Q SECS,cumulative
    stats: bool = false, // -s
    reachable: ?u32 = null, // -x
    fast_reachable: bool = false, // -X (implies reachable)
    print_tos: bool = false, // --print-tos
    print_ttl: bool = false, // --print-ttl
    help: bool = false, // -h
    version: bool = false, // -v
};

pub const Diagnostic = struct {
    /// Option (with dashes) or value the error refers to.
    text: []const u8 = "",
};

pub const ParseError = error{
    UnknownOption,
    MissingValue,
    InvalidValue,
    OutOfMemory,
};

pub const Result = struct {
    opts: Options,
    targets: std.ArrayList([]const u8),

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        self.targets.deinit(gpa);
    }
};

const short_with_value = "bBcCfHiIkOpQrStxX";

fn shortTakesValue(c: u8) bool {
    return std.mem.indexOfScalar(u8, short_with_value, c) != null;
}

pub fn parse(gpa: std.mem.Allocator, args: []const []const u8, diag: *Diagnostic) ParseError!Result {
    var res: Result = .{ .opts = .{}, .targets = .empty };
    errdefer res.targets.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len >= 2 and std.mem.eql(u8, arg[0..2], "--")) {
            if (arg.len == 2) {
                // "--": everything after is a target.
                i += 1;
                while (i < args.len) : (i += 1) try res.targets.append(gpa, args[i]);
                break;
            }
            const body = arg[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const inline_val = if (eq) |e| body[e + 1 ..] else null;
            var consumed_next = false;
            const val = inline_val orelse blk: {
                if (longTakesValue(name)) {
                    if (i + 1 >= args.len) {
                        diag.text = name;
                        return error.MissingValue;
                    }
                    consumed_next = true;
                    break :blk args[i + 1];
                }
                break :blk "";
            };
            try applyLong(&res.opts, name, val, diag);
            if (consumed_next) i += 1;
        } else if (arg.len >= 2 and arg[0] == '-') {
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const c = arg[j];
                if (shortTakesValue(c)) {
                    const val = if (j + 1 < arg.len) arg[j + 1 ..] else blk: {
                        if (i + 1 >= args.len) {
                            // fping/optparse reports the bare option letter.
                            diag.text = arg[j .. j + 1];
                            return error.MissingValue;
                        }
                        i += 1;
                        break :blk args[i];
                    };
                    try applyShortValue(&res.opts, c, val, diag);
                    break;
                }
                diag.text = arg[j .. j + 1];
                try applyShortFlag(&res.opts, c);
            }
        } else {
            try res.targets.append(gpa, arg);
        }
    }
    return res;
}

fn applyShortFlag(o: *Options, c: u8) ParseError!void {
    switch (c) {
        '4' => o.ipv4_only = true,
        '6' => o.ipv6_only = true,
        'a' => o.show_alive = true,
        'A' => o.by_addr = true,
        'd' => o.rdns = true,
        'D' => o.timestamp = true,
        'e' => o.elapsed = true,
        'g' => o.generate = true,
        'h' => o.help = true,
        'J' => o.json = true,
        'l' => o.loop = true,
        'm' => o.all_addrs = true,
        'M' => o.dont_frag = true,
        'n' => o.name_lookup = true,
        'N' => o.netdata = true,
        'o' => o.outage = true,
        'q' => o.quiet = true,
        'R' => o.random_data = true,
        's' => o.stats = true,
        'u' => o.show_unreach = true,
        'v' => o.version = true,
        else => return error.UnknownOption,
    }
}

fn applyShortValue(o: *Options, c: u8, val: []const u8, diag: *Diagnostic) ParseError!void {
    diag.text = val;
    switch (c) {
        'b' => o.size = std.fmt.parseInt(u16, val, 10) catch return error.InvalidValue,
        'B' => o.backoff = std.fmt.parseFloat(f32, val) catch return error.InvalidValue,
        // fping rejects a zero count/threshold with usage(1).
        'c' => o.count = try parseNonZero(val),
        'C' => {
            o.count = try parseNonZero(val);
            o.report_all_rtts = true;
        },
        'f' => o.file = val,
        'H' => o.ttl = std.fmt.parseInt(u8, val, 10) catch return error.InvalidValue,
        'i' => o.interval_ns = try parseMs(val),
        'I' => o.iface = val,
        'k' => o.fwmark = std.fmt.parseInt(u32, val, 10) catch return error.InvalidValue,
        'O' => o.tos = std.fmt.parseInt(u8, val, 10) catch return error.InvalidValue,
        'p' => o.period_ns = try parseMs(val),
        'Q' => try parseSquiet(o, val),
        'r' => o.retries = std.fmt.parseInt(u16, val, 10) catch return error.InvalidValue,
        'S' => o.src_addr = val,
        't' => o.timeout_ns = try parseMs(val),
        'x' => o.reachable = try parseNonZero(val),
        'X' => {
            o.reachable = try parseNonZero(val);
            o.fast_reachable = true;
        },
        else => unreachable,
    }
}

fn longTakesValue(name: []const u8) bool {
    const value_longs = [_][]const u8{
        "size",   "backoff",   "count",  "vcount",           "file",
        "ttl",    "interval",  "iface",  "fwmark",           "tos",
        "period", "retry",     "src",    "seqmap-timeout",   "timeout",
        "squiet", "reachable", "oiface", "timestamp-format", "fast-reachable",
    };
    for (value_longs) |v| if (std.mem.eql(u8, name, v)) return true;
    return false;
}

fn applyLong(o: *Options, name: []const u8, val: []const u8, diag: *Diagnostic) ParseError!void {
    diag.text = name;
    if (std.mem.eql(u8, name, "ipv4")) {
        o.ipv4_only = true;
    } else if (std.mem.eql(u8, name, "ipv6")) {
        o.ipv6_only = true;
    } else if (std.mem.eql(u8, name, "size")) {
        try applyShortValue(o, 'b', val, diag);
    } else if (std.mem.eql(u8, name, "backoff")) {
        try applyShortValue(o, 'B', val, diag);
    } else if (std.mem.eql(u8, name, "count")) {
        try applyShortValue(o, 'c', val, diag);
    } else if (std.mem.eql(u8, name, "vcount")) {
        try applyShortValue(o, 'C', val, diag);
    } else if (std.mem.eql(u8, name, "file")) {
        o.file = val;
    } else if (std.mem.eql(u8, name, "generate")) {
        o.generate = true;
    } else if (std.mem.eql(u8, name, "ttl")) {
        try applyShortValue(o, 'H', val, diag);
    } else if (std.mem.eql(u8, name, "interval")) {
        try applyShortValue(o, 'i', val, diag);
    } else if (std.mem.eql(u8, name, "iface")) {
        o.iface = val;
    } else if (std.mem.eql(u8, name, "oiface")) {
        o.oiface = val;
    } else if (std.mem.eql(u8, name, "fwmark")) {
        try applyShortValue(o, 'k', val, diag);
    } else if (std.mem.eql(u8, name, "loop")) {
        o.loop = true;
    } else if (std.mem.eql(u8, name, "all")) {
        o.all_addrs = true;
    } else if (std.mem.eql(u8, name, "dontfrag")) {
        o.dont_frag = true;
    } else if (std.mem.eql(u8, name, "tos")) {
        try applyShortValue(o, 'O', val, diag);
    } else if (std.mem.eql(u8, name, "period")) {
        try applyShortValue(o, 'p', val, diag);
    } else if (std.mem.eql(u8, name, "retry")) {
        try applyShortValue(o, 'r', val, diag);
    } else if (std.mem.eql(u8, name, "random")) {
        o.random_data = true;
    } else if (std.mem.eql(u8, name, "src")) {
        o.src_addr = val;
    } else if (std.mem.eql(u8, name, "seqmap-timeout")) {
        // Accepted for compatibility; this port frees sequence slots when
        // the probe timeout fires, so there is no separate seqmap window
        // (see pinger.zig module docs).
        _ = try parseMs(val);
    } else if (std.mem.eql(u8, name, "timeout")) {
        try applyShortValue(o, 't', val, diag);
    } else if (std.mem.eql(u8, name, "check-source")) {
        o.check_source = true;
    } else if (std.mem.eql(u8, name, "icmp-timestamp")) {
        o.icmp_timestamp = true;
    } else if (std.mem.eql(u8, name, "alive")) {
        o.show_alive = true;
    } else if (std.mem.eql(u8, name, "addr") or std.mem.eql(u8, name, "address")) {
        o.by_addr = true;
    } else if (std.mem.eql(u8, name, "rdns")) {
        o.rdns = true;
    } else if (std.mem.eql(u8, name, "timestamp")) {
        o.timestamp = true;
    } else if (std.mem.eql(u8, name, "timestamp-format")) {
        if (std.mem.eql(u8, val, "ctime")) {
            o.timestamp_format = .ctime;
        } else if (std.mem.eql(u8, val, "iso")) {
            o.timestamp_format = .iso;
        } else if (std.mem.eql(u8, val, "rfc3339")) {
            o.timestamp_format = .rfc3339;
        } else {
            diag.text = val;
            return error.InvalidValue;
        }
    } else if (std.mem.eql(u8, name, "elapsed")) {
        o.elapsed = true;
    } else if (std.mem.eql(u8, name, "json")) {
        o.json = true;
    } else if (std.mem.eql(u8, name, "name")) {
        o.name_lookup = true;
    } else if (std.mem.eql(u8, name, "netdata")) {
        o.netdata = true;
    } else if (std.mem.eql(u8, name, "outage")) {
        o.outage = true;
    } else if (std.mem.eql(u8, name, "quiet")) {
        o.quiet = true;
    } else if (std.mem.eql(u8, name, "squiet")) {
        try parseSquiet(o, val);
    } else if (std.mem.eql(u8, name, "stats")) {
        o.stats = true;
    } else if (std.mem.eql(u8, name, "unreach")) {
        o.show_unreach = true;
    } else if (std.mem.eql(u8, name, "version")) {
        o.version = true;
    } else if (std.mem.eql(u8, name, "reachable")) {
        try applyShortValue(o, 'x', val, diag);
    } else if (std.mem.eql(u8, name, "fast-reachable")) {
        try applyShortValue(o, 'X', val, diag);
    } else if (std.mem.eql(u8, name, "print-tos")) {
        o.print_tos = true;
    } else if (std.mem.eql(u8, name, "print-ttl")) {
        o.print_ttl = true;
    } else if (std.mem.eql(u8, name, "help")) {
        o.help = true;
    } else {
        return error.UnknownOption;
    }
}

fn parseNonZero(val: []const u8) ParseError!u32 {
    const n = std.fmt.parseInt(u32, val, 10) catch return error.InvalidValue;
    if (n == 0) return error.InvalidValue;
    return n;
}

fn parseMs(val: []const u8) ParseError!u64 {
    const ms = std.fmt.parseFloat(f64, val) catch return error.InvalidValue;
    if (ms < 0 or ms > 1e9) return error.InvalidValue;
    return @intFromFloat(ms * std.time.ns_per_ms);
}

fn parseSquiet(o: *Options, val: []const u8) ParseError!void {
    var spec = val;
    if (std.mem.indexOfScalar(u8, spec, ',')) |comma| {
        if (!std.mem.eql(u8, spec[comma + 1 ..], "cumulative")) return error.InvalidValue;
        o.cumulative = true;
        spec = spec[0..comma];
    }
    const secs = std.fmt.parseFloat(f64, spec) catch return error.InvalidValue;
    if (secs <= 0 or secs > 1e6) return error.InvalidValue;
    o.squiet_ns = @intFromFloat(secs * std.time.ns_per_s);
    o.quiet = true;
}

test "short flags cluster and values" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    var r = try parse(gpa, &.{ "-aq", "-c3", "-t", "250", "10.0.0.1" }, &diag);
    defer r.deinit(gpa);
    try std.testing.expect(r.opts.show_alive);
    try std.testing.expect(r.opts.quiet);
    try std.testing.expectEqual(@as(?u32, 3), r.opts.count);
    try std.testing.expectEqual(@as(?u64, 250 * std.time.ns_per_ms), r.opts.timeout_ns);
    try std.testing.expectEqual(@as(usize, 1), r.targets.items.len);
}

test "long options with = and separate value" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    var r = try parse(gpa, &.{ "--count=2", "--period", "100", "--icmp-timestamp", "host" }, &diag);
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(?u32, 2), r.opts.count);
    try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), r.opts.period_ns);
    try std.testing.expect(r.opts.icmp_timestamp);
}

test "squiet with cumulative" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    var r = try parse(gpa, &.{ "-Q", "5,cumulative", "-l", "h" }, &diag);
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(?u64, 5 * std.time.ns_per_s), r.opts.squiet_ns);
    try std.testing.expect(r.opts.cumulative);
    try std.testing.expect(r.opts.quiet);
    try std.testing.expect(r.opts.loop);
}

test "errors" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.UnknownOption, parse(gpa, &.{"--bogus"}, &diag));
    try std.testing.expectError(error.MissingValue, parse(gpa, &.{"-c"}, &diag));
    try std.testing.expectError(error.InvalidValue, parse(gpa, &.{ "-c", "x" }, &diag));
    {
        var r = try parse(gpa, &.{ "--oiface", "eth0", "h" }, &diag);
        defer r.deinit(gpa);
        try std.testing.expectEqualStrings("eth0", r.opts.oiface.?);
    }
}

test "fuzz: option parser never crashes" {
    // Runs as a smoke test under `zig build test`; becomes a real fuzz
    // target with `zig build test --fuzz` (see scripts/fuzz.sh).
    try std.testing.fuzz({}, fuzzParse, .{});
}

fn fuzzParse(_: void, smith: *std.testing.Smith) !void {
    var buf: [256]u8 = undefined;
    smith.bytes(&buf);
    const len: usize = smith.valueRangeAtMost(u16, 0, buf.len);

    // Split the byte soup on NUL into an argv-like token list.
    var args_buf: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, buf[0..len], 0);
    while (it.next()) |tok| {
        if (n == args_buf.len) break;
        args_buf[n] = tok;
        n += 1;
    }

    var diag: Diagnostic = .{};
    var r = parse(std.testing.allocator, args_buf[0..n], &diag) catch return;
    r.deinit(std.testing.allocator);
}

test "double dash ends options" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    var r = try parse(gpa, &.{ "-q", "--", "-weird-name" }, &diag);
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), r.targets.items.len);
    try std.testing.expectEqualStrings("-weird-name", r.targets.items[0]);
}
