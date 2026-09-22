// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Driver-local mode image initialization. A real SDMA IB and token share
//! the queue arena; no synthetic application fence or queue completion.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const sdma = @import("sdma_jobs.zig");
const q = @import("queue_timeline.zig");
const buffers = @import("display_buffers.zig");
const copy = @import("r4amd_copy");
pub const Owner = struct {
    self_address: usize = 0,
    engine: ?*sdma.Owner = null,
    frames: [2]*buffers.Image = undefined,
    reference: a.GfxBufferReference = .{},
    source: @import("memory_mapping.zig").Mapping = .{},
    pages: [buffers.max_bytes / 4096]u64 = undefined,
    commands: [copy.max_words * 2 + 1]u32 = undefined,
    ticket: ?q.Ticket = null,
    armed: bool = false,
    retired: bool = false,
    complete: bool = false,
    failure: ?anyerror = null,
    pub fn begin(self: *Owner, engine: *sdma.Owner, frames: [2]*buffers.Image, reference: a.GfxBufferReference, deadline: u64) !void {
        if (self.self_address != 0 or engine.self_address != @intFromPtr(engine) or !engine.registered or !engine.verified or
            frames[0] == frames[1] or frames[0].memory != engine.memory or frames[1].memory != engine.memory or
            !std.meta.eql(frames[0].shape, frames[1].shape)) return error.State;
        for (frames) |frame| if (!frame.ready or frame.initialized or frame.reachable or frame.copy_token != 0) return error.State;
        self.self_address = @intFromPtr(self); self.engine = engine; self.frames = frames;
        self.submit(reference, deadline) catch |err| {
            self.failure = err;
            if (self.armed) engine.runtime.?.timeline.fault(1)
            else if (self.ticket) |ticket| engine.runtime.?.timeline.cancelUnsubmitted(ticket) catch {};
            return err;
        };
    }
    fn submit(self: *Owner, reference: a.GfxBufferReference, deadline: u64) !void {
        const memory = self.engine.?.memory.?; const runtime = self.engine.?.runtime.?;
        if (reference.version != 1 or reference.size < @sizeOf(a.GfxBufferReference) or reference.flags != 0 or reference.reserved0 != 0 or
            reference.reference.id == 0 or reference.reference.generation == 0 or deadline <= memory.registers.nowNs()) return error.Stale;
        if (memory.memory.?.bufferImport(&reference.reference, &self.reference) != 1 or !std.meta.eql(self.reference.buffer, reference.buffer)) return error.Stale;
        var descriptor: a.GfxBufferDescriptor = .{};
        if (memory.memory.?.bufferDescribe(&self.reference.reference, &descriptor) != 1) return error.Stale;
        const shape = self.frames[0].shape;
        if (descriptor.version != 1 or descriptor.size < @sizeOf(a.GfxBufferDescriptor) or descriptor.width != shape.width or descriptor.height != shape.height or
            descriptor.location != a.gfx_buffer_location_system or descriptor.format != a.gfx_buffer_format_xrgb8888 or descriptor.modifier != 0 or
            descriptor.plane_count != 1 or descriptor.plane_offsets[0] != 0 or descriptor.plane_pitches[0] != @as(u64, shape.width) * 4 or
            descriptor.byte_length != descriptor.plane_pitches[0] * shape.height or descriptor.byte_length > buffers.max_bytes or
            descriptor.usage & a.gfx_buffer_usage_transfer_source == 0) return error.Invalid;
        const va: @import("memory_layout.zig").Span = .{ .offset = 0x6200000000, .bytes = buffers.max_bytes };
        if (va.overlaps(memory.layout.?.mc) or va.overlaps(memory.layout.?.gart)) return error.Invalid;
        try self.source.adoptReference(memory, &self.reference, va.offset, self.pages[0..@intCast((descriptor.byte_length + 4095) / 4096)]);
        try self.source.publish(&memory.virtual, &memory.registers, false, false);
        var count: usize = 0;
        for (self.frames) |frame| {
            count += try copy.encodeFill(self.commands[count..], .{ .target = frame.map.address, .bytes = shape.bytes, .value = 0 });
            count += try copy.encodeCopy(self.commands[count..], .{ .source = self.source.address, .target = frame.map.address,
                .bytes = @as(u64, shape.width) * 4, .rows = shape.height, .source_pitch = descriptor.plane_pitches[0], .target_pitch = shape.pitch });
        }
        self.commands[count] = 0; count += 1;
        const ticket = try runtime.timeline.reserveInternal(.sdma, deadline, .{ .context = self.self_address, .retire = retire });
        self.ticket = ticket;
        for (self.frames) |frame| frame.copy_token = ticket.token;
        try self.engine.?.submitIndirect(ticket, self.commands[0..count], deadline, &self.armed);
    }
    fn retire(raw: usize, fence: a.GfxFence) bool {
        const self: *Owner = @ptrFromInt(raw);
        if (self.self_address != raw or !std.meta.eql(fence, a.GfxFence{}) or self.ticket == null) return false;
        const entry = self.engine.?.runtime.?.timeline.entry(self.ticket.?) catch return false;
        if (!entry.internal or entry.phase != .retiring) return false;
        if (!self.cleanup()) return false;
        for (self.frames) |frame| {
            if (frame.copy_token != self.ticket.?.token) return false;
        }
        self.complete = self.armed and entry.result == a.gfx_queue_result_complete;
        for (self.frames) |frame| { frame.copy_token = 0; frame.initialized = self.complete; }
        self.retired = true; return true;
    }
    fn cleanup(self: *Owner) bool {
        const memory = self.engine.?.memory.?;
        if (!self.source.close(&memory.virtual, &memory.registers)) return false;
        if (self.reference.reference.id != 0) {
            if (memory.memory.?.bufferRelease(&self.reference.reference) != 1) return false;
            self.reference = .{};
        }
        return true;
    }
    pub fn poll(self: *Owner) !bool {
        if (self.self_address != @intFromPtr(self)) return error.State;
        const ticket = self.ticket orelse return self.failure orelse error.State;
        _ = self.engine.?.runtime.?.timeline.entry(ticket) catch {
            if (!self.retired) return error.Stale;
            if (!self.complete) return self.failure orelse error.DeviceLost;
            return true;
        };
        return false;
    }
    pub fn close(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        if (self.ticket) |ticket| {
            if (!self.retired) return false;
            if (self.engine.?.runtime.?.timeline.entry(ticket)) |_| return false else |_| {}
        } else if (self.armed) return false;
        if (!self.cleanup()) return false;
        self.self_address = 0; self.engine = null; self.ticket = null;
        self.armed = false; self.retired = false; self.complete = false; self.failure = null;
        return true;
    }
};
