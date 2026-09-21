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
//! Nonblocking GC9.1 CP/MEC/RLC owner, derived from pinned gfx_v9_0.c.
//! Original AMD MIT notices are retained in ThirdParty/Sources.json.
const std = @import("std");
const c = @import("start_common.zig");
const l = @import("gc_layout.zig");
const r = l.r;
const p = l.p;
const s = @import("queue_storage.zig");
const Queue = l.Queue;
const Ring = @import("queue_ring.zig").Ring;
const set = l.set;
pub const Error = c.Error;
pub const Phase = enum { empty, rlc_delay, ring_delay, map_wait, test_wait, ready, unmap_wait, kiq_wait, park, closed };
pub const Gate = struct { firmware_ready: bool, boot_held: bool, gmc_enabled: bool };
pub const Owner = struct {
    phase: Phase = .empty, touched: bool = false, faulted: bool = false, selftest_round: u8 = 0,
    rings: [3]Ring = @splat(.{}), deadline: c.Deadline = .{}, park: @import("start_engines.zig").Park = .{},
    saved_bank: u32 = 0, saved_index: u32 = 0, saved_gfx_lower: u32 = 0, saved_gfx_upper: u32 = 0,
    saved_mec_lower: u32 = 0, saved_mec_upper: u32 = 0, cu_mask: u32 = 0, rb_mask: u32 = 0,
    kiq_live: bool = false, compute_mapped: bool = false, stop_started: bool = false, kiq_dequeue: bool = false,
    commands: [1024]u32 = undefined,
    pub fn begin(self: *Owner, io: anytype, arena: anytype, gate: Gate) Error!void {
        if (self.touched or self.phase != .empty or !arena.ready or !gate.firmware_ready or !gate.boot_held or !gate.gmc_enabled) return error.Unconfirmed;
        const park = @import("start_engines.zig");
        if (try c.read(io, r.CP_ME_CNTL) & park.cp_mask != park.cp_mask or try c.read(io, r.CP_MEC_CNTL) & park.mec_mask != park.mec_mask or
            try c.read(io, r.RLC_CNTL) & r.RLC_CNTL__RLC_ENABLE_F32_MASK != 0 or try c.read(io, r.GRBM_STATUS) & r.GRBM_STATUS__GUI_ACTIVE_MASK != 0) return error.Unconfirmed;
        self.saved_bank = try c.read(io, r.GRBM_GFX_CNTL); self.saved_index = try c.read(io, r.GRBM_GFX_INDEX);
        self.saved_gfx_lower = try c.read(io, r.CP_RB_DOORBELL_RANGE_LOWER); self.saved_gfx_upper = try c.read(io, r.CP_RB_DOORBELL_RANGE_UPPER);
        self.saved_mec_lower = try c.read(io, r.CP_MEC_DOORBELL_RANGE_LOWER); self.saved_mec_upper = try c.read(io, r.CP_MEC_DOORBELL_RANGE_UPPER);
        self.touched = true; errdefer self.faulted = true;
        inline for (.{ Queue.gfx, Queue.compute, Queue.kiq }) |queue| {
            const words = try arena.words32(queue.offset(), s.ring_bytes);
            self.rings[@intFromEnum(queue)] = try Ring.init(words, 8, p.nop);
            for (words) |*word| word.* = p.nop;
            for (try arena.words32(queue.readback(), 16)) |*word| word.* = 0;
        }
        for (try arena.words32(l.mqd_offsets[0], l.cp_table + l.cp_table_bytes - l.mqd_offsets[0])) |*word| word.* = 0;
        for (try arena.words32(l.scratch_offset, 256)) |*word| word.* = 0;
        for (try arena.words32(l.sample_offset, l.sample_bytes)) |*word| word.* = 0xffffffff;
        const count = try l.clearState(&self.commands);
        for (self.commands[0..count], (try arena.words32(l.csb, l.csb_bytes))[0..count]) |word, *dest| dest.* = word;
        try self.constants(io);
        // Bring-up policy keeps CG/PG/GFXOFF and load balancing disabled until
        // the dedicated power milestone; no RLC power-save access can outlive
        // this arena. PSP already confirmed all PFP/ME/CE/MEC1/MEC2/RLC images.
        try io.write(r.RLC_CGCG_CGLS_CTRL, 0); try io.write(r.RLC_CGCG_CGLS_CTRL_3D, 0);
        const pg = r.RLC_PG_CNTL__GFX_POWER_GATING_ENABLE_MASK | r.RLC_PG_CNTL__GFX_PIPELINE_PG_ENABLE_MASK |
            r.RLC_PG_CNTL__STATIC_PER_CU_PG_ENABLE_MASK | r.RLC_PG_CNTL__DYN_PER_CU_PG_ENABLE_MASK | r.RLC_PG_CNTL__CP_PG_DISABLE_MASK;
        try c.set(io, r.RLC_PG_CNTL, pg, r.RLC_PG_CNTL__CP_PG_DISABLE_MASK);
        try set(io, "RLC_LB_CNTL", "LOAD_BALANCE_ENABLE", 0);
        try set(io, "RLC_SRM_CNTL", "SRM_ENABLE", 1);
        const csb = try arena.address(l.csb, count * 4);
        try io.write(r.RLC_CSIB_ADDR_HI, @truncate(csb >> 32)); try io.write(r.RLC_CSIB_ADDR_LO, @truncate(csb));
        try io.write(r.RLC_CSIB_LENGTH, @intCast(count));
        const table = try arena.address(l.cp_table, l.cp_table_bytes);
        if (table >> 40 != 0) return error.Unsupported;
        try io.write(r.RLC_JUMP_TABLE_RESTORE, @truncate(table >> 8));
        try set(io, "RLC_SPM_MC_CNTL", "RLC_SPM_VMID", 15);
        try c.hdpFlush(io); try set(io, "RLC_CNTL", "RLC_ENABLE_F32", 1);
        try self.deadline.start(io.nowNs(), 500_000_000, 50_000); self.phase = .rlc_delay;
    }
    fn constants(self: *Owner, io: anytype) Error!void {
        try io.write(r.GRBM_GFX_CNTL, 0);
        try io.write(r.GRBM_GFX_INDEX, r.GRBM_GFX_INDEX__INSTANCE_BROADCAST_WRITES_MASK |
            r.GRBM_GFX_INDEX__SE_BROADCAST_WRITES_MASK | r.GRBM_GFX_INDEX__SH_BROADCAST_WRITES_MASK);
        inline for (.{ r.golden_settings_gc_9_1, r.golden_settings_gc_9_1_rv1, r.golden_settings_gc_9_x_common }) |table| {
            for (table) |entry| {
                const old = if (entry.clear == 0xffffffff) 0 else try c.read(io, entry.address);
                try io.write(entry.address, (old & ~entry.clear) | entry.set);
            }
        }
        try set(io, "GRBM_CNTL", "READ_TIMEOUT", 0xff);
        try io.write(r.GRBM_GFX_INDEX, r.GRBM_GFX_INDEX__INSTANCE_BROADCAST_WRITES_MASK);
        self.cu_mask = (~((try c.read(io, r.CC_GC_SHADER_ARRAY_CONFIG) | try c.read(io, r.GC_USER_SHADER_ARRAY_CONFIG)) >> r.CC_GC_SHADER_ARRAY_CONFIG__INACTIVE_CUS__SHIFT)) & 0x7ff;
        self.rb_mask = (~((try c.read(io, r.CC_RB_BACKEND_DISABLE) | try c.read(io, r.GC_USER_RB_BACKEND_DISABLE)) >> r.CC_RB_BACKEND_DISABLE__BACKEND_DISABLE__SHIFT)) & 3;
        try io.write(r.GRBM_GFX_INDEX, self.saved_index);
        if (self.cu_mask == 0 or self.rb_mask == 0) return error.Unsupported;
        for (0..2) |vmid| {
            try io.write(r.GRBM_GFX_CNTL, l.field("GRBM_GFX_CNTL", "VMID", @intCast(vmid)));
            try io.write(r.SH_MEM_CONFIG, l.field("SH_MEM_CONFIG", "ALIGNMENT_MODE", 3) | r.SH_MEM_CONFIG__RETRY_DISABLE_MASK);
            try io.write(r.SH_MEM_BASES, if (vmid == 0) @as(u32, 0) else 0x20001000);
        }
        try io.write(r.GRBM_GFX_CNTL, self.saved_bank);
        // VMID1 is the shared, trusted graphics/compute address space. Context
        // GDS ranges are reserved by its owner, GWS/OA are not enabled here.
        try io.write(r.GDS_VMID0_BASE + 8, 0); try io.write(r.GDS_VMID0_SIZE + 8, 4096);
        try io.write(r.GDS_GWS_VMID0 + 4, 0); try io.write(r.GDS_OA_VMID0 + 4, 0);
    }
    fn initMqd(self: *Owner, io: anytype, arena: anytype, queue: Queue) Error!void {
        try io.write(r.GRBM_GFX_CNTL, queue.bank());
        if (try c.read(io, r.CP_HQD_ACTIVE) & 1 != 0) return error.Unconfirmed;
        const value = try l.mqd(io, arena, queue);
        const index: usize = if (queue == .kiq) 0 else 1;
        const raw: *const [@sizeOf(l.w.struct_v9_mqd_allocation) / 4]u32 = @ptrCast(&value);
        const output = try arena.words32(l.mqd_offsets[index], @sizeOf(l.w.struct_v9_mqd_allocation));
        for (raw, output) |word, *dest| dest.* = word;
        if (queue == .kiq) {
            const v = &value.mqd;
            try set(io, "CP_PQ_WPTR_POLL_CNTL", "EN", 0);
            inline for (.{
                .{ "CP_HQD_EOP_BASE_ADDR", "cp_hqd_eop_base_addr_lo" }, .{ "CP_HQD_EOP_BASE_ADDR_HI", "cp_hqd_eop_base_addr_hi" },
                .{ "CP_HQD_EOP_CONTROL", "cp_hqd_eop_control" }, .{ "CP_HQD_PQ_DOORBELL_CONTROL", "cp_hqd_pq_doorbell_control" },
                .{ "CP_MQD_BASE_ADDR", "cp_mqd_base_addr_lo" }, .{ "CP_MQD_BASE_ADDR_HI", "cp_mqd_base_addr_hi" }, .{ "CP_MQD_CONTROL", "cp_mqd_control" },
                .{ "CP_HQD_PQ_BASE", "cp_hqd_pq_base_lo" }, .{ "CP_HQD_PQ_BASE_HI", "cp_hqd_pq_base_hi" }, .{ "CP_HQD_PQ_CONTROL", "cp_hqd_pq_control" },
                .{ "CP_HQD_PQ_RPTR_REPORT_ADDR", "cp_hqd_pq_rptr_report_addr_lo" }, .{ "CP_HQD_PQ_RPTR_REPORT_ADDR_HI", "cp_hqd_pq_rptr_report_addr_hi" },
                .{ "CP_HQD_PQ_WPTR_POLL_ADDR", "cp_hqd_pq_wptr_poll_addr_lo" }, .{ "CP_HQD_PQ_WPTR_POLL_ADDR_HI", "cp_hqd_pq_wptr_poll_addr_hi" },
                .{ "CP_HQD_PQ_WPTR_LO", "cp_hqd_pq_wptr_lo" }, .{ "CP_HQD_PQ_WPTR_HI", "cp_hqd_pq_wptr_hi" },
                .{ "CP_HQD_VMID", "cp_hqd_vmid" }, .{ "CP_HQD_PERSISTENT_STATE", "cp_hqd_persistent_state" }, .{ "CP_HQD_IB_CONTROL", "cp_hqd_ib_control" },
                .{ "CP_HQD_QUANTUM", "cp_hqd_quantum" }, .{ "CP_HQD_PIPE_PRIORITY", "cp_hqd_pipe_priority" }, .{ "CP_HQD_QUEUE_PRIORITY", "cp_hqd_queue_priority" },
            }) |pair| try io.write(@field(r, pair[0]), @field(v, pair[1]));
            try io.write(r.CP_HQD_DEQUEUE_REQUEST, 0); try io.write(r.CP_HQD_PQ_RPTR, 0);
            try io.write(r.CP_MEC_DOORBELL_RANGE_LOWER, Queue.kiq.doorbell() * 4);
            try io.write(r.CP_MEC_DOORBELL_RANGE_UPPER, 4092);
            try c.set(io, r.RLC_CP_SCHEDULERS, 0xff, 0x80 | (2 << 5) | (1 << 3));
            try c.hdpFlush(io); self.kiq_live = true;
            try io.write(r.CP_HQD_ACTIVE, 1); try set(io, "CP_PQ_STATUS", "DOORBELL_ENABLE", 1);
        }
        try io.write(r.GRBM_GFX_CNTL, self.saved_bank);
    }
    fn gfxPre(self: *Owner, io: anytype, arena: anytype) Error!void {
        _ = self;
        try io.write(r.CP_RB_WPTR_DELAY, 0); try io.write(r.CP_RB_VMID, 0);
        try io.write(r.CP_RB0_CNTL, l.field("CP_RB0_CNTL", "RB_BUFSZ", 13) | l.field("CP_RB0_CNTL", "RB_BLKSZ", 11));
        try io.write(r.CP_RB0_WPTR, 0); try io.write(r.CP_RB0_WPTR_HI, 0);
        const rp = try arena.address(Queue.gfx.readback(), 16);
        try io.write(r.CP_RB0_RPTR_ADDR, @truncate(rp)); try io.write(r.CP_RB0_RPTR_ADDR_HI, @truncate(rp >> 32));
        try io.write(r.CP_RB_WPTR_POLL_ADDR_LO, @truncate(rp + 8)); try io.write(r.CP_RB_WPTR_POLL_ADDR_HI, @truncate((rp + 8) >> 32));
    }
    fn gfxStart(self: *Owner, io: anytype, arena: anytype) Error!void {
        try io.write(r.CP_RB0_CNTL, l.field("CP_RB0_CNTL", "RB_BUFSZ", 13) | l.field("CP_RB0_CNTL", "RB_BLKSZ", 11));
        const base = try arena.address(Queue.gfx.offset(), s.ring_bytes);
        try io.write(r.CP_RB0_BASE, @truncate(base >> 8)); try io.write(r.CP_RB0_BASE_HI, @truncate(base >> 40));
        try set(io, "CP_RB_DOORBELL_CONTROL", "DOORBELL_OFFSET", Queue.gfx.doorbell()); try set(io, "CP_RB_DOORBELL_CONTROL", "DOORBELL_EN", 1);
        try io.write(r.CP_RB_DOORBELL_RANGE_LOWER, Queue.gfx.doorbell()); try io.write(r.CP_RB_DOORBELL_RANGE_UPPER, r.CP_RB_DOORBELL_RANGE_UPPER__DOORBELL_RANGE_UPPER_MASK);
        try io.write(r.CP_MAX_CONTEXT, 7); try io.write(r.CP_DEVICE_ID, 1);
        try c.set(io, r.CP_ME_CNTL, @import("start_engines.zig").cp_mask, 0);
        var count = try l.clearState(&self.commands);
        self.commands[count..][0..7].* = .{ p.packet(0x11, 2), 3, 0x8000, 0x8000, p.packet(0x79, 1), (2 << 28) | (r.VGT_INDEX_TYPE / 4 - 0xc000), 0 };
        count += 7;
        try self.send(io, arena, .gfx, self.commands[0..count]);
    }
    pub fn send(self: *Owner, io: anytype, arena: anytype, queue: Queue, words: []const u32) Error!void {
        const ring = &self.rings[@intFromEnum(queue)];
        const staged = try ring.stage(words); try self.kick(io, arena, queue, staged);
    }
    pub fn kick(self: *Owner, io: anytype, arena: anytype, queue: Queue, staged: @import("queue_ring.zig").Ticket) Error!void {
        const cursor = try self.rings[@intFromEnum(queue)].commit(staged);
        const shadow = try arena.words32(queue.readback() + 8, 8);
        shadow[0] = @truncate(cursor); shadow[1] = @truncate(cursor >> 32);
        try c.hdpFlush(io); try arena.doorbellIndex64(queue.doorbell(), cursor);
    }
    pub fn observe(self: *Owner, io: anytype, arena: anytype) Error!void {
        try c.hdpInvalidate(io);
        inline for (.{ Queue.gfx, Queue.compute, Queue.kiq }) |queue| {
            const rp = (try arena.words32(queue.readback(), 4))[0];
            const ring = &self.rings[@intFromEnum(queue)];
            if (ring.words.len == 0) return error.State;
            // The upstream CP path returns a 32-bit DW readback and masks to
            // ring capacity. The bounded owner rejects advancement beyond
            // published work; only the exact memory fence proves completion.
            try ring.observe(rp & @as(u32, @intCast(ring.words.len - 1)));
        }
    }
    fn mapped(self: *Owner, io: anytype, arena: anytype) Error!bool {
        if (!try self.sample(io, arena, 2, l.sample_tokens[2])) return false;
        try io.write(r.GRBM_GFX_CNTL, Queue.compute.bank());
        const active = try c.read(io, r.CP_HQD_ACTIVE);
        try io.write(r.GRBM_GFX_CNTL, self.saved_bank);
        return active & 1 != 0;
    }
    fn sample(self: *Owner, io: anytype, arena: anytype, index: usize, token: u64) Error!bool {
        _ = self;
        const words = try arena.words32(l.sample_offset + index * 32, 16);
        const first = (@as(u64, words[1]) << 32) | words[0]; try io.barrier();
        const second = (@as(u64, words[1]) << 32) | words[0];
        return first == token and second == token;
    }
    pub fn advance(self: *Owner, io: anytype, arena: anytype) Error!bool {
        if (self.faulted or !self.touched or self.stop_started) return error.State;
        if (self.phase == .ready) return true;
        errdefer self.faulted = true;
        if (!try self.deadline.check(io.nowNs())) return false;
        switch (self.phase) {
            .rlc_delay => {
                if (try c.read(io, r.RLC_CNTL) & r.RLC_CNTL__RLC_ENABLE_F32_MASK == 0) return error.Unconfirmed;
                try self.initMqd(io, arena, .compute); try self.initMqd(io, arena, .kiq); try self.gfxPre(io, arena);
                try self.deadline.start(io.nowNs(), 500_000_000, 1_000_000); self.phase = .ring_delay;
            },
            .ring_delay => {
                try self.gfxStart(io, arena); try io.write(r.CP_MEC_CNTL, 0);
                const mqd = try arena.address(l.mqd_offsets[1], 4096); const wp = try arena.address(Queue.compute.readback() + 8, 8);
                const fence = try arena.address(l.sample_offset + 64, 8); const token = l.sample_tokens[2];
                self.compute_mapped = true; // Latch before uncertain KIQ publish.
                try self.send(io, arena, .kiq, &.{ p.packet(0xa0, 6), 0, 1, 0, 0, 0, 0, 0,
                    p.packet(0xa2, 5), 1 << 29, Queue.compute.doorbell() << 2, @truncate(mqd), @truncate(mqd >> 32), @truncate(wp), @truncate(wp >> 32),
                    p.packet(0x37, 4), (5 << 8) | (1 << 20), @truncate(fence), @truncate(fence >> 32), @truncate(token), @truncate(token >> 32) });
                try self.deadline.start(io.nowNs(), 2_000_000_000, 0); self.phase = .map_wait;
            },
            .map_wait => {
                try self.observe(io, arena);
                if (!try self.mapped(io, arena)) return false;
                try self.submitTests(io, arena); self.phase = .test_wait;
            },
            .test_wait => {
                try self.observe(io, arena);
                inline for (.{ Queue.gfx, Queue.compute }) |queue| {
                    const index: usize = @intFromEnum(queue); const marker: u32 = 0x4100 + @as(u32, self.selftest_round) * 16 + @as(u32, @intCast(index));
                    if (!try self.sample(io, arena, index, l.sample_tokens[index] + @as(u64, self.selftest_round) * 16)) return false;
                    if ((try arena.words32(l.sample_offset + index * 32 + 8, 4))[0] != marker) return error.Unconfirmed;
                    if (self.rings[index].read != self.rings[index].write) return false;
                }
                if (self.selftest_round == 0) { self.selftest_round = 1; try self.submitTests(io, arena); }
                else { self.phase = .ready; return true; }
            },
            else => return error.State,
        }
        return false;
    }
    fn submitTests(self: *Owner, io: anytype, arena: anytype) Error!void {
        inline for (.{ Queue.gfx, Queue.compute }) |queue| {
            const index: usize = @intFromEnum(queue); const slot = 62 + index;
            const marker: u32 = 0x4100 + @as(u32, self.selftest_round) * 16 + @as(u32, @intCast(index));
            const target = @import("sdma_jobs.zig").arena_va + l.sample_offset + index * 32 + 8;
            var words: [32]u32 = @splat(p.nop); var b: p.Builder = .{ .words = &words };
            if (queue == .gfx) b.add(&.{ p.packet(0x69, 1), r.PA_SC_GENERIC_SCISSOR_TL / 4 - 0xa000, marker })
            else b.add(&.{ p.packet(0x76, 1) | 2, r.COMPUTE_USER_DATA_15 / 4 - 0x2c00, marker });
            b.add(&.{ p.packet(0x40, 4), (5 << 8) | (1 << 20), (if (queue == .gfx) r.PA_SC_GENERIC_SCISSOR_TL else r.COMPUTE_USER_DATA_15) / 4,
                0, @truncate(target), @truncate(target >> 32) });
            const ib = try arena.ib(slot); for (words[0..16], ib[0..16]) |word, *dest| dest.* = word;
            const test_words = try arena.words32(l.sample_offset + index * 32, 16); for (test_words) |*word| word.* = 0xffffffff;
            const n = p.encodeFrame(&self.commands, .{ .engine = if (queue == .gfx) .gfx else .compute,
                .ib = @import("sdma_jobs.zig").arena_va + s.ib_offset + slot * s.ib_bytes, .words = 16,
                .fence = try arena.address(l.sample_offset + index * 32, 8), .sequence = l.sample_tokens[index] + @as(u64, self.selftest_round) * 16,
                .eop_scratch = if (queue == .gfx) try arena.address(l.scratch_offset, 256) else 0 }) catch return error.Invalid;
            try self.send(io, arena, queue, self.commands[0..n]);
        }
        try self.deadline.start(io.nowNs(), 2_000_000_000, 0);
    }
    pub fn interrupts(self: *Owner, io: anytype) Error!void {
        if (self.phase != .ready or self.faulted or self.stop_started) return error.Unconfirmed;
        try set(io, "CP_INT_CNTL_RING0", "TIME_STAMP_INT_ENABLE", 1);
        try set(io, "CP_INT_CNTL_RING0", "PRIV_REG_INT_ENABLE", 1); try set(io, "CP_INT_CNTL_RING0", "PRIV_INSTR_INT_ENABLE", 1);
        try set(io, "CP_ME1_PIPE0_INT_CNTL", "TIME_STAMP_INT_ENABLE", 1);
        try set(io, "CP_ME1_PIPE0_INT_CNTL", "PRIV_REG_INT_ENABLE", 1);
    }
    pub fn stop(self: *Owner, io: anytype, arena: anytype) Error!bool {
        if (!self.touched or self.phase == .closed) return true;
        if (!self.stop_started) {
            self.stop_started = true;
            self.phase = if (self.compute_mapped) .unmap_wait else .kiq_wait;
            try self.deadline.start(io.nowNs(), 500_000_000, 0);
            try set(io, "CP_RB_DOORBELL_CONTROL", "DOORBELL_EN", 0);
            if (self.compute_mapped) {
                try self.send(io, arena, .kiq, &.{ p.packet(0xa3, 4), 1 << 29, Queue.compute.doorbell() << 2, 0, 0, 0 });
            }
        }
        if (self.phase == .unmap_wait) {
            _ = try self.deadline.check(io.nowNs());
            try io.write(r.GRBM_GFX_CNTL, Queue.compute.bank());
            const active = try c.read(io, r.CP_HQD_ACTIVE); try io.write(r.GRBM_GFX_CNTL, self.saved_bank);
            if (active & 1 != 0) return false;
            self.compute_mapped = false; self.phase = .kiq_wait;
        }
        if (self.phase == .kiq_wait) {
            _ = try self.deadline.check(io.nowNs());
            if (self.kiq_live) {
                try io.write(r.GRBM_GFX_CNTL, Queue.kiq.bank());
                // Preparation may fail before MEC ever leaves the original
                // confirmed HALT/reset state. In that case proceed directly
                // to the idle proof; no instruction could dequeue the HQD.
                const halted = try c.read(io, r.CP_MEC_CNTL) & @import("start_engines.zig").mec_mask == @import("start_engines.zig").mec_mask;
                if (!halted and !self.kiq_dequeue) { self.kiq_dequeue = true; try io.write(r.CP_HQD_DEQUEUE_REQUEST, 1); }
                const active = try c.read(io, r.CP_HQD_ACTIVE); try io.write(r.GRBM_GFX_CNTL, self.saved_bank);
                if (!halted and active & 1 != 0) return false;
                self.kiq_live = false;
            }
            self.park.include_sdma = false; try self.park.begin(io); self.phase = .park;
        }
        if (self.phase == .park) {
            if (!self.park.confirmed and !try self.park.poll(io)) return false;
            // All CP execution is proved idle before clearing arena addresses.
            try set(io, "CP_RB_DOORBELL_CONTROL", "DOORBELL_EN", 0);
            inline for (.{ Queue.compute, Queue.kiq }) |queue| {
                try io.write(r.GRBM_GFX_CNTL, queue.bank());
                try io.write(r.CP_HQD_ACTIVE, 0);
                try set(io, "CP_HQD_PQ_DOORBELL_CONTROL", "DOORBELL_EN", 0);
                try io.write(r.CP_HQD_DEQUEUE_REQUEST, 0); try io.write(r.CP_HQD_IB_CONTROL, 0); try io.write(r.CP_HQD_PERSISTENT_STATE, 0);
            }
            try io.write(r.GRBM_GFX_CNTL, self.saved_bank); try io.write(r.GRBM_GFX_INDEX, self.saved_index);
            try io.write(r.CP_ME1_PIPE0_INT_CNTL, 0); try io.write(r.CP_INT_CNTL_RING0, 0);
            try io.write(r.RLC_CSIB_LENGTH, 0); try io.write(r.RLC_CSIB_ADDR_LO, 0); try io.write(r.RLC_CSIB_ADDR_HI, 0); try io.write(r.RLC_JUMP_TABLE_RESTORE, 0);
            try io.write(r.CP_RB_DOORBELL_RANGE_LOWER, self.saved_gfx_lower); try io.write(r.CP_RB_DOORBELL_RANGE_UPPER, self.saved_gfx_upper);
            try io.write(r.CP_MEC_DOORBELL_RANGE_LOWER, self.saved_mec_lower); try io.write(r.CP_MEC_DOORBELL_RANGE_UPPER, self.saved_mec_upper);
            try c.hdpFlush(io);
            if (try c.read(io, r.RLC_CSIB_LENGTH) != 0 or try c.read(io, r.GRBM_GFX_CNTL) != self.saved_bank or
                try c.read(io, r.CP_MEC_DOORBELL_RANGE_LOWER) != self.saved_mec_lower or try c.read(io, r.CP_MEC_DOORBELL_RANGE_UPPER) != self.saved_mec_upper) return error.Unconfirmed;
            self.phase = .closed; return true;
        }
        return false;
    }
};
