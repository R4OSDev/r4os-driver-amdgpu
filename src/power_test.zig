// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Part of the existing startup qualification; explicit register/SMU model.
const std = @import("std");
const t = std.testing;
const c = @import("start_common.zig");
const r = @import("gc_registers.zig");
const sr = @import("start_registers.zig");
const w = @import("display_clocks.zig").wire;
const a = @import("r4os").abi;
const Gfx = @import("power_gfx.zig").Owner;
const Sensor = @import("power_telemetry.zig").Owner;
const F = struct {
    var registers: [@import("memory_registers.zig").required_prefix / 4]u32 = @splat(0);
    var now: u64 = 1;
    var lease: usize = 0;
    var safe_ack = true;
    var smu_ack: u32 = 1;
    var requests: usize = 0;
    var failed_write: u32 = 0;
    var busy: u32 = 37;
    fn reset() void {
        registers = @splat(0); now = 1; lease = 0; safe_ack = true; smu_ack = 1; requests = 0; failed_write = 0; busy = 37;
        registers[sr.smu.MP1_SMN_C2PMSG_90 / 4] = 1;
        registers[r.RLC_CNTL / 4] = r.RLC_CNTL__RLC_ENABLE_F32_MASK;
        registers[r.RLC_SRM_CNTL / 4] = r.RLC_SRM_CNTL__SRM_ENABLE_MASK;
        registers[sr.pwr.PWR_MISC_CNTL_STATUS / 4] = 2 << sr.pwr.PWR_MISC_CNTL_STATUS__PWR_GFXOFF_STATUS__SHIFT;
        registers[(w.THM_BASE__INST0_SEG0 + w.mmTHM_TCON_CUR_TMP)] = 417 << w.THM_TCON_CUR_TMP__CUR_TEMP__SHIFT;
    }
    pub fn claimSmu(_: *F, owner: usize) bool { if (lease != 0) return false; lease = owner; return true; }
    pub fn releaseSmu(_: *F, owner: usize) void { std.debug.assert(lease == owner); lease = 0; }
    pub fn read(_: *F, reg: u32) c.Error!u32 { return registers[reg / 4]; }
    pub fn nowNs(_: *F) u64 { return now; }
    pub fn barrier(_: *F) c.Error!void {}
    pub fn write(_: *F, reg: u32, value: u32) c.Error!void {
        if (reg == failed_write) { failed_write = 0; return error.Disconnected; }
        registers[reg / 4] = value;
        if (reg == r.RLC_SAFE_MODE and safe_ack) registers[reg / 4] &= ~r.RLC_SAFE_MODE__CMD_MASK;
        if (reg == sr.smu.MP1_SMN_C2PMSG_66) {
            requests += 1;
            const result: u32 = switch (value) {
                w.PPSMC_MSG_GetMinGfxclkFrequency => 200,
                w.PPSMC_MSG_GetMaxGfxclkFrequency => 1400,
                w.PPSMC_MSG_GetGfxclkFrequency => 800,
                w.PPSMC_MSG_GetFclkFrequency => 1200,
                w.PPSMC_MSG_GetGfxBusy => busy,
                sr.PPSMC_MSG_EnableGfxOff, sr.PPSMC_MSG_DisableGfxOff => 0,
                // No voltage, CPU power or firmware limit writes are allowed.
                else => return error.Unsupported,
            };
            registers[sr.smu.MP1_SMN_C2PMSG_82 / 4] = result;
            registers[sr.smu.MP1_SMN_C2PMSG_90 / 4] = smu_ack;
        }
    }
};
fn drive(gfx: *Gfx, io: *F, want: bool, idle: bool, closing: bool, count: usize) !void {
    for (0..count) |_| { F.now += 1_000_000; try gfx.step(io, want, idle, closing); }
}
pub fn check() !void {
    var io: F = .{};
    F.reset(); var gfx: Gfx = .{};
    try gfx.begin(&io, true);
    try drive(&gfx, &io, true, false, false, 2); try t.expect(gfx.awake());
    const after_config = F.requests;
    try drive(&gfx, &io, false, false, false, 4);
    try t.expect(gfx.awake() and F.requests == after_config); // Idle must be proved by the queue owner.
    try drive(&gfx, &io, false, true, false, 5);
    try t.expect(gfx.phase == .allowed and !gfx.awake() and gfx.allowed);
    try t.expect(F.registers[r.RLC_PG_CNTL / 4] & r.RLC_PG_CNTL__GFX_POWER_GATING_ENABLE_MASK != 0);
    F.registers[sr.pwr.PWR_MISC_CNTL_STATUS / 4] &= ~sr.pwr.PWR_MISC_CNTL_STATUS__PWR_GFXOFF_STATUS_MASK;
    try drive(&gfx, &io, true, false, false, 5);
    try t.expect(gfx.phase == .wake_status and !gfx.awake()); // An SMU ACK alone is not awake hardware.
    F.registers[sr.pwr.PWR_MISC_CNTL_STATUS / 4] |= 2 << sr.pwr.PWR_MISC_CNTL_STATUS__PWR_GFXOFF_STATUS__SHIFT;
    try drive(&gfx, &io, true, false, false, 3);
    try t.expect(gfx.awake() and !gfx.allowed);
    try t.expect(F.registers[r.RLC_PG_CNTL / 4] & r.RLC_PG_CNTL__GFX_POWER_GATING_ENABLE_MASK == 0);
    try drive(&gfx, &io, true, false, true, 3);
    try t.expect(gfx.phase == .closed and F.registers[r.RLC_PG_CNTL / 4] == 0 and F.lease == 0);
    // Unsupported board quirk leaves clock gating but never sends GFXOFF.
    F.reset(); gfx = .{}; try gfx.begin(&io, false); try drive(&gfx, &io, false, true, false, 12);
    try t.expect(gfx.awake() and F.requests == 0);
    var identity: @import("identity.zig").Snapshot = std.mem.zeroes(@import("identity.zig").Snapshot);
    identity.pci.device_id = 0x15d8; identity.subsystem_vendor = 0x19e5; identity.subsystem_device = 0x3e14; identity.pci_revision = 0xc2;
    try t.expect(@import("power_gfx.zig").quirk(identity)); identity.subsystem_vendor = 0x17aa;
    try t.expect(!@import("power_gfx.zig").quirk(identity));
    // Late enable response retains its lease and must be explicitly disabled.
    F.reset(); gfx = .{}; try gfx.begin(&io, true); try drive(&gfx, &io, true, false, false, 2);
    F.smu_ack = 0; try drive(&gfx, &io, false, true, false, 4);
    F.now += 500_000_000; try t.expectError(error.Deadline, gfx.step(&io, true, false, false));
    try t.expect(gfx.mailbox.active and F.lease != 0 and !gfx.awake());
    F.registers[sr.smu.MP1_SMN_C2PMSG_90 / 4] = 1; F.smu_ack = 1;
    try drive(&gfx, &io, true, false, true, 10); try t.expect(gfx.phase == .closed and F.lease == 0);
    // Partial RLC configuration restores the captured values on the same path.
    F.reset(); gfx = .{}; try gfx.begin(&io, true); F.failed_write = r.CP_MEM_SLP_CNTL;
    try t.expectError(error.Disconnected, gfx.step(&io, true, false, false));
    try drive(&gfx, &io, true, false, true, 3); try t.expect(gfx.phase == .closed);
    // A negative enable ACK never strands the state machine in an inactive wait.
    F.reset(); gfx = .{}; try gfx.begin(&io, true); try drive(&gfx, &io, true, false, false, 2);
    F.smu_ack = 0xff; try drive(&gfx, &io, false, true, false, 4);
    try t.expectError(error.Response, gfx.step(&io, false, true, false));
    F.smu_ack = 1; try drive(&gfx, &io, true, false, true, 10); try t.expect(gfx.phase == .closed);
    // Thermal range and fractional precision come from THM9, not a discrete GPU sensor.
    try t.expectEqual(@as(i64, 52125), try @import("power_telemetry.zig").temperature(417 << w.THM_TCON_CUR_TMP__CUR_TEMP__SHIFT));
    try t.expectEqual(@as(i64, -12500), try @import("power_telemetry.zig").temperature((292 << w.THM_TCON_CUR_TMP__CUR_TEMP__SHIFT) | w.THM_TCON_CUR_TMP__CUR_TEMP_RANGE_SEL_MASK));
    try t.expectError(error.Disconnected, @import("power_telemetry.zig").temperature(0xffffffff));
    F.reset(); var sensor: Sensor = .{}; sensor.configure(7, 19, 0x41e3b);
    for (0..4) |_| try sensor.step(&io);
    try t.expect(sensor.min_mhz == 200 and sensor.max_mhz == 1400 and F.requests == 2);
    for (0..8) |_| try sensor.step(&io);
    try t.expectEqual(@as(usize, 2), F.requests); // No diagnostics: no sensor polling.
    sensor.demanded = 1 | (1 << 2) | (1 << 5); sensor.demanded_until = F.now + 10_000_000;
    for (0..6) |_| try sensor.step(&io);
    const state = sensor.snapshot(F.now, 0);
    try t.expectEqual(@as(i64, 800_000_000), state.metrics[0].values[0]);
    try t.expectEqual(@as(i64, 1200_000_000), state.metrics[0].values[1]);
    try t.expect(state.metrics[0].flags == (3 << 8) | a.gfx_telemetry_partial_values | a.gfx_telemetry_current_clocks | a.gfx_telemetry_fabric_clock);
    try t.expect(state.metrics[2].values[0] == 37 and state.metrics[2].flags == (1 << 8) | a.gfx_telemetry_partial_values);
    try t.expect(state.metrics[5].values[0] == 52125 and state.metrics[7].status == a.gfx_telemetry_unavailable and state.metrics[9].status == a.gfx_telemetry_unavailable);
    F.now += 3_000_000_000;
    const old = sensor.snapshot(F.now, 0); try t.expect(old.metrics[0].status == a.gfx_telemetry_stale and old.metrics[0].values[0] == 0);
    const requests = F.requests; for (0..8) |_| try sensor.step(&io); try t.expectEqual(requests, F.requests);
    F.reset(); sensor.configure(7, 20, 0x41e3a); try t.expect(sensor.unavailable & (1 << 2) != 0);
    for (0..4) |_| try sensor.step(&io);
    sensor.demanded = 1 << 2; sensor.demanded_until = 1000; try sensor.step(&io);
    try t.expectEqual(@as(usize, 2), F.requests);
    F.reset(); sensor.configure(7, 21, 0x41e3b);
    for (0..4) |_| try sensor.step(&io);
    sensor.demanded = 1; sensor.demanded_until = F.now + 10_000_000_000;
    F.smu_ack = 0; try sensor.step(&io); F.now += 500_000_000;
    try t.expectError(error.Deadline, sensor.step(&io));
    try t.expect(sensor.failed and sensor.mailbox.active and F.lease != 0);
    F.registers[sr.smu.MP1_SMN_C2PMSG_90 / 4] = 1;
    try sensor.step(&io); try t.expect(!sensor.mailbox.active and F.lease == 0);
    try t.expect(sensor.snapshot(F.now, 0).state == 3 and sensor.snapshot(F.now, 0).metrics[0].status == a.gfx_telemetry_unavailable);
    std.debug.print("[amd-power] SMU10 factory limits, finite demand, partial clocks/load, THM9, RLC/GFXOFF ACK/quirk/late-failure restoration; model only\n", .{});
}
