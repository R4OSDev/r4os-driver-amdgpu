// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Existing canonical native allocation requests, serviced by the SIMD worker.
//! AddrLib owns surface geometry; the UMA owner owns physical storage/budget.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const api = @import("r4amd_driver");
const c = api.c;
const l = @import("memory_layout.zig");
const Error = @import("start_common.zig").Error;
pub const Owner = struct {
    memory: ?*@import("memory_owner.zig").Owner = null,
    rt: ?*@import("queue_runtime.zig").Owner = null,
    handle: a.GfxBufferHandle = .{},
    arch: c.R4AmdArchitecture = undefined,
    closing: bool = false,
    pending: ?a.GfxNativeJob = null,
    reference: a.GfxBufferReference = .{},
    result: ?i32 = null,
    acknowledged: bool = false,
    scratch: [65536]u8 align(16) = undefined,
    fn notify(raw: usize) callconv(.c) i32 {
        const self: *Owner = @ptrFromInt(raw);
        @import("queue_runtime.zig").Owner.notify(@intFromPtr(self.rt.?));
        return 0;
    }
    pub fn prepare(self: *Owner, memory: *@import("memory_owner.zig").Owner, rt: *@import("queue_runtime.zig").Owner, arch: c.R4AmdArchitecture) Error!void {
        if (self.memory != null) return error.Busy;
        self.memory = memory;
        self.rt = rt;
        self.arch = arch;
        if (memory.memory.?.nativeRegister(&.{ .adapter_id = memory.adapter, .memory_generation = memory.epoch, .notify = @intFromPtr(&notify), .context = @intFromPtr(self) }, &self.handle) != 1) return error.Unsupported;
    }
    pub fn step(self: *Owner) bool {
        const memory = self.memory orelse return true;
        if (!memory.collect()) return false;
        if (self.pending == null) {
            if (self.closing or self.handle.id == 0) return true;
            var job: a.GfxNativeJob = .{};
            const rc = memory.memory.?.nativeTake(&self.handle, &job);
            if (rc == a.gfx_buffer_error_busy) return true;
            if (rc != 1) return false;
            self.pending = job;
        }
        const job = self.pending.?;
        if (self.result == null) {
            self.result = if (self.closing) a.gfx_queue_error_device_lost else if (job.allocation.deadline_ns <= memory.registers.nowNs()) a.gfx_queue_error_wait_timeout else blk: {
                if (job.version != 1 or job.size < @sizeOf(a.GfxNativeJob)) break :blk a.gfx_buffer_error_invalid;
                self.reference = self.allocate(job.allocation) catch |err| break :blk switch (err) {
                    error.Unsupported => a.gfx_buffer_error_unsupported,
                    error.Capacity => a.gfx_buffer_error_oom,
                    else => a.gfx_buffer_error_invalid,
                };
                break :blk 1;
            };
        }
        if (!self.acknowledged) {
            if (memory.memory.?.nativeComplete(&self.handle, &job.request, self.result.?, &self.reference.reference) != 1) return false;
            self.acknowledged = true;
        }
        if (self.reference.reference.id != 0) {
            if (!memory.drop(self.reference.reference)) return false;
            self.reference = .{};
        }
        self.pending = null;
        self.result = null;
        self.acknowledged = false;
        return true;
    }
    fn allocate(self: *Owner, request: a.GfxNativeAllocation) Error!a.GfxBufferReference {
        const memory = self.memory.?;
        if (request.version != 1 or request.size != @sizeOf(a.GfxNativeAllocation) or request.reserved0 != 0 or request.adapter_id != memory.adapter or
            request.memory_generation != memory.epoch or request.kind > 1 or request.layout > 1 or request.usage == 0 or
            request.usage & (a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write) != 0) return error.Invalid;
        var desc: a.GfxBufferDescriptor = .{ .location = a.gfx_buffer_location_device_local, .adapter_id = memory.adapter, .device_generation = memory.epoch, .alignment = 4096, .usage = request.usage };
        if (request.kind == 0) {
            if (request.width != 0 or request.height != 0 or request.layout != 0 or request.byte_length == 0 or request.byte_length > @import("render_virtual.zig").max_backing_bytes) return error.Unsupported;
            desc.byte_length = try l.aligned(request.byte_length, 4096);
        } else {
            if (request.byte_length != 0 or request.width == 0 or request.height == 0) return error.Invalid;
            const sw: u32 = if (request.layout == 0) 0 else if (request.usage & a.gfx_buffer_usage_scanout != 0) 9 else 10;
            const modifier = api.images.modifier(self.arch.gb_addr_config, sw) orelse return error.Unsupported;
            const image: c.R4AmdImageRequest = .{ .version = 1, .size = @sizeOf(c.R4AmdImageRequest), .gb_addr_config = self.arch.gb_addr_config, .chip_revision = self.arch.chip_revision, .device_id = self.arch.device_id, .gc_version = self.arch.gc_version, .resource_type = 1, .format = request.format, .width = request.width, .height = request.height, .depth = 1, .mip_count = 1, .samples = 1, .usage = c.image_usage_texture | c.image_usage_color |
                (if (request.usage & a.gfx_buffer_usage_scanout != 0) c.image_usage_scanout else 0), .swizzle = sw, .pipe_xor = 0, .pitch = 0, .reserved = 0, .modifier = modifier };
            var layout: c.R4AmdImageLayout = undefined;
            var mip: c.R4AmdMip = undefined;
            if (api.images.calculate(&image, &self.scratch, self.scratch.len, &layout, @ptrCast(&mip), 1) != 0) return error.Unsupported;
            desc.alignment = @max(layout.alignment, 4096);
            desc.byte_length = try l.aligned(layout.byte_length, desc.alignment);
            desc.modifier = modifier;
            desc.width = request.width;
            desc.height = request.height;
            desc.format = request.format;
            desc.plane_count = 1;
            desc.plane_pitches[0] = layout.pitch;
        }
        return memory.create(desc);
    }
    pub fn close(self: *Owner) bool {
        self.closing = true;
        const memory = self.memory orelse return true;
        if (!self.step() or self.pending != null) return false;
        if (self.handle.id != 0) {
            if (memory.memory.?.nativeUnregister(&self.handle) != 1) return false;
            self.handle = .{};
        }
        self.memory = null;
        self.rt = null;
        return true;
    }
};
