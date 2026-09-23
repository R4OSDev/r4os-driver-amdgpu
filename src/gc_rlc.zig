// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 AND MIT
// Copyright 2012-2016 Advanced Micro Devices, Inc.
// Copyright 2017 Advanced Micro Devices, Inc.
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE COPYRIGHT HOLDER(S) OR AUTHOR(S) BE LIABLE FOR ANY CLAIM, DAMAGES OR
// OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
//! Raven2 RLC save/restore programming from gfx_v9_1_init_rlc_save_restore_list
//! in the pinned gfx_v9_0.c. Preflight all data before any hardware mutation.
const std = @import("std");
const fw = @import("firmware.zig");
const c = @import("start_common.zig");
const r = @import("gc_registers.zig");
const index_addresses = [_]u32{ r.RLC_SRM_INDEX_CNTL_ADDR_0, r.RLC_SRM_INDEX_CNTL_ADDR_1, r.RLC_SRM_INDEX_CNTL_ADDR_2, r.RLC_SRM_INDEX_CNTL_ADDR_3,
    r.RLC_SRM_INDEX_CNTL_ADDR_4, r.RLC_SRM_INDEX_CNTL_ADDR_5, r.RLC_SRM_INDEX_CNTL_ADDR_6, r.RLC_SRM_INDEX_CNTL_ADDR_7 };
const index_data = [_]u32{ r.RLC_SRM_INDEX_CNTL_DATA_0, r.RLC_SRM_INDEX_CNTL_DATA_1, r.RLC_SRM_INDEX_CNTL_DATA_2, r.RLC_SRM_INDEX_CNTL_DATA_3,
    r.RLC_SRM_INDEX_CNTL_DATA_4, r.RLC_SRM_INDEX_CNTL_DATA_5, r.RLC_SRM_INDEX_CNTL_DATA_6, r.RLC_SRM_INDEX_CNTL_DATA_7 };
fn word(data: []const u8, offset: usize) u32 { return std.mem.readInt(u32, data[offset..][0..4], .little); }
pub const Plan = struct {
    ready: bool = false, generation: u64 = 0,
    // Borrowed only from the verified, retained firmware store.
    restore: []const u8 = &.{}, format: [256]u32 = @splat(0), count: usize = 0,
    indirect: [8]u32 = @splat(0), starts: [10]u32 = @splat(0),
    format_start: u32 = 0, size_address: u32 = 0, starts_address: u32 = 0,
    pub fn prepare(self: *Plan, store: *const @import("firmware_store.zig").Store) c.Error!void {
        if (self.ready) return error.Busy;
        if (!store.valid or store.generation == 0 or store.profile == null) return error.Firmware;
        if (store.profile.?.family != .raven2) return;
        try self.parse(store.container(.rlc) orelse return error.Firmware, store.specification(.rlc) orelse return error.Firmware);
        self.generation = store.generation;
    }
    // Exposed to the existing firmware/GC host tests; runtime calls prepare().
    // Structural negatives intentionally do not stop at whole-file SHA256.
    pub fn parse(self: *Plan, blob: []const u8, spec: *const fw.Firmware) c.Error!void {
        if (self.ready) return error.Busy;
        if (spec.family != .raven2 or spec.role != .rlc) return error.Firmware;
        const layout = fw.inspect(blob, spec) catch return error.Firmware;
        var next: Plan = .{};
        next.restore = layout.segments[1].span.slice(blob);
        const format = layout.segments[0].span.slice(blob);
        next.count = format.len / 4;
        const direct: usize = word(blob, 104);
        const restore_words = next.restore.len / 4;
        if (next.count == 0 or next.count > next.format.len or direct >= next.count or direct & 1 != 0 or
            restore_words == 0 or restore_words > r.RLC_SRM_ARAM_ADDR__ADDR_MASK + 1 or restore_words & 1 != 0) return error.Firmware;
        next.size_address = word(blob, 56); next.format_start = word(blob, 60); next.starts_address = word(blob, 68);
        const scratch_words = r.RLC_GPM_SCRATCH_ADDR__ADDR_MASK + 1;
        if (next.format_start >= scratch_words or next.count > scratch_words - next.format_start or
            next.size_address >= scratch_words or next.starts_address >= scratch_words or next.starts.len > scratch_words - next.starts_address)
            return error.Firmware;
        const format_end = next.format_start + next.count;
        const starts_end = next.starts_address + next.starts.len;
        if ((next.size_address >= next.format_start and next.size_address < format_end) or
            (next.size_address >= next.starts_address and next.size_address < starts_end) or
            (next.format_start < starts_end and next.starts_address < format_end)) return error.Firmware;
        for (next.format[0..next.count], 0..) |*value, i| value.* = word(format, i * 4);
        var i: usize = 0;
        while (i < direct) : (i += 2) {
            if (next.format[i] > restore_words or next.format[i + 1] > restore_words - next.format[i]) return error.Firmware;
        }
        var start_count: usize = 0;
        var indirect_count: usize = 0;
        while (i < next.count) {
            if (start_count == next.starts.len) return error.Firmware;
            next.starts[start_count] = @intCast(i); start_count += 1;
            while (i < next.count and next.format[i] != 0xffffffff) {
                if (next.count - i < 3 or next.format[i] > restore_words or next.format[i + 1] > restore_words - next.format[i]) return error.Firmware;
                const reg = next.format[i + 2];
                if (reg == 0 or reg == 0xffffffff) return error.Firmware;
                var index: usize = 0;
                while (index < indirect_count and next.indirect[index] != reg) : (index += 1) {}
                if (index == next.indirect.len) return error.Firmware;
                if (index == indirect_count) { next.indirect[index] = reg; indirect_count += 1; }
                next.format[i + 2] = @intCast(index); i += 3;
            }
            if (i == next.count) return error.Firmware; // every indirect group is terminated
            i += 1;
        }
        next.ready = true; self.* = next;
    }
    pub fn apply(self: *const Plan, io: anytype) c.Error!void {
        if (!self.ready) return error.Unconfirmed;
        var deadline: c.Deadline = .{}; try deadline.start(io.nowNs(), 500_000_000, 0);
        try c.set(io, r.RLC_SRM_CNTL, r.RLC_SRM_CNTL__AUTO_INCR_ADDR_MASK, r.RLC_SRM_CNTL__AUTO_INCR_ADDR_MASK);
        try io.write(r.RLC_SRM_ARAM_ADDR, 0);
        for (0..self.restore.len / 4) |i| {
            if (i % 128 == 0) _ = try deadline.check(io.nowNs());
            try io.write(r.RLC_SRM_ARAM_DATA, word(self.restore, i * 4));
        }
        try io.write(r.RLC_GPM_SCRATCH_ADDR, self.format_start);
        for (self.format[0..self.count]) |value| try io.write(r.RLC_GPM_SCRATCH_DATA, value);
        try io.write(r.RLC_GPM_SCRATCH_ADDR, self.size_address);
        try io.write(r.RLC_GPM_SCRATCH_DATA, @intCast(self.restore.len / 8));
        try io.write(r.RLC_GPM_SCRATCH_ADDR, self.starts_address);
        for (self.starts) |value| try io.write(r.RLC_GPM_SCRATCH_DATA, value);
        for (self.indirect, 0..) |reg, i| if (reg != 0) {
            try io.write(index_addresses[i], reg & 0x3ffff);
            try io.write(index_data[i], reg >> 20);
        };
        _ = try deadline.check(io.nowNs());
    }
};
