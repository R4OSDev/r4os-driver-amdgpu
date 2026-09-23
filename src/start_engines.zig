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
//  
//! GC9.1 / SDMA4.1 halt sequence from gfx_v9_0.c and sdma_v4_0.c.
//! This owner never restarts old BIOS rings after replacing their firmware.
const c = @import("start_common.zig");
const regs = @import("start_registers.zig");
const g = regs.gc;
const s = regs.sdma;
pub const Error = c.Error;
// AMD's gfx_v9_0_cp_{gfx,compute}_enable writes invalidate/reset controls
// along with HALT, then waits 50us. Those command bits are not a persistent
// stop receipt: the Lenovo Raven2 reads CP_ME_CNTL=0x15150000 after writing
// 0x153f0150. Require every HALT bit plus the independent idle checks below.
pub const cp_halt_mask = g.CP_ME_CNTL__CE_HALT_MASK | g.CP_ME_CNTL__PFP_HALT_MASK | g.CP_ME_CNTL__ME_HALT_MASK;
pub const mec_halt_mask = g.CP_MEC_CNTL__MEC_ME1_HALT_MASK | g.CP_MEC_CNTL__MEC_ME2_HALT_MASK;
pub const cp_mask = cp_halt_mask |
    g.CP_ME_CNTL__CE_INVALIDATE_ICACHE_MASK | g.CP_ME_CNTL__PFP_INVALIDATE_ICACHE_MASK | g.CP_ME_CNTL__ME_INVALIDATE_ICACHE_MASK |
    g.CP_ME_CNTL__CE_PIPE0_RESET_MASK | g.CP_ME_CNTL__CE_PIPE1_RESET_MASK | g.CP_ME_CNTL__PFP_PIPE0_RESET_MASK |
    g.CP_ME_CNTL__PFP_PIPE1_RESET_MASK | g.CP_ME_CNTL__ME_PIPE0_RESET_MASK | g.CP_ME_CNTL__ME_PIPE1_RESET_MASK;
pub const mec_mask = g.CP_MEC_CNTL__MEC_INVALIDATE_ICACHE_MASK | g.CP_MEC_CNTL__MEC_ME1_PIPE0_RESET_MASK |
    g.CP_MEC_CNTL__MEC_ME1_PIPE1_RESET_MASK | g.CP_MEC_CNTL__MEC_ME1_PIPE2_RESET_MASK | g.CP_MEC_CNTL__MEC_ME1_PIPE3_RESET_MASK |
    g.CP_MEC_CNTL__MEC_ME2_PIPE0_RESET_MASK | g.CP_MEC_CNTL__MEC_ME2_PIPE1_RESET_MASK |
    mec_halt_mask;
pub const Park = struct {
    include_sdma: bool = true,
    touched: bool = false, confirmed: bool = false, deadline: c.Deadline = .{},
    wait: enum { settle, cp, mec, rlc, sdma_halt, sdma_rb, sdma_ib, sdma_idle, gui, rlc_busy, serdes_cu, serdes_noncu, ready } = .settle,
    samples: [11]u32 = @splat(0), sampled: u16 = 0, polls: u32 = 0,
    /// Revalidate an engine owner's completed stop without repeating reset
    /// commands after GMC has restored the firmware memory configuration.
    /// The same independent HALT/idle checks and deadline remain mandatory.
    pub fn recheck(self: *Park, io: anytype) Error!void {
        if (!self.touched) return error.Unconfirmed;
        self.confirmed = false;
        self.wait = .settle; self.samples = @splat(0); self.sampled = 0; self.polls = 0;
        try self.deadline.start(io.nowNs(), 500_000_000, 50_000);
    }
    pub fn begin(self: *Park, io: anytype) Error!void {
        self.confirmed = false;
        self.wait = .settle; self.samples = @splat(0); self.sampled = 0; self.polls = 0;
        try self.deadline.start(io.nowNs(), 500_000_000, 50_000);
        self.touched = true;
        try c.set(io, g.CP_ME_CNTL, cp_mask, cp_mask);
        try io.write(g.CP_MEC_CNTL, mec_mask);
        if (self.include_sdma) {
            try c.set(io, s.SDMA0_GFX_RB_CNTL, s.SDMA0_GFX_RB_CNTL__RB_ENABLE_MASK, 0);
            try c.set(io, s.SDMA0_GFX_IB_CNTL, s.SDMA0_GFX_IB_CNTL__IB_ENABLE_MASK, 0);
            try c.set(io, s.SDMA0_F32_CNTL, s.SDMA0_F32_CNTL__HALT_MASK, s.SDMA0_F32_CNTL__HALT_MASK);
        }
        try c.set(io, g.RLC_CNTL, g.RLC_CNTL__RLC_ENABLE_F32_MASK, 0);
        const interrupts = g.CP_INT_CNTL_RING0__CNTX_BUSY_INT_ENABLE_MASK | g.CP_INT_CNTL_RING0__CNTX_EMPTY_INT_ENABLE_MASK |
            g.CP_INT_CNTL_RING0__CMP_BUSY_INT_ENABLE_MASK | g.CP_INT_CNTL_RING0__GFX_IDLE_INT_ENABLE_MASK;
        try c.set(io, g.CP_INT_CNTL_RING0, interrupts, 0);
        try io.barrier();
    }
    pub fn poll(self: *Park, io: anytype) Error!bool {
        if (!self.touched) return error.State;
        if (!try self.deadline.check(io.nowNs())) return false;
        self.polls +|= 1;
        self.wait = .cp;
        if (try self.sample(io, 0, g.CP_ME_CNTL) & cp_halt_mask != cp_halt_mask) return false;
        self.wait = .mec;
        if (try self.sample(io, 1, g.CP_MEC_CNTL) & mec_halt_mask != mec_halt_mask) return false;
        self.wait = .rlc;
        if (try self.sample(io, 2, g.RLC_CNTL) & g.RLC_CNTL__RLC_ENABLE_F32_MASK != 0) return false;
        if (self.include_sdma) {
            self.wait = .sdma_halt;
            if (try self.sample(io, 3, s.SDMA0_F32_CNTL) & s.SDMA0_F32_CNTL__HALT_MASK == 0) return false;
            self.wait = .sdma_rb;
            if (try self.sample(io, 4, s.SDMA0_GFX_RB_CNTL) & s.SDMA0_GFX_RB_CNTL__RB_ENABLE_MASK != 0) return false;
            self.wait = .sdma_ib;
            if (try self.sample(io, 5, s.SDMA0_GFX_IB_CNTL) & s.SDMA0_GFX_IB_CNTL__IB_ENABLE_MASK != 0) return false;
            self.wait = .sdma_idle;
            if (try self.sample(io, 6, s.SDMA0_STATUS_REG) & s.SDMA0_STATUS_REG__IDLE_MASK == 0) return false;
        }
        self.wait = .gui;
        if (try self.sample(io, 7, g.GRBM_STATUS) & g.GRBM_STATUS__GUI_ACTIVE_MASK != 0) return false;
        self.wait = .rlc_busy;
        if (try self.sample(io, 8, g.GRBM_STATUS2) & (g.GRBM_STATUS2__RLC_BUSY_MASK | g.GRBM_STATUS2__RLC_RQ_PENDING_MASK) != 0) return false;
        // Picasso has one shader engine/array. Select the actual bank for the
        // CU SERDES read, and restore the caller's index even on a failed read.
        const index = try c.read(io, g.GRBM_GFX_INDEX);
        try io.write(g.GRBM_GFX_INDEX, g.GRBM_GFX_INDEX__INSTANCE_BROADCAST_WRITES_MASK);
        self.wait = .serdes_cu;
        const cu = self.sample(io, 9, g.RLC_SERDES_CU_MASTER_BUSY) catch |err| { try io.write(g.GRBM_GFX_INDEX, index); return err; };
        try io.write(g.GRBM_GFX_INDEX, index);
        const mask = g.RLC_SERDES_NONCU_MASTER_BUSY__SE_MASTER_BUSY_MASK | g.RLC_SERDES_NONCU_MASTER_BUSY__GC_MASTER_BUSY_MASK |
            g.RLC_SERDES_NONCU_MASTER_BUSY__TC0_MASTER_BUSY_MASK | g.RLC_SERDES_NONCU_MASTER_BUSY__TC1_MASTER_BUSY_MASK;
        if (cu != 0) return false;
        self.wait = .serdes_noncu;
        if (try self.sample(io, 10, g.RLC_SERDES_NONCU_MASTER_BUSY) & mask != 0) return false;
        self.confirmed = true; self.wait = .ready; return true;
    }
    fn sample(self: *Park, io: anytype, comptime index: usize, address: u32) Error!u32 {
        const value = try c.read(io, address);
        self.samples[index] = value; self.sampled |= @as(u16, 1) << index;
        return value;
    }
};
