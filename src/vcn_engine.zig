// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 AND MIT
// /*
//  * Copyright 2016 Advanced Micro Devices, Inc.
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice shall be included in
//  * all copies or substantial portions of the Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//  * THE COPYRIGHT HOLDER(S) OR AUTHOR(S) BE LIABLE FOR ANY CLAIM, DAMAGES OR
//  * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
//  * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  * OTHER DEALINGS IN THE SOFTWARE.
//  *
//  */
// 
//! Worker/start-pump VCN1 static-power owner. All waits are nonblocking;
//! timeout, unresponsive firmware and unknown DMA retain the work arenas.
const std = @import("std");
const r = @import("vcn_registers.zig");
const c = @import("start_common.zig");
const sr = @import("start_registers.zig");
const packets = @import("vcn_packets.zig");
const qr = @import("queue_ring.zig");
const storage = @import("queue_storage.zig");
pub const stack_bytes = 128 * 1024;
pub const context_bytes = 512 * 1024;
pub const spare_ring_offset = stack_bytes + context_bytes;
pub const test_offset = spare_ring_offset + storage.ring_bytes;
pub fn ringOffset(engine: qr.Engine) usize { std.debug.assert(qr.isMedia(engine)); return 0xc0000 + @as(usize, @intFromEnum(engine) - 3) * storage.ring_bytes; }
pub const Phase = enum { empty, power_wait, tiles_wait, firmware_wait, ready, stop_idle, stop_clean, stop_umc, stop_tiles, stop_power, closed };
pub const Setup = struct { epoch: u64, firmware: u64, firmware_bytes: u32, workspace: u64, ring: [3]u64, gb_addr_config: u32, boot_held: bool };
pub const Owner = struct {
    phase: Phase = .empty, setup: ?Setup = null, deadline: c.Deadline = .{},
    smu: @import("start_smu.zig").Mailbox = .{}, touched: bool = false, powered: bool = false,
    stopping: bool = false, faulted: bool = false, rings: [3]qr.Ring = @splat(.{}),
    pub fn begin(self: *Owner, io: anytype, arena: anytype, setup: Setup) c.Error!void {
        if (self.phase != .empty or self.touched) return error.Busy;
        if (!setup.boot_held or setup.epoch == 0 or setup.gb_addr_config == 0 or setup.firmware == 0 or setup.firmware & 4095 != 0 or
            setup.firmware_bytes == 0 or setup.firmware_bytes & 4095 != 0 or setup.firmware >= (@as(u64, 1) << 40) - setup.firmware_bytes or
            setup.workspace == 0 or setup.workspace & 65535 != 0 or setup.workspace >= (@as(u64, 1) << 40) - 1024 * 1024) return error.Unconfirmed;
        for (setup.ring, 0..) |address, i| {
            if (address == 0 or address & 65535 != 0 or address >= (@as(u64, 1) << 40) - storage.ring_bytes) return error.Invalid;
            const engine: qr.Engine = @enumFromInt(i + 3);
            const length: usize = if (engine == .jpeg) packets.jpeg_words * 4 else storage.ring_bytes;
            self.rings[i] = try qr.Ring.init(try arena.words32(ringOffset(engine), length), 16, 0);
        }
        try packets.jpegPatch(setup.ring[2], try arena.words32(ringOffset(.jpeg) + packets.jpeg_words * 4, 256));
        self.setup = setup; self.touched = true;
        try self.deadline.start(io.nowNs(), 3_000_000_000, 0);
        try self.smu.begin(io, sr.PPSMC_MSG_PowerUpVcn, 0); self.phase = .power_wait;
    }
    pub fn advance(self: *Owner, io: anytype) c.Error!bool {
        if (self.phase == .ready) return true;
        if (self.stopping or self.phase == .empty or self.phase == .closed) return error.State;
        _ = try self.deadline.check(io.nowNs());
        switch (self.phase) {
            .power_wait => if (try self.smu.poll(io, false)) {
                self.powered = true;
                // All eleven tiles remain powered while this owner is active.
                try io.write(r.UVD_PGFSM_CONFIG, 0x155555); self.phase = .tiles_wait;
            },
            .tiles_wait => if (try c.read(io, r.UVD_PGFSM_STATUS) == 0) {
                try c.set(io, r.UVD_POWER_STATUS, 0x103, 0);
                try c.set(io, r.UVD_STATUS, 4, 4);
                try @import("vcn_clocks.zig").enable(io);
                try c.set(io, r.UVD_MASTINT_EN, r.UVD_MASTINT_EN__VCPU_EN_MASK, 0);
                try c.set(io, r.UVD_SYS_INT_EN, r.UVD_SYS_INT_EN__UVD_JRBC_EN_MASK, 0);
                const coherent = r.UVD_LMI_CTRL__WRITE_CLEAN_TIMER_EN_MASK | r.UVD_LMI_CTRL__MASK_MC_URGENT_MASK | r.UVD_LMI_CTRL__DATA_COHERENCY_EN_MASK | r.UVD_LMI_CTRL__VCPU_DATA_COHERENCY_EN_MASK;
                try c.set(io, r.UVD_LMI_CTRL, coherent, coherent); try io.write(r.UVD_LMI_SWAP_CNTL, 0);
                try c.set(io, r.UVD_MPC_CNTL, r.UVD_MPC_CNTL__REPLACEMENT_MODE_MASK, 2 << r.UVD_MPC_CNTL__REPLACEMENT_MODE__SHIFT);
                try io.write(r.UVD_MPC_SET_MUXA0, 1 << r.UVD_MPC_SET_MUXA0__VARA_1__SHIFT | 2 << r.UVD_MPC_SET_MUXA0__VARA_2__SHIFT | 3 << r.UVD_MPC_SET_MUXA0__VARA_3__SHIFT | 4 << r.UVD_MPC_SET_MUXA0__VARA_4__SHIFT);
                try io.write(r.UVD_MPC_SET_MUXB0, 1 << r.UVD_MPC_SET_MUXB0__VARB_1__SHIFT | 2 << r.UVD_MPC_SET_MUXB0__VARB_2__SHIFT | 3 << r.UVD_MPC_SET_MUXB0__VARB_3__SHIFT | 4 << r.UVD_MPC_SET_MUXB0__VARB_4__SHIFT);
                try io.write(r.UVD_MPC_SET_MUX, 1 << r.UVD_MPC_SET_MUX__SET_1__SHIFT | 2 << r.UVD_MPC_SET_MUX__SET_2__SHIFT);
                const s = self.setup.?;
                try writeAddress(io, r.UVD_LMI_VCPU_CACHE_64BIT_BAR_LOW, r.UVD_LMI_VCPU_CACHE_64BIT_BAR_HIGH, s.firmware);
                try io.write(r.UVD_VCPU_CACHE_OFFSET0, 0); try io.write(r.UVD_VCPU_CACHE_SIZE0, s.firmware_bytes);
                try writeAddress(io, r.UVD_LMI_VCPU_CACHE1_64BIT_BAR_LOW, r.UVD_LMI_VCPU_CACHE1_64BIT_BAR_HIGH, s.workspace);
                try io.write(r.UVD_VCPU_CACHE_OFFSET1, 0); try io.write(r.UVD_VCPU_CACHE_SIZE1, stack_bytes);
                try writeAddress(io, r.UVD_LMI_VCPU_CACHE2_64BIT_BAR_LOW, r.UVD_LMI_VCPU_CACHE2_64BIT_BAR_HIGH, s.workspace + stack_bytes);
                try io.write(r.UVD_VCPU_CACHE_OFFSET2, 0); try io.write(r.UVD_VCPU_CACHE_SIZE2, context_bytes);
                inline for (.{ r.UVD_UDEC_ADDR_CONFIG, r.UVD_UDEC_DB_ADDR_CONFIG, r.UVD_UDEC_DBW_ADDR_CONFIG, r.UVD_UDEC_DBW_UV_ADDR_CONFIG, r.UVD_MIF_CURR_ADDR_CONFIG, r.UVD_MIF_CURR_UV_ADDR_CONFIG, r.UVD_MIF_RECON1_ADDR_CONFIG, r.UVD_MIF_RECON1_UV_ADDR_CONFIG, r.UVD_MIF_REF_ADDR_CONFIG, r.UVD_MIF_REF_UV_ADDR_CONFIG, r.UVD_JPEG_ADDR_CONFIG, r.UVD_JPEG_UV_ADDR_CONFIG }) |reg| try io.write(reg, s.gb_addr_config);
                try io.write(r.UVD_REG_XX_MASK_1_0, 0x10); try c.set(io, r.UVD_RBC_XX_IB_REG_CHECK_1_0, 3, 3);
                try io.write(r.UVD_VCPU_CNTL, r.UVD_VCPU_CNTL__CLK_EN_MASK);
                try c.set(io, r.UVD_SOFT_RESET, r.UVD_SOFT_RESET__VCPU_SOFT_RESET_MASK, 0);
                try c.set(io, r.UVD_LMI_CTRL2, r.UVD_LMI_CTRL2__STALL_ARB_UMC_MASK, 0);
                try c.set(io, r.UVD_SOFT_RESET, r.UVD_SOFT_RESET__LMI_SOFT_RESET_MASK | r.UVD_SOFT_RESET__LMI_UMC_SOFT_RESET_MASK, 0);
                try c.hdpFlush(io); self.phase = .firmware_wait;
            },
            .firmware_wait => if (try c.read(io, r.UVD_STATUS) & 2 != 0) {
                try c.set(io, r.UVD_STATUS, 4, 0); try self.programRings(io);
                self.phase = .ready; return true;
            },
            else => return error.State,
        }
        return false;
    }
    fn programRings(self: *Owner, io: anytype) c.Error!void {
        const s = self.setup.?;
        const control = 16 | (1 << r.UVD_RBC_RB_CNTL__RB_BLKSZ__SHIFT) | r.UVD_RBC_RB_CNTL__RB_NO_FETCH_MASK | r.UVD_RBC_RB_CNTL__RB_NO_UPDATE_MASK | r.UVD_RBC_RB_CNTL__RB_RPTR_WR_EN_MASK;
        try io.write(r.UVD_RBC_RB_CNTL, control); try io.write(r.UVD_RBC_RB_WPTR_CNTL, 0);
        try io.write(r.UVD_RBC_RB_RPTR_ADDR, @intCast(s.ring[0] >> 34));
        try writeAddress(io, r.UVD_LMI_RBC_RB_64BIT_BAR_LOW, r.UVD_LMI_RBC_RB_64BIT_BAR_HIGH, s.ring[0]);
        try io.write(r.UVD_RBC_RB_RPTR, 0); try io.write(r.UVD_SCRATCH2, 0); try io.write(r.UVD_RBC_RB_WPTR, 0);
        try io.write(r.UVD_RBC_RB_CNTL, control & ~r.UVD_RBC_RB_CNTL__RB_NO_FETCH_MASK);
        try io.write(r.UVD_RB_RPTR, 0); try io.write(r.UVD_RB_WPTR, 0);
        try writeAddress(io, r.UVD_RB_BASE_LO, r.UVD_RB_BASE_HI, s.ring[1]); try io.write(r.UVD_RB_SIZE, storage.ring_bytes / 4);
        // Firmware knows two encoder queues. The second is owned and parked;
        // only the first queue receives application work.
        try io.write(r.UVD_RB_RPTR2, 0); try io.write(r.UVD_RB_WPTR2, 0);
        try writeAddress(io, r.UVD_RB_BASE_LO2, r.UVD_RB_BASE_HI2, s.workspace + spare_ring_offset); try io.write(r.UVD_RB_SIZE2, storage.ring_bytes / 4);
        try io.write(r.UVD_LMI_JRBC_RB_VMID, 0); try io.write(r.UVD_JRBC_RB_CNTL, 3);
        try writeAddress(io, r.UVD_LMI_JRBC_RB_64BIT_BAR_LOW, r.UVD_LMI_JRBC_RB_64BIT_BAR_HIGH, s.ring[2]);
        try io.write(r.UVD_JRBC_RB_RPTR, 0); try io.write(r.UVD_JRBC_RB_WPTR, 0); try io.write(r.UVD_JRBC_RB_CNTL, 2);
        try io.barrier(); _ = try c.read(io, r.UVD_STATUS);
    }
    pub fn interrupts(self: *Owner, io: anytype) c.Error!void {
        if (self.phase != .ready or self.stopping or self.faulted) return error.Unconfirmed;
        try c.set(io, r.UVD_MASTINT_EN, r.UVD_MASTINT_EN__VCPU_EN_MASK, r.UVD_MASTINT_EN__VCPU_EN_MASK);
        try c.set(io, r.UVD_SYS_INT_EN, r.UVD_SYS_INT_EN__UVD_JRBC_EN_MASK, r.UVD_SYS_INT_EN__UVD_JRBC_EN_MASK);
    }
    pub fn observe(self: *Owner, io: anytype) c.Error!void {
        if (self.phase != .ready and self.phase != .stop_idle) return error.State;
        for ([_]u32{ r.UVD_RBC_RB_RPTR, r.UVD_RB_RPTR, r.UVD_JRBC_RB_RPTR }, 0..) |reg, i| {
            const raw = try c.read(io, reg);
            // JPEG may be executing its 64-dword tail before it resets RPTR.
            if (i == 2 and raw >= packets.jpeg_words and raw < packets.jpeg_words + 64) continue;
            try self.rings[i].observe(raw);
        }
    }
    pub fn stage(self: *Owner, engine: qr.Engine, commands: []const u32) c.Error!qr.Ticket {
        if (self.phase != .ready or self.stopping or self.faulted or !qr.isMedia(engine) or commands.len & 15 != 0) return error.Busy;
        return self.rings[@intFromEnum(engine) - 3].stage(commands);
    }
    pub fn kick(self: *Owner, io: anytype, engine: qr.Engine, ticket: qr.Ticket) c.Error!void {
        const index = @intFromEnum(engine) - 3;
        const cursor = try self.rings[index].commit(ticket);
        try c.hdpFlush(io);
        const regs = [_]u32{ r.UVD_RBC_RB_WPTR, r.UVD_RB_WPTR, r.UVD_JRBC_RB_WPTR };
        try io.write(regs[index], @intCast(cursor & (self.rings[index].words.len - 1))); _ = try c.read(io, regs[index]);
    }
    pub fn stop(self: *Owner, io: anytype) c.Error!bool {
        if (!self.touched or self.phase == .closed) return true;
        if (!self.stopping) { self.stopping = true; try self.deadline.start(io.nowNs(), 3_000_000_000, 0); }
        _ = try self.deadline.check(io.nowNs());
        if (self.smu.active) { if (!try self.smu.poll(io, true)) return false; if (self.smu.message == sr.PPSMC_MSG_PowerUpVcn) self.powered = true; }
        if (!self.powered) return false;
        switch (self.phase) {
            .stop_idle => {
                try self.observe(io);
                for (&self.rings) |*ring| if (ring.read != ring.write) return false;
                if (try c.read(io, r.UVD_RB_RPTR2) != try c.read(io, r.UVD_RB_WPTR2) or try c.read(io, r.UVD_STATUS) & 7 != 2) return false;
                self.phase = .stop_clean;
            },
            .stop_clean => {
                const mask = r.UVD_LMI_STATUS__VCPU_LMI_WRITE_CLEAN_MASK | r.UVD_LMI_STATUS__READ_CLEAN_MASK | r.UVD_LMI_STATUS__WRITE_CLEAN_MASK | r.UVD_LMI_STATUS__WRITE_CLEAN_RAW_MASK;
                if (try c.read(io, r.UVD_LMI_STATUS) & mask != mask) return false;
                try c.set(io, r.UVD_LMI_CTRL2, r.UVD_LMI_CTRL2__STALL_ARB_UMC_MASK, r.UVD_LMI_CTRL2__STALL_ARB_UMC_MASK); self.phase = .stop_umc;
            },
            .stop_umc => {
                const mask = r.UVD_LMI_STATUS__UMC_READ_CLEAN_RAW_MASK | r.UVD_LMI_STATUS__UMC_WRITE_CLEAN_RAW_MASK;
                if (try c.read(io, r.UVD_LMI_STATUS) & mask != mask) return false;
                try c.set(io, r.UVD_MASTINT_EN, r.UVD_MASTINT_EN__VCPU_EN_MASK, 0);
                try c.set(io, r.UVD_SYS_INT_EN, r.UVD_SYS_INT_EN__UVD_JRBC_EN_MASK, 0);
                try c.set(io, r.UVD_VCPU_CNTL, r.UVD_VCPU_CNTL__CLK_EN_MASK, 0);
                const reset = r.UVD_SOFT_RESET__LMI_UMC_SOFT_RESET_MASK | r.UVD_SOFT_RESET__LMI_SOFT_RESET_MASK | r.UVD_SOFT_RESET__VCPU_SOFT_RESET_MASK;
                try c.set(io, r.UVD_SOFT_RESET, reset, reset);
                if (try c.read(io, r.UVD_SOFT_RESET) & reset != reset) return error.Unconfirmed;
                try io.write(r.UVD_STATUS, 0); try c.set(io, r.UVD_POWER_STATUS, r.UVD_POWER_STATUS__UVD_POWER_STATUS_MASK, 1);
                try io.write(r.UVD_PGFSM_CONFIG, 0x2aaaaa); self.phase = .stop_tiles;
            },
            .stop_tiles => if (try c.read(io, r.UVD_PGFSM_STATUS) & 0xffffff == 0x2aaaaa) {
                try self.smu.begin(io, sr.PPSMC_MSG_PowerDownVcn, 0); self.phase = .stop_power;
            },
            .stop_power => { self.powered = false; self.phase = .closed; return true; },
            else => self.phase = .stop_idle,
        }
        return false;
    }
};
fn writeAddress(io: anytype, low: u32, high: u32, value: u64) c.Error!void { try io.write(low, @truncate(value)); try io.write(high, @truncate(value >> 32)); }
comptime { if (r.required_prefix > @import("memory_registers.zig").required_prefix) @compileError("VCN MMIO exceeds admitted BAR"); }
