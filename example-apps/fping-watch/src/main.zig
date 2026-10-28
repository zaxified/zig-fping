//! fping-watch — a small ping monitor built on zig-fping.
//!
//! Pings a handful of targets once a minute and serves a web page with the
//! last 24 hours: status, latency and packet loss per target, plus buttons to
//! add, remove, pause and acknowledge targets. `--read-only` turns the page
//! into a public demo: the server refuses every change, not just the page.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const Monitor = @import("monitor.zig").Monitor;
const StateTag = @import("monitor.zig").StateTag;

const log = std.log.scoped(.web);

const usage =
    \\usage: fping-watch [options]
    \\
    \\  --listen ADDR:PORT   web server address (default 127.0.0.1:8080)
    \\  --targets FILE       target list, JSON (default targets.json)
    \\  --history FILE       keep the 24 h history across restarts (default: memory only)
    \\  --read-only          public demo: refuse every change
    \\  --cycle SECONDS      seconds between probing cycles (default 60)
    \\  --version            print the version and exit
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var listen_text: []const u8 = "127.0.0.1:8080";
    var monitor: Monitor = .{ .gpa = gpa, .io = io, .config_path = "targets.json" };
    defer monitor.deinit();

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--read-only")) {
            monitor.read_only = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            print(io, "fping-watch {s}\n", .{version});
            return;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return fail(io, "");
        if (i + 1 == args.len) return fail(io, "missing value");
        const value = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, arg, "--listen")) {
            listen_text = value;
        } else if (std.mem.eql(u8, arg, "--targets")) {
            monitor.config_path = value;
        } else if (std.mem.eql(u8, arg, "--history")) {
            monitor.history_path = value;
        } else if (std.mem.eql(u8, arg, "--cycle")) {
            monitor.cycle_s = std.fmt.parseInt(u31, value, 10) catch return fail(io, "bad --cycle");
            if (monitor.cycle_s < 5) return fail(io, "--cycle must be at least 5");
        } else return fail(io, "unknown option");
    }

    monitor.loadConfig() catch |err| fatal(io, "cannot load the targets from {s}: {t}", .{ monitor.config_path, err });
    monitor.loadHistory() catch |err| fatal(io, "cannot load the history from {s}: {t} (move it away to start afresh)", .{ monitor.history_path.?, err });

    const address = Io.net.IpAddress.parseLiteral(listen_text) catch return fail(io, "bad --listen");
    var server = address.listen(io, .{ .reuse_address = true }) catch |err|
        fatal(io, "cannot listen on {s}: {t}", .{ listen_text, err });
    defer server.deinit(io);
    log.info("fping-watch {s} listening on http://{s} ({d} targets{s})", .{
        version, listen_text, monitor.targets.items.len, if (monitor.read_only) ", read-only" else "",
    });

    // The probing loop, the reaper and every connection run concurrently;
    // with the default threaded Io each one is its own thread. Requests only
    // read what the probing loop recorded: no viewer ever triggers a ping.
    var connections: Connections = .{};
    var tasks: Io.Group = .init;
    defer tasks.cancel(io);
    try tasks.concurrent(io, probeLoop, .{&monitor});
    try tasks.concurrent(io, Connections.reap, .{ &connections, io });
    while (true) {
        const stream = server.accept(io) catch |err| {
            log.warn("accept: {t}", .{err});
            continue;
        };
        const slot = connections.acquire(io, stream) orelse {
            stream.close(io); // full: drop it rather than queue behind slow clients
            continue;
        };
        tasks.concurrent(io, serve, .{ &monitor, &connections, slot, stream }) catch
            connections.release(io, slot);
    }
}

/// Limits for a server reachable from the internet. Every connection holds
/// a thread, so connections are bounded twice: at most `max_connections` at
/// once (more are closed unanswered), and each one is shut down
/// `connection_deadline_s` after it was accepted, whatever the client does.
/// Without the deadline a client that sends its request a byte at a time,
/// or never, holds its thread forever. Per-client rate limits belong in the
/// reverse proxy, which sees the client addresses.
const max_connections = 256;
const connection_deadline_s = 10;

const Connections = struct {
    mutex: Io.Mutex = .init,
    slots: [max_connections]Slot = @splat(.{}),

    const Slot = struct { stream: ?Io.net.Stream = null, deadline: i64 = 0 };

    fn now(io: Io) i64 {
        return Io.Clock.awake.now(io).toSeconds();
    }

    /// A free slot, now holding `stream`; null when every slot is taken.
    fn acquire(c: *Connections, io: Io, stream: Io.net.Stream) ?usize {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        for (&c.slots, 0..) |*s, i| if (s.stream == null) {
            s.* = .{ .stream = stream, .deadline = now(io) + connection_deadline_s };
            return i;
        };
        return null;
    }

    /// Frees the slot and closes its stream. The slot is cleared first,
    /// under the lock, so `reap` never shuts down a reused descriptor.
    fn release(c: *Connections, io: Io, i: usize) void {
        const stream = blk: {
            c.mutex.lockUncancelable(io);
            defer c.mutex.unlock(io);
            const stream = c.slots[i].stream.?;
            c.slots[i].stream = null;
            break :blk stream;
        };
        stream.close(io);
    }

    /// Once a second, shuts down every connection past its deadline; the
    /// thread serving it then reads end of stream (or fails to write) and
    /// finishes.
    fn reap(c: *Connections, io: Io) Io.Cancelable!void {
        while (true) {
            try io.sleep(.fromSeconds(1), .awake);
            c.mutex.lockUncancelable(io);
            defer c.mutex.unlock(io);
            const t = now(io);
            for (&c.slots) |*s| if (s.stream) |stream| if (t >= s.deadline) {
                stream.shutdown(io, .both) catch {};
                s.deadline = std.math.maxInt(i64);
            };
        }
    }
};

fn fail(io: Io, msg: []const u8) noreturn {
    if (msg.len > 0) eprint(io, "fping-watch: {s}\n", .{msg});
    eprint(io, usage, .{});
    std.process.exit(2);
}

/// A startup error: one readable line (systemd shows it), no stack trace.
fn fatal(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    eprint(io, "fping-watch: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn eprint(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = Io.File.stderr().writer(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

fn print(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

fn probeLoop(monitor: *Monitor) void {
    monitor.loop() catch {}; // canceled at shutdown
}

// ----- HTTP ---------------------------------------------------------------------

const version = @import("build_options").version;

const index_html = @embedFile("web/index.html");
const app_js = @embedFile("web/app.js");
const style_css = @embedFile("web/style.css");
const favicon_svg = @embedFile("web/favicon.svg");

/// Sent with every response. The page loads nothing from other origins and
/// has no inline script, so the policy can be strict.
const security_headers = [_]http.Header{
    .{ .name = "content-security-policy", .value = "default-src 'self'; frame-ancestors 'none'" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "referrer-policy", .value = "no-referrer" },
};

/// One request per connection: a slow or idle client then holds a thread
/// only for one request, and the code stays simple. Put a reverse proxy in
/// front for keep-alive and TLS.
fn serve(monitor: *Monitor, connections: *Connections, slot: usize, stream: Io.net.Stream) void {
    const io = monitor.io;
    defer connections.release(io, slot);
    var recv_buf: [8 * 1024]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buf);
    var writer = stream.writer(io, &send_buf);
    var server: http.Server = .init(&reader.interface, &writer.interface);
    var request = server.receiveHead() catch return;

    var arena_state: std.heap.ArenaAllocator = .init(monitor.gpa);
    defer arena_state.deinit();
    route(monitor, &request, arena_state.allocator()) catch |err|
        log.debug("request failed: {t}", .{err});
}

fn route(monitor: *Monitor, req: *http.Server.Request, arena: std.mem.Allocator) !void {
    const method = req.head.method;
    const path = req.head.target[0 .. std.mem.findScalar(u8, req.head.target, '?') orelse req.head.target.len];

    if (method == .GET or method == .HEAD) {
        if (std.mem.eql(u8, path, "/")) return send(req, .ok, "text/html; charset=utf-8", index_html);
        if (std.mem.eql(u8, path, "/app.js")) return send(req, .ok, "text/javascript", app_js);
        if (std.mem.eql(u8, path, "/style.css")) return send(req, .ok, "text/css", style_css);
        if (std.mem.eql(u8, path, "/favicon.svg")) return send(req, .ok, "image/svg+xml", favicon_svg);
        if (std.mem.eql(u8, path, "/api/state")) return sendState(monitor, req, arena);
        if (std.mem.eql(u8, path, "/healthz")) {
            const h = monitor.health(Io.Clock.real.now(monitor.io).toSeconds());
            return send(req, if (h.ok) .ok else .service_unavailable, "application/json", try arena.print(
                "{{\"ok\":{},\"probing_ok\":{},\"last_cycle\":{d},\"version\":\"{s}\"}}",
                .{ h.ok, h.probing_ok, h.last_cycle, version },
            ));
        }
        return sendError(req, .not_found, "not found");
    }

    if (!std.mem.startsWith(u8, path, "/api/targets")) return sendError(req, .not_found, "not found");
    if (monitor.read_only) return sendError(req, .forbidden, "this is a read-only demo");
    // A cross-site form cannot send a JSON content type without a CORS
    // preflight, which this server never approves: a cheap CSRF guard.
    const content_type = req.head.content_type orelse "";
    if (!std.mem.startsWith(u8, content_type, "application/json"))
        return sendError(req, .unsupported_media_type, "send application/json");

    // POST /api/targets                {"name": ..., "host": ...}
    if (method == .POST and std.mem.eql(u8, path, "/api/targets")) {
        const NewTarget = struct { name: []const u8, host: []const u8 };
        const body = try readBody(req, arena);
        const parsed = std.json.parseFromSliceLeaky(NewTarget, arena, body, .{}) catch
            return sendError(req, .bad_request, "expected {\"name\": ..., \"host\": ...}");
        const id = monitor.add(parsed.name, parsed.host) catch |err| return sendMonitorError(req, err);
        return send(req, .created, "application/json", try arena.print("{{\"id\":{d}}}", .{id}));
    }

    // DELETE /api/targets/ID, POST /api/targets/ID/{pause,resume,ack,unack}
    var parts = std.mem.tokenizeScalar(u8, path["/api/targets".len..], '/');
    const id = std.fmt.parseInt(u32, parts.next() orelse "", 10) catch return sendError(req, .not_found, "not found");
    const verb = parts.next();
    if (parts.next() != null) return sendError(req, .not_found, "not found");
    if (method == .DELETE and verb == null) {
        monitor.remove(id) catch |err| return sendMonitorError(req, err);
    } else if (method == .POST and verb != null) {
        const action = std.meta.stringToEnum(enum { pause, @"resume", ack, unack }, verb.?) orelse
            return sendError(req, .not_found, "not found");
        monitor.apply(id, switch (action) {
            .pause => .pause,
            .@"resume" => .resume_,
            .ack => .ack,
            .unack => .unack,
        }) catch |err| return sendMonitorError(req, err);
    } else return sendError(req, .method_not_allowed, "method not allowed");
    return send(req, .ok, "application/json", "{}");
}

fn readBody(req: *http.Server.Request, arena: std.mem.Allocator) ![]u8 {
    var buf: [1024]u8 = undefined;
    const reader = try req.readerExpectContinue(&buf);
    return reader.allocRemaining(arena, .limited(4096));
}

/// GET /api/state. The page polls more often than a cycle runs; the ETag
/// lets a poll that finds nothing new end as `304 Not Modified`, no body.
fn sendState(monitor: *Monitor, req: *http.Server.Request, arena: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    const current = etagOf(&buf, monitor.stateTag());
    if (ifNoneMatch(req, current))
        return respond(req, "", .{ .status = .not_modified, .cache_control = "no-cache", .etag = current });
    const state = try monitor.stateJson(arena);
    return respond(req, state.json, .{
        .content_type = "application/json",
        .cache_control = "no-cache",
        .etag = etagOf(&buf, state.tag),
    });
}

fn etagOf(buf: *[64]u8, tag: StateTag) []const u8 {
    return std.mem.print(buf, "\"{d}-{d}\"", .{ tag.version, tag.end }) catch unreachable;
}

/// Whether an If-None-Match header lists `etag`. Also accepted: the weak
/// form and a suffix after the tag (`"1-2-gzip"`), as a compressing proxy
/// may rewrite the ETag it passes on.
fn ifNoneMatch(req: *const http.Server.Request, etag: []const u8) bool {
    const bare = etag[1 .. etag.len - 1];
    var headers = req.iterateHeaders();
    while (headers.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "if-none-match")) continue;
        var tags = std.mem.tokenizeAny(u8, h.value, ", ");
        while (tags.next()) |raw| {
            const t = std.mem.trim(u8, if (std.mem.startsWith(u8, raw, "W/")) raw[2..] else raw, "\"");
            if (std.mem.eql(u8, t, bare)) return true;
            if (std.mem.startsWith(u8, t, bare) and t[bare.len] == '-') return true;
        }
    }
    return false;
}

const Response = struct {
    status: http.Status = .ok,
    content_type: ?[]const u8 = null,
    cache_control: []const u8 = "no-store",
    etag: ?[]const u8 = null,
};

fn respond(req: *http.Server.Request, body: []const u8, r: Response) !void {
    var headers: [security_headers.len + 3]http.Header = undefined;
    @memcpy(headers[0..security_headers.len], &security_headers);
    var n: usize = security_headers.len;
    headers[n] = .{ .name = "cache-control", .value = r.cache_control };
    n += 1;
    if (r.content_type) |v| {
        headers[n] = .{ .name = "content-type", .value = v };
        n += 1;
    }
    if (r.etag) |v| {
        headers[n] = .{ .name = "etag", .value = v };
        n += 1;
    }
    try req.respond(body, .{
        .status = r.status,
        .keep_alive = false,
        // A 304 must not claim a content length of 0.
        .transfer_encoding = if (r.status == .not_modified) .none else null,
        .extra_headers = headers[0..n],
    });
}

fn send(req: *http.Server.Request, status: http.Status, content_type: []const u8, body: []const u8) !void {
    return respond(req, body, .{ .status = status, .content_type = content_type });
}

fn sendError(req: *http.Server.Request, status: http.Status, msg: []const u8) !void {
    var buf: [256]u8 = undefined;
    const body = std.mem.print(&buf, "{{\"error\":{f}}}", .{std.json.fmt(msg, .{})}) catch unreachable;
    return send(req, status, "application/json", body);
}

fn sendMonitorError(req: *http.Server.Request, err: anyerror) !void {
    return switch (err) {
        error.UnknownTarget => sendError(req, .not_found, "no such target"),
        error.InvalidName => sendError(req, .bad_request, "name: 1-64 printable characters"),
        error.InvalidHost => sendError(req, .bad_request, "host: an IP address or a DNS name"),
        error.TooManyTargets => sendError(req, .conflict, "too many targets"),
        error.NotDown => sendError(req, .conflict, "only a DOWN target can be acknowledged"),
        else => err,
    };
}

test {
    _ = @import("monitor.zig");
}
