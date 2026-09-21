// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 AND MIT
//! SDMA4.1 ring register programming and packet framing, based on pinned AMD
//! sdma_v4_0.c / vega10_sdma_pkt_open.h. Full original notice follows below.
const std = @import("std");
const c = @import("start_common.zig");
const r = @import("start_registers.zig");
const s = r.sdma;
const storage = @import("queue_storage.zig");
const q = @import("queue_registers.zig");
pub const Error = c.Error;
pub const Gate = struct { firmware_ready: bool, boot_held: bool, gmc_enabled: bool };
pub const rptr_offset = storage.wb_offset + 0x10;
pub const wptr_offset = storage.wb_offset + 0x18;
fn field(comptime reg: []const u8, comptime name: []const u8, setting: u32) u32 {
    return (setting << @as(u5, @intCast(@field(s, reg ++ "__" ++ name ++ "__SHIFT")))) & @field(s, reg ++ "__" ++ name ++ "_MASK");
}
fn set(io: anytype, comptime reg: []const u8, comptime name: []const u8, setting: u32) Error!void {
    return c.set(io, @field(s, reg), @field(s, reg ++ "__" ++ name ++ "_MASK"), field(reg, name, setting));
}
/// Flush CPU write-combining/HDP before indirect commands and drain HDP before
/// signaling their fence. Byte register offsets are taken from the NBIO source.
fn flush(out: *[6]u32) void {
    const mask = r.nb.GPU_HDP_FLUSH_DONE__SDMA0_MASK;
    out.* = .{ 8 | (1 << 26) | (3 << 28), r.nb.GPU_HDP_FLUSH_DONE, r.nb.GPU_HDP_FLUSH_REQ, mask, mask, (0xfff << 16) | 10 };
}
pub fn frame(out: []u32, cursor: u64, ib: u64, words: usize, fence: u64, token: u64, interrupt: bool) Error!usize {
    if (cursor & 7 != 0 or ib == 0 or ib & 31 != 0 or ib >= @as(u64, 1) << 48 or words == 0 or words > storage.ib_bytes / 4 or
        words * 4 > (@as(u64, 1) << 48) - ib or fence == 0 or fence & 7 != 0 or fence > (@as(u64, 1) << 48) - 8 or
        token == 0 or token == std.math.maxInt(u64) or out.len < 32) return error.Invalid;
    flush(out[0..6]); @memset(out[6..10], 0);
    // VMID1 owns the IB and resource VAs; the outer ring/fence uses VMID0.
    out[10..16].* = .{ 4 | (1 << 16), @truncate(ib), @truncate(ib >> 32), @intCast(words), 0, 0 };
    flush(out[16..22]);
    out[22..32].* = .{ 5, @truncate(fence), @truncate(fence >> 32), @truncate(token),
        5, @truncate(fence + 4), @truncate((fence + 4) >> 32), @truncate(token >> 32), if (interrupt) @as(u32, 6) else 0, 0 };
    return 32;
}
pub const Engine = struct {
    ring: @import("queue_ring.zig").Ring = .{}, touched: bool = false, running: bool = false,
    stopping: bool = false, quiesced: bool = false, saved_doorbell: u32 = 0, saved_aperture: u32 = 0, routing_restored: bool = false,
    deadline: c.Deadline = .{},
    pub fn open(self: *Engine, io: anytype, arena: anytype, gate: Gate) Error!void {
        if (self.touched or !gate.firmware_ready or !gate.boot_held or !gate.gmc_enabled or !arena.ready) return error.Unconfirmed;
        if (try c.read(io, s.SDMA0_F32_CNTL) & s.SDMA0_F32_CNTL__HALT_MASK == 0 or
            try c.read(io, s.SDMA0_STATUS_REG) & s.SDMA0_STATUS_REG__IDLE_MASK == 0 or
            try c.read(io, s.SDMA0_GFX_RB_CNTL) & s.SDMA0_GFX_RB_CNTL__RB_ENABLE_MASK != 0 or
            try c.read(io, s.SDMA0_GFX_IB_CNTL) & s.SDMA0_GFX_IB_CNTL__IB_ENABLE_MASK != 0) return error.Unconfirmed;
        const words = try arena.words32(storage.ringOffset(.sdma), storage.ring_bytes);
        self.ring = try @import("queue_ring.zig").Ring.init(words, 8, 0);
        const base = try arena.address(storage.ringOffset(.sdma), storage.ring_bytes);
        const readback = try arena.address(rptr_offset, 8); const shadow = try arena.address(wptr_offset, 8);
        if (base & 255 != 0 or readback & 7 != 0 or shadow & 7 != 0) return error.Invalid;
        self.saved_doorbell = try c.read(io, r.nb.BIF_SDMA0_DOORBELL_RANGE);
        self.saved_aperture = try c.read(io, q.nb.RCC_DOORBELL_APER_EN);
        self.touched = true;
        try c.set(io, q.nb.RCC_DOORBELL_APER_EN, q.nb.RCC_DOORBELL_APER_EN__BIF_DOORBELL_APER_EN_MASK, q.nb.RCC_DOORBELL_APER_EN__BIF_DOORBELL_APER_EN_MASK);
        for (words) |*word| word.* = 0;
        for (try arena.words32(rptr_offset, 16)) |*word| word.* = 0;
        try io.write(s.SDMA0_SEM_WAIT_FAIL_TIMER_CNTL, 0);
        const rb_mask = s.SDMA0_GFX_RB_CNTL__RB_ENABLE_MASK | s.SDMA0_GFX_RB_CNTL__RB_SIZE_MASK |
            s.SDMA0_GFX_RB_CNTL__RB_SWAP_ENABLE_MASK | s.SDMA0_GFX_RB_CNTL__RPTR_WRITEBACK_SWAP_ENABLE_MASK |
            s.SDMA0_GFX_RB_CNTL__RB_VMID_MASK | s.SDMA0_GFX_RB_CNTL__RPTR_WRITEBACK_ENABLE_MASK;
        try c.set(io, s.SDMA0_GFX_RB_CNTL, rb_mask, field("SDMA0_GFX_RB_CNTL", "RB_SIZE", 14) | s.SDMA0_GFX_RB_CNTL__RPTR_WRITEBACK_ENABLE_MASK);
        inline for (.{ s.SDMA0_GFX_RB_RPTR, s.SDMA0_GFX_RB_RPTR_HI, s.SDMA0_GFX_RB_WPTR, s.SDMA0_GFX_RB_WPTR_HI }) |reg| try io.write(reg, 0);
        try io.write(s.SDMA0_GFX_RB_RPTR_ADDR_HI, @truncate(readback >> 32)); try io.write(s.SDMA0_GFX_RB_RPTR_ADDR_LO, @truncate(readback));
        try io.write(s.SDMA0_GFX_RB_BASE, @truncate(base >> 8)); try io.write(s.SDMA0_GFX_RB_BASE_HI, @truncate(base >> 40));
        const nb_mask = r.nb.BIF_SDMA0_DOORBELL_RANGE__OFFSET_MASK | r.nb.BIF_SDMA0_DOORBELL_RANGE__SIZE_MASK;
        const nb_value = (q.sdma_doorbell << r.nb.BIF_SDMA0_DOORBELL_RANGE__OFFSET__SHIFT) |
            (@as(u32, 4) << r.nb.BIF_SDMA0_DOORBELL_RANGE__SIZE__SHIFT);
        try c.set(io, r.nb.BIF_SDMA0_DOORBELL_RANGE, nb_mask, nb_value);
        try io.write(s.SDMA0_GFX_MINOR_PTR_UPDATE, 1);
        try set(io, "SDMA0_GFX_DOORBELL_OFFSET", "OFFSET", q.sdma_doorbell);
        try set(io, "SDMA0_GFX_DOORBELL", "ENABLE", 1);
        try c.hdpFlush(io); try arena.doorbell64(.sdma, 0);
        try io.write(s.SDMA0_GFX_MINOR_PTR_UPDATE, 0);
        try io.write(s.SDMA0_GFX_RB_WPTR_POLL_ADDR_LO, @truncate(shadow)); try io.write(s.SDMA0_GFX_RB_WPTR_POLL_ADDR_HI, @truncate(shadow >> 32));
        try set(io, "SDMA0_GFX_RB_WPTR_POLL_CNTL", "F32_POLL_ENABLE", 0);
        try set(io, "SDMA0_GFX_IB_CNTL", "IB_SWAP_ENABLE", 0);
        try set(io, "SDMA0_GFX_IB_CNTL", "SWITCH_INSIDE_IB", 0);
        try set(io, "SDMA0_CNTL", "DATA_SWAP_ENABLE", 0); try set(io, "SDMA0_CNTL", "FENCE_SWAP_ENABLE", 0);
        try set(io, "SDMA0_CNTL", "AUTO_CTXSW_ENABLE", 1); try set(io, "SDMA0_CNTL", "UTC_L1_ENABLE", 1);
        try set(io, "SDMA0_CNTL", "TRAP_ENABLE", 0);
        try set(io, "SDMA0_GFX_RB_CNTL", "RB_ENABLE", 1); try set(io, "SDMA0_GFX_IB_CNTL", "IB_ENABLE", 1);
        try set(io, "SDMA0_F32_CNTL", "HALT", 0);
        if (try c.read(io, s.SDMA0_F32_CNTL) & s.SDMA0_F32_CNTL__HALT_MASK != 0 or
            try c.read(io, s.SDMA0_GFX_RB_CNTL) & s.SDMA0_GFX_RB_CNTL__RB_ENABLE_MASK == 0 or
            try c.read(io, s.SDMA0_GFX_IB_CNTL) & s.SDMA0_GFX_IB_CNTL__IB_ENABLE_MASK == 0) return error.Unconfirmed;
        self.running = true;
    }
    pub fn observe(self: *Engine, io: anytype) Error!void {
        if (!self.running or self.stopping) return error.State;
        // A 64-bit monotone byte counter: sample high/low/high to reject tearing.
        const high = try c.read(io, s.SDMA0_GFX_RB_RPTR_HI); const low = try c.read(io, s.SDMA0_GFX_RB_RPTR);
        if (high != try c.read(io, s.SDMA0_GFX_RB_RPTR_HI)) return error.Busy;
        const bytes = (@as(u64, high) << 32) | low;
        if (bytes & 3 != 0 or bytes / 4 < self.ring.read or bytes / 4 > self.ring.write) return error.Stale;
        try self.ring.observe(@intCast((bytes / 4) & (self.ring.words.len - 1)));
    }
    pub fn kick(self: *Engine, io: anytype, arena: anytype, ticket: @import("queue_ring.zig").Ticket) Error!void {
        if (!self.running or self.stopping or ticket.end > std.math.maxInt(u64) / 4) return error.State;
        // All validation/retention and timeline arm precede this irreversible
        // publish. Failure retains the ring and every referenced BO until idle.
        const write = try self.ring.commit(ticket);
        const shadow = try arena.words32(wptr_offset, 8);
        shadow[0] = @truncate(write * 4); shadow[1] = @truncate((write * 4) >> 32);
        try c.hdpFlush(io); try arena.doorbell64(.sdma, write * 4);
    }
    pub fn interrupts(self: *Engine, io: anytype) Error!void {
        if (!self.running or self.stopping) return error.State;
        try set(io, "SDMA0_CNTL", "TRAP_ENABLE", 1);
    }
    /// Shared aperture restoration follows IH/IRQ teardown. Restoring it while
    /// the IH owner is still active would disable that owner's doorbell.
    pub fn restoreRouting(self: *Engine, io: anytype) Error!void {
        if (!self.touched or self.routing_restored) return;
        if (!self.quiesced) return error.Unconfirmed;
        try io.write(q.nb.RCC_DOORBELL_APER_EN, self.saved_aperture);
        if (try c.read(io, q.nb.RCC_DOORBELL_APER_EN) != self.saved_aperture) return error.Unconfirmed;
        self.routing_restored = true;
    }
    pub fn stop(self: *Engine, io: anytype) Error!bool {
        if (!self.touched or self.quiesced) return true;
        if (!self.stopping) {
            self.running = false;
            try set(io, "SDMA0_GFX_RB_CNTL", "RB_ENABLE", 0); try set(io, "SDMA0_GFX_IB_CNTL", "IB_ENABLE", 0);
            try set(io, "SDMA0_F32_CNTL", "HALT", 1);
            try self.deadline.start(io.nowNs(), 500_000_000, 50_000); self.stopping = true;
        }
        if (!try self.deadline.check(io.nowNs())) return false;
        const idle = s.SDMA0_STATUS_REG__IDLE_MASK | s.SDMA0_STATUS_REG__MC_WR_IDLE_MASK | s.SDMA0_STATUS_REG__MC_RD_IDLE_MASK;
        if (try c.read(io, s.SDMA0_STATUS_REG) & idle != idle or
            try c.read(io, s.SDMA0_F32_CNTL) & s.SDMA0_F32_CNTL__HALT_MASK == 0 or
            try c.read(io, s.SDMA0_GFX_RB_CNTL) & s.SDMA0_GFX_RB_CNTL__RB_ENABLE_MASK != 0 or
            try c.read(io, s.SDMA0_GFX_IB_CNTL) & s.SDMA0_GFX_IB_CNTL__IB_ENABLE_MASK != 0) return false;
        try set(io, "SDMA0_CNTL", "TRAP_ENABLE", 0); try set(io, "SDMA0_GFX_DOORBELL", "ENABLE", 0);
        try io.write(r.nb.BIF_SDMA0_DOORBELL_RANGE, self.saved_doorbell);
        if (try c.read(io, r.nb.BIF_SDMA0_DOORBELL_RANGE) != self.saved_doorbell) return error.Unconfirmed;
        try c.hdpFlush(io); self.quiesced = true; return true;
    }
};

// 
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
// 
