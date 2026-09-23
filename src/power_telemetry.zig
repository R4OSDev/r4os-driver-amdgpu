// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! SMU10 queried clocks/load and THM9 temperature, independently stamped.
//! No board-limit setters, discrete-GPU power inference or GPU timer claims.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const c = @import("start_common.zig");
const wire = @import("display_clocks.zig").wire;
const thm_address: u32 = (wire.THM_BASE__INST0_SEG0 + wire.mmTHM_TCON_CUR_TMP) * 4;
const max_age: u64 = 3 * std.time.ns_per_s;
const interval: u64 = 500 * std.time.ns_per_ms;
pub fn temperature(raw: u32) c.Error!i64 {
    if (raw == 0xffffffff) return error.Disconnected;
    const units: i64 = (raw & wire.THM_TCON_CUR_TMP__CUR_TEMP_MASK) >> wire.THM_TCON_CUR_TMP__CUR_TEMP__SHIFT;
    // Range selection is in the original register, outside CUR_TEMP. Test
    // it before extracting the temperature (1/8 C), including negative values.
    const mc = units * 125 - @as(i64, if (raw & wire.THM_TCON_CUR_TMP__CUR_TEMP_RANGE_SEL_MASK != 0) 49000 else 0);
    if (mc < -49000 or mc > 150000) return error.Invalid;
    return mc;
}
pub const Owner = struct {
    adapter: u32 = 0, epoch: u64 = 0, smu_version_raw: u32 = 0,
    mailbox: @import("start_smu.zig").Mailbox = .{},
    metrics: [10]a.GfxTelemetryMetric = @splat(.{}),
    phase: enum { minimum, maximum, ready, graphics, fabric, busy } = .minimum,
    min_mhz: u32 = 0, max_mhz: u32 = 0, gfx_mhz: u32 = 0, gfx_stamp: u64 = 0,
    next_exchange: u64 = 0, next_sample: u64 = 0, demanded_until: u64 = 0, demanded: u64 = 0,
    sample_mask: u64 = 0, unavailable: u64 = 0, failures: u32 = 0, last_response: u32 = 0,
    failed: bool = false, closed: bool = false, initialized: bool = false,
    pub fn configure(self: *Owner, adapter: u32, epoch: u64, smu_version_raw: u32) void {
        self.* = .{ .adapter = adapter, .epoch = epoch, .smu_version_raw = smu_version_raw, .initialized = true };
        // SMU10 uses this boundary for PCI15D8 (Picasso flag, also set on
        // Raven2 by amdgpu_device_init_apu_flags before soc15 adds Raven2).
        if (smu_version_raw < 0x41e3b) self.unavailable |= 1 << 2;
    }
    pub fn snapshot(self: *const Owner, now: u64, policy: u32) a.GfxTelemetryState {
        var state: a.GfxTelemetryState = .{ .adapter_id = self.adapter, .memory_generation = self.epoch,
            .sampled_ns = now, .valid_until_ns = now +| max_age, .source = a.gfx_telemetry_source_smu10,
            .state = if (self.closed) 4 else if (self.failed) 3 else 1, .policy = policy, .control_status = self.last_response };
        if (self.closed or self.failed) { state.valid_until_ns = now; return state; }
        state.metrics = self.metrics;
        for (&state.metrics) |*metric| if (metric.status == a.gfx_telemetry_fresh) {
            const until = metric.source_stamp +| max_age;
            if (now < metric.source_stamp or now >= until) metric.* = .{ .status = a.gfx_telemetry_stale }
            else state.valid_until_ns = @min(state.valid_until_ns, until);
        };
        return state;
    }
    pub fn exchange(self: *Owner, memory: r4os.driver_memory.Context, io: anytype, policy: u32) c.Error!void {
        const now = io.nowNs();
        if (!self.initialized or now == 0 or now == std.math.maxInt(u64)) return error.State;
        if (now < self.next_exchange) return;
        self.next_exchange = now +| interval;
        const state = self.snapshot(now, policy);
        var wanted: a.GfxTelemetryDemand = .{};
        const rc = memory.telemetryExchange(&state, &wanted);
        if (rc != a.gfx_buffer_result_ok) return; // Optional old common cache.
        if (wanted.version != 1 or wanted.size < @sizeOf(a.GfxTelemetryDemand) or wanted.reserved0 != 0 or
            wanted.adapter_id != self.adapter or wanted.memory_generation != self.epoch or
            wanted.metric_mask & ~a.gfx_telemetry_metric_mask != 0 or wanted.until_ns > io.nowNs() +| 10 * std.time.ns_per_s) return error.Invalid;
        self.demanded_until = wanted.until_ns;
        self.demanded = wanted.metric_mask & ((1 << 0) | (1 << 2) | (1 << 5));
    }
    pub fn step(self: *Owner, io: anytype) c.Error!void {
        if (!self.initialized or self.closed) return;
        if (self.failed) {
            // A diagnostic timeout keeps ownership, but a late reply can
            // release the shared mailbox without reviving expired samples.
            if (self.mailbox.active) _ = self.mailbox.poll(io, true) catch {};
            return;
        }
        const now = io.nowNs();
        if (now == 0 or now == std.math.maxInt(u64)) return error.Deadline;
        errdefer self.failed = true;
        if (self.mailbox.active) {
            const done = self.mailbox.poll(io, false) catch |err| {
                if (err != error.Response) return err;
                self.last_response = self.mailbox.response;
                self.failures +|= 1;
                switch (self.phase) {
                    .graphics, .fabric => { self.unavailable |= 1; self.metrics[0] = .{}; },
                    .busy => { self.unavailable |= 1 << 2; self.metrics[2] = .{}; },
                    else => {},
                }
                self.phase = .ready;
                return;
            };
            if (!done) return;
            const value = self.mailbox.argument;
            self.last_response = 0;
            switch (self.phase) {
                .minimum => { if (value == 0 or value > 4000) return error.Invalid; self.min_mhz = value; self.phase = .maximum; },
                .maximum => { if (value < self.min_mhz or value > 4000) return error.Invalid; self.max_mhz = value; self.phase = .ready; },
                .graphics => { if (value > 4000) return error.Invalid; self.gfx_mhz = value; self.gfx_stamp = now; self.phase = .fabric; },
                .fabric => {
                    if (value > 4000) return error.Invalid;
                    self.metrics[0] = .{ .status = a.gfx_telemetry_fresh, .source_stamp = self.gfx_stamp,
                        .flags = a.gfx_telemetry_partial_values | a.gfx_telemetry_current_clocks | a.gfx_telemetry_fabric_clock | (3 << 8),
                        .values = .{ @as(i64, self.gfx_mhz) * 1_000_000, @as(i64, value) * 1_000_000, 0, 0 } };
                    self.phase = if (self.sample_mask & (1 << 2) != 0) .busy else .ready;
                },
                .busy => {
                    if (value > 100) return error.Invalid;
                    self.metrics[2] = .{ .status = a.gfx_telemetry_fresh, .source_stamp = now,
                        .flags = a.gfx_telemetry_partial_values | (1 << 8), .values = .{ value, 0, 0, 0 } };
                    self.phase = .ready;
                },
                else => return error.State,
            }
            return;
        }
        if (self.phase == .ready) {
            if (now >= self.demanded_until or now < self.next_sample) return;
            self.next_sample = now +| interval;
            self.sample_mask = self.demanded & ~self.unavailable;
            if (self.sample_mask & (1 << 5) != 0) {
                const raw = try io.read(thm_address);
                self.metrics[5] = .{ .status = a.gfx_telemetry_fresh, .source_stamp = now, .values = .{ try temperature(raw), 0, 0, 0 } };
            }
            self.phase = if (self.sample_mask & 1 != 0) .graphics else if (self.sample_mask & (1 << 2) != 0) .busy else .ready;
        }
        const message: u32 = switch (self.phase) {
            .minimum => wire.PPSMC_MSG_GetMinGfxclkFrequency,
            .maximum => wire.PPSMC_MSG_GetMaxGfxclkFrequency,
            .graphics => wire.PPSMC_MSG_GetGfxclkFrequency,
            .fabric => wire.PPSMC_MSG_GetFclkFrequency,
            .busy => wire.PPSMC_MSG_GetGfxBusy,
            .ready => return,
        };
        self.mailbox.begin(io, message, null) catch |err| {
            if (err == error.Busy and !self.mailbox.active) return;
            return err;
        };
    }
    pub fn drain(self: *Owner, io: anytype) bool {
        self.closed = true; self.demanded = 0; self.metrics = @splat(.{}); self.next_exchange = 0;
        if (self.mailbox.active) {
            _ = self.mailbox.poll(io, true) catch {};
            if (self.mailbox.active) return false;
        }
        return true;
    }
};
