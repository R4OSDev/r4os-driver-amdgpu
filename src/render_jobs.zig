// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Single SIMD driver-worker owner. Queue leases, DMA/PTE mappings and the
//! per-job parameter slot survive until the exact GPU fence or proven stop.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const api = @import("r4amd_driver");
const c = api.c;
const batch = api.batch;
const mem = @import("memory_owner.zig");
const Mapping = @import("memory_mapping.zig").Mapping;
const q = @import("queue_timeline.zig");
const Contexts = @import("gc_contexts.zig");
const Virtual = @import("render_virtual.zig");
const pm4 = @import("native_pm4.zig");
const Error = @import("start_common.zig").Error;
pub const capacity = 8;
pub const max_pages = 64 * 1024 * 1024 / 4096;
pub const program_va: u64 = 0x8100000000;
pub const resource_va: u64 = 0x4200000000;
pub const parameter_offset = 32768;
pub const operations: u64 = (@as(u64, 1) << a.gfx_queue_operation_render) | (@as(u64, 1) << a.gfx_queue_operation_render_list) |
    (@as(u64, 1) << a.gfx_queue_operation_render_grid_list) | (@as(u64, 1) << a.gfx_queue_operation_render_color_list) | (@as(u64, 1) << a.gfx_queue_operation_render_color_grid_list) | (@as(u64, 1) << a.gfx_queue_operation_native);
pub fn supports(operation: u32) bool {
    return operation < 64 and operations & (@as(u64, 1) << @as(u6, @intCast(operation))) != 0;
}
const Job = struct {
    owner: ?*Owner = null,
    fence: a.GfxFence = .{},
    enqueued: bool = false,
    pending: ?a.GfxDriverJob = null,
    order: u64 = 0,
    until: u64 = 0,
    jpeg_cpu: a.GfxBufferMap = .{},
    jpeg_commands: [2048]u32 = undefined,
    retired: bool = false,
    result: u32 = a.gfx_queue_result_failed,
    maps: [2]Mapping = .{ .{}, .{} },
    references: [2]a.GfxBufferReference = .{ .{}, .{} },
    held: [2]bool = .{ false, false },
    native: [pm4.max_resources]?*Virtual.Binding = @splat(null),
    native_serial: [pm4.max_resources]u64 = @splat(0),
    native_held: [pm4.max_resources]bool = @splat(false),
    pages: [2][max_pages]u64 = undefined,
    fn retire(raw: usize, fence: a.GfxFence) bool {
        const self: *Job = @ptrFromInt(raw);
        const owner = self.owner orelse return false;
        if (!std.meta.eql(self.fence, fence)) return false;
        const memory = owner.memory.?;
        if (self.jpeg_cpu.lease.id != 0) {
            if (memory.memory.?.bufferUnmap(&self.jpeg_cpu.lease) != 1) return false;
            self.jpeg_cpu = .{};
        }
        for (&self.native, &self.native_serial, &self.native_held) |*part, *serial, *held| {
            if (part.*) |binding| {
                if (binding.serial != serial.*) return false;
                if (held.*) {
                    binding.map.complete(fence) catch return false;
                    held.* = false;
                }
                part.* = null;
                serial.* = 0;
            }
        }
        for (&self.maps, &self.held) |*map, *held| {
            if (held.*) {
                map.complete(fence) catch return false;
                held.* = false;
            }
            if (!map.close(&memory.virtual, &memory.registers)) return false;
        }
        for (&self.references) |*ref| if (ref.reference.id != 0) {
            if (memory.memory.?.bufferRelease(&ref.reference) != 1) return false;
            ref.* = .{};
        };
        self.retired = true;
        return true;
    }
    fn clear(self: *Job) void {
        self.owner = null;
        self.fence = .{};
        self.enqueued = false;
        self.pending = null;
        self.order = 0;
        self.until = 0;
        self.retired = false;
        self.result = a.gfx_queue_result_failed;
    }
};
pub const Owner = struct {
    self_address: usize = 0,
    memory: ?*mem.Owner = null,
    rt: ?*@import("queue_runtime.zig").Owner = null,
    media: ?*@import("vcn_runtime.zig").Owner = null,
    contexts: ?*Contexts.Owner = null,
    context: ?Contexts.Handle = null,
    compute_context: ?Contexts.Handle = null,
    architecture: c.R4AmdArchitecture = undefined,
    virtual: Virtual.Owner = .{},
    allocations: @import("render_allocation.zig").Owner = .{},
    window: @import("memory_io.zig").Window = .{},
    pages: [16]u64 = undefined,
    translated: bool = false,
    flush_pending: bool = false,
    ready: bool = false,
    close_step: enum { idle, renderer_identity, render_jobs, allocation_provider, virtual_provider, render_context, compute_context, render_unmap, render_flush, render_window, render_mapping_count, closed } = .idle,
    admission: u64 = 0,
    failure_reports: u8 = 0,
    submit_step: enum { validate, decode, retain, describe, image, adopt, map, encode, payload, hold, enqueue } = .validate,
    jobs: [capacity]Job = @splat(.{}),
    scratch: [65536]u8 align(16) = undefined,
    payload: [4096]u8 = undefined,
    commands: [batch.max_words]u32 = undefined,
    pub fn prepare(self: *Owner, memory: *mem.Owner, rt: *@import("queue_runtime.zig").Owner, contexts: *Contexts.Owner, arch: c.R4AmdArchitecture) Error!void {
        if (self.self_address != 0 or !memory.prepared or !memory.controller.enabled or contexts.self_address != @intFromPtr(contexts) or
            memory.mapping_users >= 128 or arch.memory_generation != memory.epoch) return error.Unconfirmed;
        const layout = memory.layout.?;
        const Span = @import("memory_layout.zig").Span;
        for ([_]Span{ .{ .offset = program_va, .bytes = 65536 }, .{ .offset = resource_va, .bytes = capacity * 0x10000000 } }) |span|
            if (span.overlaps(layout.mc) or span.overlaps(layout.gart)) return error.Invalid;
        if (layout.render.span.bytes != 65536 or api.render.programBytes() > parameter_offset) return error.Capacity;
        self.self_address = @intFromPtr(self);
        self.memory = memory;
        self.rt = rt;
        self.contexts = contexts;
        self.architecture = arch;
        memory.mapping_users += 1;
        try self.window.open(memory.memory.?, layout.physical.offset, layout.physical.bytes, layout.render.span.offset, layout.render.span.bytes, true);
        const bytes: [*]volatile u8 = @ptrFromInt(self.window.value.cpu_address);
        api.render.upload(bytes[0..api.render.programBytes()]) catch return error.Capacity;
        for (bytes[api.render.programBytes()..65536]) |*byte| byte.* = 0;
        const physical = try layout.physicalAddress(layout.render.span);
        for (&self.pages, 0..) |*page, i| page.* = physical + i * 4096;
        try memory.virtual.map(program_va, &self.pages, .{ .system = false, .write = false, .execute = true });
        self.translated = true;
        self.flush_pending = true;
        try memory.controller.flush(&memory.registers, 1);
        self.flush_pending = false;
        try @import("start_common.zig").hdpFlush(&memory.registers);
        self.context = try contexts.create(.gfx, .normal, .{});
        self.compute_context = try contexts.create(.compute, .normal, .{});
        try self.virtual.prepare(memory, rt);
        try self.allocations.prepare(memory, rt, arch);
        self.ready = true;
    }
    pub fn available(self: *const Owner) bool {
        if (!self.ready) return false;
        for (&self.jobs) |*job| if (job.owner == null) return true;
        return false;
    }
    pub fn collect(self: *Owner) bool {
        var idle = true;
        for (&self.jobs) |*job| {
            if (job.owner == null) continue;
            if (job.pending != null) { idle = false; continue; }
            if (job.enqueued) {
                if (job.retired and !self.contexts.?.contains(job.fence)) job.clear() else idle = false;
            } else if (Job.retire(@intFromPtr(job), job.fence) and self.rt.?.queue.?.complete(&job.fence, job.result, 1) == 1) job.clear() else idle = false;
        }
        return idle;
    }
    pub fn work(self: *Owner) void {
        if (!self.ready) return;
        _ = self.allocations.step();
        _ = self.virtual.step();
        for (&self.jobs, 0..) |*job, index| if (job.pending) |input| {
            job.pending = null;
            self.submit(job, index, input) catch |err| self.reportFailure(job, input, err);
        };
    }
    /// Caller checks available before consuming a canonical job. Even partial
    /// validation failure transfers ownership here until cleanup is confirmed.
    pub fn accept(self: *Owner, input: a.GfxDriverJob) void {
        std.debug.assert(self.available());
        for (&self.jobs, 0..) |*job, index| if (job.owner == null) {
            job.owner = self;
            job.fence = input.fence;
            if (self.admission == std.math.maxInt(u64)) return;
            self.admission += 1;
            job.order = self.admission;
            self.submit(job, index, input) catch |err| self.reportFailure(job, input, err);
            return;
        };
        unreachable;
    }
    fn submit(self: *Owner, job: *Job, index: usize, input: a.GfxDriverJob) Error!void {
        self.submit_step = .validate;
        if (input.operation == a.gfx_queue_operation_native) return self.submitYuv(job, index, input);
        const memory = self.memory.?;
        const queue = self.rt.?.queue.?;
        if (input.version != 1 or input.size < @sizeOf(a.GfxDriverJob) or !self.rt.?.timeline.epoch.matches(input.fence) or !supports(input.operation) or
            input.reserved0 != 0 or input.reserved1 != 0 or input.source_offset != 0 or input.target_offset != 0 or input.byte_length != 0 or
            input.row_count != 0 or input.source_pitch != 0 or input.target_pitch != 0 or input.render.reserved0 != 0 or
            std.meta.eql(input.source_buffer, input.target_buffer)) return error.Invalid;
        self.submit_step = .decode;
        var list: a.GfxRenderList = .{};
        var grids: [16]a.GfxSampleGrid = @splat(.{});
        var color: ?batch.Color = null;
        const has_color = input.operation == a.gfx_queue_operation_render_color_list or input.operation == a.gfx_queue_operation_render_color_grid_list;
        const has_grid = input.operation == a.gfx_queue_operation_render_grid_list or input.operation == a.gfx_queue_operation_render_color_grid_list;
        if (has_color) {
            var mapped: a.GfxRenderColorList = .{};
            if (queue.readRenderColorList(&input.fence, &mapped) != 1 or mapped.version != 1 or mapped.size != @sizeOf(a.GfxRenderColorList) or mapped.reserved0 != 0 or
                mapped.program.version != 1 or mapped.program.size != @sizeOf(a.GfxRenderColorProgram) or mapped.program.reserved0 != 0) return error.Invalid;
            list = .{ .count = mapped.count, .commands = mapped.commands };
            color = .{ .words = mapped.program.words };
        }
        if (has_grid) {
            var mapped: a.GfxRenderGridList = .{};
            if (queue.readRenderGridList(&input.fence, &mapped) != 1 or mapped.version != 1 or mapped.size != @sizeOf(a.GfxRenderGridList) or mapped.reserved0 != 0) return error.Invalid;
            const actual: a.GfxRenderList = .{ .count = mapped.count, .commands = mapped.commands };
            if (has_color and !std.meta.eql(list, actual)) return error.Invalid;
            list = actual;
            grids = mapped.grids;
        } else if (!has_color) {
            if (input.operation == a.gfx_queue_operation_render) {
                list.count = 1;
                list.commands[0] = input.render;
            } else if (queue.readRenderList(&input.fence, &list) != 1) return error.Invalid;
        }
        if (list.version != 1 or list.size != @sizeOf(a.GfxRenderList) or list.reserved0 != 0 or list.count == 0 or list.count > 16 or !std.meta.eql(list.commands[0], input.render)) return error.Invalid;
        for (list.count..16) |i| if (!std.meta.eql(list.commands[i], a.GfxRenderCommand{}) or !std.meta.eql(grids[i], a.GfxSampleGrid{})) return error.Invalid;
        var views: [2]?batch.Image = .{ null, null };
        for ((if (input.render.kind == a.gfx_render_kind_sample) @as(usize, 0) else 1)..2) |side| {
            self.submit_step = .retain;
            if (queue.retainResource(&input.fence, @intCast(side), &job.references[side]) != 1) return error.Stale;
            var desc: a.GfxBufferDescriptor = .{};
            self.submit_step = .describe;
            if (memory.memory.?.bufferDescribe(&job.references[side].reference, &desc) != 1 or desc.byte_length == 0 or desc.byte_length > 64 * 1024 * 1024 or
                !std.meta.eql(job.references[side].buffer, if (side == 0) input.source_buffer else input.target_buffer)) return error.Invalid;
            const address = resource_va + index * 0x10000000 + side * 0x08000000;
            self.submit_step = .image;
            views[side] = batch.image(self.architecture, memory.adapter, desc, address, side == 1, if (side == 1) 0 else input.render.filter, &self.scratch) catch return error.Invalid;
            self.submit_step = .adopt;
            try job.maps[side].adopt(memory, &job.references[side], address, job.pages[side][0..@intCast((desc.byte_length + 4095) / 4096)]);
            self.submit_step = .map;
            try job.maps[side].publish(&memory.virtual, &memory.registers, side == 1, false);
        }
        const offset = parameter_offset + index * 4096;
        self.submit_step = .encode;
        const count = batch.encode(views[0], views[1].?, list.commands[0..list.count], grids[0..list.count], color, program_va, program_va + offset, &self.payload, &self.commands) catch return error.Invalid;
        return self.publish(job, input, offset, count);
    }
    fn reportFailure(self: *Owner, job: *const Job, input: a.GfxDriverJob, failure: Error) void {
        if (self.failure_reports >= 4) return;
        const rt = self.rt orelse return;
        const ctx = rt.ctx orelse return;
        self.failure_reports += 1;
        var text: [256]u8 = undefined;
        const message = std.fmt.bufPrintZ(&text, "AMDGPU render-submit: error={s} step={s} slot={d} timeline={d} point={d} operation={d} enqueued={} maps={}/{}; exact cleanup retained", .{
            @errorName(failure), @tagName(self.submit_step), input.fence.slot, input.fence.timeline, input.fence.point,
            input.operation, job.enqueued, job.maps[0].ready, job.maps[1].ready }) catch return;
        ctx.logError(message);
    }
    fn submitYuv(self: *Owner, job: *Job, index: usize, input: a.GfxDriverJob) Error!void {
        const memory = self.memory.?;
        const queue = self.rt.?.queue.?;
        if (input.version != 1 or input.size < @sizeOf(a.GfxDriverJob) or !self.rt.?.timeline.epoch.matches(input.fence) or
            input.reserved0 != 0 or input.reserved1 != 0 or input.source_offset != 0 or input.target_offset != 0 or input.byte_length != 0 or
            input.row_count != 0 or input.source_pitch != 0 or input.target_pitch != 0 or !std.meta.eql(input.render, a.GfxRenderCommand{}) or
            !std.meta.eql(input.source_buffer, a.GfxBufferHandle{}) or !std.meta.eql(input.target_buffer, a.GfxBufferHandle{})) return error.Invalid;
        var info: a.GfxNativeJobInfo = .{};
        if (queue.nativeInfo(&input.fence, &info) != 1 or info.version != 1 or info.size != @sizeOf(a.GfxNativeJobInfo) or info.reserved0 != 0 or
            info.interface_id_lo != c.backend_v1_header.interface_id_lo or info.interface_id_hi != c.backend_v1_header.interface_id_hi) return error.Unsupported;
        if (info.revision != 1) return error.Unsupported;
        // Backend protocol revision stays compatible with the YUV command.
        // Its 504-byte packet cannot collide with a 32+16*N PM4 packet.
        if (info.command_bytes != @sizeOf(api.yuv.Packet)) return self.submitPm4(job, input, info);
        if (info.resource_count < 2 or info.resource_count > 4) return error.Unsupported;
        var packet: api.yuv.Packet = undefined;
        if (queue.nativeData(&input.fence, 0, std.mem.asBytes(&packet)) != 1 or packet.header.target_binding >= info.resource_count) return error.Stale;
        var views: [4]api.yuv.Bound = undefined;
        for (0..info.resource_count) |i| {
            var value: a.GfxNativeBinding = .{};
            if (queue.nativeBinding(&input.fence, @intCast(i), &value) != 1 or value.access != @as(u32, @intFromBool(i == packet.header.target_binding))) return error.Invalid;
            const binding = try self.virtual.execution(value);
            for (job.native[0..i]) |prior| if (prior == binding) return error.Invalid;
            job.native[i] = binding;
            job.native_serial[i] = binding.serial;
            views[i] = .{ .descriptor = binding.descriptor, .address = binding.map.address };
        }
        // Distinct VA bindings may still refer to one physical BO. Reject
        // source/target feedback through any alias before publishing a draw.
        const target = job.native[packet.header.target_binding].?;
        for (job.native[0..info.resource_count], 0..) |part, i| if (i != packet.header.target_binding and
            std.meta.eql(part.?.map.reference.buffer, target.map.reference.buffer)) return error.Invalid;
        const offset = parameter_offset + index * 4096;
        const count = api.yuv.encode(self.architecture, memory.adapter, packet, views[0..info.resource_count], program_va, program_va + offset, &self.scratch, &self.payload, &self.commands) catch return error.Invalid;
        return self.publish(job, input, offset, count);
    }
    fn submitPm4(self: *Owner, job: *Job, input: a.GfxDriverJob, info: a.GfxNativeJobInfo) Error!void {
        const queue = self.rt.?.queue.?;
        if (info.resource_count == 0 or info.resource_count > pm4.max_resources or
            info.command_bytes < @sizeOf(c.R4AmdNativeSubmit) or info.command_bytes > @sizeOf(c.R4AmdNativeSubmit) + pm4.max_ibs * @sizeOf(c.R4AmdNativeIb)) return error.Invalid;
        var header: c.R4AmdNativeSubmit = undefined;
        if (queue.nativeData(&input.fence, 0, std.mem.asBytes(&header)) != 1 or header.ib_count == 0 or header.ib_count > pm4.max_ibs or
            info.command_bytes != @sizeOf(c.R4AmdNativeSubmit) + header.ib_count * @sizeOf(c.R4AmdNativeIb)) return error.Invalid;
        var ibs: [pm4.max_ibs]c.R4AmdNativeIb = undefined;
        if (queue.nativeData(&input.fence, @sizeOf(c.R4AmdNativeSubmit), std.mem.sliceAsBytes(ibs[0..header.ib_count])) != 1) return error.Stale;
        const media = header.engine >= 2 and header.engine <= 4;
        const engine: @import("queue_ring.zig").Engine = if (header.engine == 4) .jpeg else if (header.engine == 2) .decode else .encode;
        if (media) {
            if (self.media == null or !self.media.?.verified or header.ib_count != 1 or ibs[0].dwords > 2048 or ibs[0].dwords & 15 != 0) return error.Unsupported;
            const now = self.memory.?.registers.nowNs();
            if (job.until == 0) job.until = @min(input.deadline_ns, std.math.add(u64, now, 2_000_000_000) catch return error.Deadline);
            if (now >= job.until) return error.Deadline;
            var available_now = try self.media.?.canSubmit(engine);
            for (&self.jobs) |*prior| if (prior.pending != null and prior.order < job.order) { available_now = false; break; };
            if (!available_now) { job.pending = input; return; }
        }
        var bindings: [pm4.max_resources]a.GfxNativeBinding = undefined;
        for (bindings[0..info.resource_count], 0..) |*value, i| {
            if (queue.nativeBinding(&input.fence, @intCast(i), value) != 1) return error.Stale;
            const binding = try self.virtual.execution(value.*);
            for (job.native[0..i]) |prior| if (prior == binding) return error.Invalid;
            job.native[i] = binding;
            job.native_serial[i] = binding.serial;
        }
        var validation = header;
        if (media) validation.engine = 0;
        const count = try pm4.encode(validation, ibs[0..header.ib_count], bindings[0..info.resource_count], &self.commands);
        if (media and engine == .jpeg) {
            const source = job.native[ibs[0].binding_index].?;
            if (source.descriptor.location != a.gfx_buffer_location_system) return error.Unsupported;
            const bytes = @as(u64, ibs[0].dwords) * 4;
            if (self.memory.?.memory.?.bufferMap(&source.map.reference.reference, a.gfx_buffer_map_read,
                ibs[0].address - source.map.address, bytes, &job.jpeg_cpu) != 1) return error.Busy;
            const cpu = job.jpeg_cpu;
            if (cpu.version != 1 or cpu.size < @sizeOf(a.GfxBufferMap) or cpu.lease.id == 0 or cpu.lease.generation == 0 or cpu.lease.reserved0 != 0 or
                cpu.cpu_address == 0 or cpu.cpu_address & 3 != 0 or cpu.byte_length != bytes or cpu.reserved0 != 0 or
                cpu.cpu_address > std.math.maxInt(u64) - bytes or cpu.cache_policy != a.gfx_buffer_cache_write_back) return error.Invalid;
            const src: [*]const volatile u32 = @ptrFromInt(cpu.cpu_address);
            for (job.jpeg_commands[0..ibs[0].dwords], 0..) |*word, i| word.* = src[i];
            if (self.memory.?.memory.?.bufferUnmap(&job.jpeg_cpu.lease) != 1) return error.Busy;
            job.jpeg_cpu = .{};
        }
        for (job.native[0..info.resource_count], job.native_held[0..info.resource_count]) |part, *held| {
            try part.?.map.retain(input.fence);
            held.* = true;
        }
        const memory = self.memory.?;
        try @import("start_common.zig").hdpFlush(&memory.registers);
        const now = memory.registers.nowNs();
        const deadline = @min(input.deadline_ns, std.math.add(u64, now, 2_000_000_000) catch return error.Deadline);
        if (media) {
            // Timeline now owns the exact retained bindings, including on an
            // uncertain kick. Preflight failures are handled by normal reaping.
            self.media.?.submit(engine, input.fence,
                .{ .address = ibs[0].address, .dwords = ibs[0].dwords },
                if (engine == .jpeg) job.jpeg_commands[0..ibs[0].dwords] else &.{}, @min(deadline, job.until),
                .{ .context = @intFromPtr(job), .retire = Job.retire }) catch |err| {
                    for (&self.rt.?.timeline.entries) |*entry| if (entry.phase != .free and !entry.internal and std.meta.eql(entry.fence, input.fence)) { job.enqueued = true; break; };
                    return err;
                };
            job.enqueued = true;
            return;
        }
        const handle = if (header.engine == 0) self.context.? else self.compute_context.?;
        try self.contexts.?.enqueue(handle, input.fence, now, deadline, self.commands[0..count], .{ .context = @intFromPtr(job), .retire = Job.retire });
        job.enqueued = true;
    }
    fn publish(self: *Owner, job: *Job, input: a.GfxDriverJob, offset: usize, count: usize) Error!void {
        const memory = self.memory.?;
        if (count == 0) {
            job.result = a.gfx_queue_result_complete;
            return;
        }
        self.submit_step = .payload;
        const bytes: [*]volatile u8 = @ptrFromInt(self.window.value.cpu_address + offset);
        for (&self.payload, bytes[0..4096]) |src, *dst| dst.* = src;
        try @import("start_common.zig").hdpFlush(&memory.registers);
        self.submit_step = .hold;
        for (&job.maps, &job.held) |*map, *held| if (map.ready) {
            try map.retain(input.fence);
            held.* = true;
        };
        for (&job.native, &job.native_held) |*part, *held| if (part.*) |binding| {
            try binding.map.retain(input.fence);
            held.* = true;
        };
        const now = memory.registers.nowNs();
        const deadline = @min(input.deadline_ns, std.math.add(u64, now, 2_000_000_000) catch return error.Deadline);
        self.submit_step = .enqueue;
        try self.contexts.?.enqueue(self.context.?, input.fence, now, deadline, self.commands[0..count], .{ .context = @intFromPtr(job), .retire = Job.retire });
        job.enqueued = true;
    }
    /// GC has already stopped, aborted its timeline and retired its contexts.
    pub fn close(self: *Owner) bool {
        if (self.self_address == 0) return true;
        self.close_step = .renderer_identity;
        if (self.self_address != @intFromPtr(self)) return false;
        self.ready = false;
        for (&self.jobs) |*job| job.pending = null;
        self.close_step = .render_jobs;
        if (!self.collect()) return false;
        const memory = self.memory.?;
        self.close_step = .allocation_provider;
        if (!self.allocations.close()) return false;
        self.close_step = .virtual_provider;
        if (!self.virtual.close()) return false;
        if (self.context) |handle| {
            self.close_step = .render_context;
            self.contexts.?.destroy(handle) catch return false;
            self.context = null;
        }
        if (self.compute_context) |handle| {
            self.close_step = .compute_context;
            self.contexts.?.destroy(handle) catch return false;
            self.compute_context = null;
        }
        if (self.translated) {
            self.close_step = .render_unmap;
            memory.virtual.unmap(program_va, self.pages.len) catch return false;
            self.translated = false;
            self.flush_pending = true;
        }
        if (self.flush_pending) {
            self.close_step = .render_flush;
            memory.controller.flush(&memory.registers, 1) catch return false;
            self.flush_pending = false;
        }
        self.close_step = .render_window;
        if (!self.window.close()) return false;
        self.close_step = .render_mapping_count;
        if (memory.mapping_users == 0) return false;
        memory.mapping_users -= 1;
        self.self_address = 0;
        self.memory = null;
        self.rt = null;
        self.contexts = null;
        self.close_step = .closed;
        return true;
    }
};
