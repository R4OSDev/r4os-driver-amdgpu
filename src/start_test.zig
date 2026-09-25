// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std"); const t = std.testing;
const c = @import("start_common.zig"); const r = @import("start_registers.zig");
const s = @import("start_storage.zig"); const fw = @import("firmware.zig");
const Flow = @import("start_flow.zig").Flow; const Phase = @import("start_flow.zig").Phase;
const F = struct {
    var words: [@import("memory_registers.zig").required_prefix / 4]u32 align(4096) = undefined;
    var arena: [16 * 1024 * 1024 / 4]u32 align(4096) = undefined;
    var package: [fw.max_package_bytes]u8 align(16) = undefined;
    var store: @import("firmware_store.zig").Store = .{};
    var flow: Flow = .{};
    var active: *Flow = &flow;
    var view: s.View = undefined;
    var clock: u64 = 0; var writes: usize = 0; var commands: usize = 0; var loads: usize = 0;
    var smu_reply: u32 = 1; var smu_if: u32 = 6; var psp_reply: u32 = 0;
    var smu_version: u32 = 0x1e460000;
    var auto_smu = true; var auto_psp = true; var fail_write: usize = 0; var disconnected = false;
    var invalid_address = false;
    var restore_reply: u32 = 0;
    var mixed_restore_reply = false;
    var reset_writes: u32 = 0;
    var reset_asserted_ns: u64 = 0;
    var reset_clears_busy = true;
    var reset_ignored = false;
    fn reset() !void { try resetFor(.fp5); }
    fn resetFor(socket: fw.Socket) !void {
        try resetProfile(.{ .socket = socket, .pci_revision = if (socket == .am4) 0xc8 else 0xc1 });
    }
    fn resetProfile(profile: fw.Profile) !void {
        words = @splat(0); arena = @splat(0); flow = .{}; active = &flow; store = .{};
        clock = 100; writes = 0; commands = 0; loads = 0; smu_reply = 1; smu_if = 6; psp_reply = 0;
        smu_version = 0x1e460000;
        auto_smu = true; auto_psp = true; fail_write = 0; disconnected = false; invalid_address = false;
        restore_reply = 0;
        mixed_restore_reply = false;
        reset_writes = 0; reset_asserted_ns = 0; reset_clears_busy = true; reset_ignored = false;
        view = try s.View.create(&arena, 0x100300000, 0x220300000);
        store.profile = profile; store.generation = 19; store.valid = true;
        for (fw.lock.firmware, 0..) |spec, i| {
            if (!store.profile.?.selects(spec)) continue;
            const data = @import("firmware_samples").files[i + fw.firmware_first];
            store.info[i + fw.firmware_first].handle = i + 1; store.offsets[i + fw.firmware_first] = store.bytes;
            @memcpy(package[store.bytes..][0..data.len], data);
            store.layouts[i] = try fw.verify(data, &fw.lock.firmware[i]);
            store.bytes += std.mem.alignForward(usize, data.len, 16);
        }
        store.allocation.cpu_address = @intFromPtr(&package);
        words[r.smu.MP1_SMN_C2PMSG_90 / 4] = 1;
        words[r.pwr.PWR_MISC_CNTL_STATUS / 4] = 2 << r.pwr.PWR_MISC_CNTL_STATUS__PWR_GFXOFF_STATUS__SHIFT;
        words[r.sdma.SDMA0_STATUS_REG / 4] = r.sdma.SDMA0_STATUS_REG__IDLE_MASK;
        for (0..4) |i| words[r.dc.hubp_cntl[i] / 4] = r.dc.HUBP0_DCHUBP_CNTL__HUBP_DISABLE_MASK;
        words[r.dc.hubp_cntl[0] / 4] = 0; words[r.dc.format[0] / 4] = 8;
        words[r.dc.primary[0] / 4] = 0x100000; words[r.dc.primary_hi[0] / 4] = 1;
        words[r.dc.inuse[0] / 4] = 0x100000; words[r.dc.inuse_hi[0] / 4] = 1;
        words[r.dc.pitch[0] / 4] = 31; words[r.dc.otg[0] / 4] = 1;
    }
    pub fn read(_: *@This(), address: u32) c.Error!u32 { return if (disconnected) 0xffffffff else words[address / 4]; }
    pub fn write(_: *@This(), address: u32, value: u32) c.Error!void {
        writes += 1; if (writes == fail_write) return error.Invalid;
        if (address == r.gc.GRBM_SOFT_RESET) {
            reset_writes += 1;
            // The recovery must isolate RLC: no CP/GFX or unrelated reset.
            std.debug.assert((value ^ words[address / 4]) & ~r.gc.GRBM_SOFT_RESET__SOFT_RESET_RLC_MASK == 0);
            if (reset_ignored) return;
            if (value & r.gc.GRBM_SOFT_RESET__SOFT_RESET_RLC_MASK != 0) reset_asserted_ns = clock else {
                std.debug.assert(reset_asserted_ns != 0 and clock - reset_asserted_ns >= 50_000);
                if (reset_clears_busy) words[r.gc.GRBM_STATUS2 / 4] &= ~r.gc.GRBM_STATUS2__RLC_BUSY_MASK;
            }
        }
        words[address / 4] = value;
        // Hardware CP receipt from Native40; MEC models command bits that
        // do not persist, not a measured MEC sample (the CP check ran first).
        if (address == r.gc.CP_ME_CNTL) words[address / 4] &= 0x15150000;
        if (address == r.gc.CP_MEC_CNTL) words[address / 4] &= 0x50000000;
        if (address == r.smu.MP1_SMN_C2PMSG_66 and auto_smu) {
            words[r.smu.MP1_SMN_C2PMSG_82 / 4] = switch (value) { r.PPSMC_MSG_GetSmuVersion => smu_version, r.PPSMC_MSG_GetDriverIfVersion => smu_if, else => 0 };
            words[r.smu.MP1_SMN_C2PMSG_90 / 4] = smu_reply;
        }
        if (address == r.psp.MP0_SMN_C2PMSG_64 and auto_psp) words[address / 4] = value | 0x80000000;
        if (address == r.psp.MP0_SMN_C2PMSG_67 and auto_psp) acknowledge(value);
    }
    fn acknowledge(wptr: u32) void {
        commands += 1;
        const frame = s.ring / 4 + ((wptr + 1024 - 16) % 1024);
        std.debug.assert(arena[frame] == @as(u32, @truncate(view.address(s.command))) and arena[frame + 1] == view.address(s.command) >> 32);
        std.debug.assert(arena[frame + 2] == 0 and arena[frame + 3] == @as(u32, @truncate(view.address(s.fence))));
        const base = s.command / 4; const args = base + 7; const cmd = arena[base + 2];
        std.debug.assert(arena[base] == 0 and arena[base + 1] == 0 and arena[base + 3] == 0);
        const resp = base + c.wire.R4_PSP_RESPONSE / 4;
        arena[resp] = psp_reply;
        if (cmd == c.wire.GFX_CMD_ID_SETUP_TMR) {
            std.debug.assert(arena[args] == @as(u32, @truncate(view.address(view.tmr_offset))) and arena[args + 2] == s.tmr_bytes and arena[args + 3] == 2);
            std.debug.assert(arena[args + 4] == @as(u32, @truncate(view.physical + view.tmr_offset)));
        }
        if (cmd == c.wire.GFX_CMD_ID_LOAD_IP_FW) {
            const entry = &active.plan.entries[active.upload];
            if (entry.restoreList() and restore_reply != 0) arena[resp] = restore_reply;
            if (mixed_restore_reply and entry.restoreList()) arena[resp] = if (active.upload == 8) 0xffff300f else 0xffff000f;
            std.debug.assert(arena[args + 2] == entry.span.bytes and arena[args + 3] == entry.fw_type);
            const original = entry.span.slice(store.container(entry.role).?);
            for (0..original.len / 4) |i| std.debug.assert(arena[s.staging / 4 + i] == std.mem.readInt(u32, original[i * 4..][0..4], .little));
            const target = if (invalid_address) 1 else view.address(view.tmr_offset) + 4096;
            arena[resp + 2] = @truncate(target); arena[resp + 3] = @truncate(target >> 32); loads += 1;
        }
        if (cmd == c.wire.GFX_CMD_ID_LOAD_ASD) arena[resp + 1] = 7;
        arena[s.fence / 4] = arena[frame + 5];
    }
    pub fn barrier(_: *@This()) c.Error!void {}
    pub fn nowNs(_: *@This()) u64 { return clock; }
    fn begin(io: *@This()) !void { try flow.begin(io, view, &store, 23, true); }
    fn tick(io: *@This()) !void { clock += 1_000_000; try flow.advance(io); }
    fn until(io: *@This(), phase: Phase) !void {
        for (0..1000) |_| { if (flow.phase == phase) return; try tick(io); }
        return error.TestUnexpectedResult;
    }
    fn close(io: *@This()) !void { flow.abort(io); try until(io, .closed); try t.expect(flow.safeToRelease()); }
};

test "Picasso PSP10 actual command ABI, original upload sections, bounded SMU10 start and reverse teardown" {
    try @import("power_test.zig").check();
    var io: F = .{}; try F.reset();
    try t.expectEqual(@as(u32, 0x58a08), r.smu.MP1_SMN_C2PMSG_66); // actual IP_BASE, not incorrect macro
    try t.expectEqual(@as(usize, 0x100000), F.view.tmr_offset);
    try t.expectError(error.Invalid, s.View.create(&F.arena, 0x100300000, 0x220301000));
    try t.expectError(error.Unconfirmed, F.flow.begin(&io, F.view, &F.store, 23, false));
    try t.expectEqual(@as(usize, 0), F.writes);
    try F.begin(&io); try F.until(&io, .firmware_ready);
    try t.expect(F.flow.firmwareReady() and F.loads == 13 and F.commands == 15);
    try t.expect(F.flow.plan.entries[4].span.bytes < fw.specification(.picasso, .mec).payload_bytes);
    try t.expectEqual(@as(u32, c.wire.GFX_FW_TYPE_CP_MEC_ME2), F.flow.plan.entries[7].fw_type);
    try t.expectEqual(@as(u32, 0x1e4600), F.flow.smu_version);
    try t.expect(F.words[r.gc.CP_ME_CNTL / 4] & @import("start_engines.zig").cp_mask != 0);
    try F.close(&io); try t.expectEqual(@as(usize, 17), F.commands);
    try t.expect(!F.flow.firmwareReady() and !F.flow.psp.ring_possible and !F.flow.psp.tmr_possible);
    // Explicit abort at every forward phase, including in-flight commands.
    inline for (std.meta.tags(Phase)) |phase| {
        if (@intFromEnum(phase) > @intFromEnum(Phase.empty) and @intFromEnum(phase) <= @intFromEnum(Phase.firmware_ready)) {
            try F.reset(); try F.begin(&io); try F.until(&io, phase); try F.close(&io);
        }
    }
    try F.reset(); F.smu_if = 7; try F.begin(&io); try F.until(&io, .firmware_ready); try F.close(&io);
    try F.resetFor(.am4); try F.begin(&io); try F.until(&io, .firmware_ready);
    try t.expect(F.flow.plan.entries[11].role == .rlc_am4 and F.flow.plan.entries[11].version == 551); try F.close(&io);
    try F.resetProfile(.{ .family = .raven2, .socket = .fp5, .pci_revision = 0xc4 });
    try F.begin(&io);
    try t.expect(F.flow.rlc.ready and F.flow.rlc.generation == F.store.generation);
    try t.expectEqual(@as(usize, 0), F.writes);
    try F.until(&io, .firmware_ready);
    try t.expect(F.flow.plan.entries[11].role == .rlc and F.flow.plan.entries[11].version == 73);
    try F.close(&io);
    // A successful PSP response is not a persistent engine stop. Reproduce
    // the measured post-load SDMA HALT=0 before allowing any GMC consumer.
    try F.resetProfile(.{ .family = .raven2, .socket = .fp5, .pci_revision = 0xc4 });
    try F.begin(&io); try F.until(&io, .asd_wait);
    F.words[r.sdma.SDMA0_F32_CNTL / 4] = 0;
    try F.tick(&io);
    try t.expect(F.flow.psp.asd_ready and F.flow.phase == .firmware_park and !F.flow.firmwareReady());
    try F.tick(&io);
    try t.expect(F.flow.phase == .firmware_parked and !F.flow.firmwareReady());
    try t.expect(F.words[r.sdma.SDMA0_F32_CNTL / 4] & r.sdma.SDMA0_F32_CNTL__HALT_MASK != 0);
    F.words[r.gc.GRBM_STATUS2 / 4] = r.gc.GRBM_STATUS2__RLC_BUSY_MASK;
    try F.tick(&io); try t.expect(!F.flow.firmwareReady() and F.flow.engines.wait == .rlc_busy);
    F.words[r.gc.GRBM_STATUS2 / 4] = 0;
    try F.until(&io, .firmware_ready);
    // An outer engine stop is followed by fresh checks without a second
    // reset. A stale/missing HALT still times out and retains all firmware.
    for ([_]bool{ false, true }) |missing_halt| {
        F.flow.cleanup_recheck = true;
        F.flow.abort(&io); try F.until(&io, .cleanup_park);
        if (missing_halt) F.words[r.sdma.SDMA0_F32_CNTL / 4] = 0;
        const writes_before = F.writes;
        try F.tick(&io);
        try t.expect(F.flow.phase == .cleanup_parked and F.writes == writes_before);
        if (missing_halt) {
            try F.tick(&io); try t.expect(F.flow.engines.wait == .sdma_halt and !F.flow.safeToRelease());
            F.clock += 500_000_000;
            try t.expectError(error.Deadline, F.flow.advance(&io));
            try t.expect(F.flow.phase == .retained and F.flow.psp.asd_ready and F.flow.psp.tmr_ready);
            F.words[r.sdma.SDMA0_F32_CNTL / 4] = r.sdma.SDMA0_F32_CNTL__HALT_MASK;
            try F.close(&io);
        } else {
            try F.until(&io, .closed); try t.expect(F.flow.safeToRelease());
            try F.reset(); try F.begin(&io); try F.until(&io, .firmware_ready);
        }
    }
    try F.resetProfile(.{ .family = .raven2, .socket = .fp5, .pci_revision = 0xc4 });
    for (fw.lock.firmware, 0..) |spec, i| if (spec.family == .raven2 and spec.role == .rlc) {
        std.mem.writeInt(u32, F.package[F.store.offsets[i + fw.firmware_first] + 60..][0..4], 511, .little);
    };
    try t.expectError(error.Firmware, F.begin(&io));
    try t.expectEqual(@as(usize, 0), F.writes);
    // Third interface revisions cannot reach PSP or engine writes.
    try F.reset(); F.smu_if = 8; try F.begin(&io); try F.until(&io, .smu_interface_wait);
    try t.expectError(error.Interface, F.tick(&io)); try F.close(&io); try t.expectEqual(@as(usize, 0), F.commands);
}

test "Picasso startup failures preserve outstanding mailbox, TMR and firmware ownership" {
    try checkRavenCleanupReset();
    // Each execution HALT bit is still mandatory even if all command bits
    // have cleared. A missing bit must time out without admitting PSP work.
    var park_io: F = .{};
    inline for (.{ .{ r.gc.CP_ME_CNTL, 0x01000000 }, .{ r.gc.CP_ME_CNTL, 0x04000000 },
        .{ r.gc.CP_ME_CNTL, 0x10000000 }, .{ r.gc.CP_MEC_CNTL, 0x40000000 }, .{ r.gc.CP_MEC_CNTL, 0x10000000 } }) |missing| {
        try F.reset(); try F.begin(&park_io); try F.until(&park_io, .parked);
        F.words[missing[0] / 4] &= ~@as(u32, missing[1]);
        try F.tick(&park_io); try t.expect(F.flow.phase == .parked and !F.flow.engines.confirmed);
        try t.expectEqual(@as(usize, 0), F.commands);
        F.clock += 500_000_000; try t.expectError(error.Deadline, F.flow.advance(&park_io));
        try t.expect(!F.flow.safeToRelease()); try F.close(&park_io);
    }
    // HALT alone does not establish idle. A busy engine still blocks and
    // retains ownership until its independent status check succeeds.
    try F.reset(); try F.begin(&park_io); try F.until(&park_io, .parked);
    F.words[r.gc.GRBM_STATUS / 4] = r.gc.GRBM_STATUS__GUI_ACTIVE_MASK;
    try F.tick(&park_io); try t.expect(F.flow.engines.wait == .gui and !F.flow.engines.confirmed);
    F.clock += 500_000_000; try t.expectError(error.Deadline, F.flow.advance(&park_io));
    try t.expect(!F.flow.safeToRelease());
    F.words[r.gc.GRBM_STATUS / 4] = 0; try F.close(&park_io);
    // The real MMIO wrapper arbitrates across different worker-owned
    // mailboxes, including an acknowledged response not consumed yet.
    try F.reset();
    var registers: @import("memory_io.zig").Registers = .{ .clock = .{ .table = .{ .now_ns = @intFromPtr(&N.clock) } },
        .window = .{ .value = .{ .handle = .{ .id = 1, .generation = 1 }, .cpu_address = @intFromPtr(&F.words), .byte_length = @sizeOf(@TypeOf(F.words)) } } };
    var first: @import("start_smu.zig").Mailbox = .{};
    var second: @import("start_smu.zig").Mailbox = .{};
    try first.begin(&registers, r.PPSMC_MSG_GetSmuVersion, null);
    F.words[r.smu.MP1_SMN_C2PMSG_90 / 4] = 1;
    F.words[r.smu.MP1_SMN_C2PMSG_82 / 4] = 0x41e3b00;
    try t.expectError(error.Busy, second.begin(&registers, r.PPSMC_MSG_GetDriverIfVersion, null));
    try t.expect(try first.poll(&registers, false));
    try t.expectEqual(@as(u32, 0x41e3b00), first.argument);
    try second.begin(&registers, r.PPSMC_MSG_GetDriverIfVersion, null);
    F.clock += 500_000_000;
    try t.expectError(error.Deadline, second.poll(&registers, false));
    try t.expect(registers.smu_owner == @intFromPtr(&second) and !registers.close());
    F.words[r.smu.MP1_SMN_C2PMSG_90 / 4] = 0xff;
    try t.expectError(error.Response, second.poll(&registers, true));
    try t.expect(registers.smu_owner == 0 and !second.active);
    // A display clock transaction waits for ownership rather than consuming
    // another command's completed reply or failing the modeset.
    F.words[r.smu.MP1_SMN_C2PMSG_90 / 4] = 1;
    try first.begin(&registers, r.PPSMC_MSG_GetSmuVersion, null);
    const clocks = @import("display_clocks.zig");
    var point: clocks.Point = .{};
    try point.begin(&registers, .{ .dcf_khz = 600000, .soc_khz = 800000, .fabric_khz = 800000, .memory_khz = 1200000 }, 600000, true);
    try t.expect(point.phase == .fabric and !point.driver.active);
    try t.expect(!try point.step(&registers));
    F.words[r.smu.MP1_SMN_C2PMSG_90 / 4] = 1;
    try t.expect(try first.poll(&registers, true));
    try t.expect(!try point.step(&registers));
    try t.expect(point.driver.active and point.driver.message == clocks.wire.PPSMC_MSG_SetHardMinFclkByFreq);
    F.words[r.smu.MP1_SMN_C2PMSG_90 / 4] = 1;
    try t.expect(try point.driver.poll(&registers, true));

    var io: F = .{};
    for ([_]u32{ 0xff, 0xfe, 0xfd, 0xfc }) |result| {
        try F.reset(); F.smu_reply = result; try F.begin(&io); try F.tick(&io);
        try t.expectError(error.Response, F.tick(&io)); try F.close(&io); try t.expect(!F.flow.firmwareReady());
    }
    try F.reset(); try F.begin(&io); try F.until(&io, .gfx_wake_send); F.auto_smu = false;
    try F.tick(&io); F.clock += 500_000_000; try t.expectError(error.Deadline, F.flow.advance(&io));
    try t.expect(F.flow.smu.active and !F.flow.safeToRelease());
    F.words[r.smu.MP1_SMN_C2PMSG_90 / 4] = 1; F.auto_smu = true; try F.close(&io);
    try F.reset(); try F.begin(&io); try F.until(&io, .tmr_send); F.psp_reply = 0x100;
    try F.tick(&io); try t.expectError(error.Response, F.tick(&io));
    try t.expect(F.flow.psp.tmr_possible and !F.flow.psp.tmr_ready and !F.flow.safeToRelease());
    F.psp_reply = 0; try F.close(&io);
    try F.reset(); try F.begin(&io); try F.until(&io, .firmware_send); F.psp_reply = 0x100;
    try F.tick(&io); try t.expectError(error.Response, F.tick(&io));
    F.psp_reply = 0; try F.close(&io); try t.expect(!F.flow.plan.entries[0].confirmed);
    try F.reset(); try F.begin(&io); try F.until(&io, .firmware_send); F.invalid_address = true;
    try F.tick(&io); try t.expectError(error.Firmware, F.tick(&io)); F.invalid_address = false; try F.close(&io);
    // The bounded Raven2 probe distinguishes all restore receipts from the
    // main RLC/VCN images. It never reports rejected images as confirmed and
    // never submits ASD or admits engines, even if later uploads succeed.
    try F.resetProfile(.{ .family = .raven2, .socket = .fp5, .pci_revision = 0xc4 });
    F.mixed_restore_reply = true; try F.begin(&io);
    while (F.flow.upload < F.flow.plan.count) try F.tick(&io);
    try t.expectEqual(@as(usize, 13), F.loads);
    try t.expectEqual(@as(usize, 14), F.commands); // TMR + uploads, no ASD
    try t.expectEqual(@as(u8, 3), F.flow.restore_rejected);
    for (F.flow.plan.entries[0..F.flow.plan.count], 0..) |entry, index| {
        try t.expect(entry.receipt);
        try t.expectEqual(!entry.restoreList(), entry.confirmed);
        try t.expectEqual(if (entry.restoreList()) @as(u32, if (index == 8) 0xffff300f else 0xffff000f) else 0, entry.response);
    }
    try t.expect(!F.flow.firmwareReady() and !F.flow.plan.confirmed() and !F.flow.psp.asd_ready);
    try t.expectError(error.Response, F.tick(&io)); try F.close(&io);
    try t.expectEqual(@as(usize, 15), F.commands); // destroy TMR, no ASD unload
    // Exact-board opt-in and measured SMU permit core execution with restore
    // unavailable, never inventing three firmware acknowledgements.
    try F.resetProfile(.{ .family = .raven2, .socket = .fp5, .pci_revision = 0xc4 });
    F.flow.allow_restore_degraded = true; F.smu_version = 0x251f00; F.smu_if = 7;
    F.mixed_restore_reply = true; try F.begin(&io); try F.until(&io, .firmware_ready);
    try t.expect(F.flow.firmwareReady() and !F.flow.plan.confirmed() and !F.flow.plan.restoreConfirmed());
    try t.expect(F.flow.psp.asd_ready and F.commands == 15);
    F.flow.plan.entries[11].confirmed = false;
    try t.expect(!F.flow.firmwareReady()); // main RLC is mandatory
    F.flow.plan.entries[11].confirmed = true;
    F.flow.plan.entries[8].receipt = false;
    try t.expect(!F.flow.firmwareReady()); // timeout/missing response cannot opt in
    F.flow.plan.entries[8].receipt = true;
    F.flow.plan.entries[8].version = 107;
    try t.expect(!F.flow.firmwareReady()); // historical comparison is not qualified
    F.flow.plan.entries[8].version = 73;
    F.flow.plan.entries[9].response = 0xffff0008;
    try t.expect(!F.flow.firmwareReady());
    F.flow.plan.entries[9].response = 0xffff000f;
    F.flow.smu_version_raw ^= 1; try t.expect(!F.flow.firmwareReady()); F.flow.smu_version_raw ^= 1;
    F.flow.allow_restore_degraded = false; try t.expect(!F.flow.firmwareReady()); F.flow.allow_restore_degraded = true;
    try F.close(&io); try t.expectEqual(@as(usize, 17), F.commands);
    try F.resetProfile(.{ .family = .raven2, .socket = .fp5, .pci_revision = 0xc4 });
    F.flow.allow_restore_degraded = true; F.mixed_restore_reply = true; try F.begin(&io);
    while (F.flow.upload < F.flow.plan.count) try F.tick(&io);
    try t.expectError(error.Response, F.tick(&io)); // different SMU stays blocked
    try t.expect(!F.flow.psp.asd_ready); try F.close(&io);
    // Neither Picasso, other status codes nor another firmware type receives
    // this diagnostic continuation. An exact timeout still retains ownership.
    for ([_]fw.Family{ .picasso, .raven2 }) |family| {
        for ([_]u32{ 0xffff300f, 0xffff000f, 0xffff0008, 0xffffffff }) |reply| {
            if (family == .raven2 and (reply == 0xffff300f or reply == 0xffff000f)) continue;
            try F.resetProfile(.{ .family = family, .socket = .fp5, .pci_revision = if (family == .raven2) 0xc4 else 0xc1 });
            F.restore_reply = reply; try F.begin(&io);
            while (F.flow.upload < 8 or F.flow.phase != .firmware_wait) try F.tick(&io);
            try t.expectError(error.Response, F.tick(&io));
            try t.expect(F.flow.restore_rejected == 0 and F.loads == 9 and !F.flow.psp.asd_ready);
            F.restore_reply = 0; try F.close(&io);
        }
    }
    try F.resetProfile(.{ .family = .raven2, .socket = .fp5, .pci_revision = 0xc4 });
    try F.begin(&io); try F.until(&io, .firmware_send); F.psp_reply = 0xffff300f;
    try F.tick(&io); try t.expectError(error.Response, F.tick(&io));
    try t.expect(F.flow.restore_rejected == 0 and F.loads == 1);
    F.psp_reply = 0; try F.close(&io);
    try F.reset(); try F.begin(&io); try F.until(&io, .firmware_send); F.auto_psp = false;
    try F.tick(&io); const token = F.flow.psp.token;
    F.arena[s.fence / 4] = token - 1; try F.tick(&io); try t.expect(F.flow.phase == .firmware_wait);
    F.clock += 2_000_000_000; try t.expectError(error.Deadline, F.flow.advance(&io));
    try t.expect(!F.flow.safeToRelease() and F.flow.psp.operation == .firmware);
    F.clock += 8_000_000_000; try t.expectError(error.Deadline, F.flow.advance(&io));
    try t.expect(F.flow.phase == .retained and !F.flow.safeToRelease());
    // Late exact completion is observed only for cleanup; no new ready state.
    F.auto_psp = true; F.acknowledge(F.words[r.psp.MP0_SMN_C2PMSG_67 / 4]);
    try F.close(&io); try t.expect(!F.flow.firmwareReady() and !F.flow.plan.entries[0].confirmed);
    try F.reset(); try F.begin(&io); F.clock = 0;
    try t.expectError(error.Deadline, F.flow.advance(&io)); F.clock = 100; try F.close(&io);
    try F.reset(); try F.begin(&io); try F.until(&io, .psp_create); F.auto_psp = false;
    try F.tick(&io); F.clock += 500_000_000; try t.expectError(error.Deadline, F.flow.advance(&io));
    try t.expect(F.flow.psp.ring_possible and !F.flow.safeToRelease());
    F.auto_psp = true; F.words[r.psp.MP0_SMN_C2PMSG_64 / 4] |= 0x80000000; try F.close(&io);
    try F.reset(); try F.begin(&io); try F.until(&io, .firmware_ready);
    F.disconnected = true; F.flow.abort(&io); try F.tick(&io);
    try t.expectError(error.Disconnected, F.tick(&io)); try t.expect(!F.flow.safeToRelease());
    F.disconnected = false; try F.close(&io);
}

fn prepareRavenCleanup(io: *F) !void {
    try F.resetProfile(.{ .family = .raven2, .socket = .fp5, .pci_revision = 0xc4 });
    try F.begin(io); try F.until(io, .firmware_ready);
    F.flow.cleanup_recheck = true;
    F.flow.abort(io); try F.until(io, .cleanup_parked);
    F.words[r.gc.GRBM_STATUS2 / 4] = 0x01000008; // measured post-GMC Raven2 value
}
fn checkRavenCleanupReset() !void {
    var io: F = .{};
    try prepareRavenCleanup(&io);
    const commands = F.commands;
    F.clock += 50_000; try F.flow.advance(&io);
    try t.expectEqual(@as(u32, 1), F.reset_writes);
    try t.expect(F.flow.phase == .cleanup_parked and !F.flow.safeToRelease() and F.commands == commands);
    F.clock += 49_999; try F.flow.advance(&io);
    try t.expectEqual(@as(u32, 1), F.reset_writes);
    F.clock += 1; try F.flow.advance(&io);
    try t.expectEqual(@as(u32, 2), F.reset_writes);
    try t.expect(F.flow.phase == .cleanup_parked and F.commands == commands);
    F.clock += 49_999; try F.flow.advance(&io);
    try t.expect(F.flow.phase == .cleanup_parked and F.commands == commands);
    F.clock += 1; try F.flow.advance(&io);
    try t.expect(F.flow.phase == .cleanup_asd and !F.flow.safeToRelease());
    try F.until(&io, .closed);
    try t.expect(F.flow.safeToRelease() and F.reset_writes == 2);

    // One RLC reset never overrides execution, pending DMA, or SERDES vetoes.
    inline for (.{ .{ r.gc.CP_ME_CNTL, 0 }, .{ r.gc.CP_MEC_CNTL, 0 },
        .{ r.gc.RLC_CNTL, r.gc.RLC_CNTL__RLC_ENABLE_F32_MASK }, .{ r.sdma.SDMA0_F32_CNTL, 0 },
        .{ r.gc.GRBM_STATUS, r.gc.GRBM_STATUS__GUI_ACTIVE_MASK },
        .{ r.gc.GRBM_STATUS2, r.gc.GRBM_STATUS2__RLC_BUSY_MASK | r.gc.GRBM_STATUS2__RLC_RQ_PENDING_MASK },
        .{ r.gc.RLC_SERDES_CU_MASTER_BUSY, 1 }, .{ r.gc.RLC_SERDES_NONCU_MASTER_BUSY, r.gc.RLC_SERDES_NONCU_MASTER_BUSY__GC_MASTER_BUSY_MASK } }) |veto| {
        try prepareRavenCleanup(&io); F.words[veto[0] / 4] = veto[1];
        try F.tick(&io); try t.expect(F.reset_writes == 0 and !F.flow.safeToRelease());
        F.clock += 500_000_000;
        try t.expectError(error.Deadline, F.flow.advance(&io));
        try t.expect(F.flow.phase == .retained and F.flow.psp.asd_ready and F.flow.psp.tmr_ready);
    }
    // A reset that does not clear BUSY is not a receipt and is not repeated.
    try prepareRavenCleanup(&io); F.reset_clears_busy = false;
    for (0..5) |_| try F.tick(&io);
    try t.expect(F.reset_writes == 2 and F.flow.phase == .cleanup_parked and !F.flow.safeToRelease());
    F.clock += 500_000_000; try t.expectError(error.Deadline, F.flow.advance(&io));
    try t.expect(F.flow.psp.asd_ready and F.flow.psp.tmr_ready and F.reset_writes == 2);
    // Failed assertion/readback, failed release and clock regression retain.
    for (0..4) |failure| {
        try prepareRavenCleanup(&io);
        if (failure == 0) F.fail_write = F.writes + 3; // two bank-selection writes precede reset
        if (failure == 1) F.reset_ignored = true;
        if (failure < 2) {
            if (failure == 0) try t.expectError(error.Invalid, F.tick(&io)) else try t.expectError(error.Unconfirmed, F.tick(&io));
        } else {
            try F.tick(&io);
            if (failure == 2) {
                F.fail_write = F.writes + 1;
                try t.expectError(error.Invalid, F.tick(&io));
            } else {
                F.clock -= 1;
                try t.expectError(error.Deadline, F.flow.advance(&io));
            }
        }
        try t.expect(F.flow.phase == .retained and !F.flow.safeToRelease() and F.flow.psp.tmr_ready and F.flow.psp.asd_ready);
    }
    // The fallback is restricted to Raven2 post-engine cleanup; startup stays
    // non-destructive and another family's cleanup must still retain.
    for ([_]bool{ false, true }) |picasso| {
        if (picasso) { try F.reset(); try F.begin(&io); try F.until(&io, .firmware_ready); F.flow.cleanup_recheck = true; F.flow.abort(&io); try F.until(&io, .cleanup_parked); }
        else { try F.resetProfile(.{ .family = .raven2, .socket = .fp5, .pci_revision = 0xc4 }); try F.begin(&io); try F.until(&io, .parked); }
        F.words[r.gc.GRBM_STATUS2 / 4] = r.gc.GRBM_STATUS2__RLC_BUSY_MASK;
        for (0..5) |_| try F.tick(&io);
        try t.expect(F.reset_writes == 0 and !F.flow.safeToRelease());
    }
}

test "Picasso boot display guard compares actual scanout, format, pitch and routing without register writes" {
    var io: F = .{}; try F.reset(); var guard: @import("start_guard.zig").Guard = .{};
    try guard.capture(&io, 0x100100000, 128); try t.expect(try guard.matches(&io));
    try t.expectEqual(@as(usize, 0), F.writes);
    F.words[r.dc.hubp_cntl[0] / 4] |= r.dc.HUBP0_DCHUBP_CNTL__HUBP_IN_BLANK_MASK;
    try t.expect(try guard.matches(&io)); // vblank is live status, not routing
    F.words[r.dc.primary[0] / 4] += 256; try t.expect(!try guard.matches(&io));
    F.words[r.dc.primary[0] / 4] -= 256; F.words[r.dc.top[0] / 4] = 3; try t.expect(!try guard.matches(&io));
    try F.reset(); guard = .{}; F.words[r.dc.flip[0] / 4] = r.dc.HUBPREQ0_DCSURF_FLIP_CONTROL__SURFACE_FLIP_PENDING_MASK;
    try t.expectError(error.Unconfirmed, guard.capture(&io, 0x100100000, 128));
    try F.reset(); guard = .{}; F.words[r.dc.surface[0] / 4] = r.dc.HUBPREQ0_DCSURF_SURFACE_CONTROL__PRIMARY_SURFACE_DCC_EN_MASK;
    try t.expectError(error.Unconfirmed, guard.capture(&io, 0x100100000, 128));
    // Original DCN1 hubp1_is_flip_pending checks EARLIEST_INUSE, not the
    // adjacent SURFACE_INUSE shadow (0xe94c/0xe950). The Lenovo firmware
    // leaves that shadow zero. A stale earliest address must still fail.
    try F.reset(); guard = .{};
    F.words[0xe94c / 4] = 0; F.words[0xe950 / 4] = 0;
    try guard.capture(&io, 0x100100000, 128);
    guard = .{}; F.words[r.dc.inuse[0] / 4] = 0;
    F.words[0xe94c / 4] = 0x100000; F.words[0xe950 / 4] = 1;
    try t.expectError(error.Unconfirmed, guard.capture(&io, 0x100100000, 128));
    try t.expectEqual(@as(usize, 0), F.writes);
    // Initial GOP admission is tied to this exact board, ROM and geometry.
    // Restored/native DCN planes keep the original minus-one convention.
    const bp = @import("boot_pitch.zig"); const a = @import("r4os").abi;
    const snapshot: @import("identity.zig").Snapshot = .{
        .pci = .{ .bus_kind = 2, .vendor_id = 0x1002, .device_id = 0x15d8, .class_code = 3 },
        .subsystem_vendor = 0x17aa, .subsystem_device = 0x3808, .pci_revision = 0xc4,
    };
    const chip = try @import("identity.zig").chip(0x15d8, 0x090015d8);
    const boot: a.GfxNativeBootInfo = .{ .generation = 1, .state = a.display_state_bootfb,
        .width = 1920, .height = 1080, .pitch = 7680, .byte_length = 8294400, .format = a.gfx_buffer_format_xrgb8888 };
    const policy = bp.select(snapshot, chip, bp.rom_sha256, boot);
    try t.expectEqual(bp.Policy.lenovo_gop_1920, policy);
    var changed_board = snapshot; changed_board.subsystem_device ^= 1;
    try t.expectEqual(bp.Policy.standard, bp.select(changed_board, chip, bp.rom_sha256, boot));
    var changed_rom = bp.rom_sha256; changed_rom[0] ^= 1;
    try t.expectEqual(bp.Policy.standard, bp.select(snapshot, chip, changed_rom, boot));
    const restore_quirk = @import("start_firmware.zig").restoreQuirk;
    try t.expect(restore_quirk(snapshot, chip, bp.rom_sha256));
    try t.expect(!restore_quirk(changed_board, chip, bp.rom_sha256));
    try t.expect(!restore_quirk(snapshot, chip, changed_rom));
    var changed_revision = snapshot; changed_revision.pci_revision ^= 1;
    try t.expect(!restore_quirk(changed_revision, chip, bp.rom_sha256));
    var changed_boot = boot; changed_boot.pitch += 4;
    try t.expectEqual(bp.Policy.standard, bp.select(snapshot, chip, bp.rom_sha256, changed_boot));
    changed_boot = boot; changed_boot.width -= 1;
    try t.expectEqual(bp.Policy.standard, bp.select(snapshot, chip, bp.rom_sha256, changed_boot));
    changed_boot = boot; changed_boot.state = a.display_state_preparing;
    try t.expectEqual(bp.Policy.standard, bp.select(snapshot, chip, bp.rom_sha256, changed_boot));
    try F.reset(); F.words[r.dc.pitch[0] / 4] = 1920;
    guard = .{}; try t.expectError(error.Unconfirmed, guard.capture(&io, 0x100100000, 7680));
    guard = .{}; try guard.captureFirmware(&io, 0x100100000, 7680, policy);
    try t.expect(guard.firmware_pitch and try guard.matches(&io));
    F.words[r.dc.pitch[0] / 4] = 1921; try t.expect(!try guard.matches(&io));
    guard = .{}; try t.expectError(error.Unconfirmed, guard.captureFirmware(&io, 0x100100000, 7680, policy));
    F.words[r.dc.pitch[0] / 4] = 1920; F.words[r.dc.inuse[0] / 4] = 0;
    guard = .{}; try t.expectError(error.Unconfirmed, guard.captureFirmware(&io, 0x100100000, 7680, policy));
    F.words[r.dc.inuse[0] / 4] = 0x100000; F.words[r.dc.flip[0] / 4] = r.dc.HUBPREQ0_DCSURF_FLIP_CONTROL__SURFACE_FLIP_PENDING_MASK;
    guard = .{}; try t.expectError(error.Unconfirmed, guard.captureFirmware(&io, 0x100100000, 7680, policy));
    try t.expectEqual(@as(usize, 0), F.writes);
}

const N = struct {
    const r4os = @import("r4os"); const a = r4os.abi;
    var run: @import("start_runtime.zig").Owner = .{};
    var memory: @import("memory_owner.zig").Owner = .{};
    var map: @import("memory_layout.zig").Layout = undefined;
    var api: a.DriverApi = undefined;
    var expected: a.GfxNativeBootInfo = .{};
    var request: a.GfxBootHoldRequest = .{};
    var command: u32 = 2; var held = false; var effects = false; var mapped = false;
    var buffer_live = false; var cpu_live = false; var recoveries: usize = 0;
    var fail_unmap = false; var fail_finish = false; var fail_release = false; var fail_pci = false;
    var pixels: [4096]u8 = @splat(0x5a);
    var last_wptr: u32 = 0;
    fn reset() !void { try resetProfile(.picasso); }
    fn resetProfile(profile: @import("asic_profile.zig").Profile) !void {
        try F.resetProfile(.{ .family = if (profile == .raven2) .raven2 else .picasso,
            .socket = .fp5, .pci_revision = if (profile == .raven2) 0xc4 else 0xc1 });
        run = .{}; memory = .{}; F.active = &run.flow;
        command = 2; held = false; effects = false; mapped = false; buffer_live = false; cpu_live = false;
        recoveries = 0; fail_unmap = false; fail_finish = false; fail_release = false; fail_pci = false; last_wptr = 0;
        map = try @import("memory_layout.zig").Layout.create(profile, .{ .base = 0x220000000, .bytes = 512 * 1024 * 1024 },
            .{ .base = 0x100000000, .bytes = 512 * 1024 * 1024 }, 0x100000, 2 * 1024 * 1024, null);
        expected = .{ .generation = 11, .state = a.display_state_bootfb, .physical_address = 0x220100000,
            .byte_length = 4096, .width = 32, .height = 32, .pitch = 128, .format = a.gfx_buffer_format_xrgb8888 };
        api = undefined; api.magic = a.driver_magic; api.version = a.driver_api_version; api.size = @sizeOf(a.DriverApi);
        api.gfx_memory_query = memoryQuery; api.gfx_display_query = displayQuery; api.resource_query = resourceQuery;
        api.pci_read_config32 = config; api.pci_write_config32 = configWrite;
        memory.self_address = @intFromPtr(&memory); memory.layout = &map; memory.epoch = 23; memory.adapter = 7; memory.prepared = true;
        memory.memory = r4os.r4dev.DriverContext.init(&api).memory().?;
        memory.registers.clock = r4os.r4dev.DriverContext.init(&api).resources().?;
        memory.registers.window.value = .{ .handle = .{ .id = 1, .generation = 1 }, .physical_address = 0xf0000000, .cpu_address = @intFromPtr(&F.words), .byte_length = @sizeOf(@TypeOf(F.words)) };
        F.view = try s.View.create(&F.arena, try map.mcAddress(map.firmware.span), try map.physicalAddress(map.firmware.span));
    }
    fn prepare() !void {
        const ctx = r4os.r4dev.DriverContext.init(&api);
        var snapshot: @import("identity.zig").Snapshot = .{ .pci = .{ .bus_kind = 2, .vendor_id = 0x1002, .device_id = 0x15d8, .class_code = 3 }, .pci_revision = F.store.profile.?.pci_revision, .command = 2 };
        snapshot.bars[5] = .{ .raw = 0xf0000000, .base = 0xf0000000, .kind = .memory32 };
        try run.prepare(&ctx, &memory, &snapshot, try @import("identity.zig").chip(0x15d8, if (map.profile == .raven2) 0x090015d8 else 0x010015d8), &F.store, expected, 0x100000, .standard);
    }
    fn clock() callconv(.c) u64 { return F.clock; }
    fn resourceQuery(out: *a.DriverResourceApi) callconv(.c) i32 { out.* = .{ .now_ns = @intFromPtr(&clock) }; return 0; }
    fn memoryQuery(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        out.* = .{ .mmio_map = @intFromPtr(&mmioMap), .mmio_unmap = @intFromPtr(&mmioUnmap), .collect = @intFromPtr(&collect),
            .buffer_create = @intFromPtr(&create), .buffer_map = @intFromPtr(&mapBuffer), .buffer_unmap = @intFromPtr(&unmapBuffer), .buffer_release = @intFromPtr(&release) }; return 1;
    }
    fn displayQuery(out: *a.GfxDriverDisplayApi) callconv(.c) i32 { out.* = .{ .boot_info = @intFromPtr(&bootInfo), .boot_hold = @intFromPtr(&hold), .boot_finish = @intFromPtr(&finish) }; return 1; }
    fn config(_: u8, _: u8, _: u8, _: u8, offset: u16) callconv(.c) u32 { return switch (offset) { 0 => 0x15d81002, 4 => command, 8 => 0x03000000 | @as(u32, F.store.profile.?.pci_revision), 0x24 => 0xf0000000, else => 0 }; }
    fn configWrite(_: u8, _: u8, _: u8, _: u8, offset: u16, value: u32) callconv(.c) i32 {
        std.debug.assert(offset == 4 and value >> 16 == 0 and held and effects);
        command = value; return if (fail_pci) -1 else 0; // fail after possible PCI mutation
    }
    fn mmioMap(req: *const a.GfxMmioRequest, out: *a.GfxMmioWindow) callconv(.c) i32 {
        std.debug.assert(!mapped and req.resource_base == map.physical.offset and req.byte_offset == map.firmware.span.offset);
        std.debug.assert(req.byte_length == @sizeOf(@TypeOf(F.arena)) and req.cache_policy == a.gfx_buffer_cache_write_combining);
        mapped = true; out.* = .{ .handle = .{ .id = 2, .generation = 1 }, .cpu_address = @intFromPtr(&F.arena), .physical_address = req.resource_base + req.byte_offset,
            .byte_length = req.byte_length, .cache_policy = req.cache_policy }; return 1;
    }
    fn mmioUnmap(_: *const a.GfxBufferHandle, quiesced: u32) callconv(.c) i32 {
        std.debug.assert(mapped and quiesced == 1 and run.flow.safeToRelease()); if (fail_unmap) return -1; mapped = false; return 1;
    }
    fn collect() callconv(.c) i32 { return 1; }
    fn create(_: *const a.GfxBufferDescriptor, out: *a.GfxBufferReference) callconv(.c) i32 {
        std.debug.assert(!buffer_live); buffer_live = true; out.* = .{ .buffer = .{ .id = 3, .generation = 1 }, .reference = .{ .id = 4, .generation = 1 } }; return 1;
    }
    fn mapBuffer(_: *const a.GfxBufferHandle, mode: u32, _: u64, bytes: u64, out: *a.GfxBufferMap) callconv(.c) i32 {
        std.debug.assert(held and buffer_live and mode == a.gfx_buffer_map_read and bytes == 4096); cpu_live = true;
        out.* = .{ .lease = .{ .id = 5, .generation = 1 }, .cpu_address = @intFromPtr(&pixels), .byte_length = 4096 }; return 1;
    }
    fn unmapBuffer(_: *const a.GfxBufferHandle) callconv(.c) i32 { std.debug.assert(cpu_live); cpu_live = false; return 1; }
    fn release(_: *const a.GfxBufferHandle) callconv(.c) i32 {
        std.debug.assert(!held and !cpu_live and buffer_live); if (fail_release) return -1; buffer_live = false; return 1;
    }
    fn bootInfo(out: *a.GfxNativeBootInfo) callconv(.c) i32 { out.* = expected; if (held) out.state = a.display_state_preparing; return 1; }
    fn hold(req: *const a.GfxBootHoldRequest, out: *a.GfxNativeState) callconv(.c) i32 {
        std.debug.assert(!held and buffer_live); held = true; request = req.*;
        out.* = .{ .generation = 12, .state = a.display_state_preparing, .retained = 1, .outcome = a.gfx_output_outcome_validated }; return 1;
    }
    fn finish(generation: u64, op: u32, out: *a.GfxNativeState) callconv(.c) i32 {
        std.debug.assert(generation == 12 and held);
        out.* = .{ .generation = 12, .state = a.display_state_preparing, .retained = 1, .outcome = a.gfx_output_outcome_validated };
        if (op == 1) { effects = true; return 1; }
        if (fail_finish) return -1;
        if (op == 2) {
            const callback: *const fn (u64, u64, *const a.GfxNativeBootInfo) callconv(.c) i32 = @ptrFromInt(request.restore_callback);
            var description = expected; description.generation = generation; description.state = a.display_state_preparing;
            if (callback(request.context, generation, &description) != 1) return -1;
            recoveries += 1;
        } else std.debug.assert(!effects);
        held = false; effects = false;
        out.* = .{ .generation = 12, .state = a.display_state_bootfb, .outcome = a.gfx_output_outcome_old_preserved }; return 1;
    }
    fn emulate() void {
        F.clock += 1_000_000;
        const smu = F.words[r.smu.MP1_SMN_C2PMSG_66 / 4];
        if (F.words[r.smu.MP1_SMN_C2PMSG_90 / 4] == 0 and smu != 0) {
            F.words[r.smu.MP1_SMN_C2PMSG_82 / 4] = switch (smu) { r.PPSMC_MSG_GetSmuVersion => 0x1e460000, r.PPSMC_MSG_GetDriverIfVersion => 6, else => 0 };
            F.words[r.smu.MP1_SMN_C2PMSG_90 / 4] = 1;
        }
        const psp = &F.words[r.psp.MP0_SMN_C2PMSG_64 / 4]; if (psp.* != 0) psp.* |= 0x80000000;
        const wptr = F.words[r.psp.MP0_SMN_C2PMSG_67 / 4];
        if (wptr != last_wptr) { F.acknowledge(wptr); last_wptr = wptr; }
    }
    fn ready() !void {
        for (0..1000) |_| { emulate(); try run.advance(); if (run.firmwareReady()) return; }
        return error.TestUnexpectedResult;
    }
    fn close() bool { for (0..1000) |_| { emulate(); if (run.close()) return true; } return false; }
};

test "Picasso native owner uses real SDK MMIO, canonical boot hold/recovery and PCI lifetime" {
    try N.reset(); try N.prepare();
    try t.expect(N.command == 6 and N.held and N.effects and N.mapped and N.memory.start_users == 1 and N.memory.firmware_users == 1);
    try t.expect(!N.memory.close(.{ .memory_epoch = 23, .boot_held = true, .engines_quiesced = true }));
    try N.ready(); try t.expect(N.run.firmwareReady() and N.run.flow.plan.confirmed());
    const amd = @import("r4amd");
    const facts = @import("device_facts.zig");
    var engine: @import("gc_engine.zig").Owner = .{ .phase = .ready, .cu_mask = 0xff, .rb_mask = 3, .gb_addr_config = 0x24000042 };
    const arch: amd.R4AmdArchitecture = .{ .version = 1, .size = @sizeOf(amd.R4AmdArchitecture), .vendor_id = 0x1002,
        .device_id = 0x15d8, .gc_version = amd.gc_9_1_0, .sdma_version = amd.sdma_4_1_0, .gb_addr_config = engine.gb_addr_config,
        .chip_revision = N.run.chip.?.external_revision, .bind_alignment = 4096, .memory_generation = N.memory.epoch,
        .flags = 0, .reserved = 0, .max_image_bytes = 64 * 1024 * 1024 };
    const copied = try facts.capture(&N.run, &engine, arch);
    try t.expectEqual(arch, copied.architecture);
    try t.expectEqual(@as(u32, 0xc1), copied.pci_revision);
    try t.expectEqual(@as(u32, 0x42), copied.architecture.chip_revision);
    try t.expectEqual(@as(u32, 0xff), copied.cu_mask);
    try t.expectEqual(N.map.native_budget, copied.native_budget);
    try t.expect(copied.uma_bytes == N.map.physical.bytes and copied.flags == 3 and copied.me_feature != 0 and copied.mec_feature != 0);
    engine.cu_mask = 0;
    try t.expectError(error.Unconfirmed, facts.capture(&N.run, &engine, arch));
    engine.cu_mask = 0xff; engine.stop_started = true;
    try t.expectError(error.Unconfirmed, facts.capture(&N.run, &engine, arch));
    engine.stop_started = false; N.memory.epoch += 1;
    try t.expectError(error.Unconfirmed, facts.capture(&N.run, &engine, arch));
    N.memory.epoch -= 1;
    N.fail_unmap = true; try t.expect(!N.close());
    try t.expect(N.held and N.mapped and N.memory.firmware_users == 1 and N.command == 2);
    N.fail_unmap = false; N.fail_release = true; try t.expect(!N.close());
    try t.expect(!N.held and !N.mapped and N.memory.start_users == 1 and N.buffer_live and N.recoveries == 1);
    N.fail_release = false; try t.expect(N.close()); try t.expect(N.recoveries == 1 and N.memory.start_users == 0);
    // Actual Raven2 identity, firmware topology and clock profile stay paired.
    try N.resetProfile(.raven2); try N.prepare(); try N.ready();
    engine = .{ .phase = .ready, .cu_mask = 7, .rb_mask = 1, .gb_addr_config = 0x24000041 };
    var rv = arch;
    rv.gc_version = amd.gc_9_2_2; rv.sdma_version = amd.sdma_4_1_1;
    rv.chip_revision = 0x82; rv.gb_addr_config = engine.gb_addr_config;
    const raven2 = try facts.capture(&N.run, &engine, rv);
    try t.expect(raven2.pci_revision == 0xc4 and raven2.asic_revision == 9 and raven2.max_cu_per_sh == 3 and raven2.max_rb_per_se == 1);
    try t.expect(raven2.cu_mask == 7 and raven2.rb_mask == 1 and raven2.architecture.gc_version == amd.gc_9_2_2);
    rv.sdma_version = amd.sdma_4_1_0;
    try t.expectError(error.Unconfirmed, facts.capture(&N.run, &engine, rv));
    rv.sdma_version = amd.sdma_4_1_1; engine.cu_mask = 15;
    try t.expectError(error.Unconfirmed, facts.capture(&N.run, &engine, rv));
    engine.cu_mask = 7; engine.rb_mask = 3;
    try t.expectError(error.Unconfirmed, facts.capture(&N.run, &engine, rv));
    engine.rb_mask = 1; N.map.profile = .picasso;
    try t.expectError(error.Unconfirmed, facts.capture(&N.run, &engine, rv));
    N.map.profile = .raven2; try t.expect(N.close());
    try N.reset(); try N.prepare(); try N.ready();
    F.words[r.dc.primary[0] / 4] += 256;
    try t.expectError(error.Unconfirmed, N.run.advance()); try t.expect(!N.close());
    try t.expect(N.held and N.effects and N.recoveries == 0 and N.memory.start_users == 1);
    F.words[r.dc.primary[0] / 4] -= 256; try t.expect(N.close());
    try N.reset(); N.fail_pci = true;
    try t.expectError(error.Unconfirmed, N.prepare()); try t.expect(N.command == 6 and !N.run.flow.firmwareReady());
    N.fail_pci = false; try t.expect(N.close()); try t.expect(N.command == 2 and N.recoveries == 1);
}
