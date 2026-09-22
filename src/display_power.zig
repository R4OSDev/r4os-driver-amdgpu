// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Copied common screen intent; only a joined DCN task acknowledges physical
//! off/on. Images, cursor BOs, epochs and connector identity remain retained.
const std = @import("std");
const a = @import("r4os").abi;
const Entry = struct {
    identity: a.GfxOutputId = .{},
    intent: a.GfxPowerRequest = .{},
    published: ?a.GfxOutputPower = null,
    phase: u32 = a.gfx_power_phase_on,
    pending: bool = false,
    completed: bool = false,
    receipt: u64 = 0,
    point: u64 = 0,
};
pub const Owner = struct {
    entries: [2]Entry = @splat(.{}),
    pub fn permits(self: *const Owner, primary: bool) bool {
        return self.entries[if (primary) @as(usize, 0) else 1].phase == a.gfx_power_phase_on;
    }
    pub fn held(self: *const Owner) bool { return !self.permits(true) or !self.permits(false); }
    pub fn transition(self: *const Owner) bool {
        for (&self.entries) |*e| if (e.pending or e.phase == a.gfx_power_phase_stopping or e.phase == a.gfx_power_phase_waking) return true;
        return false;
    }
    fn ready(output: anytype) bool {
        if (!output.modes.permitsQueue() or output.modes.pending != null or output.mode_inbox != null or output.cursor.phase != .idle or
            output.present.?.input != null or output.health_pending or output.brightness_pending or
            output.connector.waiting() or output.core.?.thread != 0) return false;
        const head = &output.additional;
        return !head.draining and !head.waiting() and head.mode_inbox == null and head.presentation.input == null and
            (head.phase != .active or (head.modes.permitsQueue() and head.modes.pending == null));
    }
    /// `drive=false` is the GC-sleep path: inspect copied requests only, then
    /// the queue power owner wakes GC before a normal worker drives hardware.
    pub fn poll(self: *Owner, output: anytype, drive: bool) !void {
        const outputs = output.outputs.?; const core = output.core.?;
        if (!outputs.supportsPower() or !output.modes.ready) return;
        for (&self.entries, 0..) |*e, i| {
            if (!e.pending) continue;
            if (!drive or !core.poll()) return;
            e.pending = false;
            const life = if (i == 0) &core.scanout_owner else &core.extra_scanout;
            const off = e.phase == a.gfx_power_phase_stopping;
            if (core.result != 0 or core.phase != .programmed or life.phase != (if (off) @as(@TypeOf(life.phase), .stopped) else .active)) {
                e.phase = a.gfx_power_phase_unavailable;
                _ = try publish(e, outputs, output.last_time, i == 0);
                return error.Unconfirmed;
            }
            e.receipt = std.math.add(u64, e.receipt, 1) catch return error.Exhausted;
            e.point = life.sequence;
            if (!off) {
                if (i == 0) output.present.?.sequence = life.sequence else output.additional.presentation.sequence = life.sequence;
                output.next_health = output.last_time; output.health_retry_deadline = 0; output.next_brightness = output.last_time;
            }
            e.completed = true;
        }
        // Another DCN task may mutate scanout/connector data until joined.
        if (core.thread != 0) return;
        for (&self.entries, 0..) |*e, i| {
            const primary = i == 0;
            const identity = if (primary) output.output else output.additional.output;
            if ((!primary and (output.additional.phase != .active or output.additional.draining)) or
                identity.connection_generation == 0 or (primary and output.primary_failure != null)) {
                if (!e.pending) e.* = .{};
                continue;
            }
            const epoch = if (primary) output.epoch else output.additional.epoch;
            const life = core.scanoutFor(epoch);
            if (!std.meta.eql(e.identity, identity)) e.* = .{ .identity = identity, .point = life.sequence };
            if (e.completed) {
                if (e.phase == a.gfx_power_phase_waking) {
                    const unpause = outputs.pauseOutput(&e.identity, false);
                    if (unpause == a.gfx_output_error_busy) return;
                    if (unpause != a.gfx_output_ok) return error.Catalog;
                    e.phase = a.gfx_power_phase_on;
                } else e.phase = a.gfx_power_phase_off;
                e.completed = false;
            }
            if (!try publish(e, outputs, output.last_time, primary)) return;
            var intent: a.GfxPowerRequest = .{};
            const status = outputs.readPower(&identity, &intent);
            if (status == a.gfx_output_error_busy or status == a.gfx_output_error_stale) continue;
            if (status != a.gfx_output_ok or !std.meta.eql(intent.identity, identity) or intent.off > 1 or intent.sequence < e.intent.sequence) return error.Catalog;
            e.intent = intent;
            const off = intent.off != 0;
            if ((off and e.phase == a.gfx_power_phase_on) or (!off and e.phase == a.gfx_power_phase_off)) {
                // Stop new common presentation before touching the hardware.
                // Existing transactions drain in the normal worker first.
                if (!ready(output)) continue;
                if (outputs.pauseOutput(&identity, true) != a.gfx_output_ok) continue;
                e.phase = if (off) a.gfx_power_phase_stopping else a.gfx_power_phase_waking;
                if (!try publish(e, outputs, output.last_time, primary)) return;
            }
            if (e.phase != a.gfx_power_phase_stopping and e.phase != a.gfx_power_phase_waking) continue;
            if (!drive or !ready(output)) continue;
            // A reversed request completes the already admitted transition,
            // then converges on the newest intent in the next worker pass.
            try core.powerCommand(.{ .epoch = epoch, .off = e.phase == a.gfx_power_phase_stopping });
            e.pending = true; return;
        }
    }
    fn publish(e: *Entry, outputs: anytype, now: u64, primary: bool) !bool {
        var value: a.GfxOutputPower = .{ .identity = e.identity,
            .capabilities = a.gfx_power_cap_signal | @as(u32, if (primary) a.gfx_power_cap_sink else 0),
            .phase = e.phase, .sequence = if (e.published) |old| old.sequence else 1,
            .request_sequence = e.intent.sequence, .since_ns = if (e.published) |old| old.since_ns else now,
            .control_receipt = e.receipt, .core_point = e.point, .window_point = e.point,
            .reason = if (e.phase == a.gfx_power_phase_unavailable) a.gfx_power_reason_rejected else 0 };
        if (e.published) |old| {
            if (std.meta.eql(old, value)) return true;
            value.sequence = std.math.add(u64, value.sequence, 1) catch return error.Exhausted;
            value.since_ns = @max(now, old.since_ns);
        }
        const status = outputs.publishPower(&value);
        if (status == a.gfx_output_error_busy) return false;
        if (status != a.gfx_output_ok) return error.Catalog;
        e.published = value; return true;
    }
};
