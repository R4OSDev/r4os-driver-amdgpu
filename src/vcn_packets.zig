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
//! VCN1 ring framing. IB addresses are VMID1 for VCPU engines; JPEG1 fetches
//! its copied IB from the owned VMID0 arena. Picture buffers still use VMID1.
const std = @import("std");
const r = @import("vcn_registers.zig");
const c = @import("start_common.zig");
pub const Engine = @import("queue_ring.zig").Engine;
pub const max_words = 128;
pub const jpeg_words = 8192;
const Writer = struct {
    data: [max_words]u32 = @splat(0), count: usize = 0,
    fn put(self: *Writer, data: []const u32) void { @memcpy(self.data[self.count..][0..data.len], data); self.count += data.len; }
    fn reg(self: *Writer, offset: u32, value: u32) void { self.put(&.{ offset / 4, value }); }
    fn j(self: *Writer, offset: u32, condition: u32, kind: u32, value: u32) void { self.put(&.{ offset / 4 | condition << 24 | kind << 28, value }); }
    fn external(self: *Writer, offset: u32, value: u32) void {
        const direct = (offset >= 0x1f800 and offset <= 0x21fff) or (offset >= 0x1e000 and offset <= 0x1e1ff);
        self.reg(r.UVD_JRBC_EXTERNAL_REG_BASE, if (direct) 0 else offset);
        self.reg(if (direct) offset else 0, value);
    }
};
pub const Ib = struct { address: u64, dwords: u32 };
pub fn frame(engine: Engine, ib: ?Ib, fence: u64, sequence: u32, ring: u64, output: []u32) c.Error!usize {
    if (!@import("queue_ring.zig").isMedia(engine) or fence == 0 or fence & 7 != 0 or fence >= (@as(u64, 1) << 40) - 8 or sequence == 0 or sequence == std.math.maxInt(u32)) return error.Invalid;
    if (ib) |value| if (value.address == 0 or value.address & 31 != 0 or value.dwords == 0 or value.dwords > 2048 or value.dwords & 15 != 0 or value.address >= (@as(u64, 1) << 40) - @as(u64, value.dwords) * 4) return error.Invalid;
    if (engine == .jpeg and (ring == 0 or ring & 255 != 0 or ring >= (@as(u64, 1) << 40))) return error.Invalid;
    var w: Writer = .{};
    switch (engine) {
        .decode => {
            w.reg(r.UVD_GPCOM_VCPU_DATA0, 0); w.reg(r.UVD_GPCOM_VCPU_CMD, 0xa << 1);
            if (ib) |value| {
                w.reg(r.UVD_LMI_RBC_IB_VMID, 1);
                w.reg(r.UVD_LMI_RBC_IB_64BIT_BAR_LOW, @truncate(value.address));
                w.reg(r.UVD_LMI_RBC_IB_64BIT_BAR_HIGH, @truncate(value.address >> 32));
                w.reg(r.UVD_RBC_IB_SIZE, value.dwords);
            }
            w.reg(r.UVD_CONTEXT_ID, sequence);
            w.reg(r.UVD_GPCOM_VCPU_DATA0, @truncate(fence)); w.reg(r.UVD_GPCOM_VCPU_DATA1, @truncate(fence >> 32));
            w.reg(r.UVD_GPCOM_VCPU_CMD, 0);
            w.reg(r.UVD_GPCOM_VCPU_DATA0, 0); w.reg(r.UVD_GPCOM_VCPU_DATA1, 0); w.reg(r.UVD_GPCOM_VCPU_CMD, 2);
            w.reg(r.UVD_GPCOM_VCPU_CMD, 0xb << 1);
            while (w.count & 15 != 0) w.reg(r.UVD_NO_OP, 0);
        },
        .encode => {
            if (ib) |value| w.put(&.{ 2, 1, @truncate(value.address), @truncate(value.address >> 32), value.dwords });
            w.put(&.{ 3, @truncate(fence), @truncate(fence >> 32), sequence, 4, 1 });
            while (w.count & 15 != 0) w.put(&.{0});
        },
        .jpeg => {
            w.external(0x68e04, 0x80010000);
            if (ib) |value| {
                w.reg(r.UVD_LMI_JRBC_IB_VMID, 0);
                w.reg(r.UVD_LMI_JPEG_VMID, 0x11);
                w.reg(r.UVD_LMI_JRBC_IB_64BIT_BAR_LOW, @truncate(value.address)); w.reg(r.UVD_LMI_JRBC_IB_64BIT_BAR_HIGH, @truncate(value.address >> 32));
                w.reg(r.UVD_JRBC_IB_SIZE, value.dwords);
                w.reg(r.UVD_LMI_JRBC_RB_MEM_RD_64BIT_BAR_LOW, @truncate(ring)); w.reg(r.UVD_LMI_JRBC_RB_MEM_RD_64BIT_BAR_HIGH, @truncate(ring >> 32));
                w.j(0, 0, 2, 0); w.reg(r.UVD_JRBC_RB_COND_RD_TIMER, 0x01400200); w.reg(r.UVD_JRBC_RB_REF_DATA, 2); w.j(r.UVD_JRBC_STATUS, 3, 3, 2);
            }
            w.reg(r.UVD_JPEG_GPCOM_DATA0, sequence); w.reg(r.UVD_JPEG_GPCOM_DATA1, sequence);
            w.reg(r.UVD_LMI_JRBC_RB_MEM_WR_64BIT_BAR_LOW, @truncate(fence)); w.reg(r.UVD_LMI_JRBC_RB_MEM_WR_64BIT_BAR_HIGH, @truncate(fence >> 32));
            w.reg(r.UVD_JPEG_GPCOM_CMD, 8); w.j(r.UVD_JPEG_GPCOM_CMD, 0, 4, 0);
            w.reg(r.UVD_JRBC_RB_COND_RD_TIMER, 0x01400200); w.reg(r.UVD_JRBC_RB_REF_DATA, sequence);
            w.reg(r.UVD_LMI_JRBC_RB_MEM_RD_64BIT_BAR_LOW, @truncate(fence)); w.reg(r.UVD_LMI_JRBC_RB_MEM_RD_64BIT_BAR_HIGH, @truncate(fence >> 32));
            w.j(0, 3, 2, 0xffffffff); w.external(0x3fbc, 1); w.j(0, 0, 7, 0);
            w.external(0x68e04, 0x00010000);
            while (w.count & 15 != 0) w.j(0, 0, 6, 0);
        },
        else => unreachable,
    }
    if (output.len < w.count) return error.Capacity;
    @memcpy(output[0..w.count], w.data[0..w.count]); return w.count;
}
/// JPEG1 has no RB_SIZE register. This AMD tail sequence makes the hardware
/// cursor wrap at the software ring end; it is outside the normal word mask.
pub fn jpegPatch(ring: u64, output: []volatile u32) c.Error!void {
    if (ring == 0 or ring & 255 != 0 or ring >= (@as(u64, 1) << 40) or output.len < 64) return error.Invalid;
    var w: Writer = .{};
    w.external(r.UVD_LMI_JRBC_RB_MEM_RD_64BIT_BAR_LOW, @truncate(ring));
    w.external(r.UVD_LMI_JRBC_RB_MEM_RD_64BIT_BAR_HIGH, @truncate(ring >> 32));
    for (0..3) |_| w.j(0, 0, 2, 0);
    w.external(r.UVD_JRBC_RB_CNTL, 0x13); w.external(r.UVD_JRBC_RB_REF_DATA, 1);
    w.reg(r.UVD_JRBC_RB_COND_RD_TIMER, 0x01400200); w.reg(r.UVD_JRBC_RB_REF_DATA, 1);
    w.reg(r.UVD_JRBC_EXTERNAL_REG_BASE, 0); w.j(r.UVD_JRBC_RB_CNTL, 0, 3, 1);
    for (0..13) |_| w.j(0, 0, 6, 0);
    w.external(r.UVD_JRBC_RB_RPTR, 0); w.external(r.UVD_JRBC_RB_CNTL, 0x12);
    for (output[0..w.count], w.data[0..w.count]) |*dst, src| dst.* = src;
}
