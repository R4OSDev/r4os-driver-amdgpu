// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! GMC9 (non translate-further): 4 KB PTEs, 48-bit physical addresses.
//! Original format/flags: amdgpu_vm.h, gmc_v9_0.c and amdgpu_vm.c.
const std = @import("std");
const layout = @import("memory_layout.zig");
pub const Error = layout.Error;
pub const physical_mask: u64 = 0x0000fffffffff000;
pub const Attributes = struct { system: bool, write: bool = false, execute: bool = false };
pub fn pte(address: u64, attributes: Attributes) Error!u64 {
    if (address == 0 or address & ~physical_mask != 0) return error.Invalid;
    // CPU-WB system pages are snooped; UMA CPU access uses WC. MTYPE_UC
    // avoids silently assuming coherent GPU L2 access in either domain.
    return address | 1 | (if (attributes.system) @as(u64, 6) else 0) | 32 |
        (if (attributes.write) @as(u64, 64) else 0) | (if (attributes.execute) @as(u64, 16) else 0) | (@as(u64, 3) << 57);
}
pub fn pde(physical: u64, system: bool) Error!u64 {
    if (physical == 0 or physical & ~physical_mask != 0) return error.Invalid;
    // PDEs point to GPU-physical memory, never the MC alias. No leaf/TF bit.
    return physical | 1 | (if (system) @as(u64, 6) else 0);
}
pub const Flat = struct {
    entries: []volatile u64, aperture: layout.Span, mapped_pages: usize = 0,
    pub fn init(entries: []volatile u64, aperture: layout.Span) Error!Flat {
        _ = try layout.pages(aperture.offset, aperture.bytes, layout.address_limit);
        if (entries.len != aperture.bytes / 4096 or @intFromPtr(entries.ptr) & 4095 != 0) return error.Invalid;
        for (entries) |*entry| entry.* = 0;
        return .{ .entries = entries, .aperture = aperture };
    }
    fn index(self: *const Flat, address: u64, count: usize) Error!usize {
        const bytes = std.math.mul(u64, count, 4096) catch return error.Overflow;
        if (address & 4095 != 0 or !self.aperture.contains(.{ .offset = address, .bytes = bytes })) return error.Invalid;
        return @intCast((address - self.aperture.offset) / 4096);
    }
    pub fn map(self: *Flat, address: u64, physical: []const u64, attributes: Attributes) Error!void {
        const start = try self.index(address, physical.len);
        // Validate the whole mapping before publishing any PTE. A zero page
        // is a sparse hole, never substituted with a dummy physical page.
        for (physical, 0..) |value, i| {
            if (value == 0) return error.Sparse;
            _ = try pte(value, attributes);
            if (self.entries[start + i] != 0) return error.Busy;
        }
        for (physical, 0..) |value, i| self.entries[start + i] = try pte(value, attributes);
        self.mapped_pages += physical.len;
    }
    pub fn unmap(self: *Flat, address: u64, count: usize) Error!void {
        const start = try self.index(address, count);
        for (self.entries[start..][0..count]) |entry| if (entry & 1 == 0) return error.Sparse;
        for (self.entries[start..][0..count]) |*entry| entry.* = 0;
        self.mapped_pages -= count;
    }
};
/// Four 9-bit levels, 48-bit unsigned GPU VA, 4 KB leaves. The
/// resident table arena is caller owned and cannot be returned until both
/// hubs are disabled/quiesced. Empty directories stay allocated until reset.
/// This prevents reusing a PDE page still cached in a walker after an unmap.
pub const Virtual = struct {
    const max_nodes = 512;
    entries: []volatile u64 = &.{}, physical: u64 = 0, count: usize = 0, mapped_pages: usize = 0,
    pub fn init(self: *Virtual, entries: []volatile u64, physical: u64) Error!void {
        if (self.count != 0 or entries.len < 4 * 512 or entries.len > max_nodes * 512 or entries.len % 512 != 0 or
            @intFromPtr(entries.ptr) & 4095 != 0) return error.Invalid;
        _ = try layout.pages(physical, entries.len * 8, layout.address_limit); _ = try pde(physical, false);
        for (entries) |*entry| entry.* = 0;
        self.* = .{ .entries = entries, .physical = physical, .count = 1 };
    }
    pub fn root(self: *const Virtual) Error!u64 { return pde(self.physical, false); }
    fn leaf(self: *Virtual, va: u64, create: bool) Error!*volatile u64 {
        if (self.count == 0 or va == 0 or va >= layout.address_limit or va & 4095 != 0) return error.Invalid;
        var node: usize = 0;
        inline for (.{ @as(u6, 39), @as(u6, 30), @as(u6, 21) }) |shift| {
            const slot = &self.entries[node * 512 + @as(usize, @intCast((va >> shift) & 511))];
            if (slot.* == 0) {
                if (!create) return error.Sparse;
                if (self.count == self.entries.len / 512) return error.Capacity;
                const next = self.count; self.count += 1;
                slot.* = try pde(self.physical + next * 4096, false);
            }
            const physical = slot.* & physical_mask;
            if (slot.* != try pde(physical, false) or physical < self.physical or physical - self.physical >= self.count * 4096) return error.Stale;
            node = @intCast((physical - self.physical) / 4096);
        }
        return &self.entries[node * 512 + @as(usize, @intCast((va >> 12) & 511))];
    }
    pub fn map(self: *Virtual, address: u64, physical: []const u64, attributes: Attributes) Error!void {
        const bytes = std.math.mul(u64, physical.len, 4096) catch return error.Overflow;
        _ = try layout.pages(address, bytes, layout.address_limit);
        for (physical, 0..) |value, i| {
            if (value == 0) return error.Sparse;
            _ = try pte(value, attributes);
            // Any capacity failure leaves only empty, valid directories;
            // no partial mapped data page or unexpected GPU access exists.
            if ((try self.leaf(address + i * 4096, true)).* != 0) return error.Busy;
        }
        for (physical, 0..) |value, i| (try self.leaf(address + i * 4096, false)).* = try pte(value, attributes);
        self.mapped_pages += physical.len;
    }
    pub fn unmap(self: *Virtual, address: u64, count: usize) Error!void {
        const bytes = std.math.mul(u64, count, 4096) catch return error.Overflow;
        _ = try layout.pages(address, bytes, layout.address_limit);
        for (0..count) |i| if ((try self.leaf(address + i * 4096, false)).* & 1 == 0) return error.Sparse;
        for (0..count) |i| (try self.leaf(address + i * 4096, false)).* = 0;
        self.mapped_pages -= count;
    }
    pub fn lookup(self: *Virtual, address: u64) Error!u64 { return (try self.leaf(address, false)).*; }
};
