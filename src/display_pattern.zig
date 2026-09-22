// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Legacy mode jobs carry canonical SYSTEM/XR24 pixels. A default-limited
//! CTA mode converts that pattern once, before either private BO is published.
//! Explicit color jobs already carry encoded pixels and use the SDMA owner.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
pub const Owner = struct {
    memory: ?r4os.driver_memory.Context = null,
    reference: a.GfxBufferReference = .{},
    read: a.GfxBufferMap = .{},
    pub fn step(self: *Owner, memory: r4os.driver_memory.Context, reference: a.GfxBufferReference, frame: *@import("display_buffers.zig").Image) !bool {
        if (frame.ready or frame.initialized or frame.reachable or frame.window.value.cpu_address == 0 or
            frame.shape.format != a.gfx_buffer_format_xrgb8888) return error.State;
        const bytes = @as(u64, frame.shape.width) * frame.shape.height * 4;
        if (self.memory == null) {
            self.memory = memory;
            if (reference.version != 1 or reference.size < @sizeOf(a.GfxBufferReference) or reference.flags != 0 or reference.reserved0 != 0 or
                memory.bufferImport(&reference.reference, &self.reference) != 1 or !std.meta.eql(self.reference.buffer, reference.buffer)) return error.Stale;
            var descriptor: a.GfxBufferDescriptor = .{};
            if (memory.bufferDescribe(&self.reference.reference, &descriptor) != 1 or descriptor.version != 1 or descriptor.size < @sizeOf(a.GfxBufferDescriptor) or
                descriptor.location != a.gfx_buffer_location_system or descriptor.format != a.gfx_buffer_format_xrgb8888 or descriptor.modifier != 0 or
                descriptor.width != frame.shape.width or descriptor.height != frame.shape.height or descriptor.plane_count != 1 or
                descriptor.plane_offsets[0] != 0 or descriptor.plane_pitches[0] != @as(u64, frame.shape.width) * 4 or descriptor.byte_length != bytes or
                descriptor.usage & (a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_cpu_read) !=
                    (a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_cpu_read)) return error.Invalid;
            if (memory.bufferMap(&self.reference.reference, a.gfx_buffer_map_read, 0, bytes, &self.read) != 1) return error.Map;
            if (self.read.lease.id == 0 or self.read.lease.generation == 0 or self.read.cpu_address == 0 or self.read.byte_length != bytes or
                self.read.cpu_address > std.math.maxInt(u64) - bytes) return error.Map;
        }
        const source: [*]const u8 = @ptrFromInt(self.read.cpu_address);
        const target: [*]volatile u8 = @ptrFromInt(frame.window.value.cpu_address);
        const stop = @min(frame.shape.height, frame.copied + @max(@as(u32, 1), 262144 / frame.shape.pitch));
        for (frame.copied..stop) |y| {
            for (0..frame.shape.width) |x| {
                const offset = (y * frame.shape.width + x) * 4;
                const pixel = @import("display_color.zig").limitedPixel(std.mem.readInt(u32, source[offset..][0..4], .little));
                inline for (0..4) |byte| target[y * frame.shape.pitch + x * 4 + byte] = @truncate(pixel >> (byte * 8));
            }
            for (frame.shape.width * 4..frame.shape.pitch) |x| target[y * frame.shape.pitch + x] = 0;
        }
        frame.copied = stop;
        if (stop != frame.shape.height) return false;
        for (@as(usize, frame.shape.pitch) * frame.shape.height..@intCast(frame.shape.bytes)) |i| target[i] = 0;
        try frame.memory.?.registers.barrier(); frame.initialized = true; return true;
    }
    pub fn close(self: *Owner) bool {
        const memory = self.memory orelse return true;
        if (self.read.lease.id != 0) {
            if (memory.bufferUnmap(&self.read.lease) != 1) return false;
            self.read = .{};
        }
        if (self.reference.reference.id != 0) {
            if (memory.bufferRelease(&self.reference.reference) != 1) return false;
            self.reference = .{};
        }
        self.memory = null; return true;
    }
};
