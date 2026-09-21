// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Private panel worker to the common copied brightness contract. No MMIO
//! or policy in the kernel; a successful publication never starts a modeset.
const std = @import("std");
const a = @import("r4os").abi;
const panel = @import("panel.zig");
pub const Bridge = struct {
    identity: a.GfxOutputId = .{},
    receipt: ?a.GfxOutputBrightness = null,
    acknowledged: u64 = 0,
    published: u64 = 0,
    pub fn service(self: *Bridge, p: *panel.Panel, outputs: anytype, identity: a.GfxOutputId, now: u64) !void {
        if (identity.adapter_id == 0 or identity.connector_id == 0 or identity.device_generation == 0 or
            identity.connection_generation == 0 or now == 0) return error.Invalid;
        if (!std.meta.eql(identity, self.identity)) {
            self.* = .{ .identity = identity };
        }
        if (self.receipt == null) try self.record(p, now, 0, null);
        // Retry only the copied receipt if publication failed. The completed
        // hardware operation is never replayed while the catalog is busy.
        try self.publish(outputs);
        var request: a.GfxBrightnessRequest = .{};
        if (outputs.readBrightness(&identity, &request) != a.gfx_output_ok) return error.Catalog;
        if (!std.meta.eql(request.identity, identity) or request.sequence < self.acknowledged or request.level > 65535) return error.Stale;
        if (request.sequence == 0 or request.sequence == self.acknowledged) return;
        if (self.receipt.?.sequence == std.math.maxInt(u64)) return error.Exhausted;
        var failure: ?panel.Error = null;
        p.setBrightness(@intCast(request.level)) catch |err| { failure = err; };
        self.acknowledged = request.sequence;
        try self.record(p, @max(now, p.io.now(p.io.context)), request.sequence, failure);
        try self.publish(outputs);
    }
    fn record(self: *Bridge, p: *const panel.Panel, now: u64, request: u64, failure: ?panel.Error) !void {
        const sequence = std.math.add(u64, if (self.receipt) |old| old.sequence else 0, 1) catch return error.Exhausted;
        var value: a.GfxOutputBrightness = .{ .identity = self.identity, .sequence = sequence,
            .request_sequence = request, .since_ns = now, .minimum = p.route.minimum, .maximum = p.route.maximum,
            .current = p.brightness, .flags = if (p.brightness_known) a.gfx_brightness_flag_current_known else 0 };
        value.path = switch (p.brightness_path) { .unavailable => 0, .pwm => a.gfx_brightness_path_pwm,
            .aux8 => a.gfx_brightness_path_aux8, .aux16 => a.gfx_brightness_path_aux16 };
        if (value.path == 0) {
            value.reason = switch (p.brightness_reason) { .firmware_owner => a.gfx_brightness_reason_firmware_owner,
                .invalid_pwm => a.gfx_brightness_reason_invalid_panel, else => a.gfx_brightness_reason_unsupported };
            value.flags = 0;
        } else if (failure) |err| {
            value.phase = a.gfx_brightness_phase_failed;
            value.reason = switch (err) { error.Timeout => a.gfx_brightness_reason_timeout,
                error.State => a.gfx_brightness_reason_inactive, else => a.gfx_brightness_reason_io };
        } else if (p.brightness_known) {
            value.phase = a.gfx_brightness_phase_ready;
        } else {
            value.path = 0; value.flags = 0; value.reason = a.gfx_brightness_reason_inactive;
        }
        self.receipt = value;
    }
    fn publish(self: *Bridge, outputs: anytype) !void {
        const value = self.receipt orelse return error.State;
        if (self.published == value.sequence) return;
        if (outputs.publishBrightness(&value) != a.gfx_output_ok) return error.Catalog;
        self.published = value.sequence;
    }
};
