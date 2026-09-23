// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! APU stolen memory is already excluded from the host PMM. This owner only
//! partitions that existing extent; it never contributes physical RAM pages.
const std = @import("std");
const boot = @import("boot.zig");
const bios = @import("bios.zig");
pub const page: u64 = 4096;
pub const address_limit: u64 = @as(u64, 1) << 48;
pub const gart_bytes: u64 = 1024 * 1024 * 1024;
pub const table_bytes: u64 = gart_bytes / page * 8;
// VMID1 covers the complete native 2 GB aperture plus retained display maps.
// Directory pages remain owned until both hubs are quiescent; include scratch.
pub const context_bytes: u64 = 8 * 1024 * 1024;
pub const Error = error{ Invalid, Overflow, Capacity, Busy, Stale, Sparse, Unsupported };
pub const Span = struct {
    offset: u64 = 0, bytes: u64 = 0,
    pub fn end(self: Span) u64 { return self.offset + self.bytes; }
    pub fn overlaps(self: Span, other: Span) bool { return self.bytes != 0 and other.bytes != 0 and self.offset < other.end() and other.offset < self.end(); }
    pub fn contains(self: Span, value: Span) bool { return value.bytes != 0 and value.offset >= self.offset and value.offset - self.offset < self.bytes and value.bytes <= self.bytes - (value.offset - self.offset); }
};
pub fn aligned(value: u64, alignment: u64) Error!u64 {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.Invalid;
    return (std.math.add(u64, value, alignment - 1) catch return error.Overflow) & ~(alignment - 1);
}
pub fn checked(offset: u64, bytes: u64, limit: u64) Error!Span {
    if (bytes == 0 or offset >= limit or bytes > limit - offset) return error.Invalid;
    return .{ .offset = offset, .bytes = bytes };
}
pub fn pages(offset: u64, bytes: u64, limit: u64) Error!Span {
    if ((offset | bytes) & (page - 1) != 0) return error.Invalid;
    return checked(offset, bytes, limit);
}
pub const Role = enum { firmware, tables, rings, contexts, buffer };
pub const Allocation = struct { serial: u64 = 0, span: Span = .{}, role: Role = .buffer };
/// Serialized by the driver worker. Reserved firmware/boot extents form a
/// union; overlapping declarations cannot create duplicated capacity/charge.
pub const Pool = struct {
    bytes: u64 = 0,
    reserved: [16]Span = @splat(.{}), count: usize = 0,
    allocations: [128]Allocation = @splat(.{}), serial: u64 = 0,
    reserved_bytes: u64 = 0, allocated_bytes: u64 = 0,
    pub fn reserve(self: *Pool, offset: u64, length: u64) Error!void {
        if (self.allocated_bytes != 0) return error.Busy;
        _ = try checked(offset, length, self.bytes);
        var span: Span = .{ .offset = offset & ~(page - 1), .bytes = (try aligned(offset + length, page)) - (offset & ~(page - 1)) };
        if (span.end() > self.bytes) return error.Invalid;
        // Preflight capacity without mutating the owner on rejection.
        var joined: usize = 0;
        for (self.reserved[0..self.count]) |other| if (span.offset <= other.end() and other.offset <= span.end()) { joined += 1; };
        if (joined == 0 and self.count == self.reserved.len) return error.Capacity;
        var i: usize = 0;
        while (i < self.count) {
            const other = self.reserved[i];
            if (span.offset > other.end() or other.offset > span.end()) { i += 1; continue; }
            const last = @max(span.end(), other.end()); span.offset = @min(span.offset, other.offset); span.bytes = last - span.offset;
            self.reserved_bytes -= other.bytes; self.count -= 1; self.reserved[i] = self.reserved[self.count];
            i = 0;
        }
        self.reserved[self.count] = span; self.count += 1; self.reserved_bytes += span.bytes;
    }
    pub fn allocate(self: *Pool, length: u64, alignment: u64, role: Role) Error!Allocation {
        if (length == 0 or alignment == 0 or alignment > gart_bytes or !std.math.isPowerOfTwo(alignment)) return error.Invalid;
        const bytes = try aligned(length, @max(page, alignment));
        if (self.serial == std.math.maxInt(u64)) return error.Overflow;
        var slot: ?*Allocation = null;
        for (&self.allocations) |*entry| if (entry.serial == 0) { slot = entry; break; };
        const target = slot orelse return error.Capacity;
        var span: Span = .{ .bytes = bytes };
        while (true) {
            if (span.offset >= self.bytes or bytes > self.bytes - span.offset) return error.Capacity;
            var next = span.offset;
            for (self.reserved[0..self.count]) |other| if (span.overlaps(other)) { next = @max(next, other.end()); };
            for (&self.allocations) |*other| if (other.serial != 0 and span.overlaps(other.span)) { next = @max(next, other.span.end()); };
            if (next == span.offset) break;
            span.offset = try aligned(next, @max(page, alignment));
        }
        self.serial += 1; target.* = .{ .serial = self.serial, .span = span, .role = role }; self.allocated_bytes += bytes;
        return target.*;
    }
    pub fn owns(self: *const Pool, allocation: Allocation) bool {
        if (allocation.serial == 0) return false;
        for (&self.allocations) |*entry| if (std.meta.eql(entry.*, allocation)) return true;
        return false;
    }
    /// Caller must first retire canonical references/maps/fences and remove
    /// GPU translations. A pool ticket alone is not a hardware quiescence proof.
    pub fn release(self: *Pool, allocation: Allocation) Error!void {
        if (allocation.serial == 0) return error.Stale;
        for (&self.allocations) |*entry| if (std.meta.eql(entry.*, allocation)) {
            self.allocated_bytes -= entry.span.bytes; entry.* = .{}; return;
        };
        return error.Stale;
    }
};
pub const Layout = struct {
    profile: @import("asic_profile.zig").Profile,
    physical: Span, mc: Span, gart: Span,
    pool: Pool,
    firmware: Allocation, tables: Allocation, rings: Allocation, contexts: Allocation, render: Allocation, media: Allocation,
    native_budget: u64,
    pub fn create(profile: @import("asic_profile.zig").Profile, uma: boot.Range, mc: boot.Range, boot_offset: u64, boot_bytes: u64, firmware: ?bios.Reservation) Error!Layout {
        const physical = try pages(uma.base, uma.bytes, address_limit);
        if (physical.offset == 0) return error.Invalid;
        const gpu = try pages(mc.base, mc.bytes, address_limit);
        if (gpu.bytes < physical.bytes) return error.Invalid;
        var pool: Pool = .{ .bytes = physical.bytes };
        // APU ROM shadow / legacy VGA data remains private to firmware.
        try pool.reserve(0, 256 * 1024);
        try pool.reserve(boot_offset, boot_bytes);
        if (firmware) |fw| {
            if (fw.bytes != 0) try pool.reserve(fw.offset, fw.bytes);
            // v2.1 used_by_driver_in_kb requests CPU scratch for an ATOM
            // interpreter; it does not describe VRAM preceding the FW range.
            // Panel/HDMI ATOM runtimes own their separate CPU heap scratch.
        }
        // Explicit independent work arenas. IP start owns their contents and
        // may subdivide these bounds; resizing requires a new memory epoch.
        const fw = try pool.allocate(16 * 1024 * 1024, 1024 * 1024, .firmware);
        const tables = try pool.allocate(table_bytes, page, .tables);
        const rings = try pool.allocate(1024 * 1024, 64 * 1024, .rings);
        const contexts = try pool.allocate(context_bytes, 64 * 1024, .contexts);
        // Immutable shaders plus eight independent 4 KB descriptor/push slots.
        // Contexts above are page tables and must never contain shader data.
        const render = try pool.allocate(64 * 1024, 64 * 1024, .contexts);
        const media = try pool.allocate(1024 * 1024, 64 * 1024, .contexts);
        // VMID0's flat 1 GB GART is distinct from the MC aperture. Choose the
        // first complete aligned gap, without interpreting a CPU pointer as VA.
        const gart_base = if (gpu.offset >= gart_bytes) @as(u64, 0) else try aligned(gpu.end(), gart_bytes);
        const gart = try pages(gart_base, gart_bytes, address_limit);
        if (gart.overlaps(gpu)) return error.Invalid;
        _ = try profile.apertureHigh(gpu.offset + physical.bytes);
        return .{ .profile = profile, .physical = physical, .mc = .{ .offset = gpu.offset, .bytes = physical.bytes }, .gart = gart,
            .pool = pool, .firmware = fw, .tables = tables, .rings = rings, .contexts = contexts, .render = render, .media = media,
            .native_budget = pool.bytes - pool.reserved_bytes - pool.allocated_bytes };
    }
    pub fn physicalAddress(self: *const Layout, span: Span) Error!u64 {
        _ = try pages(span.offset, span.bytes, self.physical.bytes); return self.physical.offset + span.offset;
    }
    pub fn mcAddress(self: *const Layout, span: Span) Error!u64 {
        _ = try pages(span.offset, span.bytes, self.mc.bytes); return self.mc.offset + span.offset;
    }
};
