//! Allocation-failure injection for the option parser: every allocation
//! fails once; parse() must return error.OutOfMemory and leak nothing.

const std = @import("std");
const options = @import("options.zig");

fn parseCase(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var diag: options.Diagnostic = .{};
    var r = options.parse(gpa, args, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return, // usage errors are legal outcomes here
    };
    r.deinit(gpa);
}

test "alloc failure: options.parse" {
    const gpa = std.testing.allocator;
    // Enough targets to force the target list to grow several times.
    const many = [_][]const u8{ "-c", "3", "-p", "100", "-a", "h1", "h2", "h3", "h4", "h5", "h6", "h7", "h8", "h9", "h10", "h11", "h12", "h13", "h14", "h15", "h16", "h17", "h18", "h19", "h20" };
    try std.testing.checkAllAllocationFailures(gpa, parseCase, .{@as([]const []const u8, &many)});
    const none = [_][]const u8{};
    try std.testing.checkAllAllocationFailures(gpa, parseCase, .{@as([]const []const u8, &none)});
}
