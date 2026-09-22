// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Common upload/present jobs: actual SDMA copy into an inactive private BO,
//! then a DCN flip receipt. Queue completion cannot precede that receipt.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const dc = @import("display_core.zig");
const buffers = @import("display_buffers.zig");
const sdma = @import("sdma_jobs.zig");
const q = @import("queue_timeline.zig");
const copy = @import("r4amd_copy");
pub const source_va: u64 = 0x6100000000;
pub const Plan = struct {
    source: u64, target: u64, row_bytes: u64, rows: u32, source_pitch: u64, target_pitch: u64, preserve: bool,
    pub fn make(input: a.GfxDriverJob, source: a.GfxBufferDescriptor, target: buffers.Shape) !Plan {
        if (!supports(input.operation) or source.version != 1 or source.size < @sizeOf(a.GfxBufferDescriptor) or
            source.width != target.width or source.height != target.height or source.format != a.gfx_buffer_format_xrgb8888 or
            source.modifier != 0 or source.plane_count != 1 or source.plane_offsets[0] != 0 or
            source.usage & a.gfx_buffer_usage_transfer_source == 0 or source.byte_length == 0 or source.byte_length > buffers.max_bytes or
            input.target_buffer.id != 0 or input.target_buffer.generation != 0 or input.target_offset != 0 or input.target_pitch != 0 or
            input.reserved0 != 0 or input.reserved1 != 0) return error.Invalid;
        const pitch = source.plane_pitches[0];
        if (pitch < @as(u64, target.width) * 4 or pitch > buffers.max_bytes or pitch % 4 != 0 or
            try copy.extent(@as(u64, target.width) * 4, pitch, target.height) > source.byte_length) return error.Invalid;
        if (input.operation == a.gfx_queue_operation_present) {
            if (input.source_offset != 0 or input.byte_length != @as(u64, target.width) * 4 or input.row_count != target.height or input.source_pitch != pitch) return error.Invalid;
            return .{ .source = 0, .target = 0, .row_bytes = input.byte_length, .rows = input.row_count,
                .source_pitch = pitch, .target_pitch = target.pitch, .preserve = false };
        }
        // Legacy CPU-console damage owns exactly this span, not the rest of
        // the source. Preserve the prior private image before patching it.
        if (pitch != @as(u64, target.width) * 4 or input.source_offset % 4 != 0 or input.byte_length == 0 or input.byte_length % 4 != 0 or
            input.source_offset >= source.byte_length or input.byte_length > source.byte_length - input.source_offset or
            input.row_count != 0 or input.source_pitch != 0) return error.Invalid;
        const rows = (input.byte_length - 1) / pitch + 1;
        const row_bytes = (input.byte_length - 1) % pitch + 1;
        const x = input.source_offset % pitch; const y = input.source_offset / pitch;
        if (row_bytes % 4 != 0 or x + row_bytes > pitch or y >= target.height or rows > target.height - y) return error.Invalid;
        return .{ .source = input.source_offset, .target = y * target.pitch + x, .row_bytes = row_bytes, .rows = @intCast(rows),
            .source_pitch = pitch, .target_pitch = target.pitch,
            .preserve = x != 0 or y != 0 or row_bytes != pitch or rows != target.height };
    }
};
pub fn supports(operation: u32) bool { return operation == a.gfx_queue_operation_upload or operation == a.gfx_queue_operation_present; }
pub const Owner = struct {
    self_address: usize = 0,
    engine: ?*sdma.Owner = null,
    core: ?*dc.Owner = null,
    epoch: dc.scanout.Epoch = undefined,
    target: a.GfxOutputTarget = .{},
    frames: [2]*buffers.Image = undefined,
    front: u1 = 0,
    back: u1 = 1,
    sequence: u64 = 0,
    input: ?a.GfxDriverJob = null,
    ticket: ?q.Ticket = null,
    reference: a.GfxBufferReference = .{},
    source: @import("memory_mapping.zig").Mapping = .{},
    pages: [buffers.max_bytes / 4096]u64 = undefined,
    commands: [copy.max_words * 2 + 1]u32 = undefined,
    source_held: bool = false,
    frame_held: [2]bool = .{false, false},
    armed: bool = false,
    cleaned: bool = false,
    retired: bool = false,
    phase: enum { idle, copying, flip_retry, flip_wait, sample_wait, ack_wait, failed } = .idle,
    failure: ?anyerror = null,
    failed_output: bool = false,
    receipt: ?dc.scanout.Receipt = null,
    source_fence: a.GfxFence = .{},
    acquired: u64 = 0, rendered: u64 = 0, submitted: u64 = 0, visible: u64 = 0, released: u64 = 0, rejected: u64 = 0,
    pub fn bind(self: *Owner, engine: *sdma.Owner, core: *dc.Owner, frames: [2]*buffers.Image, epoch: dc.scanout.Epoch, target: a.GfxOutputTarget) !void {
        if (self.self_address != 0 or engine.self_address != @intFromPtr(engine) or !engine.registered or !engine.verified or
            core.self_address != @intFromPtr(core) or core.thread != 0 or core.phase != .programmed or
            core.scanout_owner.phase != .active or !std.meta.eql(core.scanout_owner.epoch, epoch) or !std.meta.eql(engine.binding, epoch.backend) or
            target.adapter_id != epoch.output.adapter_id or target.connector_id != epoch.output.connector_id or target.device_generation != epoch.output.device_generation or
            target.connection_generation != epoch.output.connection_generation or target.display_generation != epoch.display or target.head_id != core.mode.pipe or
            frames[0] == frames[1] or frames[0].memory != engine.memory or frames[1].memory != engine.memory or
            !frames[0].ready or !frames[1].ready or !std.meta.eql(frames[0].shape, frames[1].shape) or
            core.scanout_owner.current.?.address != frames[0].mc_address or !std.meta.eql(core.scanout_owner.current.?.reference, frames[0].reference.reference)) return error.State;
        self.self_address = @intFromPtr(self); self.engine = engine; self.core = core; self.frames = frames; self.epoch = epoch; self.target = target;
        self.sequence = core.scanout_owner.sequence;
    }
    pub fn available(self: *const Owner) bool {
        return self.self_address == @intFromPtr(self) and self.phase == .idle and self.input == null and self.failure == null and
            self.core.?.thread == 0 and self.core.?.phase == .programmed and self.core.?.scanout_owner.phase == .active;
    }
    pub fn rebind(self: *Owner, frames: [2]*buffers.Image, epoch: dc.scanout.Epoch, target: a.GfxOutputTarget, receipt: ?dc.scanout.Receipt) !void {
        if (!self.available() or self.source.self_address != 0 or self.reference.reference.id != 0) return error.State;
        if (receipt) |value| if (!std.meta.eql(value.epoch, epoch) or value.image.address != frames[0].mc_address) return error.Stale;
        const address = self.self_address;
        self.self_address = 0;
        self.bind(self.engine.?, self.core.?, frames, epoch, target) catch |err| { self.self_address = address; return err; };
        self.front = 0; self.back = 1;
        if (receipt) |value| {
            self.receipt = value; self.source_fence = .{};
        }
    }
    pub fn accept(self: *Owner, input: a.GfxDriverJob) void {
        std.debug.assert(self.available() and supports(input.operation));
        self.acquired +|= 1;
        self.input = input; self.back = 1 - self.front;
        self.submit() catch |err| {
            self.failure = err; self.phase = .failed; self.rejected +|= 1;
            self.failed_output = self.armed;
            if (self.armed) self.engine.?.runtime.?.timeline.fault(1)
            else if (self.ticket) |ticket| self.engine.?.runtime.?.timeline.cancelUnsubmitted(ticket) catch {};
        };
    }
    fn submit(self: *Owner) !void {
        const input = self.input.?; const engine = self.engine.?; const runtime = engine.runtime.?; const memory = engine.memory.?;
        if (input.version != 1 or input.size < @sizeOf(a.GfxDriverJob) or !runtime.timeline.epoch.matches(input.fence) or
            memory.epoch != self.epoch.memory or self.sequence == std.math.maxInt(u64) or input.deadline_ns <= memory.registers.nowNs() or
            (input.display_target.connector_id != 0 and !std.meta.eql(input.display_target, self.target))) return error.Stale;
        if (runtime.queue.?.retainResource(&input.fence, 0, &self.reference) != 1) return error.Stale;
        var descriptor: a.GfxBufferDescriptor = .{};
        if (!std.meta.eql(self.reference.buffer, input.source_buffer) or memory.memory.?.bufferDescribe(&self.reference.reference, &descriptor) != 1) return error.Invalid;
        const plan = try Plan.make(input, descriptor, self.frames[self.back].shape);
        const source_span: @import("memory_layout.zig").Span = .{ .offset = source_va, .bytes = buffers.max_bytes };
        if (source_span.overlaps(memory.layout.?.mc) or source_span.overlaps(memory.layout.?.gart)) return error.Invalid;
        try self.source.adopt(memory, &self.reference, source_va, self.pages[0..@intCast((descriptor.byte_length + 4095) / 4096)]);
        try self.source.publish(&memory.virtual, &memory.registers, false, false);
        var count: usize = 0;
        if (plan.preserve) count = try copy.encodeCopy(&self.commands, .{ .source = self.frames[self.front].map.address, .target = self.frames[self.back].map.address,
            .bytes = @as(u64, self.frames[self.front].shape.width) * 4, .rows = self.frames[self.front].shape.height,
            .source_pitch = self.frames[self.front].shape.pitch, .target_pitch = self.frames[self.back].shape.pitch });
        count += try copy.encodeCopy(self.commands[count..], .{ .source = self.source.address + plan.source, .target = self.frames[self.back].map.address + plan.target,
            .bytes = plan.row_bytes, .rows = plan.rows, .source_pitch = plan.source_pitch, .target_pitch = plan.target_pitch });
        self.commands[count] = 0; count += 1; // SDMA memory-operation drain before the exact fence.
        const ticket = try runtime.timeline.reserve(input.fence, .sdma, input.deadline_ns, .{ .context = self.self_address, .retire = retire });
        self.ticket = ticket;
        try self.source.retain(input.fence); self.source_held = true;
        try self.frames[self.back].map.retain(input.fence); self.frame_held[self.back] = true;
        if (plan.preserve) { try self.frames[self.front].map.retain(input.fence); self.frame_held[self.front] = true; }
        self.phase = .copying;
        try engine.submitIndirect(ticket, self.commands[0..count], input.deadline_ns, &self.armed);
    }
    fn cleanupCopy(self: *Owner) bool {
        if (self.cleaned) return true;
        const memory = self.engine.?.memory.?; const fence = self.input.?.fence;
        if (self.source_held) { self.source.complete(fence) catch return false; self.source_held = false; }
        for (self.frames, &self.frame_held) |frame, *held| if (held.*) { frame.map.complete(fence) catch return false; held.* = false; };
        if (!self.source.close(&memory.virtual, &memory.registers)) return false;
        if (self.reference.reference.id != 0) {
            if (memory.memory.?.bufferRelease(&self.reference.reference) != 1) return false;
            self.reference = .{};
        }
        self.cleaned = true; return true;
    }
    fn retire(raw: usize, fence: a.GfxFence) bool {
        const self: *Owner = @ptrFromInt(raw);
        if (self.self_address != raw or self.input == null or !std.meta.eql(self.input.?.fence, fence) or self.ticket == null) return false;
        const entry = self.engine.?.runtime.?.timeline.entry(self.ticket.?) catch return false;
        if (entry.phase != .retiring) return false; // Only actual SDMA completion/quiescence can enter cleanup.
        if (!self.cleanupCopy()) return false;
        if (entry.result != a.gfx_queue_result_complete) {
            if (self.armed) { self.failure = error.DeviceLost; self.failed_output = true; }
            self.retired = true; return true;
        }
        const done = self.confirm() catch |err| {
            // Source DMA is retired; uncertain display writes retain the
            // private frames and trigger the outer output recovery owner.
            self.failure = err; self.failed_output = true; self.phase = .failed; self.rejected +|= 1;
            entry.result = a.gfx_queue_result_failed; self.retired = true; return true;
        };
        self.retired = done; return done;
    }
    fn confirm(self: *Owner) !bool {
        const core = self.core.?;
        if (!core.poll()) return false;
        if (core.phase != .programmed or !std.meta.eql(core.scanout_owner.epoch, self.epoch)) return error.Stale;
        const deadline = self.input.?.deadline_ns;
        if (self.engine.?.memory.?.registers.nowNs() >= deadline) return error.Deadline;
        switch (self.phase) {
            .copying => {
                self.rendered +|= 1; self.sequence += 1;
                self.phase = .flip_retry;
            },
            .flip_retry => {
                try core.scanoutCommand(.{ .operation = .flip, .epoch = self.epoch, .sequence = self.sequence,
                    .image = try self.frames[self.back].scanout(), .deadline_ns = @min(deadline, self.engine.?.memory.?.registers.nowNs() + std.time.ns_per_s) });
                self.phase = .flip_wait;
            },
            .flip_wait, .sample_wait => {
                if (core.result != 0 and core.result != dc.c.R4DCN_BUSY) return error.Unconfirmed;
                if (self.phase == .flip_wait) {
                    if (core.result == dc.c.R4DCN_BUSY and core.scanout_owner.phase == .active and core.scanout_owner.pending == null) {
                        self.phase = .flip_retry; return false;
                    }
                    self.submitted +|= 1;
                }
                if (self.phase == .sample_wait and core.result == 0) {
                    const receipt = core.scanout_owner.receipt orelse return error.Unconfirmed;
                    if (receipt.sequence != self.sequence or receipt.image.address != self.frames[self.back].mc_address or
                        !std.meta.eql(receipt.epoch, self.epoch)) return error.Stale;
                    self.receipt = receipt; self.source_fence = self.input.?.fence; self.visible +|= 1; self.front = self.back;
                    if (receipt.previous != null) self.released +|= 1;
                    try core.scanoutCommand(.{ .operation = .acknowledge, .epoch = self.epoch, .sequence = self.sequence });
                    self.phase = .ack_wait;
                } else try core.scanoutCommand(.{ .operation = .sample, .epoch = self.epoch });
                if (self.phase == .flip_wait) self.phase = .sample_wait;
            },
            .ack_wait => { if (core.result != 0) return error.Unconfirmed; return true; },
            else => return error.State,
        }
        return false;
    }
    /// Called on every queue-worker step, including a failed submission which
    /// never obtained a timeline slot. It does not claim hardware quiescence.
    pub fn work(self: *Owner) void {
        if (self.self_address == 0 or self.input == null) return;
        if (self.self_address != @intFromPtr(self)) return;
        if (self.ticket) |ticket| {
            _ = self.engine.?.runtime.?.timeline.entry(ticket) catch {
                if (self.retired) self.clearJob(); return;
            };
        } else if (!self.armed and self.cleanupCopy()) {
            if (self.engine.?.queue.?.complete(&self.input.?.fence, a.gfx_queue_result_failed, 1) == 1) self.clearJob();
        }
    }
    fn clearJob(self: *Owner) void {
        self.input = null; self.ticket = null; self.armed = false; self.cleaned = false; self.retired = false;
        if (!self.failed_output) self.failure = null;
        self.phase = if (self.failure != null) .failed else .idle;
    }
};
