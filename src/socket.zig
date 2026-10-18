//! Non-blocking ICMP sockets for IPv4/IPv6 on Linux.
//!
//! Tries an unprivileged SOCK_DGRAM ICMP socket first (requires
//! net.ipv4.ping_group_range to cover the process group), then falls back to
//! SOCK_RAW (requires CAP_NET_RAW or root) — configurable via `Mode`.
//!
//! Replies are read with recvmsg so ancillary data can be captured:
//! SO_TIMESTAMPNS kernel receive timestamps (accurate RTT under load),
//! TTL/hop limit and TOS/traffic class (fping --print-ttl/--print-tos),
//! and the source address (fping --check-source).

const std = @import("std");
const linux = std.os.linux;

pub const Mode = enum {
    /// Prefer unprivileged DGRAM, fall back to RAW.
    auto,
    dgram,
    raw,
};

pub const Kind = enum { dgram, raw };
pub const Family = enum { v4, v6 };

pub const OpenError = error{
    /// Neither DGRAM (ping_group_range) nor RAW (CAP_NET_RAW) is available.
    PermissionDenied,
    AddressFamilyUnsupported,
    /// Source address bind failed (fping -S).
    SourceAddressBind,
    /// SO_BINDTODEVICE failed (fping -I); requires CAP_NET_RAW.
    InterfaceBind,
    Unexpected,
};

pub const SendError = error{
    WouldBlock,
    NetworkUnreachable,
    HostUnreachable,
    PermissionDenied,
    MessageTooLong,
    Unexpected,
};

/// Socket-level options applied at open time. All optional; mirrors the
/// fping probing options that map to setsockopt calls.
/// How a RAW socket picks its ICMP echo identifier. DGRAM sockets always use
/// the kernel-assigned one, which is unique per socket.
pub const RawIdent = union(enum) {
    /// `pid & 0xffff`, as fping does (the default, so the CLI matches fping).
    pid,
    /// Distinct for every socket this process opens: a random base drawn once
    /// per process plus a counter. Library improvement over fping: several
    /// Pinger instances in one process (or several processes) running RAW
    /// sockets would otherwise share the pid ident and could take each
    /// other's replies.
    unique,
    /// A caller-chosen identifier.
    fixed: u16,
};

pub const Options = struct {
    recv_buf_size: u32 = 1 << 20,
    /// Echo identifier of a RAW socket (ignored for DGRAM sockets).
    raw_ident: RawIdent = .pid,
    /// IP TTL / IPv6 unicast hops (fping -H).
    ttl: ?u8 = null,
    /// IP TOS / IPv6 traffic class (fping -O).
    tos: ?u8 = null,
    /// Set the Don't Fragment flag (fping -M).
    dont_fragment: bool = false,
    /// Routing mark (fping -k/--fwmark); requires CAP_NET_ADMIN.
    fwmark: ?u32 = null,
    /// Bind to a specific interface (fping -I); requires CAP_NET_RAW.
    iface: ?[]const u8 = null,
    /// Send probes via a specific outgoing interface while receiving from
    /// any (fping --oiface): every send carries an IP_PKTINFO/IPV6_PKTINFO
    /// control message with this interface index.
    oiface_index: ?u32 = null,
    /// Source address to bind (fping -S). Must match the socket family.
    source: ?union(Family) {
        v4: linux.sockaddr.in,
        v6: linux.sockaddr.in6,
    } = null,
};

/// Ancillary information captured for one received packet.
pub const RecvInfo = struct {
    packet: []u8,
    /// Kernel receive timestamp, CLOCK_REALTIME ns (SO_TIMESTAMPNS).
    timestamp_real_ns: ?i64 = null,
    /// Received TTL (v4) or hop limit (v6).
    ttl: ?u8 = null,
    /// Received TOS (v4) or traffic class (v6).
    tos: ?u8 = null,
    /// Source address of the packet (sockaddr bytes, family-specific).
    src: SrcAddr = .none,

    pub const SrcAddr = union(enum) {
        none,
        v4: linux.sockaddr.in,
        v6: linux.sockaddr.in6,
    };
};

const Socket = @This();

fd: i32,
family: Family,
kind: Kind,
/// ICMP echo identifier this socket sends with and accepts replies for
/// (host byte order). For DGRAM sockets the kernel enforces/rewrites it.
ident: u16,
/// Outgoing interface index for --oiface (0 = routing table decides).
oiface_index: u32 = 0,
/// IPv4 source for the pktinfo spec_dst field when both -S and --oiface
/// are used (network byte order; 0 = unset).
pktinfo_src4: u32 = 0,

var unique_base: std.atomic.Value(u32) = .init(0);
var unique_next: std.atomic.Value(u16) = .init(0);

fn rawIdent(mode: RawIdent) u16 {
    return switch (mode) {
        .pid => @intCast(linux.getpid() & 0xffff),
        .fixed => |v| v,
        .unique => uniqueIdent(),
    };
}

/// Random per-process base (bit 16 marks it initialised) plus a counter, so
/// up to 65536 sockets of one process never share an identifier.
fn uniqueIdent() u16 {
    var base = unique_base.load(.acquire);
    if (base == 0) {
        var r: [2]u8 = undefined;
        const rc = linux.getrandom(&r, r.len, 0);
        const rnd: u16 = if (linux.errno(rc) == .SUCCESS and rc == r.len)
            std.mem.readInt(u16, &r, .little)
        else
            @truncate(@as(u32, @bitCast(linux.getpid())));
        const fresh: u32 = @as(u32, 1 << 16) | rnd;
        base = unique_base.cmpxchgStrong(0, fresh, .acq_rel, .acquire) orelse fresh;
    }
    return @as(u16, @truncate(base)) +% unique_next.fetchAdd(1, .monotonic);
}

test "RawIdent: pid matches fping, fixed is verbatim, unique never repeats in-process" {
    try std.testing.expectEqual(@as(u16, @intCast(linux.getpid() & 0xffff)), rawIdent(.pid));
    try std.testing.expectEqual(@as(u16, 0xbeef), rawIdent(.{ .fixed = 0xbeef }));
    var seen: std.StaticBitSet(1 << 16) = .empty;
    for (0..1000) |_| {
        const id = rawIdent(.unique);
        try std.testing.expect(!seen.isSet(id));
        seen.set(id);
    }
}

pub fn open(family: Family, mode: Mode, opts: Options) OpenError!Socket {
    const domain: u32 = switch (family) {
        .v4 => linux.AF.INET,
        .v6 => linux.AF.INET6,
    };
    const proto: u32 = switch (family) {
        .v4 => linux.IPPROTO.ICMP,
        .v6 => linux.IPPROTO.ICMPV6,
    };
    const flags: u32 = linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;

    var kind: Kind = undefined;
    var fd: i32 = -1;

    if (mode == .auto or mode == .dgram) {
        const rc = linux.socket(domain, linux.SOCK.DGRAM | flags, proto);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                fd = @intCast(rc);
                kind = .dgram;
            },
            .ACCES, .PERM, .AFNOSUPPORT, .PROTONOSUPPORT, .INVAL => {},
            else => return error.Unexpected,
        }
    }
    if (fd < 0 and (mode == .auto or mode == .raw)) {
        const rc = linux.socket(domain, linux.SOCK.RAW | flags, proto);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                fd = @intCast(rc);
                kind = .raw;
            },
            .ACCES, .PERM => return error.PermissionDenied,
            .AFNOSUPPORT, .PROTONOSUPPORT => return error.AddressFamilyUnsupported,
            else => return error.Unexpected,
        }
    }
    if (fd < 0) return error.PermissionDenied;
    errdefer _ = linux.close(fd);

    var self: Socket = .{ .fd = fd, .family = family, .kind = kind, .ident = 0 };

    // A large receive buffer absorbs reply bursts when thousands of probes
    // are in flight; losing replies inflates false loss.
    if (opts.recv_buf_size > 0)
        setOptInt(fd, linux.SOL.SOCKET, linux.SO.RCVBUF, opts.recv_buf_size);

    // Kernel receive timestamps; optional (older kernels), errors ignored —
    // the engine falls back to userspace timing.
    setOptInt(fd, linux.SOL.SOCKET, linux.SO.TIMESTAMPNS_OLD, 1);

    switch (family) {
        .v4 => {
            setOptInt(fd, linux.SOL.IP, linux.IP.RECVTTL, 1);
            setOptInt(fd, linux.SOL.IP, linux.IP.RECVTOS, 1);
            if (opts.ttl) |v| setOptInt(fd, linux.SOL.IP, linux.IP.TTL, @as(u32, v));
            if (opts.tos) |v| setOptInt(fd, linux.SOL.IP, linux.IP.TOS, @as(u32, v));
            if (opts.dont_fragment)
                setOptInt(fd, linux.SOL.IP, linux.IP.MTU_DISCOVER, linux.IP.PMTUDISC_DO);
        },
        .v6 => {
            setOptInt(fd, linux.SOL.IPV6, linux.IPV6.RECVHOPLIMIT, 1);
            setOptInt(fd, linux.SOL.IPV6, linux.IPV6.RECVTCLASS, 1);
            if (opts.ttl) |v| setOptInt(fd, linux.SOL.IPV6, linux.IPV6.UNICAST_HOPS, @as(u32, v));
            if (opts.tos) |v| setOptInt(fd, linux.SOL.IPV6, linux.IPV6.TCLASS, @as(u32, v));
            if (opts.dont_fragment)
                setOptInt(fd, linux.SOL.IPV6, linux.IPV6.MTU_DISCOVER, linux.IPV6.PMTUDISC_DO);
        },
    }

    if (opts.fwmark) |mark| setOptInt(fd, linux.SOL.SOCKET, linux.SO.MARK, mark);

    if (opts.iface) |name| {
        const rc = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.BINDTODEVICE, name.ptr, @intCast(name.len));
        if (linux.errno(rc) != .SUCCESS) return error.InterfaceBind;
    }

    if (opts.oiface_index) |idx| self.oiface_index = idx;

    if (opts.source) |src| {
        const ok = switch (src) {
            .v4 => |sa| family == .v4 and bindAddr(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)),
            .v6 => |sa| family == .v6 and bindAddr(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in6)),
        };
        if (!ok) return error.SourceAddressBind;
        if (src == .v4) self.pktinfo_src4 = src.v4.addr;
        if (kind == .dgram) self.ident = try self.boundIdent();
    } else if (kind == .dgram) {
        // Bind to the wildcard to learn the kernel-assigned echo identifier
        // ("port").
        try self.bindWildcard();
        self.ident = try self.boundIdent();
    }

    if (kind == .raw) self.ident = rawIdent(opts.raw_ident);

    return self;
}

pub fn close(self: *Socket) void {
    _ = linux.close(self.fd);
    self.* = undefined;
}

fn setOptInt(fd: i32, level: i32, opt: u32, value: u32) void {
    const v: u32 = value;
    _ = linux.setsockopt(fd, level, opt, @ptrCast(&v), @sizeOf(u32));
}

fn bindAddr(fd: i32, addr: *const linux.sockaddr, len: linux.socklen_t) bool {
    return linux.errno(linux.bind(fd, addr, len)) == .SUCCESS;
}

fn bindWildcard(self: *Socket) OpenError!void {
    switch (self.family) {
        .v4 => {
            const sa: linux.sockaddr.in = .{ .port = 0, .addr = 0 };
            if (!bindAddr(self.fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) return error.Unexpected;
        },
        .v6 => {
            const sa: linux.sockaddr.in6 = .{ .port = 0, .flowinfo = 0, .addr = @splat(0), .scope_id = 0 };
            if (!bindAddr(self.fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in6))) return error.Unexpected;
        },
    }
}

fn boundIdent(self: *Socket) OpenError!u16 {
    var storage: [@sizeOf(linux.sockaddr.in6)]u8 align(8) = @splat(0);
    var len: linux.socklen_t = storage.len;
    const rc = linux.getsockname(self.fd, @ptrCast(&storage), &len);
    if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
    // sockaddr.in and sockaddr.in6 both store the port (= echo ident for
    // ping sockets) big-endian at offset 2.
    return std.mem.readInt(u16, storage[2..4], .big);
}

pub fn sendTo(self: *const Socket, addr: *const linux.sockaddr, addr_len: linux.socklen_t, packet: []const u8) SendError!void {
    const rc = if (self.oiface_index != 0)
        self.sendmsgPktinfo(addr, addr_len, packet)
    else
        linux.sendto(self.fd, packet.ptr, packet.len, linux.MSG.NOSIGNAL, addr, addr_len);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .AGAIN, .NOBUFS => return error.WouldBlock,
        .NETUNREACH, .NETDOWN => return error.NetworkUnreachable,
        .HOSTUNREACH, .HOSTDOWN => return error.HostUnreachable,
        .ACCES, .PERM => return error.PermissionDenied,
        .MSGSIZE => return error.MessageTooLong,
        else => return error.Unexpected,
    }
}

/// Build the IP_PKTINFO / IPV6_PKTINFO control message forcing the
/// outgoing interface (fping --oiface, see socket_sendto_ping_ipv4 in
/// socket4.c). Returns the control length to pass in msghdr.
fn buildPktinfo(self: *const Socket, control: *align(@alignOf(linux.cmsghdr)) [64]u8) usize {
    const hdr_len = @sizeOf(linux.cmsghdr);
    const cmsg: *linux.cmsghdr = @ptrCast(control);
    switch (self.family) {
        .v4 => {
            const info: linux.in_pktinfo = .{
                .ifindex = @intCast(self.oiface_index),
                .spec_dst = self.pktinfo_src4,
                .addr = 0,
            };
            cmsg.* = .{ .len = hdr_len + @sizeOf(linux.in_pktinfo), .level = linux.SOL.IP, .type = linux.IP.PKTINFO };
            @memcpy(control[hdr_len..][0..@sizeOf(linux.in_pktinfo)], std.mem.asBytes(&info));
        },
        .v6 => {
            const info: linux.in6_pktinfo = .{
                .addr = @splat(0),
                .ifindex = @intCast(self.oiface_index),
            };
            cmsg.* = .{ .len = hdr_len + @sizeOf(linux.in6_pktinfo), .level = linux.SOL.IPV6, .type = linux.IPV6.PKTINFO };
            @memcpy(control[hdr_len..][0..@sizeOf(linux.in6_pktinfo)], std.mem.asBytes(&info));
        },
    }
    return std.mem.alignForward(usize, cmsg.len, @alignOf(linux.cmsghdr));
}

fn sendmsgPktinfo(self: *const Socket, addr: *const linux.sockaddr, addr_len: linux.socklen_t, packet: []const u8) usize {
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
    const control_len = self.buildPktinfo(&control);

    var iov = [_]std.posix.iovec_const{.{ .base = packet.ptr, .len = packet.len }};
    const msg: linux.msghdr_const = .{
        .name = addr,
        .namelen = addr_len,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = control_len,
        .flags = 0,
    };
    return linux.sendmsg(self.fd, &msg, linux.MSG.NOSIGNAL);
}

/// Messages exchanged per sendmmsg/recvmmsg syscall.
pub const batch_max = 16;

/// Send up to batch_max same-family packets with one sendmmsg call.
/// Returns how many packets the kernel accepted; the caller retries the
/// remainder via sendTo, which reports an accurate per-packet errno
/// (sendmmsg stops at the first failure without saying why).
/// error.TooManyPackets: more than batch_max packets;
/// error.LengthMismatch: `addrs` and `packets` differ in length.
pub fn sendMany(
    self: *const Socket,
    addrs: []const *const linux.sockaddr,
    addr_len: linux.socklen_t,
    packets: []const []const u8,
) error{ TooManyPackets, LengthMismatch }!usize {
    if (packets.len > batch_max) return error.TooManyPackets;
    if (addrs.len != packets.len) return error.LengthMismatch;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
    const control_len: usize = if (self.oiface_index != 0) self.buildPktinfo(&control) else 0;

    var iovs: [batch_max]std.posix.iovec = undefined;
    var msgs: [batch_max]linux.mmsghdr = undefined;
    for (packets, addrs, 0..) |pkt, addr, i| {
        // mmsghdr embeds the mutable msghdr; the kernel never writes
        // through iov/name on the send path, so the casts are safe.
        iovs[i] = .{ .base = @constCast(pkt.ptr), .len = pkt.len };
        msgs[i] = .{
            .hdr = .{
                .name = @constCast(addr),
                .namelen = addr_len,
                .iov = @ptrCast(&iovs[i]),
                .iovlen = 1,
                .control = if (control_len != 0) &control else null,
                .controllen = control_len,
                .flags = 0,
            },
            .len = 0,
        };
    }
    const rc = linux.sendmmsg(self.fd, &msgs, @intCast(packets.len), linux.MSG.NOSIGNAL);
    if (linux.errno(rc) != .SUCCESS) return 0;
    return rc;
}

/// Read one packet with ancillary data; returns null when the socket is
/// drained (EAGAIN) or on transient errors.
pub fn recvMsg(self: *const Socket, buf: []u8) ?RecvInfo {
    var src_storage: [@sizeOf(linux.sockaddr.in6)]u8 align(8) = @splat(0);
    var control: [256]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var iov: std.posix.iovec = .{ .base = buf.ptr, .len = buf.len };
    var msg: linux.msghdr = .{
        .name = @ptrCast(&src_storage),
        .namelen = src_storage.len,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };

    const rc = linux.recvmsg(self.fd, &msg, 0);
    if (linux.errno(rc) != .SUCCESS) return null;

    var info: RecvInfo = .{ .packet = buf[0..rc] };
    info.src = parseSrc(&src_storage, msg.namelen);
    parseControl(control[0..msg.controllen], &info);
    return info;
}

fn parseSrc(storage: *const [@sizeOf(linux.sockaddr.in6)]u8, namelen: linux.socklen_t) RecvInfo.SrcAddr {
    if (namelen < 2) return .none;
    // sa_family is a host-order integer (unlike port/addr), so read it in
    // native byte order: a .little read never matched on big-endian Linux,
    // turning every --check-source source into .none (accepted unchecked).
    const af = std.mem.bytesToValue(u16, storage[0..2]);
    if (af == linux.AF.INET and namelen >= @sizeOf(linux.sockaddr.in)) {
        return .{ .v4 = std.mem.bytesToValue(linux.sockaddr.in, storage[0..@sizeOf(linux.sockaddr.in)]) };
    } else if (af == linux.AF.INET6 and namelen >= @sizeOf(linux.sockaddr.in6)) {
        return .{ .v6 = std.mem.bytesToValue(linux.sockaddr.in6, storage[0..@sizeOf(linux.sockaddr.in6)]) };
    }
    return .none;
}

/// Reusable storage for batched receives: one packet slab of batch_max
/// slots (allocated by the owner) plus per-message scratch headers.
pub const RecvBatch = struct {
    /// batch_max * slot_size bytes.
    slab: []u8,
    slot_size: usize,
    addrs: [batch_max][@sizeOf(linux.sockaddr.in6)]u8 align(8) = undefined,
    controls: [batch_max][256]u8 align(@alignOf(linux.cmsghdr)) = undefined,
    iovs: [batch_max]std.posix.iovec = undefined,
    msgs: [batch_max]linux.mmsghdr = undefined,
    infos: [batch_max]RecvInfo = undefined,
};

/// Read up to batch_max packets with one recvmmsg call. Returns the empty
/// slice when the socket is drained (EAGAIN) or on transient errors; a
/// full slice means more packets may be waiting — call again.
/// error.BufferTooSmall: `b.slab` is shorter than batch_max * b.slot_size.
pub fn recvBatch(self: *const Socket, b: *RecvBatch) error{BufferTooSmall}![]const RecvInfo {
    if (b.slab.len < batch_max * b.slot_size) return error.BufferTooSmall;
    for (0..batch_max) |i| {
        b.iovs[i] = .{ .base = b.slab.ptr + i * b.slot_size, .len = b.slot_size };
        b.msgs[i] = .{
            .hdr = .{
                .name = @ptrCast(&b.addrs[i]),
                .namelen = b.addrs[i].len,
                .iov = @ptrCast(&b.iovs[i]),
                .iovlen = 1,
                .control = &b.controls[i],
                .controllen = b.controls[i].len,
                .flags = 0,
            },
            .len = 0,
        };
    }
    const rc = linux.recvmmsg(self.fd, &b.msgs, batch_max, 0, null);
    if (linux.errno(rc) != .SUCCESS) return b.infos[0..0];
    const n: usize = rc;
    for (b.msgs[0..n], 0..) |*m, i| {
        var info: RecvInfo = .{ .packet = b.slab[i * b.slot_size ..][0..m.len] };
        info.src = parseSrc(&b.addrs[i], m.hdr.namelen);
        parseControl(b.controls[i][0..m.hdr.controllen], &info);
        b.infos[i] = info;
    }
    return b.infos[0..n];
}

/// SO_TIMESTAMPNS_OLD carries the legacy `struct timespec` of two native
/// longs. Not linux.timespec: on riscv32 that is the 64-bit kernel_timespec,
/// which would never fit the 8-byte payload.
const OldTimespec = extern struct { sec: isize, nsec: isize };

/// Walk the cmsg list (manual CMSG_NXTHDR; std has no cmsg iteration
/// helpers as of 0.17).
fn parseControl(control: []const u8, info: *RecvInfo) void {
    const hdr_len = @sizeOf(linux.cmsghdr);
    const cmsg_align = @alignOf(linux.cmsghdr);
    var off: usize = 0;
    while (off + hdr_len <= control.len) {
        const cmsg: *const linux.cmsghdr = @ptrCast(@alignCast(control.ptr + off));
        if (cmsg.len < hdr_len or off + cmsg.len > control.len) break;
        const data = control[off + hdr_len .. off + cmsg.len];

        if (cmsg.level == linux.SOL.SOCKET and cmsg.type == linux.SO.TIMESTAMPNS_OLD) {
            if (data.len >= @sizeOf(OldTimespec)) {
                const ts: *const OldTimespec = @ptrCast(@alignCast(data.ptr));
                info.timestamp_real_ns = @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
            }
        } else if (cmsg.level == linux.SOL.IP and cmsg.type == linux.IP.TTL) {
            // IP_TTL / IPV6_HOPLIMIT / IPV6_TCLASS carry a host-order int;
            // a .little read truncated to 0 on big-endian targets.
            if (data.len >= 4) info.ttl = @truncate(std.mem.bytesToValue(u32, data[0..4]));
        } else if (cmsg.level == linux.SOL.IP and cmsg.type == linux.IP.TOS) {
            if (data.len >= 1) info.tos = data[0];
        } else if (cmsg.level == linux.SOL.IPV6 and cmsg.type == linux.IPV6.HOPLIMIT) {
            if (data.len >= 4) info.ttl = @truncate(std.mem.bytesToValue(u32, data[0..4]));
        } else if (cmsg.level == linux.SOL.IPV6 and cmsg.type == linux.IPV6.TCLASS) {
            if (data.len >= 4) info.tos = @truncate(std.mem.bytesToValue(u32, data[0..4]));
        }

        // CMSG_NXTHDR: advance by len rounded up to cmsghdr alignment.
        off += std.mem.alignForward(usize, cmsg.len, cmsg_align);
    }
}

fn appendCmsg(buf: []align(@alignOf(linux.cmsghdr)) u8, off: *usize, level: i32, typ: i32, data: []const u8) void {
    const hdr_len = @sizeOf(linux.cmsghdr);
    const hdr: linux.cmsghdr = .{ .len = hdr_len + data.len, .level = level, .type = typ };
    @memcpy(buf[off.*..][0..hdr_len], std.mem.asBytes(&hdr));
    @memcpy(buf[off.* + hdr_len ..][0..data.len], data);
    off.* += std.mem.alignForward(usize, hdr_len + data.len, @alignOf(linux.cmsghdr));
}

test "parseControl reads host-order ints and timestamps" {
    // The kernel writes these as native ints; building them with
    // std.mem.toBytes keeps the test meaningful on big-endian targets.
    var buf: [256]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
    var off: usize = 0;
    const ts: OldTimespec = .{ .sec = 12, .nsec = 345 };
    appendCmsg(&buf, &off, linux.SOL.SOCKET, linux.SO.TIMESTAMPNS_OLD, std.mem.asBytes(&ts));
    appendCmsg(&buf, &off, linux.SOL.IP, linux.IP.TTL, &std.mem.toBytes(@as(u32, 61)));
    appendCmsg(&buf, &off, linux.SOL.IP, linux.IP.TOS, &.{0xb8});
    var info: RecvInfo = .{ .packet = &.{} };
    parseControl(buf[0..off], &info);
    try std.testing.expectEqual(@as(?i64, 12 * std.time.ns_per_s + 345), info.timestamp_real_ns);
    try std.testing.expectEqual(@as(?u8, 61), info.ttl);
    try std.testing.expectEqual(@as(?u8, 0xb8), info.tos);

    off = 0;
    appendCmsg(&buf, &off, linux.SOL.IPV6, linux.IPV6.HOPLIMIT, &std.mem.toBytes(@as(u32, 63)));
    appendCmsg(&buf, &off, linux.SOL.IPV6, linux.IPV6.TCLASS, &std.mem.toBytes(@as(u32, 0x20)));
    info = .{ .packet = &.{} };
    parseControl(buf[0..off], &info);
    try std.testing.expectEqual(@as(?u8, 63), info.ttl);
    try std.testing.expectEqual(@as(?u8, 0x20), info.tos);
}

test "parseSrc reads the host-order address family" {
    var storage: [@sizeOf(linux.sockaddr.in6)]u8 align(8) = @splat(0);
    const sa4: linux.sockaddr.in = .{ .port = 0, .addr = std.mem.bytesToValue(u32, &[4]u8{ 192, 0, 2, 7 }) };
    @memcpy(storage[0..@sizeOf(linux.sockaddr.in)], std.mem.asBytes(&sa4));
    const src4 = parseSrc(&storage, @sizeOf(linux.sockaddr.in));
    try std.testing.expectEqual([4]u8{ 192, 0, 2, 7 }, std.mem.toBytes(src4.v4.addr));

    const sa6: linux.sockaddr.in6 = .{ .port = 0, .flowinfo = 0, .addr = .{ 0x20, 0x01, 0x0d, 0xb8 } ++ @as([12]u8, @splat(0)), .scope_id = 0 };
    @memcpy(storage[0..], std.mem.asBytes(&sa6));
    const src6 = parseSrc(&storage, @sizeOf(linux.sockaddr.in6));
    try std.testing.expectEqual(@as(u8, 0xb8), src6.v6.addr[3]);

    try std.testing.expectEqual(RecvInfo.SrcAddr.none, parseSrc(&storage, 1));
}

test "parseSrc rejects an address shorter than its family needs" {
    var storage: [@sizeOf(linux.sockaddr.in6)]u8 align(8) = @splat(0);
    const sa6: linux.sockaddr.in6 = .{ .port = 0, .flowinfo = 0, .addr = @splat(0x11), .scope_id = 0 };
    @memcpy(storage[0..], std.mem.asBytes(&sa6));
    try std.testing.expectEqual(RecvInfo.SrcAddr.none, parseSrc(&storage, @sizeOf(linux.sockaddr.in)));
    try std.testing.expect(parseSrc(&storage, @sizeOf(linux.sockaddr.in6)) == .v6);

    const sa4: linux.sockaddr.in = .{ .port = 0, .addr = 0x01020304 };
    storage = @splat(0);
    @memcpy(storage[0..@sizeOf(linux.sockaddr.in)], std.mem.asBytes(&sa4));
    try std.testing.expectEqual(RecvInfo.SrcAddr.none, parseSrc(&storage, @sizeOf(linux.sockaddr.in) - 1));
    try std.testing.expectEqual(RecvInfo.SrcAddr.none, parseSrc(&storage, 8));
    try std.testing.expect(parseSrc(&storage, @sizeOf(linux.sockaddr.in)) == .v4);
}

test "parseControl stops at a zero-length or overrunning cmsg and accepts an exact fit" {
    var buf: [64]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
    var info: RecvInfo = .{ .packet = &.{} };

    // len == 0: must neither loop forever nor slice backwards.
    parseControl(buf[0..48], &info);
    try std.testing.expectEqual(@as(?u8, null), info.ttl);

    // len beyond the buffer: the message is truncated, nothing is read.
    const hdr: linux.cmsghdr = .{ .len = 100, .level = linux.SOL.IP, .type = linux.IP.TTL };
    @memcpy(buf[0..@sizeOf(linux.cmsghdr)], std.mem.asBytes(&hdr));
    parseControl(buf[0..48], &info);
    try std.testing.expectEqual(@as(?u8, null), info.ttl);

    // A message that ends exactly at the end of the buffer (no trailing
    // alignment padding) is complete.
    buf = @splat(0);
    var off: usize = 0;
    appendCmsg(&buf, &off, linux.SOL.IP, linux.IP.TTL, &std.mem.toBytes(@as(u32, 77)));
    parseControl(buf[0 .. @sizeOf(linux.cmsghdr) + 4], &info);
    try std.testing.expectEqual(@as(?u8, 77), info.ttl);
}
