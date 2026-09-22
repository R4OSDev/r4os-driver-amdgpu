// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const c = @import("start_common.zig");
const r = @import("start_registers.zig");
const s = @import("start_storage.zig");
const fw = @import("firmware_store.zig");
pub const Error = c.Error;
pub const Phase = enum { empty, smu_version_send, smu_version_wait, smu_interface_send, smu_interface_wait,
    gfx_wake_send, gfx_wake_wait, gfx_on, sdma_wake_send, sdma_wake_wait, park, parked,
    psp_create, psp_wait, tmr_send, tmr_wait, firmware_send, firmware_wait, asd_send, asd_wait,
    firmware_ready, cleanup_drain, cleanup_park, cleanup_parked, cleanup_asd, cleanup_tmr, cleanup_ring, closed, retained };
pub const Flow = struct {
    phase: Phase = .empty, failure: ?Error = null, failed_phase: Phase = .empty,
    epoch: u64 = 0, smu_version_raw: u32 = 0, smu_version: u32 = 0, smu_interface: u32 = 0,
    smu_effects: bool = false, upload: usize = 0, view: ?s.View = null, store: ?*const fw.Store = null,
    total: c.Deadline = .{}, cleanup_deadline: c.Deadline = .{},
    smu: @import("start_smu.zig").Mailbox = .{}, psp: @import("start_psp.zig").Controller = .{},
    engines: @import("start_engines.zig").Park = .{}, plan: @import("start_firmware.zig").Plan = .{},
    pub fn begin(self: *Flow, io: anytype, view: s.View, store: *const fw.Store, epoch: u64, boot_latched: bool) Error!void {
        if (self.phase != .empty) return error.Busy;
        if (epoch == 0 or !boot_latched) return error.Unconfirmed;
        try self.plan.prepare(store); try self.total.start(io.nowNs(), 35_000_000_000, 0);
        self.epoch = epoch; self.view = view; self.store = store; self.phase = .smu_version_send;
    }
    pub fn advance(self: *Flow, io: anytype) Error!void {
        self.step(io) catch |err| {
            if (self.failure == null) { self.failure = err; self.failed_phase = self.phase; }
            if (@intFromEnum(self.phase) < @intFromEnum(Phase.cleanup_drain)) self.abort(io) else self.phase = .retained;
            return err;
        };
    }
    fn step(self: *Flow, io: anytype) Error!void {
        if (self.phase == .empty or self.phase == .closed or self.phase == .retained or self.phase == .firmware_ready) return;
        const cleanup = @intFromEnum(self.phase) >= @intFromEnum(Phase.cleanup_drain);
        _ = try (if (cleanup) &self.cleanup_deadline else &self.total).check(io.nowNs());
        const view = self.view.?;
        if (!cleanup and (!self.store.?.valid or self.store.?.generation != self.plan.generation)) return error.Stale;
        switch (self.phase) {
            .smu_version_send => try self.send(io, r.PPSMC_MSG_GetSmuVersion, .smu_version_wait),
            .smu_version_wait => if (try self.smu.poll(io, false)) {
                self.smu_version_raw = self.smu.argument;
                self.smu_version = self.smu.argument >> 8;
                if (self.smu_version == 0) return error.Firmware;
                self.phase = .smu_interface_send;
            },
            .smu_interface_send => try self.send(io, r.PPSMC_MSG_GetDriverIfVersion, .smu_interface_wait),
            .smu_interface_wait => if (try self.smu.poll(io, false)) {
                self.smu_interface = self.smu.argument;
                if (self.smu_interface != r.smu_driver_if and self.smu_interface != r.smu_driver_if + 1) return error.Interface;
                self.phase = .gfx_wake_send;
            },
            .gfx_wake_send => { self.smu_effects = true; try self.send(io, r.PPSMC_MSG_DisableGfxOff, .gfx_wake_wait); },
            .gfx_wake_wait => if (try self.smu.poll(io, false)) { self.phase = .gfx_on; },
            .gfx_on => if (try gfxOn(io)) { self.phase = .sdma_wake_send; },
            .sdma_wake_send => try self.send(io, r.PPSMC_MSG_PowerUpSdma, .sdma_wake_wait),
            .sdma_wake_wait => if (try self.smu.poll(io, false)) { self.phase = .park; },
            .park => { try self.engines.begin(io); self.phase = .parked; },
            .parked => if (try self.engines.poll(io)) { self.phase = .psp_create; },
            .psp_create => { try self.psp.create(io, view); self.phase = .psp_wait; },
            .psp_wait => if (try self.psp.pollMailbox(io, false)) { self.phase = .tmr_send; },
            .tmr_send => {
                const gpu = view.address(view.tmr_offset); const physical = view.physical + view.tmr_offset;
                // virt_phy_addr is bit 1 in the original PSP C bitfield.
                try self.psp.submit(io, view, .tmr, &.{ @truncate(gpu), @truncate(gpu >> 32), s.tmr_bytes, 2, @truncate(physical), @truncate(physical >> 32) });
                self.phase = .tmr_wait;
            },
            .tmr_wait => if (try self.psp.poll(io, view, false)) { self.phase = .firmware_send; },
            .firmware_send => {
                if (self.upload == self.plan.count) { self.phase = .asd_send; return; }
                const entry = &self.plan.entries[self.upload];
                const blob = self.store.?.container(entry.role) orelse return error.Firmware;
                try view.copyFirmware(entry.span.slice(blob));
                const gpu = view.address(s.staging);
                try self.psp.submit(io, view, .firmware, &.{ @truncate(gpu), @truncate(gpu >> 32), @intCast(entry.span.bytes), entry.fw_type });
                self.phase = .firmware_wait;
            },
            .firmware_wait => if (try self.psp.poll(io, view, false)) {
                const entry = &self.plan.entries[self.upload]; const addr = self.psp.firmware_address;
                // MEC instruction bases are consumed by the later GC ring owner.
                // A nonzero returned address must point into our actual TMR.
                const tmr = view.address(view.tmr_offset);
                if (addr != 0 and (addr < tmr or addr >= tmr + s.tmr_bytes or entry.span.bytes > tmr + s.tmr_bytes - addr)) return error.Firmware;
                if ((entry.fw_type == c.wire.GFX_FW_TYPE_CP_MEC or entry.fw_type == c.wire.GFX_FW_TYPE_VCN) and addr == 0) return error.Firmware;
                entry.address = addr; entry.confirmed = true;
                self.upload += 1; self.phase = .firmware_send;
            },
            .asd_send => {
                try view.copyFirmware(self.plan.asd.slice(self.store.?.container(.asd) orelse return error.Firmware));
                const gpu = view.address(s.staging);
                // ASD has no shared buffer on PSP10 (PSP_ASD_SHARED_MEM_SIZE=0).
                try self.psp.submit(io, view, .asd, &.{ @truncate(gpu), @truncate(gpu >> 32), @intCast(self.plan.asd.bytes), 0, 0, 0 });
                self.phase = .asd_wait;
            },
            .asd_wait => if (try self.psp.poll(io, view, false)) { self.phase = .firmware_ready; },
            .cleanup_drain => {
                if (self.smu.active) {
                    _ = self.smu.poll(io, true) catch |err| { if (self.smu.active) return err; return; };
                    if (self.smu.active) return;
                }
                if (self.psp.mailbox != .none) {
                    if (!try self.psp.pollMailbox(io, true)) return;
                }
                if (self.psp.operation != .none) {
                    _ = self.psp.poll(io, view, true) catch |err| { if (self.psp.operation != .none) return err; return; };
                    if (self.psp.operation != .none) return;
                }
                self.phase = .cleanup_park;
            },
            .cleanup_park => {
                if (!self.smu_effects and !self.engines.touched) { self.phase = .cleanup_asd; return; }
                if (!try gfxOn(io)) return;
                try self.engines.begin(io); self.phase = .cleanup_parked;
            },
            .cleanup_parked => if (try self.engines.poll(io)) { self.phase = .cleanup_asd; },
            .cleanup_asd => {
                if (self.psp.operation != .none) { _ = try self.psp.poll(io, view, false); return; }
                if (self.psp.asd_ready) { try self.psp.submit(io, view, .unload, &.{self.psp.asd_session}); return; }
                self.phase = .cleanup_tmr;
            },
            .cleanup_tmr => {
                if (self.psp.operation != .none) { _ = try self.psp.poll(io, view, false); return; }
                if (self.psp.tmr_possible) { try self.psp.submit(io, view, .destroy, &.{}); return; }
                self.phase = .cleanup_ring;
            },
            .cleanup_ring => {
                if (self.psp.mailbox != .none) { _ = try self.psp.pollMailbox(io, false); return; }
                if (self.psp.ring_possible) { try self.psp.stop(io); return; }
                if (!self.psp.safeToRelease()) return error.Retained;
                self.phase = .closed;
            },
            else => unreachable,
        }
    }
    fn send(self: *Flow, io: anytype, message: u32, next: Phase) Error!void {
        self.smu.begin(io, message, null) catch |err| { if (err == error.Busy and !self.smu.active) return; return err; };
        self.phase = next;
    }
    pub fn abort(self: *Flow, io: anytype) void {
        if (self.phase == .empty or self.phase == .closed) return;
        self.cleanup_deadline.start(io.nowNs(), 8_000_000_000, 0) catch { self.phase = .retained; return; };
        self.phase = .cleanup_drain;
    }
    pub fn firmwareReady(self: *const Flow) bool {
        return self.phase == .firmware_ready and self.failure == null and self.plan.confirmed() and
            self.psp.ring_ready and self.psp.tmr_ready and self.psp.asd_ready and self.engines.confirmed and
            self.smu_version != 0 and (self.smu_interface == r.smu_driver_if or self.smu_interface == r.smu_driver_if + 1);
    }
    pub fn safeToRelease(self: *const Flow) bool {
        return (self.phase == .empty or self.phase == .closed) and !self.smu.active and self.psp.safeToRelease() and
            (!self.engines.touched or self.engines.confirmed);
    }
};
fn gfxOn(io: anytype) Error!bool {
    return try c.read(io, r.pwr.PWR_MISC_CNTL_STATUS) & r.pwr.PWR_MISC_CNTL_STATUS__PWR_GFXOFF_STATUS_MASK ==
        @as(u32, 2) << @as(u5, @intCast(r.pwr.PWR_MISC_CNTL_STATUS__PWR_GFXOFF_STATUS__SHIFT));
}
