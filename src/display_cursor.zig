// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! One common cursor job, private UMA image, and exact DCN cursor receipt.
//! The serialized queue worker owns BO changes; the DCN task only borrows.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const dc = @import("display_core.zig");
const buffers = @import("display_buffers.zig");
pub const Phase = enum { idle, validate, image, copy, publish, retire_image, barrier, submit, wait, sample, sample_wait, ack, ack_wait, reply, failed };
pub const Owner = struct {
    job: ?a.GfxDriverCursorJob = null,
    phase: Phase = .idle,
    configured: bool = false,
    images: [2]buffers.Image = .{ .{}, .{} },
    front: u1 = 0,
    back: u1 = 1,
    image_sequence: u64 = 0,
    hot_x: u32 = 0, hot_y: u32 = 0,
    visible: bool = false,
    read: a.GfxBufferMap = .{},
    pixels: [64 * 64]u32 = undefined,
    update: dc.scanout.Cursor = .{},
    armed: bool = false,
    reply: a.GfxDriverCursorCompletion = .{},
    failure: ?anyerror = null,
    lost: bool = false,
    /// Barrier waits must allow the queued image to reach actual visibility.
    pub fn permitsQueue(self: *const Owner) bool { return self.phase == .idle or self.phase == .barrier; }
    pub fn step(self: *Owner, output: anytype) !void {
        const display = output.display.?;
        const memory = output.native.?.memory.?;
        if (self.job) |job| if (output.last_time >= job.deadline_ns) return error.Deadline;
        if (!self.configured) {
            if (!display.supportsCursor()) return error.Unsupported;
            const status = display.cursorConfigure(&.{ .head_id = output.mode.pipe, .flags = 15, .backend = output.engine.?.binding,
                .display_generation = output.epoch.display, .max_width = 64, .max_height = 64,
                .min_x = -4096, .min_y = -4096, .max_x = 8191, .max_y = 8191 });
            if (status == a.gfx_output_error_busy) return;
            if (status != a.gfx_output_ok) return error.Unsupported;
            self.configured = true;
        }
        if (self.phase == .idle) {
            if (!output.present.?.available()) return;
            var job: a.GfxDriverCursorJob = .{};
            const status = display.cursorTake(&output.engine.?.binding, &job);
            if (status == 0 or status == a.gfx_output_error_busy) return;
            if (status != a.gfx_output_ok) return error.Stale;
            self.job = job; self.phase = .validate; self.back = 1 - self.front;
        }
        if (self.phase == .reply or self.phase == .failed) {
            if (!self.closeRead(memory)) return;
            if (!self.armed and !self.images[self.back].close(true)) return;
            const status = display.cursorComplete(&self.reply);
            if (status == a.gfx_output_error_busy) return;
            if (status != a.gfx_output_ok) return error.Publication;
            if (self.lost) return error.Visibility;
            self.job = null; self.phase = .idle; self.armed = false; self.failure = null; return;
        }
        self.advance(output) catch |err| {
            self.failure = err; self.lost = self.armed;
            self.reply = .{ .sequence = self.job.?.sequence, .display_generation = self.job.?.request.display_generation,
                .error_code = if (err == error.Deadline) a.gfx_output_error_timeout else a.gfx_output_error_invalid,
                .outcome = if (self.lost) a.gfx_output_outcome_lost else a.gfx_output_outcome_old_preserved,
                .visibility = if (self.lost) a.display_cursor_visibility_unknown else @intFromBool(self.visible) };
            self.phase = .failed;
        };
    }
    fn advance(self: *Owner, output: anytype) !void {
        const job = self.job.?; const request = job.request;
        const core = output.core.?; const memory = output.native.?.memory.?;
        const now = memory.registers.nowNs();
        if (now == 0 or now >= job.deadline_ns) return error.Deadline;
        switch (self.phase) {
            .validate => {
                if (job.version != 1 or job.size < @sizeOf(a.GfxDriverCursorJob) or job.sequence == 0 or
                    !std.meta.eql(job.backend, output.epoch.backend) or memory.epoch != output.epoch.memory or
                    request.version != 1 or request.size < @sizeOf(a.DisplayCursorRequest) or request.head_id != output.mode.pipe or
                    request.display_generation != output.epoch.display or request.operation > a.display_cursor_operation_release or
                    (job.barrier_timeline == 0) != (job.barrier_point == 0)) return error.Stale;
                if (request.operation == a.display_cursor_operation_prepare) {
                    if (self.visible or request.width == 0 or request.width > 64 or request.height == 0 or request.height > 64 or
                        request.hotspot_x >= request.width or request.hotspot_y >= request.height or request.pitch < request.width * 4 or
                        request.pitch % 4 != 0 or request.pitch > 65536 or request.byte_length != request.pitch * request.height or
                        request.reference.id == 0 or request.reference.generation == 0 or request.reference.reserved0 != 0) return error.Invalid;
                    var descriptor: a.GfxBufferDescriptor = .{};
                    if (memory.memory.?.bufferDescribe(&request.reference, &descriptor) != 1 or descriptor.location != a.gfx_buffer_location_system or
                        descriptor.adapter_id != 0 or descriptor.device_generation != 0 or descriptor.width != request.width or descriptor.height != request.height or
                        descriptor.format != a.gfx_buffer_format_argb8888 or descriptor.plane_count != 1 or descriptor.modifier != 0 or
                        descriptor.plane_offsets[0] != 0 or descriptor.plane_pitches[0] != request.pitch or descriptor.byte_length != request.byte_length or
                        descriptor.usage & a.gfx_buffer_usage_cpu_read == 0) return error.Invalid;
                    self.phase = .image;
                } else {
                    if (request.operation == a.display_cursor_operation_show or request.operation == a.display_cursor_operation_move) {
                        if (self.image_sequence == 0 or request.image_sequence != self.image_sequence or !self.images[self.front].ready or
                            (request.operation == a.display_cursor_operation_move and !self.visible)) return error.Stale;
                        self.update = .{ .image = try self.images[self.front].scanout(), .width = self.images[self.front].shape.width,
                            .height = self.images[self.front].shape.height, .x = request.x, .y = request.y, .hot_x = self.hot_x, .hot_y = self.hot_y };
                        self.phase = if (request.operation == a.display_cursor_operation_show) .barrier else .submit;
                    } else { self.update = .{}; self.phase = .submit; }
                }
            },
            .image => {
                if (!self.images[self.back].close(true)) return;
                try self.images[self.back].allocate(memory, try buffers.Shape.make(request.width, request.height, true), 2 + @as(u8, self.back));
                self.phase = .copy;
            },
            .copy => {
                if (self.read.lease.id == 0 and memory.memory.?.bufferMap(&request.reference, a.gfx_buffer_map_read, 0, request.byte_length, &self.read) != 1) return error.Map;
                if (self.read.lease.id == 0 or self.read.lease.generation == 0 or self.read.cpu_address == 0 or self.read.cpu_address % 4 != 0 or
                    self.read.byte_length < request.byte_length or self.read.cpu_address > std.math.maxInt(u64) - request.byte_length) return error.Map;
                const source: [*]const u32 = @ptrFromInt(self.read.cpu_address);
                for (0..request.height) |y| for (0..request.width) |x| { self.pixels[y * request.width + x] = source[y * (request.pitch / 4) + x]; };
                try self.images[self.back].copyCursor(self.pixels[0..@as(usize, request.width) * request.height]);
                self.phase = .publish;
            },
            .publish => {
                if (!self.closeRead(memory)) return;
                try self.images[self.back].publish();
                self.phase = .retire_image;
            },
            .retire_image => {
                // Prepare never exposes the new image. The previous image is
                // known hidden from its exact hide receipt before replacement.
                if (!self.images[self.front].close(true)) return;
                self.front = self.back; self.back = 1 - self.front;
                self.image_sequence = job.sequence; self.hot_x = request.hotspot_x; self.hot_y = request.hotspot_y;
                self.applied(false); // hidden image, no cursor-register writes
            },
            .barrier => {
                if (!output.present.?.available()) return;
                if (job.barrier_point != 0) {
                    const receipt = output.present.?.receipt orelse return;
                    if (!std.meta.eql(receipt.epoch, output.epoch) or output.present.?.source_fence.timeline != job.barrier_timeline or
                        output.present.?.source_fence.point < job.barrier_point or receipt.observed_ns == 0) return;
                }
                self.phase = .submit;
            },
            .submit => {
                if (!output.present.?.available()) return;
                self.armed = true;
                try core.scanoutCommand(.{ .operation = .cursor, .epoch = output.epoch, .sequence = job.sequence,
                    .cursor = self.update, .deadline_ns = @min(job.deadline_ns, now + std.time.ns_per_s) });
                self.phase = .wait;
            },
            .wait, .sample_wait, .ack_wait => {
                if (!core.poll()) return;
                if (core.phase != .programmed or (core.result != 0 and core.result != dc.c.R4DCN_BUSY)) return error.Visibility;
                if (self.phase == .wait and core.result == dc.c.R4DCN_BUSY and core.scanout_owner.phase == .active and core.scanout_owner.cursor_pending == null) {
                    // The native bridge refused the unsafe VUPDATE window
                    // before any writes; retry the same request and sequence.
                    self.armed = false; self.phase = .submit; return;
                }
                if (self.phase == .ack_wait) {
                    if (core.result != 0) return error.Visibility;
                    if (request.operation == a.display_cursor_operation_release) {
                        if (!self.images[self.front].close(true)) return;
                        self.image_sequence = 0;
                    }
                    self.applied(self.update.image != null);
                } else if (self.phase == .sample_wait and core.result == 0) {
                    const receipt = core.scanout_owner.cursor_receipt orelse return error.Visibility;
                    if (!std.meta.eql(receipt.epoch, output.epoch) or receipt.sequence != job.sequence or !std.meta.eql(receipt.update, self.update)) return error.Stale;
                    self.phase = .ack;
                } else self.phase = .sample;
            },
            .sample => { try core.scanoutCommand(.{ .operation = .cursor_sample, .epoch = output.epoch }); self.phase = .sample_wait; },
            .ack => { try core.scanoutCommand(.{ .operation = .cursor_acknowledge, .epoch = output.epoch, .sequence = job.sequence }); self.phase = .ack_wait; },
            else => return error.State,
        }
    }
    fn applied(self: *Owner, visible: bool) void {
        self.visible = visible;
        self.reply = .{ .sequence = self.job.?.sequence, .display_generation = self.job.?.request.display_generation,
            .outcome = a.gfx_output_outcome_applied, .visibility = @intFromBool(visible) };
        self.phase = .reply;
    }
    fn closeRead(self: *Owner, memory: *@import("memory_owner.zig").Owner) bool {
        if (self.read.lease.id == 0) return true;
        if (memory.memory.?.bufferUnmap(&self.read.lease) != 1) return false;
        self.read = .{}; return true;
    }
    /// Only after core.close proved cursor and scanout stopped/restored.
    pub fn close(self: *Owner, memory: *@import("memory_owner.zig").Owner, stopped: bool) bool {
        if (!stopped or !self.closeRead(memory)) return false;
        for (&self.images) |*image| if (!image.close(true)) return false;
        self.job = null; self.phase = .idle; return true;
    }
};
