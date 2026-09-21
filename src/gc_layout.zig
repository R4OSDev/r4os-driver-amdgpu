// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 AND MIT
// Copyright 2012-2016 Advanced Micro Devices, Inc.
// Copyright 2017 Advanced Micro Devices, Inc.
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
//  
//! GC9 data layouts and clear state, based on original AMD v9_structs.h and
//! clearstate_gfx9.h. Original notices are retained in ThirdParty/Sources.json.
const std = @import("std");
const c = @import("start_common.zig");
pub const w = @cImport({ @cInclude("gc_wire.h"); });
pub const p = @import("r4amd_pm4");
pub const r = @import("gc_registers.zig");
const s = @import("queue_storage.zig");
const q = @import("queue_registers.zig");
pub const csb = 0x11000;
pub const csb_bytes = 4096;
pub const kiq_ring = 0x50000;
pub const mqd_offsets = [_]usize{ 0x60000, 0x61000 };
pub const eop_offsets = [_]usize{ 0x62000, 0x63000 };
pub const cp_table = 0x64000;
pub const cp_table_bytes = 0x10800; // ALIGN(96 * five firmware jump tables * 4, 2048) + 64KB GDS save area
pub const scratch_offset = 0x75000; // per-GFX-ring EOP workaround, 256B
pub const sample_offset = s.wb_offset + 0x600;
pub const sample_bytes = 128;
pub const sample_tokens = [_]u64{ 0x4746583900000001, 0x4d45433900000002, 0x4b49513900000003 };
pub const rptr_offsets = [_]usize{ s.wb_offset + 0x20, s.wb_offset + 0x30, s.wb_offset + 0x40 };
pub const Queue = enum(u2) {
    gfx, compute, kiq,
    pub fn offset(self: Queue) usize { return switch (self) { .gfx => s.ringOffset(.gfx), .compute => s.ringOffset(.compute), .kiq => kiq_ring }; }
    pub fn doorbell(self: Queue) u32 { return switch (self) { .gfx => q.gfx_doorbell, .compute => q.compute_doorbell, .kiq => q.kiq_doorbell }; }
    pub fn readback(self: Queue) usize { return rptr_offsets[@intFromEnum(self)]; }
    pub fn bank(self: Queue) u32 {
        return switch (self) { .gfx => 0, .compute => field("GRBM_GFX_CNTL", "MEID", 1),
            .kiq => field("GRBM_GFX_CNTL", "MEID", 2) | field("GRBM_GFX_CNTL", "PIPEID", 1) };
    }
};
pub fn field(comptime reg: []const u8, comptime name: []const u8, value: u32) u32 {
    return (value << @as(u5, @intCast(@field(r, reg ++ "__" ++ name ++ "__SHIFT")))) & @field(r, reg ++ "__" ++ name ++ "_MASK");
}
pub fn set(io: anytype, comptime reg: []const u8, comptime name: []const u8, value: u32) c.Error!void {
    try c.set(io, @field(r, reg), @field(r, reg ++ "__" ++ name ++ "_MASK"), field(reg, name, value));
}
pub fn clearState(out: []u32) c.Error!usize {
    // The unchanged original has one context section, eight extents, sentinel.
    if (out.len < 904 or w.gfx9_cs_data[0].id != w.SECT_CONTEXT or w.gfx9_cs_data[1].section != null) return error.Invalid;
    var b: p.Builder = .{ .words = out };
    b.add(&.{ p.packet(0x4a, 0), 2 << 28, p.packet(0x28, 1), 0x80000000, 0x80000000 });
    for (w.gfx9_SECT_CONTEXT_defs[0..8]) |extent| {
        if (extent.extent == null or extent.reg_index < 0xa000 or extent.reg_count > 4096) return error.Invalid;
        b.add(&.{ p.packet(0x69, @intCast(extent.reg_count)), extent.reg_index - 0xa000 });
        b.add(extent.extent[0..extent.reg_count]);
    }
    b.add(&.{ p.packet(0x4a, 0), 3 << 28, p.packet(0x12, 0), 0 });
    if (b.used != 904) return error.Invalid;
    return b.used;
}
/// Kernel-owned HQDs use VMID0 for queue/MQD storage and VMID1 for IBs.
/// KIQ is MEC2/pipe1/queue0 (never unsupported MEC2 pipes2/3); the ordinary
/// compute queue is MEC1/pipe0/queue0, mapped by that KIQ, not by metadata alone.
pub fn mqd(io: anytype, arena: anytype, queue: Queue) c.Error!w.struct_v9_mqd_allocation {
    if (queue == .gfx) return error.Invalid;
    const index: usize = if (queue == .kiq) 0 else 1;
    const base = try arena.address(mqd_offsets[index], 4096);
    const ring = try arena.address(queue.offset(), s.ring_bytes);
    const eop = try arena.address(eop_offsets[index], 4096);
    const rp = try arena.address(queue.readback(), 8); const wp = rp + 8;
    if ((base | ring | eop) & 255 != 0 or (rp | wp) & 7 != 0) return error.Invalid;
    var allocation = std.mem.zeroes(w.struct_v9_mqd_allocation);
    allocation.dynamic_cu_mask = 0xffffffff; allocation.dynamic_rb_mask = 0xffffffff;
    const v = &allocation.mqd;
    v.header = 0xc0310800; v.compute_pipelinestat_enable = 1; v.compute_misc_reserved = 3;
    w.r4amd_mqd_thread_masks(v);
    v.dynamic_cu_mask_addr_lo = @truncate(base + @offsetOf(w.struct_v9_mqd_allocation, "dynamic_cu_mask"));
    v.dynamic_cu_mask_addr_hi = @truncate((base + @offsetOf(w.struct_v9_mqd_allocation, "dynamic_cu_mask")) >> 32);
    v.cp_hqd_eop_base_addr_lo = @truncate(eop >> 8); v.cp_hqd_eop_base_addr_hi = @truncate(eop >> 40);
    v.cp_hqd_eop_control = (try c.read(io, r.CP_HQD_EOP_CONTROL) & ~r.CP_HQD_EOP_CONTROL__EOP_SIZE_MASK) | field("CP_HQD_EOP_CONTROL", "EOP_SIZE", 9);
    v.cp_hqd_pq_doorbell_control = (try c.read(io, r.CP_HQD_PQ_DOORBELL_CONTROL) &
        ~(r.CP_HQD_PQ_DOORBELL_CONTROL__DOORBELL_OFFSET_MASK | r.CP_HQD_PQ_DOORBELL_CONTROL__DOORBELL_EN_MASK |
        r.CP_HQD_PQ_DOORBELL_CONTROL__DOORBELL_SOURCE_MASK | r.CP_HQD_PQ_DOORBELL_CONTROL__DOORBELL_HIT_MASK)) |
        field("CP_HQD_PQ_DOORBELL_CONTROL", "DOORBELL_OFFSET", queue.doorbell()) | r.CP_HQD_PQ_DOORBELL_CONTROL__DOORBELL_EN_MASK;
    v.cp_mqd_base_addr_lo = @truncate(base); v.cp_mqd_base_addr_hi = @truncate(base >> 32);
    v.cp_mqd_control = try c.read(io, r.CP_MQD_CONTROL) & ~r.CP_MQD_CONTROL__VMID_MASK;
    v.cp_hqd_pq_base_lo = @truncate(ring >> 8); v.cp_hqd_pq_base_hi = @truncate(ring >> 40);
    v.cp_hqd_pq_control = (try c.read(io, r.CP_HQD_PQ_CONTROL) & ~(r.CP_HQD_PQ_CONTROL__QUEUE_SIZE_MASK |
        r.CP_HQD_PQ_CONTROL__RPTR_BLOCK_SIZE_MASK | r.CP_HQD_PQ_CONTROL__ENDIAN_SWAP_MASK | r.CP_HQD_PQ_CONTROL__UNORD_DISPATCH_MASK |
        r.CP_HQD_PQ_CONTROL__ROQ_PQ_IB_FLIP_MASK | r.CP_HQD_PQ_CONTROL__PRIV_STATE_MASK | r.CP_HQD_PQ_CONTROL__KMD_QUEUE_MASK)) |
        field("CP_HQD_PQ_CONTROL", "QUEUE_SIZE", 13) | field("CP_HQD_PQ_CONTROL", "RPTR_BLOCK_SIZE", 9) |
        r.CP_HQD_PQ_CONTROL__PRIV_STATE_MASK | r.CP_HQD_PQ_CONTROL__KMD_QUEUE_MASK;
    v.cp_hqd_pq_rptr_report_addr_lo = @truncate(rp); v.cp_hqd_pq_rptr_report_addr_hi = @truncate(rp >> 32);
    v.cp_hqd_pq_wptr_poll_addr_lo = @truncate(wp); v.cp_hqd_pq_wptr_poll_addr_hi = @truncate(wp >> 32);
    v.cp_hqd_persistent_state = (try c.read(io, r.CP_HQD_PERSISTENT_STATE) & ~r.CP_HQD_PERSISTENT_STATE__PRELOAD_SIZE_MASK) | field("CP_HQD_PERSISTENT_STATE", "PRELOAD_SIZE", 0x53);
    v.cp_hqd_ib_control = (try c.read(io, r.CP_HQD_IB_CONTROL) & ~r.CP_HQD_IB_CONTROL__MIN_IB_AVAIL_SIZE_MASK) | field("CP_HQD_IB_CONTROL", "MIN_IB_AVAIL_SIZE", 3);
    v.cp_hqd_quantum = field("CP_HQD_QUANTUM", "QUANTUM_EN", 1) | field("CP_HQD_QUANTUM", "QUANTUM_SCALE", 1) | field("CP_HQD_QUANTUM", "QUANTUM_DURATION", 1);
    // Ordinary queue priority is normal. Logical priorities are scheduled at
    // complete-IB boundaries with bounded ageing by the context owner.
    v.cp_hqd_active = @intFromBool(queue == .kiq);
    return allocation;
}
comptime {
    if (csb + csb_bytes > s.ringOffset(.sdma) or kiq_ring + s.ring_bytes != mqd_offsets[0] or
        mqd_offsets[1] + 4096 != eop_offsets[0] or eop_offsets[1] + 4096 != cp_table or cp_table + cp_table_bytes > scratch_offset or
        scratch_offset + 256 > s.ib_offset or sample_offset + sample_bytes > csb or r.required_prefix > @import("memory_registers.zig").required_prefix)
        @compileError("GFX9 arena layout/prefix mismatch");
}
