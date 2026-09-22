// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! HDMI receiver discovery and canonical identity, with independent native
//! head admission and physical retirement in the shared DCN task.
const std = @import("std");
const a = @import("r4os").abi;
const dc = @import("display_core.zig");
const hdmi = @import("hdmi_runtime.zig");
pub const Owner = struct {
    core: ?*dc.Owner = null,
    head: ?*@import("display_head.zig").Owner = null,
    phase: enum { idle, wait_service, catalog, wait_catalog, publication, binding, wait_binding, discard } = .idle,
    next_sample: u64 = 0,
    next_probe: u64 = 0,
    deadline: u64 = 0,
    token: u64 = 0,
    output: a.GfxOutputId = .{},
    publication: a.GfxOutputPublication = .{},
    receiver: a.GfxReceiverInfo = .{},
    last_error: ?anyerror = null,
    samples: u64 = 0,
    quarantined: bool = false,
    pub fn waiting(self: *const Owner) bool { return self.phase == .wait_service or self.phase == .wait_binding or self.phase == .wait_catalog; }
    fn runtime(self: *Owner) *hdmi.Runtime { return @ptrFromInt(self.core.?.hdmi_allocation.cpu_address); }
    /// Always poll a task already launched before another core user runs.
    pub fn poll(self: *Owner, output: anytype) !void {
        if (!self.waiting()) return;
        const core = self.core.?;
        if (self.phase == .wait_catalog) {
            if (try self.head.?.planCatalog(output)) { self.publication = self.head.?.publication; self.phase = .publication; }
            else if (self.head.?.phase == .catalog) self.phase = .catalog;
            return;
        }
        if (!core.poll()) {
            if (output.last_time >= self.deadline) return error.Deadline;
            return;
        }
        if (core.phase == .retained) return error.Visibility;
        const rt = self.runtime();
        if (self.phase == .wait_binding) {
            if (core.result == 0) { try self.head.?.published(self.output); self.phase = .idle; }
            else self.phase = .discard;
            return;
        }
        self.samples +|= 1;
        self.phase = .idle;
        if (rt.connection.phase == .retained) {
            self.last_error = error.Unconfirmed; self.quarantined = true;
            self.head.?.fail(error.Unconfirmed); return;
        }
        if (rt.output.adapter_id == 0 and rt.connection.phase == .disconnected) {
            self.output = .{};
            if (self.head.?.released) { self.head.?.* = .{}; core.extra_scanout = .{}; }
        }
        if (core.result != 0) { self.last_error = rt.last_error; self.next_sample = output.last_time + std.time.ns_per_s; return; }
        if (rt.connection.phase == .probing and rt.receiver.valid) {
            self.token = rt.connection.generation;
            try rt.receiver.describe(rt.route.?.native.connector, &self.receiver);
            if (self.head.?.self_address != 0) return error.State;
            try self.head.?.begin(output, self.receiver, self.token);
            self.phase = .catalog;
        }
    }
    /// One bounded action per queue-worker slice. A busy catalog must not
    /// block the mode owner whose transaction is currently holding it.
    pub fn step(self: *Owner, output: anytype) !void {
        const core = output.core.?;
        if (core.hdmi_allocation.handle == 0 or !core.hdmi_storage_valid) return;
        self.core = core; self.head = &output.additional;
        if (self.quarantined or self.waiting() or core.thread != 0 or (output.primary_failure == null and output.cursor.phase != .idle) or !output.modes.ready or
            (output.primary_failure == null and output.modes.waiting()) or output.additional.waiting()) return;
        const rt = self.runtime();
        switch (self.phase) {
            .idle => {
                if (output.last_time < self.next_sample) return;
                const probe = output.last_time >= self.next_probe;
                if (probe) self.next_probe = output.last_time + 2 * std.time.ns_per_s;
                self.next_sample = output.last_time + 100 * std.time.ns_per_ms;
                self.deadline = output.last_time + 5 * std.time.ns_per_s;
                core.stop_extra = output.additional.draining;
                try core.hdmiCommand(if (probe) .probe else .service); self.phase = .wait_service;
            },
            .catalog => {
                if (core.scanout_owner.phase != .active and core.scanout_owner.phase != .stopped) return;
                if (try self.head.?.planCatalog(output)) { self.publication = self.head.?.publication; self.phase = .publication; }
                else if (self.head.?.waiting()) self.phase = .wait_catalog;
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
                self.output = .{};
                if (self.head.?.self_address != 0) { self.head.?.hardware_stopped = true; if (!self.head.?.closeResources()) return; self.head.?.* = .{}; }
                self.phase = .idle;
            },
            else => return error.State,
        }
    }
    fn retire(raw: usize, token: u64, step_value: hdmi.hotplug.Step) hdmi.hotplug.Receipt {
        const self: *Owner = @ptrFromInt(raw); const rt = self.runtime();
        var receipt: hdmi.hotplug.Receipt = .{ .generation = token };
        if (self.core.?.workerStorage()) |_| {} else |_| return receipt;
        if (token != rt.connection.generation) return receipt;
        const head = self.head orelse return receipt;
        receipt = head.retire(token, step_value);
        if (step_value == .stop and receipt.done) {
            rt.run(.stop, self.core.?.mode) catch return .{ .generation = token };
            var stopped: u32 = 0;
            if (dc.c.r4dcn_hdmi_stopped(rt.storage, 1, &stopped) != 0 or stopped != 1) return .{ .generation = token };
        }
        return receipt;
    }
    pub fn closeMetadata(self: *Owner, outputs: anytype) bool {
        if (self.output.connection_generation == 0) return true;
        const result = outputs.withdraw(&self.output);
        if (result != a.gfx_output_ok and result != a.gfx_output_error_stale) return false;
        self.output = .{}; return true;
    }
};
