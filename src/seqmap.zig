//! Mapping between the 16-bit ICMP sequence number and the (target, probe)
//! pair it was sent for, plus the transmit timestamp used for RTT.
//!
//! Sequence numbers are handed out round-robin from a fixed table of 65536
//! slots (same approach as fping's seqmap.c). A slot is freed explicitly by
//! the engine on reply, timeout, or send error, so exhaustion can only occur
//! when more than 65535 probes are genuinely outstanding — the engine's
//! in-flight cap must stay below that.

const std = @import("std");

pub const capacity = 65536;

pub const Entry = struct {
    target: u32,
    probe: u16,
    sent_ns: i64,
    /// Set when the first reply arrives; the slot stays reserved until its
    /// timeout event fires so further replies can be counted as duplicates.
    answered: bool = false,
};

const SeqMap = @This();

slots: []?Entry,
next: u16 = 0,

pub fn init(gpa: std.mem.Allocator) !SeqMap {
    const slots = try gpa.alloc(?Entry, capacity);
    @memset(slots, null);
    return .{ .slots = slots };
}

pub fn deinit(self: *SeqMap, gpa: std.mem.Allocator) void {
    gpa.free(self.slots);
    self.* = undefined;
}

/// Reserve the next sequence number for a probe.
pub fn add(self: *SeqMap, target: u32, probe: u16, sent_ns: i64) error{Exhausted}!u16 {
    const seq = self.next;
    if (self.slots[seq] != null) return error.Exhausted;
    self.slots[seq] = .{ .target = target, .probe = probe, .sent_ns = sent_ns };
    self.next = seq +% 1;
    return seq;
}

/// Look up a sequence number from a received reply. Returns null for
/// sequence numbers we do not currently have outstanding (stale replies
/// or packets that are not ours).
pub fn fetch(self: *const SeqMap, seq: u16) ?Entry {
    return self.slots[seq];
}

/// Mutable lookup (for marking a slot answered).
pub fn fetchPtr(self: *SeqMap, seq: u16) ?*Entry {
    return if (self.slots[seq]) |*e| e else null;
}

/// Release a slot. Idempotent.
pub fn release(self: *SeqMap, seq: u16) void {
    self.slots[seq] = null;
}

/// Release every slot (start of a new probing round).
pub fn clear(self: *SeqMap) void {
    @memset(self.slots, null);
}

test "round-robin add/fetch/release" {
    var map = try SeqMap.init(std.testing.allocator);
    defer map.deinit(std.testing.allocator);

    const s0 = try map.add(10, 0, 1111);
    const s1 = try map.add(11, 3, 2222);
    try std.testing.expectEqual(@as(u16, 0), s0);
    try std.testing.expectEqual(@as(u16, 1), s1);

    const e = map.fetch(s1).?;
    try std.testing.expectEqual(@as(u32, 11), e.target);
    try std.testing.expectEqual(@as(u16, 3), e.probe);
    try std.testing.expectEqual(@as(i64, 2222), e.sent_ns);

    map.release(s0);
    try std.testing.expectEqual(@as(?Entry, null), map.fetch(s0));
    map.release(s0); // idempotent
}

test "exhaustion when slot still occupied after wrap" {
    var map = try SeqMap.init(std.testing.allocator);
    defer map.deinit(std.testing.allocator);

    var i: u32 = 0;
    while (i < capacity) : (i += 1) {
        _ = try map.add(i, 0, 1);
    }
    try std.testing.expectError(error.Exhausted, map.add(99, 0, 2));
    map.release(0);
    const seq = try map.add(99, 0, 3);
    try std.testing.expectEqual(@as(u16, 0), seq);
}

test "clear releases every occupied slot" {
    var map = try SeqMap.init(std.testing.allocator);
    defer map.deinit(std.testing.allocator);

    for (0..5) |i| _ = try map.add(@intCast(i), 0, 1);
    map.clear();
    for (0..5) |i| try std.testing.expectEqual(@as(?Entry, null), map.fetch(@intCast(i)));
    // Nothing is left to collide with once the sequence space wraps.
    map.next = 2;
    _ = try map.add(7, 0, 1);
}

test "init leaves no slot occupied even on dirty memory" {
    // Fresh OS pages are zero (= null); an allocator that hands out
    // occupied-looking slots shows whether init really clears the table.
    // (Debug and ReleaseSafe poison fresh allocations with 0xaa after the
    // allocator returns, which reads as null, so only ReleaseFast/Small can
    // observe a missing clear.)
    const Dirty = struct {
        const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
        child: std.mem.Allocator,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }
        fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const p = self.child.vtable.alloc(self.child.ptr, len, a, ra) orelse return null;
            // Fill with copies of a valid occupied slot: whatever the
            // layout of ?Entry, none of these reads as null.
            const occupied: ?Entry = .{ .target = 1, .probe = 1, .sent_ns = 1 };
            var off: usize = 0;
            while (off + @sizeOf(?Entry) <= len) : (off += @sizeOf(?Entry))
                @memcpy(p[off..][0..@sizeOf(?Entry)], std.mem.asBytes(&occupied));
            return p;
        }
        fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.child.vtable.resize(self.child.ptr, m, a, n, ra);
        }
        fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.child.vtable.remap(self.child.ptr, m, a, n, ra);
        }
        fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.child.vtable.free(self.child.ptr, m, a, ra);
        }
    };
    var dirty: Dirty = .{ .child = std.testing.allocator };
    var map = try SeqMap.init(dirty.allocator());
    defer map.deinit(dirty.allocator());
    for ([_]u16{ 0, 1, 40000, 65535 }) |s| try std.testing.expectEqual(@as(?Entry, null), map.fetch(s));
    try std.testing.expectEqual(@as(?*Entry, null), map.fetchPtr(7));
    _ = try map.add(1, 0, 1);
}

test "fetchPtr hands out the live slot, and an entry is not born answered" {
    var map = try SeqMap.init(std.testing.allocator);
    defer map.deinit(std.testing.allocator);
    const seq = try map.add(4, 2, 99);
    try std.testing.expect(!map.fetch(seq).?.answered);
    try std.testing.expectEqual(@as(i64, 99), map.fetch(seq).?.sent_ns);
    map.fetchPtr(seq).?.answered = true;
    try std.testing.expect(map.fetch(seq).?.answered);
    try std.testing.expectEqual(@as(?*Entry, null), map.fetchPtr(seq +% 1));
    // Sequence numbers advance by exactly one, wrapping at 65536.
    map.next = 65535;
    try std.testing.expectEqual(@as(u16, 65535), try map.add(5, 0, 1));
    try std.testing.expectEqual(@as(u16, 0), map.next);
}
