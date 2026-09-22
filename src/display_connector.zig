// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Periodic HDMI receiver discovery with a real common OutputId. Scanout on
//! additional heads is owned by the subsequent multihead milestone.
const std = @import("std");
const a = @import("r4os").abi;
const dc = @import("display_core.zig");
const hdmi = @import("hdmi_runtime.zig");
pub const Owner = struct {
    core: ?*dc.Owner = null,
    phase: enum { idle, wait_service, publication, binding, wait_binding, discard } = .idle,
    next_sample: u64 = 0,
    next_probe: u64 = 0,
    deadline: u64 = 0,
    token: u64 = 0,
    output: a.GfxOutputId = .{},
    publication: a.GfxOutputPublication = .{},
    receiver: a.GfxReceiverInfo = .{},
    last_error: ?anyerror = null,
    samples: u64 = 0,
    pub fn waiting(self: *const Owner) bool { return self.phase == .wait_service or self.phase == .wait_binding; }
    fn runtime(self: *Owner) *hdmi.Runtime { return @ptrFromInt(self.core.?.hdmi_allocation.cpu_address); }
    /// Always poll a task already launched before another core user runs.
    pub fn poll(self: *Owner, output: anytype) !void {
        if (!self.waiting()) return;
        const core = self.core.?;
        if (!core.poll()) {
            if (output.last_time >= self.deadline) return error.Deadline;
            return;
        }
        if (core.phase == .retained) return error.Visibility;
        const rt = self.runtime();
        if (self.phase == .wait_binding) {
            self.phase = if (core.result == 0) .idle else .discard;
            return;
        }
        self.samples +|= 1;
        self.phase = .idle;
        if (rt.connection.phase == .retained) return error.Unconfirmed;
        if (rt.output.adapter_id == 0 and rt.connection.phase == .disconnected) self.output = .{};
        if (core.result != 0) { self.last_error = rt.last_error; self.next_sample = output.last_time + std.time.ns_per_s; return; }
        if (rt.connection.phase == .probing and rt.receiver.valid) {
            self.token = rt.connection.generation;
            try rt.receiver.describe(rt.route.?.native.connector, &self.receiver);
            self.publication = .{ .backend = output.engine.?.binding, .info = .{
                .identity = .{ .adapter_id = output.output.adapter_id, .device_generation = output.output.device_generation,
                    .connector_id = self.receiver.connector_id }, .connector_kind = self.receiver.connector_kind,
                .flags = self.receiver.flags,
                .edid_bytes = self.receiver.edid_bytes, .possible_heads = output.publication.info.possible_heads,
                .possible_planes = output.publication.info.possible_planes, .possible_plls = output.publication.info.possible_plls,
                .limits = output.publication.info.limits } };
            const limits = self.publication.info.limits;
            for (self.receiver.modes[0..self.receiver.mode_count]) |mode| {
                if (mode.width > limits.max_width or mode.height > limits.max_height or mode.pixel_clock_hz > limits.max_pixel_clock_hz) continue;
                self.publication.modes[self.publication.info.mode_count] = mode; self.publication.info.mode_count += 1;
                if (self.publication.info.preferred_mode_id == 0 or mode.mode_id == self.receiver.preferred_mode_id)
                    self.publication.info.preferred_mode_id = mode.mode_id;
            }
            self.publication.edid = self.receiver.edid;
            self.phase = .publication;
        }
    }
    /// One bounded action per queue-worker slice. A busy catalog must not
    /// block the mode owner whose transaction is currently holding it.
    pub fn step(self: *Owner, output: anytype) !void {
        const core = output.core.?;
        if (core.hdmi_allocation.handle == 0 or !core.hdmi_storage_valid) return;
        self.core = core;
        if (self.waiting() or !output.present.?.available() or output.cursor.phase != .idle or
            !output.modes.permitsQueue() or output.modes.pending != null) return;
        const rt = self.runtime();
        switch (self.phase) {
            .idle => {
                if (output.last_time < self.next_sample) return;
                const probe = output.last_time >= self.next_probe;
                if (probe) self.next_probe = output.last_time + 2 * std.time.ns_per_s;
                self.next_sample = output.last_time + 100 * std.time.ns_per_ms;
                self.deadline = output.last_time + 5 * std.time.ns_per_s;
                try core.hdmiCommand(if (probe) .probe else .service); self.phase = .wait_service;
            },
            .publication => {
                const status = output.outputs.?.publish(&self.publication, &self.output);
                if (status == a.gfx_output_error_busy) return;
                if (status != a.gfx_output_ok or self.output.adapter_id != output.output.adapter_id or
                    self.output.device_generation != output.output.device_generation or self.output.connector_id != rt.route.?.native.connector or
                    self.output.connection_generation == 0) return error.Publication;
                self.phase = .binding;
            },
            .binding => {
                self.deadline = output.last_time + std.time.ns_per_s;
                try core.hdmiPublish(self.token, self.output, .{ .context = @intFromPtr(self), .retire = retire });
                self.phase = .wait_binding;
            },
            .discard => {
                const status = output.outputs.?.withdraw(&self.output);
                if (status == a.gfx_output_error_busy) return;
                if (status != a.gfx_output_ok and status != a.gfx_output_error_stale) return error.Publication;
                self.output = .{}; self.phase = .idle;
            },
            else => return error.State,
        }
    }
    fn retire(raw: usize, token: u64, step_value: hdmi.hotplug.Step) hdmi.hotplug.Receipt {
        const self: *Owner = @ptrFromInt(raw); const rt = self.runtime();
        var receipt: hdmi.hotplug.Receipt = .{ .generation = token };
        if (self.core.?.workerStorage()) |_| {} else |_| return receipt;
        // This owner never submits an HDMI frame or borrows a mode/cursor BO.
        // Such an activation must first replace this receiver-only contract.
        if (token != rt.connection.generation or rt.activation_attempted or rt.configured) return receipt;
        if (step_value == .stop) rt.run(.stop, self.core.?.mode) catch return receipt;
        var stopped: u32 = 0;
        if (dc.c.r4dcn_hdmi_stopped(rt.storage, 1, &stopped) != 0 or stopped != 1) return receipt;
        receipt.scanout_stopped = true; receipt.done = true;
        return receipt;
    }
    pub fn closeMetadata(self: *Owner, outputs: anytype) bool {
        if (self.output.connection_generation == 0) return true;
        const result = outputs.withdraw(&self.output);
        if (result != a.gfx_output_ok and result != a.gfx_output_error_stale) return false;
        self.output = .{}; return true;
    }
};
