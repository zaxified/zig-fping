//! Build-time tool: turns deploy/about.json into the about page of the demo,
//! for a demo hub to show (see README "About page").
//!
//!   about <about.json> <version> <out about.json> <out about.html> <out about-card.html>
//!
//! The card is a bare `<article>` with stable class names and schema.org
//! microdata, no styles and no scripts, for the hub to include and style;
//! about.html is the same card as a standalone page; about.json is the
//! source plus the version, for templating.

const std = @import("std");
const Io = std.Io;

const About = struct {
    id: []const u8,
    title: []const u8,
    tagline: []const u8,
    summary: []const u8,
    features: []const []const u8,
    built_with: []const u8,
    license: []const u8,
    source: []const u8,
    screenshot: []const u8,
    screenshot_alt: []const u8,
    screenshot_width: u32,
    screenshot_height: u32,
    version: []const u8 = "",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 6) return error.Usage;

    const source = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 16));
    var about = try std.json.parseFromSliceLeaky(About, arena, source, .{});
    if (about.version.len != 0) return error.VersionComesFromBuildZigZon;
    about.version = args[2];

    var json: Io.Writer.Allocating = .init(arena);
    try json.writer.print("{f}\n", .{std.json.fmt(about, .{ .whitespace = .indent_2 })});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = json.written() });

    var card: Io.Writer.Allocating = .init(arena);
    try writeCard(&card.writer, about);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[5], .data = card.written() });

    var page: Io.Writer.Allocating = .init(arena);
    try writePage(&page.writer, about, card.written());
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[4], .data = page.written() });
}

fn writeCard(w: *Io.Writer, a: About) Io.Writer.Error!void {
    try w.print(
        \\<!-- {[title]f} {[version]f} about card, generated from deploy/about.json.
        \\     No styles, no scripts: the page that includes it styles the classes. -->
        \\<article class="demo" id="demo-{[id]f}" data-demo="{[id]f}" data-version="{[version]f}" itemscope itemtype="https://schema.org/SoftwareApplication">
        \\  <header class="demo-header">
        \\    <h2 class="demo-title" itemprop="name">{[title]f}</h2>
        \\    <p class="demo-tagline">{[tagline]f}</p>
        \\  </header>
        \\  <figure class="demo-screenshot">
        \\    <img src="{[screenshot]f}" alt="{[alt]f}" width="{[width]d}" height="{[height]d}" loading="lazy" itemprop="screenshot">
        \\  </figure>
        \\  <p class="demo-summary" itemprop="description">{[summary]f}</p>
        \\  <ul class="demo-features">
        \\
    , .{
        .title = esc(a.title),
        .version = esc(a.version),
        .id = esc(a.id),
        .tagline = esc(a.tagline),
        .screenshot = esc(a.screenshot),
        .alt = esc(a.screenshot_alt),
        .width = a.screenshot_width,
        .height = a.screenshot_height,
        .summary = esc(a.summary),
    });
    for (a.features) |f| try w.print("    <li>{f}</li>\n", .{esc(f)});
    try w.print(
        \\  </ul>
        \\  <dl class="demo-facts">
        \\    <dt>Version</dt><dd itemprop="softwareVersion">{[version]f}</dd>
        \\    <dt>Built with</dt><dd>{[built_with]f}</dd>
        \\    <dt>License</dt><dd itemprop="license">{[license]f}</dd>
        \\    <dt>Source</dt><dd><a class="demo-source" href="{[source]f}" itemprop="url">{[source]f}</a></dd>
        \\  </dl>
        \\  <meta itemprop="applicationCategory" content="Network monitoring">
        \\  <meta itemprop="operatingSystem" content="Linux">
        \\</article>
        \\
    , .{
        .version = esc(a.version),
        .built_with = esc(a.built_with),
        .license = esc(a.license),
        .source = esc(a.source),
    });
}

fn writePage(w: *Io.Writer, a: About, card: []const u8) Io.Writer.Error!void {
    try w.print(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>About {[title]f}</title>
        \\<meta name="description" content="{[tagline]f}">
        \\<style>
        \\:root {{ color-scheme: light dark; --fg: #1b1f24; --muted: #59636e; --line: #d8dee4; --bg: #f6f8fa; --card: #fff; --accent: #2f80ed; }}
        \\@media (prefers-color-scheme: dark) {{ :root {{ --fg: #e6edf3; --muted: #9198a1; --line: #30363d; --bg: #0d1117; --card: #161b22; --accent: #58a6ff; }} }}
        \\body {{ margin: 0; padding: 2rem 1rem; background: var(--bg); color: var(--fg); font: 16px/1.5 system-ui, sans-serif; }}
        \\.demo {{ max-width: 46rem; margin: 0 auto; padding: 1.5rem; background: var(--card); border: 1px solid var(--line); border-radius: 12px; }}
        \\.demo-title {{ margin: 0; font-size: 1.6rem; }}
        \\.demo-tagline {{ margin: .25rem 0 1rem; color: var(--muted); }}
        \\.demo-screenshot {{ margin: 0 0 1rem; }}
        \\.demo-screenshot img {{ display: block; width: 100%; height: auto; border: 1px solid var(--line); border-radius: 8px; }}
        \\.demo-features {{ padding-left: 1.2rem; }}
        \\.demo-facts {{ display: grid; grid-template-columns: max-content 1fr; gap: .25rem 1rem; margin: 1rem 0 0; }}
        \\.demo-facts dt {{ color: var(--muted); }}
        \\.demo-facts dd {{ margin: 0; overflow-wrap: anywhere; }}
        \\a {{ color: var(--accent); }}
        \\</style>
        \\</head>
        \\<body>
        \\
    , .{ .title = esc(a.title), .tagline = esc(a.tagline) });
    try w.writeAll(card);
    try w.writeAll("</body>\n</html>\n");
}

/// HTML-escapes text for element content and quoted attribute values.
fn esc(s: []const u8) Escaped {
    return .{ .s = s };
}

const Escaped = struct {
    s: []const u8,

    pub fn format(e: Escaped, w: *Io.Writer) Io.Writer.Error!void {
        for (e.s) |c| switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeByte(c),
        };
    }
};

test "escaping" {
    var buf: [64]u8 = undefined;
    const out = try std.mem.print(&buf, "{f}", .{esc("<a href=\"x\">&'")});
    try std.testing.expectEqualStrings("&lt;a href=&quot;x&quot;&gt;&amp;&#39;", out);
}
