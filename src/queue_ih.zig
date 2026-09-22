// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 AND MIT
// Original AMD MIT notices are retained below and in ThirdParty/Sources.json.
// vega10_ih.c
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

// amdgpu_ih.c
// /*
//  * Copyright 2014 Advanced Micro Devices, Inc.
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

// nbio_v7_0.c
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
//! Vega10 IH / NBIO7 programming and 32-byte IV decoding for Picasso.
const std = @import("std");
const r = @import("queue_registers.zig");
const timeline = @import("queue_timeline.zig");
pub const Error = @import("memory_hubs.zig").Error;
pub const Event = struct {
    epoch: timeline.Epoch,
    client: u8, source: u8, ring: u8, vmid: u4, vmid_source: bool,
    timestamp: u48, timestamp_source: bool, pasid: u16, node: u8, data: [4]u32,
    pub fn decode(words: [8]u32, epoch: timeline.Epoch) Event {
        return .{ .epoch = epoch, .client = @truncate(words[0]), .source = @truncate(words[0] >> 8),
            .ring = @truncate(words[0] >> 16), .vmid = @truncate(words[0] >> 24), .vmid_source = words[0] >> 31 != 0,
            .timestamp = @as(u48, words[1]) | @as(u48, words[2] & 0xffff) << 32,
            .timestamp_source = words[2] >> 31 != 0, .pasid = @truncate(words[3]), .node = @truncate(words[3] >> 16),
            .data = words[4..8].* };
    }
    pub fn faultMask(self: Event) @import("queue_ring.zig").EngineMask {
        // EOP/TRAP are wake hints only; success always needs a fence writeback.
        return switch (self.client) {
            r.client_VMC, r.client_UTCL2 => @import("queue_ring.zig").all_engines,
            0x10 => switch (self.source) { 124, 119, 120, 126 => 0, else => @import("queue_ring.zig").media_engines },
            r.client_SDMA0, r.client_SDMA1 => if (self.source == r.sdma_SDMA_TRAP and self.client == r.client_SDMA0) 0 else 1,
            r.client_GRBM_CP => if (self.source == r.gfx_CP_EOP_INTERRUPT) 0 else 6,
            else => 0, // Other IP owners (e.g. DCN) receive the complete event.
        };
    }
};
/// Single producer under the IRQ admission gate, single worker consumer.
/// Indices wrap independently of GPU timestamps. No allocation or BO access.
pub const Mailbox = struct {
    entries: [128]Event = undefined, producer: u32 = 0, consumer: u32 = 0,
    pub fn push(self: *Mailbox, event: Event) bool {
        const producer = @atomicLoad(u32, &self.producer, .monotonic);
        const consumer = @atomicLoad(u32, &self.consumer, .acquire);
        if (producer -% consumer >= self.entries.len) return false;
        self.entries[producer % self.entries.len] = event;
        @atomicStore(u32, &self.producer, producer +% 1, .release); return true;
    }
    pub fn pop(self: *Mailbox) ?Event {
        const consumer = @atomicLoad(u32, &self.consumer, .monotonic);
        if (consumer == @atomicLoad(u32, &self.producer, .acquire)) return null;
        const value = self.entries[consumer % self.entries.len];
        @atomicStore(u32, &self.consumer, consumer +% 1, .release); return value;
    }
};
pub fn field(value: u32, mask: u32, shift: u32, setting: u32) u32 {
    return (value & ~mask) | ((setting << @as(u5, @intCast(shift))) & mask);
}
fn set(value: u32, comptime R: type, comptime reg: []const u8, comptime name: []const u8, setting: u32) u32 {
    return field(value, @field(R, reg ++ "__" ++ name ++ "_MASK"), @field(R, reg ++ "__" ++ name ++ "__SHIFT"), setting);
}
fn read(io: anytype, offset: u32) Error!u32 {
    const value = try io.read(offset); if (value == 0xffffffff) return error.Disconnected; return value;
}
pub const Setup = struct {
    epoch: timeline.Epoch, ring_gpu: u64, writeback_gpu: u64, dummy_dma: u64,
    bytes: u32, msi: bool,
};
pub const Controller = struct {
    configured: bool = false, touched: bool = false, enabled: bool = false,
    setup: ?Setup = null, rptr: u32 = 0, control: u32 = 0, stop_started: ?u64 = null,
    previous_interrupt: u32 = 0, previous_dummy: u32 = 0, previous_aperture: u32 = 0, previous_range: u32 = 0,
    pub fn configure(self: *Controller, io: anytype, setup: Setup) Error!void {
        if (self.touched) return error.Busy;
        if (setup.epoch.adapter == 0 or setup.epoch.device == 0 or setup.epoch.reset == 0 or
            setup.bytes < 4096 or setup.bytes > 256 * 1024 or !std.math.isPowerOfTwo(setup.bytes) or
            setup.ring_gpu == 0 or setup.ring_gpu & 255 != 0 or setup.ring_gpu >= (@as(u64, 1) << 48) - setup.bytes or
            setup.writeback_gpu == 0 or setup.writeback_gpu & 3 != 0 or setup.writeback_gpu >= (@as(u64, 1) << 48) - 4 or
            setup.dummy_dma == 0 or setup.dummy_dma & 255 != 0 or setup.dummy_dma >= (@as(u64, 1) << 40)) return error.Invalid;
        const old = try read(io, r.ih.IH_RB_CNTL);
        if (old & r.ih.IH_RB_CNTL__RB_ENABLE_MASK != 0) return error.Unconfirmed;
        // No migration/log rings are owned on this APU. Refuse live firmware
        // state rather than taking over an unowned ring or silently losing it.
        if ((try read(io, r.ih.IH_RB_CNTL_RING1)) & r.ih.IH_RB_CNTL_RING1__RB_ENABLE_MASK != 0 or
            (try read(io, r.ih.IH_RB_CNTL_RING2)) & r.ih.IH_RB_CNTL_RING2__RB_ENABLE_MASK != 0) return error.Unconfirmed;
        self.previous_interrupt = try read(io, r.nb.INTERRUPT_CNTL);
        self.previous_dummy = try read(io, r.nb.INTERRUPT_CNTL2);
        self.previous_aperture = try read(io, r.nb.RCC_DOORBELL_APER_EN);
        self.previous_range = try read(io, r.nb.BIF_IH_DOORBELL_RANGE);
        self.setup = setup; self.touched = true;
        try io.write(r.nb.INTERRUPT_CNTL2, @intCast(setup.dummy_dma >> 8));
        var interrupt = set(self.previous_interrupt, r.nb, "INTERRUPT_CNTL", "IH_DUMMY_RD_OVERRIDE", 0);
        interrupt = set(interrupt, r.nb, "INTERRUPT_CNTL", "IH_REQ_NONSNOOP_EN", 0);
        try io.write(r.nb.INTERRUPT_CNTL, interrupt);
        var control = set(old, r.ih, "IH_RB_CNTL", "RB_ENABLE", 0);
        control = set(control, r.ih, "IH_RB_CNTL", "ENABLE_INTR", 0);
        control = set(control, r.ih, "IH_RB_CNTL", "MC_SPACE", 4); // existing UMA/MC VRAM arena
        control = set(control, r.ih, "IH_RB_CNTL", "MC_SWAP", 0);
        control = set(control, r.ih, "IH_RB_CNTL", "MC_RO", 0);
        control = set(control, r.ih, "IH_RB_CNTL", "MC_VMID", 0);
        control = set(control, r.ih, "IH_RB_CNTL", "MC_SNOOP", 1);
        control = set(control, r.ih, "IH_RB_CNTL", "RB_SIZE", std.math.log2_int(u32, setup.bytes / 4));
        control = set(control, r.ih, "IH_RB_CNTL", "WPTR_WRITEBACK_ENABLE", 1);
        control = set(control, r.ih, "IH_RB_CNTL", "WPTR_OVERFLOW_ENABLE", 1);
        control = set(control, r.ih, "IH_RB_CNTL", "RPTR_REARM", @intFromBool(setup.msi));
        control = set(control, r.ih, "IH_RB_CNTL", "RB_GPU_TS_ENABLE", 1);
        self.control = control & ~r.ih.IH_RB_CNTL__WPTR_OVERFLOW_CLEAR_MASK;
        try io.write(r.ih.IH_RB_BASE, @truncate(setup.ring_gpu >> 8));
        try io.write(r.ih.IH_RB_BASE_HI, @intCast(setup.ring_gpu >> 40));
        try io.write(r.ih.IH_RB_CNTL, control | r.ih.IH_RB_CNTL__WPTR_OVERFLOW_CLEAR_MASK);
        try io.write(r.ih.IH_RB_CNTL, self.control);
        try io.write(r.ih.IH_RB_WPTR_ADDR_LO, @truncate(setup.writeback_gpu));
        try io.write(r.ih.IH_RB_WPTR_ADDR_HI, @intCast(setup.writeback_gpu >> 32));
        try io.write(r.ih.IH_RB_WPTR, 0); try io.write(r.ih.IH_RB_RPTR, 0);
        try io.write(r.ih.IH_DOORBELL_RPTR, r.ih.IH_DOORBELL_RPTR__ENABLE_MASK | r.ih_doorbell);
        var range = set(self.previous_range, r.nb, "BIF_IH_DOORBELL_RANGE", "OFFSET", r.ih_doorbell);
        range = set(range, r.nb, "BIF_IH_DOORBELL_RANGE", "SIZE", 2);
        try io.write(r.nb.BIF_IH_DOORBELL_RANGE, range);
        try io.write(r.nb.RCC_DOORBELL_APER_EN, self.previous_aperture | r.nb.RCC_DOORBELL_APER_EN__BIF_DOORBELL_APER_EN_MASK);
        try io.barrier();
        if ((try read(io, r.ih.IH_RB_BASE)) != @as(u32, @truncate(setup.ring_gpu >> 8)) or
            (try read(io, r.ih.IH_RB_CNTL)) != self.control) return error.Unconfirmed;
        self.configured = true;
    }
    pub fn enable(self: *Controller, io: anytype) Error!void {
        if (!self.configured or self.enabled or self.stop_started != null) return error.Busy;
        self.control |= r.ih.IH_RB_CNTL__RB_ENABLE_MASK | r.ih.IH_RB_CNTL__ENABLE_INTR_MASK;
        try io.write(r.ih.IH_RB_CNTL, self.control); try io.barrier();
        if ((try read(io, r.ih.IH_RB_CNTL)) != self.control) return error.Unconfirmed;
        self.enabled = true;
    }
    pub fn mask(self: *Controller, io: anytype) Error!void {
        if (!self.touched) return;
        self.control &= ~r.ih.IH_RB_CNTL__ENABLE_INTR_MASK;
        try io.write(r.ih.IH_RB_CNTL, self.control); try io.barrier();
    }
    /// At most 32 vectors per producer entry. Full mailbox is backpressure:
    /// leave unrecorded entries on the GPU ring for the next worker poll.
    pub fn capture(self: *Controller, io: anytype, storage: anytype, mailbox: *Mailbox) Error!u32 {
        if (!self.enabled or self.stop_started != null) return error.Busy;
        const setup = self.setup.?;
        const raw = try read(io, r.ih.IH_RB_WPTR);
        if (raw & r.ih.IH_RB_WPTR__RB_OVERFLOW_MASK != 0) return error.Capacity;
        const wptr = raw & r.ih.IH_RB_WPTR__OFFSET_MASK;
        if (wptr >= setup.bytes or wptr & 31 != 0) return error.Invalid;
        try io.barrier();
        const words = try storage.words32(0, setup.bytes);
        var count: u32 = 0;
        while (self.rptr != wptr and count < 32) {
            var data: [8]u32 = undefined;
            for (&data, 0..) |*word, i| word.* = words[self.rptr / 4 + i];
            if (!mailbox.push(Event.decode(data, setup.epoch))) break;
            self.rptr = (self.rptr + 32) & (setup.bytes - 1); count += 1;
        }
        if (count != 0) {
            const wb = try storage.words32(@import("queue_storage.zig").wb_offset + 4, 4); wb[0] = self.rptr;
            try storage.doorbell32(r.ih_doorbell, self.rptr);
        }
        return count;
    }
    /// Disable/read back, then allow the upstream 1ms drain interval without
    /// sleeping or spinning under the IRQ owner. Caller retries in task context.
    pub fn close(self: *Controller, io: anytype) Error!void {
        if (!self.touched) return;
        if (self.stop_started == null) {
            self.control &= ~(r.ih.IH_RB_CNTL__RB_ENABLE_MASK | r.ih.IH_RB_CNTL__ENABLE_INTR_MASK);
            try io.write(r.ih.IH_RB_CNTL, self.control); try io.barrier();
            if ((try read(io, r.ih.IH_RB_CNTL)) & (r.ih.IH_RB_CNTL__RB_ENABLE_MASK | r.ih.IH_RB_CNTL__ENABLE_INTR_MASK) != 0) return error.Unconfirmed;
            const now = io.nowNs(); if (now == std.math.maxInt(u64)) return error.Deadline;
            self.stop_started = now; self.enabled = false; return error.Busy;
        }
        const now = io.nowNs();
        if (now == std.math.maxInt(u64) or now < self.stop_started.?) return error.Deadline;
        if (now - self.stop_started.? < 1_000_000) return error.Busy;
        if ((try read(io, r.ih.IH_RB_CNTL)) & (r.ih.IH_RB_CNTL__RB_ENABLE_MASK | r.ih.IH_RB_CNTL__ENABLE_INTR_MASK) != 0) return error.Unconfirmed;
        try io.write(r.ih.IH_DOORBELL_RPTR, 0);
        try io.write(r.nb.BIF_IH_DOORBELL_RANGE, self.previous_range);
        try io.write(r.nb.RCC_DOORBELL_APER_EN, self.previous_aperture);
        try io.write(r.nb.INTERRUPT_CNTL, self.previous_interrupt);
        try io.write(r.nb.INTERRUPT_CNTL2, self.previous_dummy);
        try io.barrier(); _ = try read(io, r.ih.IH_RB_CNTL);
        self.* = .{};
    }
};
