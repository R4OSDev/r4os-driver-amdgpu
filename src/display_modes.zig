// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Common asynchronous mode transactions, owned by the existing queue worker.
//! Old private frames survive apply until confirm or a proven rollback.
const std = @import("std");
const a = @import("r4os").abi;
const dc = @import("display_core.zig");
const buffers = @import("display_buffers.zig");
const panel = @import("panel_runtime.zig");
const timing = @import("r4gfx_edid").timing;
pub const Phase = enum { empty, catalog, catalog_wait, publish_catalog, rekey, rekey_wait, idle, allocate, publish_buffer, copy,
    copy_wait, plan, plan_wait, apply, apply_wait, retire_previous, reject_cleanup, reply, failed };
pub const Owner = struct {
    self_address: usize = 0,
    phase: Phase = .empty,
    ready: bool = false,
    enabled: bool = false,
    catalog_index: usize = 0,
    candidate: a.GfxOutputMode = .{},
    spare: [2]buffers.Image = .{ .{}, .{} },
    banks: [2][2]*buffers.Image = undefined,
    active_bank: u1 = 0,
    next_bank: u1 = 1,
    index: u1 = 0,
    previous: [2]*buffers.Image = undefined,
    previous_mode: dc.c.struct_r4dcn_mode = undefined,
    next_mode: dc.c.struct_r4dcn_mode = undefined,
    next_epoch: dc.scanout.Epoch = undefined,
    shape: buffers.Shape = undefined,
    job: ?a.GfxDriverModeJob = null,
    pending: ?a.GfxDriverModeJob = null,
    last_sequence: u64 = 0,
    hardware_armed: bool = false,
    reply: a.GfxDriverModeCompletion = .{},
    failure: ?anyerror = null,
    copy: @import("display_copy.zig").Owner = .{},
    pub fn permitsQueue(self: *const Owner) bool { return self.ready and self.phase == .idle; }
    pub fn step(self: *Owner, output: anytype) !void {
        if (self.self_address == 0) {
            self.self_address = @intFromPtr(self); self.phase = .catalog;
            self.banks = .{ output.frames, .{ &self.spare[0], &self.spare[1] } };
        }
        if (self.self_address != @intFromPtr(self)) return error.State;
        if (self.phase == .idle) {
            if (!output.present.?.available() or output.cursor.phase != .idle) return;
            var job: a.GfxDriverModeJob = .{};
            const status = output.outputs.?.takeMode(&output.engine.?.binding, &job);
            if (status == 0 or status == a.gfx_output_error_busy) return;
            if (status != a.gfx_output_ok) return error.Publication;
            self.job = job; self.hardware_armed = false; self.failure = null;
            self.accept(output) catch |err| { try self.reject(err); };
            return;
        }
        // A stuck common publication also has a bound. Its proven resources
        // remain held for the parent reset owner after this deadline.
        if (self.job) |job| if (output.last_time >= job.deadline_ns) return error.Deadline;
        self.advance(output) catch |err| { try self.reject(err); };
    }
    fn reject(self: *Owner, err: anyerror) !void {
        self.failure = err;
        const job = self.job orelse return err;
        if (job.operation != a.gfx_mode_operation_apply or self.pending != null or self.hardware_armed or self.copy.armed) {
            self.phase = .failed; return err;
        }
        self.reply = .{ .ticket = job.ticket, .sequence = job.sequence, .operation = job.operation,
            .outcome = a.gfx_output_outcome_old_preserved, .quiesced = 2,
            .error_code = if (err == error.Stale) a.gfx_output_error_stale else a.gfx_output_error_unsupported };
        self.phase = .reject_cleanup;
    }
    fn accept(self: *Owner, output: anytype) !void {
        const job = self.job.?; const core = output.core.?; const assignment = job.assignment;
        if (job.version != 1 or job.size < @sizeOf(a.GfxDriverModeJob) or job.ticket == 0 or job.sequence == 0 or
            job.reserved0 != 0 or !std.meta.eql(job.backend, output.epoch.backend) or
            !std.meta.eql(assignment.output, output.output) or core.memory.?.epoch != output.epoch.memory or
            job.deadline_ns <= output.last_time or output.cursor.visible or core.scanout_owner.cursor_current.image != null) return error.Stale;
        if (job.operation == a.gfx_mode_operation_apply) {
            if (self.pending != null) return error.State;
            if (assignment.version != 1 or assignment.size < @sizeOf(a.GfxScanoutState) or assignment.reserved0 != 0 or
                assignment.head_id != output.mode.pipe or assignment.plane_id != output.mode.pipe or assignment.pll_id != output.mode.pipe or
                assignment.mode_id != job.mode.mode_id or assignment.source_x != 0 or assignment.source_y != 0 or
                assignment.destination_x != 0 or assignment.destination_y != 0 or assignment.rotation != 0 or assignment.color != 0 or
                assignment.source_width != job.mode.width or assignment.source_height != job.mode.height or
                assignment.destination_width != job.mode.width or assignment.destination_height != job.mode.height or
                assignment.bits_per_color != (if (output.mode.flags & 8 != 0) @as(u32, 6) else 8)) return error.Unsupported;
            var found = false;
            for (output.publication.modes[0..output.publication.info.mode_count]) |mode| if (std.meta.eql(mode, job.mode)) { found = true; break; };
            if (!found) return error.Stale;
            self.next_bank = 1 - self.active_bank;
            self.previous = .{ output.present.?.frames[output.present.?.front], output.present.?.frames[1 - output.present.?.front] };
            self.previous_mode = output.mode; self.previous_mode.mc_address = self.previous[0].mc_address;
            self.shape = try buffers.Shape.make(job.mode.width, job.mode.height, false);
            self.next_mode = try nativeMode(job.mode, output.mode.pipe, assignment.bits_per_color, self.previous[0].mc_address);
            self.index = 0; self.phase = .allocate;
        } else {
            const pending = self.pending orelse return error.Stale;
            if (job.ticket != pending.ticket or job.sequence <= self.last_sequence or
                !std.meta.eql(job.assignment, pending.assignment) or !std.meta.eql(job.mode, pending.mode) or
                !std.meta.eql(job.reference, pending.reference)) return error.Stale;
            if (job.operation == a.gfx_mode_operation_confirm) {
                self.next_bank = self.active_bank;
                self.phase = .retire_previous;
            } else if (job.operation == a.gfx_mode_operation_rollback) {
                self.next_bank = 1 - self.active_bank; self.next_mode = self.previous_mode;
                self.shape = self.previous[0].shape; self.phase = .plan;
            } else return error.Invalid;
        }
        self.last_sequence = job.sequence;
    }
    fn advance(self: *Owner, output: anytype) !void {
        const core = output.core.?;
        switch (self.phase) {
            .catalog => {
                const p = &@as(*panel.Runtime, @ptrFromInt(core.panel_allocation.cpu_address)).protocol.?;
                if (self.catalog_index >= p.report.mode_count or output.publication.info.mode_count >= a.gfx_output_max_modes) {
                    self.phase = .publish_catalog; return;
                }
                const item = p.report.modes[self.catalog_index]; self.catalog_index += 1;
                if (!p.supportsTiming(item) or item.nominal_millihz != 0 or item.clock_hz % 1000 != 0) return;
                const candidate = describe(item, output.publication.info.mode_count + 1);
                for (output.publication.modes[0..output.publication.info.mode_count]) |old| {
                    var comparison = candidate; comparison.mode_id = old.mode_id; comparison.flags = (candidate.flags & ~@as(u32, 8)) | (old.flags & 8);
                    if (std.meta.eql(comparison, old)) return;
                }
                const mode = nativeMode(candidate, output.mode.pipe, p.bpc, output.frames[0].mc_address) catch return;
                self.candidate = candidate; try core.planMode(mode); self.phase = .catalog_wait;
            },
            .catalog_wait => {
                if (!core.poll()) return;
                if (core.result == 0 and core.candidate_valid) {
                    const info = &output.publication.info;
                    output.publication.modes[info.mode_count] = self.candidate; info.mode_count += 1;
                    info.limits.max_width = @max(info.limits.max_width, self.candidate.width);
                    info.limits.max_height = @max(info.limits.max_height, self.candidate.height);
                    info.limits.max_pixel_clock_hz = @max(info.limits.max_pixel_clock_hz, self.candidate.pixel_clock_hz);
                }
                self.phase = .catalog;
            },
            .publish_catalog => {
                if (!self.enabled) {
                    const status = output.outputs.?.enableModes(&output.engine.?.binding);
                    if (status == a.gfx_output_error_busy) return;
                    if (status != a.gfx_output_ok) return error.Unsupported;
                    self.enabled = true;
                }
                const limits = &output.publication.info.limits;
                limits.flags = a.gfx_output_limit_modeset;
                limits.total_pixel_clock_hz = limits.max_pixel_clock_hz;
                limits.bandwidth_bytes_per_second = limits.max_pixel_clock_hz * 4;
                var identity: a.GfxOutputId = .{};
                const status = output.outputs.?.publish(&output.publication, &identity);
                if (status == a.gfx_output_error_busy) return;
                if (status != a.gfx_output_ok or identity.adapter_id != output.output.adapter_id or identity.connector_id != output.output.connector_id or
                    identity.device_generation != output.output.device_generation or identity.connection_generation <= output.output.connection_generation) return error.Publication;
                output.output = identity; self.next_epoch = output.epoch; self.next_epoch.output = identity;
                self.phase = .rekey;
            },
            .rekey => { try core.scanoutCommand(.{ .operation = .rekey, .epoch = self.next_epoch }); self.phase = .rekey_wait; },
            .rekey_wait => {
                if (!core.poll()) return;
                if (core.result != 0) return error.Unconfirmed;
                output.epoch = self.next_epoch; output.target.connection_generation = output.output.connection_generation;
                try output.present.?.rebind(output.frames, output.epoch, output.target, null);
                self.ready = true; self.phase = .idle;
            },
            .allocate => {
                const frame = self.banks[self.next_bank][self.index];
                try frame.allocate(output.native.?.memory.?, self.shape, @as(u8, self.next_bank) * 4 + self.index);
                self.phase = .publish_buffer;
            },
            .publish_buffer => {
                try self.banks[self.next_bank][self.index].publishGpuTarget();
                if (self.index == 0) { self.index = 1; self.phase = .allocate; } else self.phase = .copy;
            },
            .copy => {
                try self.copy.begin(output.engine.?, self.banks[self.next_bank], self.job.?.reference, self.job.?.deadline_ns);
                self.phase = .copy_wait;
            },
            .copy_wait => {
                if (!try self.copy.poll()) return;
                if (!self.copy.close()) return;
                self.next_mode.mc_address = self.banks[self.next_bank][0].mc_address;
                self.phase = .plan;
            },
            .plan => { try core.planMode(self.next_mode); self.phase = .plan_wait; },
            .plan_wait => {
                if (!core.poll()) return;
                if (core.result != 0 or !core.candidate_valid) return error.Unsupported;
                self.next_epoch = output.epoch;
                if (self.next_epoch.mode == std.math.maxInt(u64) or core.scanout_owner.sequence >= std.math.maxInt(u64) - 1) return error.Capacity;
                self.next_epoch.mode += 1; self.phase = .apply;
            },
            .apply => {
                const frames = if (self.job.?.operation == a.gfx_mode_operation_rollback) self.previous else self.banks[self.next_bank];
                const image = try frames[0].scanout();
                self.hardware_armed = true;
                try core.applyMode(.{ .mode = self.next_mode, .epoch = self.next_epoch, .image = image,
                    .sequence = core.scanout_owner.sequence + 1, .deadline_ns = self.job.?.deadline_ns });
                self.phase = .apply_wait;
            },
            .apply_wait => {
                if (!core.poll()) return;
                if (core.result != 0) return error.Unconfirmed;
                const receipt = core.mode_receipt orelse return error.Unconfirmed;
                const rollback = self.job.?.operation == a.gfx_mode_operation_rollback;
                const frames = if (rollback) self.previous else self.banks[self.next_bank];
                try output.present.?.rebind(frames, self.next_epoch, output.target, receipt);
                output.frames = frames; output.mode = self.next_mode; output.shape = self.shape; output.epoch = self.next_epoch;
                self.active_bank = self.next_bank;
                if (rollback) self.phase = .retire_previous else {
                    self.pending = self.job;
                    self.reply = .{ .ticket = self.job.?.ticket, .sequence = self.job.?.sequence, .operation = self.job.?.operation,
                        .outcome = a.gfx_output_outcome_applied, .quiesced = 1 };
                    self.phase = .reply;
                }
            },
            .retire_previous => {
                // Replaced frames are inactive after the new address receipt.
                // Confirm and rollback both retire the other retained bank.
                for (self.banks[1 - self.active_bank]) |frame| if (!frame.close(true)) return;
                const job = self.job.?;
                const reverted = job.operation == a.gfx_mode_operation_rollback;
                self.reply = .{ .ticket = job.ticket, .sequence = job.sequence, .operation = job.operation,
                    .outcome = if (reverted) a.gfx_output_outcome_old_preserved else a.gfx_output_outcome_applied,
                    .quiesced = if (reverted) 2 else 1 };
                self.phase = .reply;
            },
            .reject_cleanup => {
                if (!self.copy.close()) return;
                for (self.banks[1 - self.active_bank]) |frame| if (!frame.close(true)) return;
                self.phase = .reply;
            },
            .reply => {
                const status = output.outputs.?.completeMode(&self.reply);
                if (status == a.gfx_output_error_busy) return;
                if (status != a.gfx_output_ok) return error.Publication;
                if (self.reply.operation != a.gfx_mode_operation_apply or self.reply.outcome != a.gfx_output_outcome_applied) self.pending = null;
                self.job = null; self.hardware_armed = false; self.failure = null; self.phase = .idle;
            },
            else => return error.State,
        }
    }
    /// Called after DCN stops and the actual SDMA timeline retires. The
    /// common reset owner separately releases its borrowed source references.
    pub fn close(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or !self.copy.close()) return false;
        for (self.banks) |bank| for (bank) |frame| if (!frame.close(true)) return false;
        return true;
    }
};
fn describe(value: timing.Timing, id: u32) a.GfxOutputMode {
    return .{ .mode_id = id, .flags = value.flags & 14, .width = value.width, .height = value.height, .pixel_clock_hz = value.clock_hz,
        .h_total = value.h_total, .h_sync_start = value.h_start, .h_sync_end = value.h_end,
        .v_total = value.v_total, .v_sync_start = value.v_start, .v_sync_end = value.v_end, .refresh_millihz = value.millihz() };
}
fn nativeMode(mode: a.GfxOutputMode, pipe: u32, bpc: u32, address: u64) !dc.c.struct_r4dcn_mode {
    if (mode.version != 1 or mode.size < @sizeOf(a.GfxOutputMode) or mode.reserved0 != 0 or mode.pixel_clock_hz == 0 or
        mode.pixel_clock_hz % 1000 != 0 or mode.pixel_clock_hz > 720_000_000 or mode.flags & ~@as(u32, 14) != 0 or
        mode.width > mode.h_sync_start or mode.h_sync_start >= mode.h_sync_end or mode.h_sync_end > mode.h_total or
        mode.height > mode.v_sync_start or mode.v_sync_start >= mode.v_sync_end or mode.v_sync_end > mode.v_total or
        mode.h_total > 16384 or mode.v_total > 16384 or (bpc != 6 and bpc != 8)) return error.Unsupported;
    const shape = try buffers.Shape.make(mode.width, mode.height, false);
    return .{ .mc_address = address, .buffer_bytes = shape.bytes, .pitch_bytes = shape.pitch, .width = mode.width, .height = mode.height,
        .h_total = mode.h_total, .h_front = mode.h_sync_start - mode.width, .h_sync = mode.h_sync_end - mode.h_sync_start,
        .v_total = mode.v_total, .v_front = mode.v_sync_start - mode.height, .v_sync = mode.v_sync_end - mode.v_sync_start,
        .pixel_khz = @intCast(mode.pixel_clock_hz / 1000), .pipe = pipe, .flags = (mode.flags & 6) | @as(u32, if (bpc == 6) 8 else 0) };
}
