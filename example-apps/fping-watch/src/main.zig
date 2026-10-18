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

const log = std.log.scoped(.web);

const usage =
    \\usage: fping-watch [options]
    \\
    \\  --listen ADDR:PORT   web server address (default 127.0.0.1:8080)
    \\  --targets FILE       target list, JSON (default targets.json)
    \\  --history FILE       keep the 24 h history across restarts (default: memory only)
    \\  --read-only          public demo: refuse every change
    \\  --cycle SECONDS      seconds between probing cycles (default 60)
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

    try monitor.loadConfig();
    try monitor.loadHistory();

    const address = Io.net.IpAddress.parseLiteral(listen_text) catch return fail(io, "bad --listen");
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    log.info("listening on http://{s} ({d} targets{s})", .{
        listen_text, monitor.targets.items.len, if (monitor.read_only) ", read-only" else "",
    });

    // The probing loop and every connection run concurrently; with the
    // default threaded Io each one is its own thread.
    var tasks: Io.Group = .init;
    defer tasks.cancel(io);
    try tasks.concurrent(io, probeLoop, .{&monitor});
    while (true) {
        const stream = server.accept(io) catch |err| {
            log.warn("accept: {t}", .{err});
            continue;
        };
        tasks.concurrent(io, serve, .{ &monitor, stream }) catch serve(&monitor, stream);
    }
}

fn fail(io: Io, msg: []const u8) error{InvalidArguments} {
    var buf: [1024]u8 = undefined;
    var w = Io.File.stderr().writer(io, &buf);
    if (msg.len > 0) w.interface.print("fping-watch: {s}\n", .{msg}) catch {};
    w.interface.writeAll(usage) catch {};
    w.interface.flush() catch {};
    return error.InvalidArguments;
}

fn probeLoop(monitor: *Monitor) void {
    monitor.loop() catch {}; // canceled at shutdown
}

// ----- HTTP ---------------------------------------------------------------------

const index_html = @embedFile("web/index.html");
const app_js = @embedFile("web/app.js");
const style_css = @embedFile("web/style.css");

/// Sent with every response. The page loads nothing from other origins and
/// has no inline script, so the policy can be strict.
const security_headers = [_]http.Header{
    .{ .name = "content-security-policy", .value = "default-src 'self'; frame-ancestors 'none'" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "referrer-policy", .value = "no-referrer" },
    .{ .name = "cache-control", .value = "no-store" },
};

/// One request per connection: a slow or idle client then holds a thread
/// only for one request, and the code stays simple. Put a reverse proxy in
/// front for keep-alive, TLS and timeouts.
fn serve(monitor: *Monitor, stream: Io.net.Stream) void {
    const io = monitor.io;
    defer stream.close(io);
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
        if (std.mem.eql(u8, path, "/api/state")) {
            var aw: Io.Writer.Allocating = .init(arena);
            try monitor.writeState(&aw.writer);
            return send(req, .ok, "application/json", aw.written());
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

fn send(req: *http.Server.Request, status: http.Status, content_type: []const u8, body: []const u8) !void {
    var headers: [security_headers.len + 1]http.Header = undefined;
    headers[0] = .{ .name = "content-type", .value = content_type };
    @memcpy(headers[1..], &security_headers);
    try req.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &headers });
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
