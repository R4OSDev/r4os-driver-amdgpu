// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 AND MIT
// Copyright 2016 Advanced Micro Devices, Inc.
// 
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
// THE COPYRIGHT HOLDER(S) OR AUTHOR(S) BE LIABLE FOR ANY CLAIM, DAMAGES OR
// OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
// 
//! Picasso GMC9 programming, ported from pinned AMD MIT gfxhub_v1_0.c,
//! mmhub_v1_0.c, athub_v1_0.c and gmc_v9_0.c. No Linux runtime dependencies.
const std = @import("std");
const r = @import("memory_registers.zig");
const l = @import("memory_layout.zig");
const p = @import("memory_pages.zig");
pub const Error = l.Error || error{ Deadline, Disconnected, Unconfirmed };
pub const Gate = struct { memory_epoch: u64, boot_held: bool, engines_quiesced: bool };
fn field(value: u32, mask: u32, shift: u32, setting: u32) u32 { return (value & ~mask) | ((setting << @as(u5, @intCast(shift))) & mask); }
fn set(io: anytype, comptime R: type, comptime reg: []const u8, comptime name: []const u8, value: u32) Error!void {
    const offset = @field(R, reg); const old = try io.read(offset);
    if (old == 0xffffffff) return error.Disconnected;
    try io.write(offset, field(old, @field(R, reg ++ "__" ++ name ++ "_MASK"), @field(R, reg ++ "__" ++ name ++ "__SHIFT"), value));
}
pub fn flush(io: anytype, vmid: u4) Error!void {
    try io.barrier();
    // Complete CPU writes before walker invalidation. CPU fence alone is not
    // a GPU HDP/TLB acknowledgement. Picasso specifically needs no MM semaphore.
    try io.write(r.nb.HDP_MEM_COHERENCY_FLUSH_CNTL, 0);
    _ = try io.read(r.nb.HDP_MEM_COHERENCY_FLUSH_CNTL);
    const start = io.nowNs(); const deadline = std.math.add(u64, start, 10_000_000) catch return error.Deadline;
    var last = start;
    inline for (.{ r.gfx, r.mm }) |R| {
        const req = (@as(u32, 1) << vmid) | R.VM_INVALIDATE_ENG0_REQ__INVALIDATE_L2_PTES_MASK |
            R.VM_INVALIDATE_ENG0_REQ__INVALIDATE_L2_PDE0_MASK | R.VM_INVALIDATE_ENG0_REQ__INVALIDATE_L2_PDE1_MASK |
            R.VM_INVALIDATE_ENG0_REQ__INVALIDATE_L2_PDE2_MASK | R.VM_INVALIDATE_ENG0_REQ__INVALIDATE_L1_PTES_MASK;
        try io.write(R.VM_INVALIDATE_ENG17_REQ, req);
        // Required GFX9 posted-read boundary prevents an old ACK being accepted.
        _ = try io.read(R.VM_INVALIDATE_ENG17_REQ);
        var confirmed = false;
        for (0..10000) |_| {
            const now = io.nowNs(); if (now < last or now >= deadline) return error.Deadline; last = now;
            const ack = try io.read(R.VM_INVALIDATE_ENG17_ACK);
            if (ack == 0xffffffff) return error.Disconnected;
            if (ack & (@as(u32, 1) << vmid) != 0) { confirmed = true; break; }
        }
        if (!confirmed) return error.Deadline;
    }
    try io.barrier();
}
fn context(io: anytype, comptime R: type, vmid: u4, root: u64, span: l.Span, depth: u2) Error!void {
    const distance = R.VM_CONTEXT1_PAGE_TABLE_BASE_ADDR_LO32 - R.VM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32;
    const offset = distance * @as(u32, vmid);
    try io.write(R.VM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32 + offset, @truncate(root));
    try io.write(R.VM_CONTEXT0_PAGE_TABLE_BASE_ADDR_HI32 + offset, @truncate(root >> 32));
    try io.write(R.VM_CONTEXT0_PAGE_TABLE_START_ADDR_LO32 + offset, @truncate(span.offset >> 12));
    try io.write(R.VM_CONTEXT0_PAGE_TABLE_START_ADDR_HI32 + offset, @truncate(span.offset >> 44));
    try io.write(R.VM_CONTEXT0_PAGE_TABLE_END_ADDR_LO32 + offset, @truncate((span.end() - 1) >> 12));
    try io.write(R.VM_CONTEXT0_PAGE_TABLE_END_ADDR_HI32 + offset, @truncate((span.end() - 1) >> 44));
    const control = R.VM_CONTEXT0_CNTL__ENABLE_CONTEXT_MASK |
        (@as(u32, depth) << @as(u5, @intCast(R.VM_CONTEXT0_CNTL__PAGE_TABLE_DEPTH__SHIFT))) |
        R.VM_CONTEXT0_CNTL__RANGE_PROTECTION_FAULT_ENABLE_INTERRUPT_MASK |
        R.VM_CONTEXT0_CNTL__PDE0_PROTECTION_FAULT_ENABLE_INTERRUPT_MASK |
        R.VM_CONTEXT0_CNTL__VALID_PROTECTION_FAULT_ENABLE_INTERRUPT_MASK |
        R.VM_CONTEXT0_CNTL__READ_PROTECTION_FAULT_ENABLE_INTERRUPT_MASK |
        R.VM_CONTEXT0_CNTL__WRITE_PROTECTION_FAULT_ENABLE_INTERRUPT_MASK |
        R.VM_CONTEXT0_CNTL__EXECUTE_PROTECTION_FAULT_ENABLE_INTERRUPT_MASK;
    // block_size=9 => encoded zero; retry/default-page substitution disabled.
    try io.write(R.VM_CONTEXT0_CNTL + @as(u32, vmid) * (R.VM_CONTEXT1_CNTL - R.VM_CONTEXT0_CNTL), control);
}
pub const Controller = struct {
    epoch: u64 = 0, touched: bool = false, enabled: bool = false,
    pub fn enable(self: *Controller, io: anytype, map: *const l.Layout, virtual_root: u64, scratch_physical: u64, gate: Gate) Error!void {
        if (self.touched or self.enabled) return error.Busy;
        if (gate.memory_epoch == 0 or !gate.boot_held or !gate.engines_quiesced) return error.Unconfirmed;
        const gart_root = try p.pde(try map.physicalAddress(map.tables.span), false);
        if (virtual_root != try p.pde(virtual_root & p.physical_mask, false)) return error.Invalid;
        if (!map.physical.contains(.{ .offset = scratch_physical, .bytes = 4096 }) or scratch_physical & 4095 != 0) return error.Invalid;
        const context_physical = try map.physicalAddress(map.contexts.span);
        if ((virtual_root & p.physical_mask) != context_physical or scratch_physical != context_physical + map.contexts.span.bytes - 4096) return error.Invalid;
        self.epoch = gate.memory_epoch; self.touched = true;
        // Memory and hub register mutation occurs exclusively in the owner's
        // preemptible worker, after the start owner has parked every engine.
        try set(io, r.at, "ATHUB_MISC_CNTL", "CG_ENABLE", 0);
        try set(io, r.at, "ATHUB_MISC_CNTL", "CG_MEM_LS_ENABLE", 0);
        for (0..16) |i| try io.write(r.at.ATC_VMID0_PASID_MAPPING + @as(u32, @intCast(i)) * 4, 0);
        inline for (.{ r.gfx, r.mm }) |R| {
            for (0..16) |i| try io.write(R.VM_CONTEXT0_CNTL + @as(u32, @intCast(i)) * (R.VM_CONTEXT1_CNTL - R.VM_CONTEXT0_CNTL), 0);
            try io.write(R.MC_VM_AGP_BASE, 0);
            try io.write(R.MC_VM_AGP_BOT, 0x00ffffff); try io.write(R.MC_VM_AGP_TOP, 0); // no AGP alias
            try io.write(R.MC_VM_SYSTEM_APERTURE_LOW_ADDR, @intCast(map.mc.offset >> 18));
            try io.write(R.MC_VM_SYSTEM_APERTURE_HIGH_ADDR, @intCast((map.mc.end() - 1) >> 18));
            try io.write(R.MC_VM_SYSTEM_APERTURE_DEFAULT_ADDR_LSB, @truncate(scratch_physical >> 12));
            try io.write(R.MC_VM_SYSTEM_APERTURE_DEFAULT_ADDR_MSB, @truncate(scratch_physical >> 44));
            try io.write(R.VM_L2_PROTECTION_FAULT_DEFAULT_ADDR_LO32, @truncate(scratch_physical >> 12));
            try io.write(R.VM_L2_PROTECTION_FAULT_DEFAULT_ADDR_HI32, @truncate(scratch_physical >> 44));
            try set(io, R, "VM_L2_PROTECTION_FAULT_CNTL2", "ACTIVE_PAGE_MIGRATION_PTE_READ_RETRY", 1);
            inline for (.{ .{ "ENABLE_L1_TLB", 1 }, .{ "SYSTEM_ACCESS_MODE", 3 }, .{ "ENABLE_ADVANCED_DRIVER_MODEL", 1 },
                .{ "SYSTEM_APERTURE_UNMAPPED_ACCESS", 0 }, .{ "MTYPE", 3 }, .{ "ATC_EN", 1 } }) |setting|
                try set(io, R, "MC_VM_MX_L1_TLB_CNTL", setting[0], setting[1]);
            inline for (.{ .{ "ENABLE_L2_CACHE", 1 }, .{ "ENABLE_L2_FRAGMENT_PROCESSING", 1 }, .{ "L2_PDE0_CACHE_TAG_GENERATION_MODE", 0 },
                .{ "PDE_FAULT_CLASSIFICATION", 0 }, .{ "CONTEXT1_IDENTITY_ACCESS_MODE", 1 }, .{ "IDENTITY_MODE_FRAGMENT_SIZE", 0 } }) |setting|
                try set(io, R, "VM_L2_CNTL", setting[0], setting[1]);
            try set(io, R, "VM_L2_CNTL2", "INVALIDATE_ALL_L1_TLBS", 1); try set(io, R, "VM_L2_CNTL2", "INVALIDATE_L2_CACHE", 1);
            var value = field(R.VM_L2_CNTL3_DEFAULT, R.VM_L2_CNTL3__BANK_SELECT_MASK, R.VM_L2_CNTL3__BANK_SELECT__SHIFT, 9);
            value = field(value, R.VM_L2_CNTL3__L2_CACHE_BIGK_FRAGMENT_SIZE_MASK, R.VM_L2_CNTL3__L2_CACHE_BIGK_FRAGMENT_SIZE__SHIFT, 6);
            try io.write(R.VM_L2_CNTL3, value);
            value = R.VM_L2_CNTL4_DEFAULT & ~(R.VM_L2_CNTL4__VMC_TAP_PDE_REQUEST_PHYSICAL_MASK | R.VM_L2_CNTL4__VMC_TAP_PTE_REQUEST_PHYSICAL_MASK);
            try io.write(R.VM_L2_CNTL4, value);
            try io.write(R.VM_L2_CONTEXT1_IDENTITY_APERTURE_LOW_ADDR_LO32, 0xffffffff);
            try io.write(R.VM_L2_CONTEXT1_IDENTITY_APERTURE_LOW_ADDR_HI32, 0xf);
            try io.write(R.VM_L2_CONTEXT1_IDENTITY_APERTURE_HIGH_ADDR_LO32, 0); try io.write(R.VM_L2_CONTEXT1_IDENTITY_APERTURE_HIGH_ADDR_HI32, 0);
            try io.write(R.VM_L2_CONTEXT_IDENTITY_PHYSICAL_OFFSET_LO32, 0); try io.write(R.VM_L2_CONTEXT_IDENTITY_PHYSICAL_OFFSET_HI32, 0);
            const stride = R.VM_INVALIDATE_ENG1_ADDR_RANGE_LO32 - R.VM_INVALIDATE_ENG0_ADDR_RANGE_LO32;
            for (0..18) |i| {
                try io.write(R.VM_INVALIDATE_ENG0_ADDR_RANGE_LO32 + @as(u32, @intCast(i)) * stride, 0xffffffff);
                try io.write(R.VM_INVALIDATE_ENG0_ADDR_RANGE_HI32 + @as(u32, @intCast(i)) * stride, 0x1f);
            }
            inline for (.{ "RANGE_PROTECTION_FAULT_ENABLE_DEFAULT", "PDE0_PROTECTION_FAULT_ENABLE_DEFAULT", "PDE1_PROTECTION_FAULT_ENABLE_DEFAULT",
                "PDE2_PROTECTION_FAULT_ENABLE_DEFAULT", "TRANSLATE_FURTHER_PROTECTION_FAULT_ENABLE_DEFAULT", "NACK_PROTECTION_FAULT_ENABLE_DEFAULT",
                "DUMMY_PAGE_PROTECTION_FAULT_ENABLE_DEFAULT", "VALID_PROTECTION_FAULT_ENABLE_DEFAULT", "READ_PROTECTION_FAULT_ENABLE_DEFAULT",
                "WRITE_PROTECTION_FAULT_ENABLE_DEFAULT", "EXECUTE_PROTECTION_FAULT_ENABLE_DEFAULT" }) |name|
                try set(io, R, "VM_L2_PROTECTION_FAULT_CNTL", name, 0);
            try set(io, R, "VM_L2_PROTECTION_FAULT_CNTL", "CRASH_ON_NO_RETRY_FAULT", 1);
            try set(io, R, "VM_L2_PROTECTION_FAULT_CNTL", "CRASH_ON_RETRY_FAULT", 1);
            try context(io, R, 0, gart_root, map.gart, 0);
            try context(io, R, 1, virtual_root, .{ .offset = 0, .bytes = l.address_limit }, 3);
        }
        try io.write(r.hdp.HDP_NONSURFACE_BASE, @truncate(map.mc.offset >> 8));
        try io.write(r.hdp.HDP_NONSURFACE_BASE_HI, @truncate(map.mc.offset >> 40));
        try flush(io, 0); try flush(io, 1); self.enabled = true;
    }
    pub fn disable(self: *Controller, io: anytype, gate: Gate) Error!void {
        if (!self.touched) return;
        if (gate.memory_epoch != self.epoch or !gate.engines_quiesced or !gate.boot_held) return error.Unconfirmed;
        self.enabled = false;
        inline for (.{ r.gfx, r.mm }) |R| {
            for (0..16) |i| try io.write(R.VM_CONTEXT0_CNTL + @as(u32, @intCast(i)) * (R.VM_CONTEXT1_CNTL - R.VM_CONTEXT0_CNTL), 0);
        }
        try flush(io, 0); try flush(io, 1);
        inline for (.{ r.gfx, r.mm }) |R| {
            try set(io, R, "MC_VM_MX_L1_TLB_CNTL", "ENABLE_L1_TLB", 0);
            try set(io, R, "MC_VM_MX_L1_TLB_CNTL", "ENABLE_ADVANCED_DRIVER_MODEL", 0);
            try set(io, R, "VM_L2_CNTL", "ENABLE_L2_CACHE", 0); try io.write(R.VM_L2_CNTL3, 0);
        }
        try io.barrier(); self.* = .{};
    }
};
