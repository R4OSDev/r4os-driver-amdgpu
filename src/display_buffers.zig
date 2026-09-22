// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Private linear UMA scanout images and the portable CPU console shadow.
//! Only the serialized native/queue worker mutates memory.Owner or its pool.
//! The display task borrows these exact retained references; it never frees BOs.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const mem = @import("memory_owner.zig");
const l = @import("memory_layout.zig");
const io = @import("memory_io.zig");
const mapping = @import("memory_mapping.zig");
const life = @import("scanout_lifetime.zig");
pub const max_bytes = 64 * 1024 * 1024;
pub const gpu_base: u64 = 0x6000000000;
pub const Shape = struct {
    width: u32, height: u32, pitch: u32, bytes: u64, format: u32,
    pub fn make(width: u32, height: u32, cursor: bool) !Shape {
        if (width == 0 or height == 0 or width > (if (cursor) @as(u32, 64) else 4096) or height > (if (cursor) @as(u32, 64) else 4096)) return error.Invalid;
        const pitch = if (cursor) 256 else try l.aligned(@as(u64, width) * 4, 256);
        const bytes = try l.aligned(pitch * height, 4096);
        if (bytes > max_bytes) return error.Capacity;
        return .{ .width = width, .height = height, .pitch = @intCast(pitch), .bytes = bytes,
            .format = if (cursor) a.gfx_buffer_format_argb8888 else a.gfx_buffer_format_xrgb8888 };
    }
    pub fn descriptor(self: Shape, memory: *const mem.Owner) a.GfxBufferDescriptor {
        return .{ .width = self.width, .height = self.height, .byte_length = self.bytes, .format = self.format, .plane_count = 1,
            .plane_pitches = .{ self.pitch, 0, 0, 0 }, .usage = a.gfx_buffer_usage_scanout | a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_transfer_target,
            .location = a.gfx_buffer_location_device_local, .adapter_id = memory.adapter, .device_generation = memory.epoch };
    }
};
pub const Image = struct {
    self_address: usize = 0,
    memory: ?*mem.Owner = null,
    epoch: u64 = 0,
    shape: Shape = undefined,
    reference: a.GfxBufferReference = .{},
    mc_address: u64 = 0,
    gpu_address: u64 = 0,
    map: mapping.Mapping = .{},
    window: io.Window = .{},
    pages: [max_bytes / 4096]u64 = undefined,
    copied: u32 = 0,
    initialized: bool = false,
    reachable: bool = false,
    ready: bool = false,
    copy_token: u64 = 0,
    pub fn allocate(self: *Image, memory: *mem.Owner, shape: Shape, slot: u8) !void {
        if (self.self_address != 0 or slot >= 16 or memory.self_address != @intFromPtr(memory) or !memory.prepared or
            memory.engine_users == std.math.maxInt(u32) or !memory.controller.enabled or memory.controller.epoch != memory.epoch) return error.State;
        if (!std.meta.eql(shape, try Shape.make(shape.width, shape.height, shape.format == a.gfx_buffer_format_argb8888))) return error.Invalid;
        const map = memory.layout.?;
        const va: l.Span = .{ .offset = gpu_base + @as(u64, slot) * max_bytes, .bytes = shape.bytes };
        if (va.overlaps(map.mc) or va.overlaps(map.gart)) return error.Invalid;
        self.self_address = @intFromPtr(self); self.memory = memory; self.epoch = memory.epoch; self.shape = shape;
        memory.engine_users += 1;
        self.reference = try memory.create(shape.descriptor(memory));
        const backing = try memory.backing(self.reference.buffer);
        if (backing.bytes != shape.bytes) return error.Invalid;
        self.mc_address = map.mc.offset + backing.offset - map.physical.offset;
        try self.window.open(memory.memory.?, map.physical.offset, map.physical.bytes, backing.offset - map.physical.offset, backing.bytes, true);
        self.gpu_address = va.offset;
    }
    /// Initialize an unpublished image in bounded row chunks. The immutable
    /// boot capture is a canonical CPU read lease, never a raw old BAR alias.
    pub fn copyBoot(self: *Image, snapshot: *const @import("boot_snapshot.zig").Snapshot) !bool {
        if (self.self_address != @intFromPtr(self) or self.initialized or self.reachable or self.ready or
            !snapshot.valid or !snapshot.effects or snapshot.held_generation == 0 or snapshot.read.lease.id == 0 or
            snapshot.boot.width != self.shape.width or snapshot.boot.height != self.shape.height or self.shape.format != a.gfx_buffer_format_xrgb8888 or
            snapshot.boot.pitch < @as(u64, self.shape.width) * 4 or snapshot.read.byte_length < @as(u64, snapshot.boot.pitch) * snapshot.boot.height or
            snapshot.read.cpu_address == 0 or snapshot.read.cpu_address > std.math.maxInt(u64) - snapshot.read.byte_length or
            self.window.value.cpu_address == 0) return error.State;
        const source: [*]const u8 = @ptrFromInt(snapshot.read.cpu_address);
        const target: [*]volatile u8 = @ptrFromInt(self.window.value.cpu_address);
        const stop = @min(self.shape.height, self.copied + @max(@as(u32, 1), (256 * 1024) / self.shape.pitch));
        for (self.copied..stop) |y| {
            const to = y * self.shape.pitch; const from = y * snapshot.boot.pitch;
            for (0..self.shape.width * 4) |x| target[to + x] = source[from + x];
            for (self.shape.width * 4..self.shape.pitch) |x| target[to + x] = 0;
        }
        self.copied = stop;
        if (stop != self.shape.height) return false;
        for (@as(usize, self.shape.pitch) * self.shape.height..@as(usize, @intCast(self.shape.bytes))) |i| target[i] = 0;
        try self.memory.?.registers.barrier(); self.initialized = true; return true;
    }
    /// Initial additional output is black until its first composed frame.
    /// Keep the same bounded row work and no uninitialized scanout padding.
    pub fn clear(self: *Image) !bool {
        if (self.self_address != @intFromPtr(self) or self.initialized or self.reachable or self.ready or self.window.value.cpu_address == 0) return error.State;
        const target: [*]volatile u8 = @ptrFromInt(self.window.value.cpu_address);
        const begin = @as(usize, self.copied) * self.shape.pitch;
        const stop = @min(self.shape.height, self.copied + @max(@as(u32, 1), (256 * 1024) / self.shape.pitch));
        const end = if (stop == self.shape.height) self.shape.bytes else @as(u64, stop) * self.shape.pitch;
        for (begin..@intCast(end)) |i| target[i] = 0;
        self.copied = stop;
        if (stop != self.shape.height) return false;
        try self.memory.?.registers.barrier(); self.initialized = true; return true;
    }
    /// Caller-provided cursor pixels use premultiplied ARGB. The unused rows
    /// and 64-pixel native pitch remain zero; no old image may be reachable.
    pub fn copyCursor(self: *Image, pixels: []const u32) !void {
        if (self.self_address != @intFromPtr(self) or self.initialized or self.reachable or self.ready or
            self.shape.format != a.gfx_buffer_format_argb8888 or pixels.len != @as(usize, self.shape.width) * self.shape.height or
            self.window.value.cpu_address == 0) return error.State;
        const target: [*]volatile u32 = @ptrFromInt(self.window.value.cpu_address);
        for (0..@as(usize, @intCast(self.shape.bytes / 4))) |i| target[i] = 0;
        for (0..self.shape.height) |y| for (0..self.shape.width) |x| { target[y * 64 + x] = pixels[y * self.shape.width + x]; };
        try self.memory.?.registers.barrier(); self.initialized = true;
    }
    pub fn publish(self: *Image) !void {
        if (!self.initialized) return error.State;
        try self.publishMapping();
    }
    /// A private, still unreachable BO may be initialized by actual SDMA.
    /// Its copy owner sets initialized only after the exact internal fence.
    pub fn publishGpuTarget(self: *Image) !void {
        if (self.initialized) return error.State;
        try self.publishMapping();
    }
    fn publishMapping(self: *Image) !void {
        if (self.self_address != @intFromPtr(self) or self.ready or self.reachable or self.map.self_address != 0) return error.State;
        const memory = self.memory.?;
        if (!self.window.close()) return error.Busy;
        try self.map.prepareNative(memory, self.reference.reference, self.gpu_address, self.pages[0..@intCast(self.shape.bytes / 4096)]);
        try self.map.publish(&memory.virtual, &memory.registers, true, false);
        self.ready = true;
    }
    pub fn scanout(self: *Image) !life.Image {
        if (self.self_address != @intFromPtr(self) or !self.ready or !self.initialized or self.copy_token != 0 or self.memory.?.epoch != self.epoch) return error.Stale;
        self.reachable = true; // Latch before submitting any DCN address write.
        return .{ .reference = self.reference.reference, .address = self.mc_address, .bytes = self.shape.bytes };
    }
    pub fn close(self: *Image, scanout_stopped: bool) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.copy_token != 0 or (self.reachable and !scanout_stopped)) return false;
        const memory = self.memory orelse return false;
        if (memory.self_address != @intFromPtr(memory) or memory.epoch != self.epoch or memory.engine_users == 0) return false;
        // Mapping refuses while an SDMA fence is still using this image.
        if (!self.map.close(&memory.virtual, &memory.registers) or !self.window.close()) return false;
        if (self.reference.reference.id != 0) {
            if (!memory.drop(self.reference.reference)) return false;
            self.reference = .{};
        }
        if (!memory.collect()) return false;
        memory.engine_users -= 1;
        self.self_address = 0; self.memory = null; self.epoch = 0; self.mc_address = 0; self.gpu_address = 0;
        self.copied = 0; self.initialized = false; self.reachable = false; self.ready = false;
        return true;
    }
};

pub const Shadow = struct {
    memory: ?r4os.driver_memory.Context = null,
    reference: a.GfxBufferReference = .{},
    descriptor: a.GfxBufferDescriptor = .{},
    map: a.GfxBufferMap = .{},
    copied: u32 = 0,
    ready: bool = false,
    pub fn create(self: *Shadow, memory: r4os.driver_memory.Context, width: u32, height: u32) !void {
        if (self.memory != null or width == 0 or width > 4096 or height == 0 or height > 4096) return error.Invalid;
        self.memory = memory;
        self.descriptor = .{ .width = width, .height = height, .byte_length = @as(u64, width) * height * 4,
            .format = a.gfx_buffer_format_xrgb8888, .plane_count = 1, .plane_pitches = .{@as(u64, width) * 4, 0, 0, 0},
            .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source };
        if (memory.bufferCreate(&self.descriptor, &self.reference) != 1) return error.Capacity;
        if (!io.handle(self.reference.reference) or !io.handle(self.reference.buffer) or self.reference.flags != 0) return error.Invalid;
        self.ready = true;
    }
    pub fn close(self: *Shadow) bool {
        if (self.memory) |memory| {
            if (self.map.lease.id != 0) {
                if (memory.bufferUnmap(&self.map.lease) != 1) return false;
                self.map = .{};
            }
            if (self.reference.reference.id != 0) {
                if (memory.bufferRelease(&self.reference.reference) != 1) return false;
                self.reference = .{};
            }
        }
        self.* = .{}; return true;
    }
};
