// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! The target board's additional HDMI head. Queue/BO work stays in the
//! serialized engine worker; connector retirement supplies physical stop.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const dc = @import("display_core.zig");
const buffers = @import("display_buffers.zig");
const modes = @import("display_modes.zig");
const hotplug = @import("hdmi_hotplug.zig");
pub const Phase = enum { empty, catalog, catalog_wait, publication, allocate, clear, publish_buffer, register, plan, plan_wait, apply, apply_wait, activate, active, draining, retired, failed };
pub const Owner = struct {
    self_address: usize = 0,
    core: ?*dc.Owner = null,
    engine: ?*@import("sdma_jobs.zig").Owner = null,
    native: ?*@import("start_runtime.zig").Owner = null,
    display: ?r4os.driver_display.Context = null,
    outputs: ?r4os.driver_outputs.Context = null,
    pipeline: ?*@import("display_pipeline.zig").Owner = null,
    output: a.GfxOutputId = .{},
    publication: a.GfxOutputPublication = .{},
    receiver: a.GfxReceiverInfo = .{},
    epoch: dc.scanout.Epoch = undefined,
    target: a.GfxOutputTarget = .{},
    mode: dc.c.struct_r4dcn_mode = undefined,
    shape: buffers.Shape = undefined,
    images: [2]buffers.Image = .{ .{}, .{} },
    frames: [2]*buffers.Image = undefined,
    presentation: @import("display_present.zig").Owner = .{},
    present: ?*@import("display_present.zig").Owner = null,
    modes: modes.Owner = .{},
    // Additional heads use the desktop's already transformed software cursor.
    cursor: struct { phase: enum { idle } = .idle, visible: bool = false } = .{},
    statistics: @import("display_stats.zig").Owner = .{},
    color: @import("display_color.zig").Owner = .{},
    signal: ?@import("display_color.zig").color.Signal = null,
    mode_inbox: ?a.GfxDriverModeJob = null,
    slot_base: u8 = 8,
    phase: Phase = .empty,
    index: u1 = 0,
    catalog_index: usize = 0,
    candidate: a.GfxOutputMode = .{},
    token: u64 = 0,
    deadline: u64 = 0,
    last_time: u64 = 0,
    failure: ?anyerror = null,
    initial_receipt: ?dc.scanout.Receipt = null,
    callback_confirmed: bool = false,
    draining: bool = false,
    hardware_stopped: bool = false,
    release_requested: bool = false,
    released: bool = false,
    pub fn waiting(self: *const Owner) bool {
        if (self.draining and self.core != null and self.core.?.thread != 0 and self.core.?.taskFor(self.mode.pipe, self.output.connector_id)) return true;
        return self.phase == .catalog_wait or self.phase == .plan_wait or self.phase == .apply_wait or (self.phase == .active and self.modes.waiting());
    }
    pub fn begin(self: *Owner, parent: anytype, receiver: a.GfxReceiverInfo, token: u64) !void {
        if (self.phase != .empty or !parent.display.?.supportsOutputs() or token == 0) return error.State;
        self.self_address = @intFromPtr(self); self.core = parent.core; self.engine = parent.engine; self.native = parent.native;
        self.display = parent.display; self.outputs = parent.outputs; self.pipeline = parent.pipeline;
        self.receiver = receiver; self.token = token; self.frames = .{ &self.images[0], &self.images[1] }; self.present = &self.presentation;
        self.last_time = parent.last_time; self.deadline = parent.last_time + 10 * std.time.ns_per_s;
        const pipe: u32 = if (parent.mode.pipe == 0) 1 else 0;
        const mask = @as(u32, 1) << @intCast(pipe);
        self.mode = parent.mode; self.mode.pipe = pipe; self.mode.flags = 1;
        const core = self.core.?;
        self.publication = .{ .backend = self.engine.?.binding, .info = .{
            .identity = .{ .adapter_id = parent.output.adapter_id, .device_generation = parent.output.device_generation, .connector_id = receiver.connector_id },
            .connector_kind = receiver.connector_kind, .flags = receiver.flags, .edid_bytes = receiver.edid_bytes,
            .possible_heads = mask, .possible_planes = mask, .possible_plls = mask,
            .limits = .{ .flags = a.gfx_output_limit_modeset, .head_mask = mask, .plane_mask = mask, .pll_mask = mask,
                .pitch_alignment = 256, .bpc_mask = 1 << 8, .total_pixel_clock_hz = @as(u64, core.fixed_disp_khz) * 2000,
                .bandwidth_bytes_per_second = @as(u64, core.limits.fabric_khz) * core.limits.channels * 16000 } }, .edid = receiver.edid };
        self.phase = .catalog;
    }
    /// Catalog preparation happens before the connector publishes its one
    /// canonical identity. Admission uses both outputs in the original DML.
    pub fn planCatalog(self: *Owner, parent: anytype) !bool {
        const core = self.core.?; self.last_time = parent.last_time;
        if (self.last_time >= self.deadline) return error.Deadline;
        if (self.phase == .catalog_wait) {
            if (!core.poll()) return false;
            if (core.phase == .retained) return error.Unconfirmed;
            if (core.result == 0 and core.candidate_valid) {
                const info = &self.publication.info;
                self.publication.modes[info.mode_count] = self.candidate; info.mode_count += 1;
                info.limits.max_width = @max(info.limits.max_width, self.candidate.width);
                info.limits.max_height = @max(info.limits.max_height, self.candidate.height);
                info.limits.max_pixel_clock_hz = @max(info.limits.max_pixel_clock_hz, self.candidate.pixel_clock_hz);
                if (info.preferred_mode_id == 0 or self.candidate.mode_id == self.receiver.preferred_mode_id) info.preferred_mode_id = self.candidate.mode_id;
            }
            self.phase = .catalog;
        }
        if (self.phase != .catalog) return self.phase == .publication;
        if (core.thread != 0) return false;
        if (self.catalog_index == self.receiver.mode_count or self.publication.info.mode_count == a.gfx_output_max_modes) {
            self.phase = .publication; return true;
        }
        self.candidate = self.receiver.modes[self.catalog_index]; self.catalog_index += 1;
        var candidate = modes.nativeMode(self.candidate, self.mode.pipe, 8, parent.frames[0].mc_address) catch return false;
        candidate.flags |= 1;
        try core.planMode(candidate); self.phase = .catalog_wait; return false;
    }
    pub fn published(self: *Owner, identity: a.GfxOutputId) !void {
        if (self.phase != .publication or identity.connection_generation == 0 or self.output.connection_generation != 0) return error.State;
        self.output = identity;
        if (self.publication.info.mode_count == 0) { self.phase = .retired; self.hardware_stopped = true; return; }
        var selected = self.publication.modes[0];
        for (self.publication.modes[0..self.publication.info.mode_count]) |candidate| if (candidate.mode_id == self.publication.info.preferred_mode_id) { selected = candidate; break; };
        self.shape = try buffers.Shape.make(selected.width, selected.height, false);
        self.mode = try modes.nativeMode(selected, self.mode.pipe, 8, 4096); self.mode.flags |= 1;
        const hdmi: *@import("hdmi_runtime.zig").Runtime = @ptrFromInt(self.core.?.hdmi_allocation.cpu_address);
        const colors = @import("display_color.zig");
        self.signal = colors.defaultSignal(&hdmi.receiver.report, try colors.timing(&hdmi.receiver.report, self.mode));
        self.phase = .allocate;
    }
    pub fn step(self: *Owner, parent: anytype) void {
        if (self.self_address == 0) return;
        self.last_time = parent.last_time; self.presentation.work();
        if (self.presentation.failed_output) self.fail(self.presentation.failure orelse error.Visibility);
        if (self.draining) {
            if (self.core.?.thread != 0 and self.core.?.taskFor(self.mode.pipe, self.output.connector_id) and !self.core.?.poll()) return;
            self.drainMode();
            if (self.hardware_stopped) _ = self.closeTarget();
            if (self.release_requested) self.released = self.closeResources();
            return;
        }
        if (self.phase == .empty or self.phase == .catalog or self.phase == .catalog_wait or self.phase == .publication or self.phase == .retired) return;
        if (self.phase != .active and self.last_time >= self.deadline) { self.fail(error.Deadline); return; }
        self.advance() catch |err| self.fail(err);
    }
    fn advance(self: *Owner) !void {
        const core = self.core.?;
        if (self.waiting()) {
            if (!core.poll()) return;
        } else if (core.thread != 0) return;
        switch (self.phase) {
            .allocate => { try self.frames[self.index].allocate(self.engine.?.memory.?, self.shape, self.slot_base + self.index); self.phase = .clear; },
            .clear => { if (try self.frames[self.index].clearColor(if (self.signal.?.range == .limited) 0xff101010 else 0)) self.phase = .publish_buffer; },
            .publish_buffer => {
                try self.frames[self.index].publish();
                if (self.index == 0) { self.index = 1; self.phase = .allocate; } else self.phase = .register;
            },
            .register => {
                const request: a.GfxAdditionalOutput = .{ .backend = self.engine.?.binding, .output = self.output,
                    .head_id = self.mode.pipe, .width = self.mode.width, .height = self.mode.height, .format = a.gfx_buffer_format_xrgb8888 };
                const result = self.display.?.outputRegister(&request, &self.target);
                if (result == a.gfx_output_error_busy) return;
                if (result != a.gfx_output_ok or self.target.connection_generation != self.output.connection_generation or self.target.head_id != self.mode.pipe or
                    self.target.connector_id != self.output.connector_id or self.target.adapter_id != self.output.adapter_id or
                    self.target.device_generation != self.output.device_generation or self.target.display_generation == 0) return error.Publication;
                self.epoch = .{ .backend = self.engine.?.binding, .output = self.output, .memory = self.engine.?.memory.?.epoch,
                    .display = self.target.display_generation, .mode = 1 };
                self.mode.mc_address = self.frames[0].mc_address; self.phase = .plan;
            },
            .plan => { try core.planMode(self.mode); self.phase = .plan_wait; },
            .plan_wait => { if (core.result != 0 or !core.candidate_valid) return error.Unsupported; self.phase = .apply; },
            .apply => {
                try core.applyMode(.{ .mode = self.mode, .epoch = self.epoch, .image = try self.frames[0].scanout(), .sequence = 1,
                    .deadline_ns = self.last_time + 2 * std.time.ns_per_s, .signal = self.signal }); self.phase = .apply_wait;
            },
            .apply_wait => {
                if (core.result != 0) return error.Visibility;
                const receipt = core.mode_receipt orelse return error.Unconfirmed;
                if (!std.meta.eql(receipt.epoch, self.epoch) or receipt.image.address != self.frames[0].mc_address) return error.Stale;
                self.initial_receipt = receipt;
                try self.presentation.bind(self.engine.?, core, self.frames, self.epoch, self.target);
                self.phase = .activate;
            },
            .activate => {
                const result = self.display.?.outputTransition(&self.target, 0, false);
                if (result == a.gfx_output_error_busy) return;
                if (result != a.gfx_output_ok) return error.Publication;
                self.callback_confirmed = true; self.phase = .active;
                self.modes.self_address = @intFromPtr(&self.modes); self.modes.ready = true; self.modes.enabled = true; self.modes.phase = .idle;
                self.modes.banks = .{ self.frames, .{ &self.modes.spare[0], &self.modes.spare[1] } };
            },
            .active => { self.statistics.publish(self); try self.modes.step(self); },
            else => {},
        }
    }
    pub fn fail(self: *Owner, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        self.draining = true; self.phase = .draining;
        self.presentation.cancel_display = true;
        if (self.output.connection_generation != 0) _ = self.outputs.?.pauseOutput(&self.output, true);
        // The next HDMI service runs Connection.invalidate in its DCN task.
    }
    fn drainMode(self: *Owner) void { _ = self.modes.abandon(self); }
    /// Called only inside the joined connector task. It requests queue-owner
    /// cleanup; it never frees a BO from the task or infers stop from timeout.
    pub fn retire(self: *Owner, token: u64, action: hotplug.Step) hotplug.Receipt {
        var receipt: hotplug.Receipt = .{ .generation = token };
        if (token != self.token or self.self_address != @intFromPtr(self)) return receipt;
        if (action == .drain) { self.draining = true; self.presentation.cancel_display = true; }
        receipt.pending_jobs = @intFromBool(self.presentation.input != null or self.mode_inbox != null or self.modes.job != null or self.modes.pending != null or
            (self.modes.copy.self_address != 0 and !self.modes.copy.retired));
        if (action == .stop and receipt.pending_jobs == 0) {
            const hooks = self.core.?.hooks.?;
            if (!hooks.remove.?(hooks.context)) return receipt;
            self.hardware_stopped = true;
        }
        if (action == .release) self.release_requested = true;
        receipt.scanout_stopped = self.hardware_stopped;
        receipt.done = receipt.pending_jobs == 0 and (action != .release or self.released) and
            ((action != .settle and action != .withdraw) or self.target.display_generation == 0);
        return receipt;
    }
    fn closeTarget(self: *Owner) bool {
        if (!self.hardware_stopped or self.presentation.input != null or self.modes.job != null or self.mode_inbox != null) return false;
        if (self.target.display_generation != 0) {
            const result = self.display.?.outputTransition(&self.target, 2, true);
            if (result != a.gfx_output_ok and result != a.gfx_output_error_stale) return false;
            self.target = .{};
        }
        return true;
    }
    pub fn closeResources(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (!self.hardware_stopped or self.presentation.input != null or !self.modes.copy.close() or !self.closeTarget()) return false;
        if (!self.modes.close()) return false;
        for (&self.images) |*frame| if (!frame.close(true)) return false;
        return true;
    }
    pub fn reset(self: *Owner) bool {
        if (self.self_address == 0) return true;
        self.hardware_stopped = true;
        // Common deviceReset already owns canonical target/mode retirement.
        self.target = .{};
        self.mode_inbox = null; self.modes.job = null; self.modes.pending = null;
        if (!self.closeResources()) return false;
        self.* = .{}; return true;
    }
};
