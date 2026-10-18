//! Fuzz harness for the option parser (test-only; see scripts/fuzz.sh).

const std = @import("std");
const fuzz_driver = @import("fuzz_driver");
const options = @import("options.zig");
const parse = options.parse;
const Options = options.Options;
const ParseError = options.ParseError;
const Diagnostic = options.Diagnostic;

// ---- fuzzing ------------------------------------------------------------------
//
// The harness is generic over its source of choices (fuzz_driver.Rng under
// scripts/fuzz.sh, a Smith script under the optional `zig build test --fuzz`).
// Three argv sources per run: the raw bytes split on NUL (a corpus entry is an
// argv), a real argv with a few octets changed, and a generated argv built from
// the option tables, which random octets would almost never spell. Plus one
// differential check: the four spellings of a value option agree.

/// Real option vectors, NUL-separated: clusters, attached and separate values,
/// long options with `=` and without, `--`, -g specs, the out-of-range and NaN
/// values that main.validate or parse must reject, a missing value.
const option_seeds = [_][]const u8{
    fuzz_driver.seed("-c\x003\x00-p\x00100\x00host"),
    fuzz_driver.seed("-aq\x00-c3\x00--timeout=500\x00h1\x00h2"),
    fuzz_driver.seed("--count\x005\x00--oiface\x00eth0\x00h"),
    fuzz_driver.seed("-g\x00192.168.1.0/24"),
    fuzz_driver.seed("-g\x0010.0.0.250\x0010.0.1.2"),
    fuzz_driver.seed("-Q\x005,cumulative\x00-l\x00h"),
    fuzz_driver.seed("-q\x00--\x00-weird-name"),
    fuzz_driver.seed("--timestamp-format=rfc3339\x00-D\x00h"),
    fuzz_driver.seed("-b\x0070000\x00-H\x00300\x00h"),
    fuzz_driver.seed("-i\x00nan\x00h"),
    fuzz_driver.seed("-r\x0065535\x00-B\x001.5\x00h"),
    fuzz_driver.seed("-4\x00-6\x00--ipv4\x00h"),
    fuzz_driver.seed("-c"), // missing value
    fuzz_driver.seed("--bogus"),
    fuzz_driver.seed("-aqeZ\x00h"), // unknown flag inside a cluster
    fuzz_driver.seed(""),
};

const flag_letters = "46aAdDeghJlmMnNoqRsuv";
const value_letters = "bBcCfHiIkOpQrStxX";
const long_flags = [_][]const u8{
    "ipv4",         "ipv6",           "generate",  "loop",      "all",     "dontfrag", "random",
    "check-source", "icmp-timestamp", "alive",     "addr",      "address", "rdns",     "timestamp",
    "elapsed",      "json",           "name",      "netdata",   "outage",  "quiet",    "stats",
    "unreach",      "version",        "print-tos", "print-ttl", "help",    "bogus",
};
const long_values = [_][]const u8{
    "size",   "backoff",   "count",  "vcount",           "file",
    "ttl",    "interval",  "iface",  "fwmark",           "tos",
    "period", "retry",     "src",    "seqmap-timeout",   "timeout",
    "squiet", "reachable", "oiface", "timestamp-format", "fast-reachable",
};
const value_pool = [_][]const u8{
    "0",     "1",   "3",       "56",   "255",      "256",            "65535", "65536", "4294967295",   "4294967296",
    "-1",    "1.5", "0.5",     "1e3",  "nan",      "inf",            "",      "abc",   "5,cumulative", "5,x",
    "ctime", "iso", "rfc3339", "eth0", "10.0.0.1", "192.168.1.0/24", "-",
};
const target_pool = [_][]const u8{ "host", "10.0.0.1", "::1", "example.test", "-", "-weird", "a b" };

/// Spelling pairs of a value option, for the differential check.
const equiv_opts = [_]struct { u8, []const u8 }{
    .{ 'b', "size" },      .{ 'B', "backoff" },        .{ 'c', "count" },   .{ 'C', "vcount" },
    .{ 'H', "ttl" },       .{ 'i', "interval" },       .{ 'k', "fwmark" },  .{ 'O', "tos" },
    .{ 'p', "period" },    .{ 'r', "retry" },          .{ 't', "timeout" }, .{ 'Q', "squiet" },
    .{ 'x', "reachable" }, .{ 'X', "fast-reachable" }, .{ 'f', "file" },    .{ 'I', "iface" },
    .{ 'S', "src" },
};
const equiv_values = [_][]const u8{ "0", "1", "3", "56", "255", "256", "65535", "65536", "1.5", "0.5", "1000", "5,cumulative", "abc", "" };

/// An argv under construction; the tokens live in its own storage.
const Argv = struct {
    items: [24][]const u8 = undefined,
    n: usize = 0,
    store: [2048]u8 = undefined,
    used: usize = 0,

    fn add(self: *Argv, parts: []const []const u8) void {
        if (self.n == self.items.len) return;
        const start = self.used;
        for (parts) |p| {
            const k = @min(p.len, self.store.len - self.used);
            @memcpy(self.store[self.used..][0..k], p);
            self.used += k;
        }
        self.items[self.n] = self.store[start..self.used];
        self.n += 1;
    }
    fn list(self: *const Argv) []const []const u8 {
        return self.items[0..self.n];
    }
};

fn optionsHarness(comptime S: type, src: *S, gpa: std.mem.Allocator) anyerror!void {
    var buf: [256]u8 = undefined;
    const len: usize = src.slice(&buf);
    if (len != 0) fuzz_driver.hit("raw_nonempty");
    try checkArgv(gpa, splitNul(buf[0..len]).list(), .{});

    // A real argv with up to two octets changed.
    const body = fuzz_driver.frameOf(option_seeds[src.index(option_seeds.len)]);
    var mut: [256]u8 = undefined;
    @memcpy(mut[0..body.len], body);
    if (body.len > 0) for (0..src.index(3)) |_| {
        mut[src.index(body.len)] = src.value(u8);
        fuzz_driver.hit("mutated");
    };
    try checkArgv(gpa, splitNul(mut[0..body.len]).list(), .{});

    // A generated argv.
    var gen: Argv = .{};
    var used_long = false;
    var used_cluster = false;
    var used_value = false;
    for (0..src.index(8)) |_| switch (src.index(7)) {
        0 => gen.add(&.{target_pool[src.index(target_pool.len)]}),
        1 => { // flag cluster, optionally ending in a value option
            var cl: [8]u8 = undefined;
            cl[0] = '-';
            const k = 1 + src.index(4);
            for (cl[1 .. 1 + k]) |*c| c.* = flag_letters[src.index(flag_letters.len)];
            used_cluster = true;
            if (src.index(3) == 0) {
                cl[1 + k] = value_letters[src.index(value_letters.len)];
                gen.add(&.{ cl[0 .. k + 2], value_pool[src.index(value_pool.len)] });
            } else gen.add(&.{cl[0 .. 1 + k]});
        },
        2 => { // short value option, attached or separate
            const letter = [1]u8{value_letters[src.index(value_letters.len)]};
            const v = value_pool[src.index(value_pool.len)];
            used_value = true;
            if (src.index(2) == 0) {
                gen.add(&.{ "-", &letter, v });
            } else {
                gen.add(&.{ "-", &letter });
                gen.add(&.{v});
            }
        },
        3 => {
            gen.add(&.{ "--", long_flags[src.index(long_flags.len)] });
            used_long = true;
        },
        4 => {
            const name = long_values[src.index(long_values.len)];
            const v = value_pool[src.index(value_pool.len)];
            used_long = true;
            used_value = true;
            if (src.index(2) == 0) {
                gen.add(&.{ "--", name, "=", v });
            } else {
                gen.add(&.{ "--", name });
                gen.add(&.{v});
            }
        },
        5 => gen.add(&.{"--"}),
        else => gen.add(&.{ "-", &[1]u8{src.value(u8)} }),
    };
    try checkArgv(gpa, gen.list(), .{ .long = used_long, .cluster = used_cluster, .value = used_value });

    // The four spellings of one value option agree.
    const eq = equiv_opts[src.index(equiv_opts.len)];
    const val = equiv_values[src.index(equiv_values.len)];
    try checkEquivalent(gpa, eq[0], eq[1], val);
}

fn splitNul(bytes: []const u8) Argv {
    var a: Argv = .{};
    var it = std.mem.splitScalar(u8, bytes, 0);
    while (it.next()) |tok| a.add(&.{tok});
    return a;
}

const Shape = struct { long: bool = false, cluster: bool = false, value: bool = false };

fn checkArgv(gpa: std.mem.Allocator, args: []const []const u8, shape: Shape) !void {
    var diag: Diagnostic = .{};
    var r = parse(gpa, args, &diag) catch |e| {
        switch (e) {
            error.UnknownOption => fuzz_driver.hit("err_unknown"),
            error.MissingValue => fuzz_driver.hit("err_missing"),
            error.InvalidValue => fuzz_driver.hit("err_invalid"),
            error.OutOfMemory => return e,
        }
        return;
    };
    defer r.deinit(gpa);
    fuzz_driver.hit("parsed_ok");
    if (r.targets.items.len != 0) fuzz_driver.hit("with_targets");
    if (shape.long) fuzz_driver.hit("long_ok");
    if (shape.cluster) fuzz_driver.hit("cluster_ok");
    if (shape.value) fuzz_driver.hit("value_ok");
    for (args) |a| if (std.mem.eql(u8, a, "--")) fuzz_driver.hit("dashdash");

    // What parse promises about its result (usage errors in fping).
    const o = r.opts;
    if (o.count) |c| try std.testing.expect(c != 0);
    if (o.ttl) |t| try std.testing.expect(t != 0);
    if (o.reachable) |x| try std.testing.expect(x != 0);
    if (o.fast_reachable) try std.testing.expect(o.reachable != null);
    if (o.squiet_ns) |q| try std.testing.expect(q > 0 and o.quiet);
    if (o.cumulative) try std.testing.expect(o.squiet_ns != null);
    // every target is one of the arguments, in order, so none is invented
    var at: usize = 0;
    for (r.targets.items) |t| {
        while (at < args.len and !std.mem.eql(u8, args[at], t)) at += 1;
        try std.testing.expect(at < args.len);
        at += 1;
    }
}

/// `-cV`, `-c V`, `--count=V`, `--count V` give the same result (or the same
/// error) and the same single target.
fn checkEquivalent(gpa: std.mem.Allocator, letter: u8, long: []const u8, val: []const u8) !void {
    var forms: [4]Argv = @splat(.{});
    if (val.len != 0) forms[0].add(&.{ "-", &[1]u8{letter}, val }) else forms[0].add(&.{ "-", &[1]u8{letter} });
    forms[0].add(&.{"h"});
    forms[1].add(&.{ "-", &[1]u8{letter} });
    forms[1].add(&.{val});
    forms[1].add(&.{"h"});
    forms[2].add(&.{ "--", long, "=", val });
    forms[2].add(&.{"h"});
    forms[3].add(&.{ "--", long });
    forms[3].add(&.{val});
    forms[3].add(&.{"h"});

    // An attached empty value is "-c" alone, which takes the next argument:
    // that form is only comparable with a non-empty value.
    const first: usize = if (val.len == 0) 1 else 0;
    var want: ?(ParseError!Options) = null;
    var diag: Diagnostic = .{};
    for (forms[first..]) |*f| {
        var r = parse(gpa, f.list(), &diag) catch |e| {
            if (want) |w| {
                try std.testing.expectError(e, w);
            } else want = e;
            continue;
        };
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), r.targets.items.len);
        try std.testing.expectEqualStrings("h", r.targets.items[0]);
        if (want) |w| {
            const wo = try w;
            // NaN backoff compares unequal to itself; the pool has no NaN here.
            try std.testing.expectEqualDeep(wo, r.opts);
        } else want = r.opts;
    }
    fuzz_driver.hit("equiv_checked");
    if (want) |w| {
        if (w) |_| fuzz_driver.hit("equiv_ok") else |_| fuzz_driver.hit("equiv_error");
    } else unreachable;
}

test "fuzz: option parser never crashes" {
    // Optional `zig build test --fuzz`; a plain run replays the corpus once.
    try std.testing.fuzz({}, fuzz_driver.smithEntry(optionsHarness, 512), .{ .corpus = &option_seeds });
}

test "fuzz driver: options" {
    try fuzz_driver.run(optionsHarness, .{ .name = "options" });
}

test "fuzz harness: options reaches every branch in 500 seeds" {
    try fuzz_driver.expectReach(optionsHarness, "options", 500, &.{
        "raw_nonempty",
        "mutated",
        "parsed_ok",
        "err_unknown",
        "err_missing",
        "err_invalid",
        "with_targets",
        "dashdash",
        "long_ok",
        "cluster_ok",
        "value_ok",
        "equiv_checked",
        "equiv_ok",
        "equiv_error",
    });
}
