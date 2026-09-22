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
    var auto_smu = true; var auto_psp = true; var fail_write: usize = 0; var disconnected = false;
    var invalid_address = false;
    fn reset() !void { try resetFor(.fp5); }
    fn resetFor(socket: fw.Socket) !void {
        words = @splat(0); arena = @splat(0); flow = .{}; active = &flow; store = .{};
        clock = 100; writes = 0; commands = 0; loads = 0; smu_reply = 1; smu_if = 6; psp_reply = 0;
        auto_smu = true; auto_psp = true; fail_write = 0; disconnected = false; invalid_address = false;
        view = try s.View.create(&arena, 0x100300000, 0x220300000);
        store.profile = .{ .socket = socket, .pci_revision = if (socket == .am4) 0xc8 else 0xc1 }; store.generation = 19; store.valid = true;
        for (fw.lock.firmware, 0..) |spec, i| {
            if (!store.profile.?.includes(spec.role)) continue;
            const data = @import("firmware_samples").files[i + 3];
            store.info[i + 3].handle = i + 1; store.offsets[i + 3] = store.bytes;
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
        words[address / 4] = value;
        if (address == r.smu.MP1_SMN_C2PMSG_66 and auto_smu) {
            words[r.smu.MP1_SMN_C2PMSG_82 / 4] = switch (value) { r.PPSMC_MSG_GetSmuVersion => 0x1e460000, r.PPSMC_MSG_GetDriverIfVersion => smu_if, else => 0 };
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
    var io: F = .{}; try F.reset();
    try t.expectEqual(@as(u32, 0x58a08), r.smu.MP1_SMN_C2PMSG_66); // actual IP_BASE, not incorrect macro
    try t.expectEqual(@as(usize, 0x100000), F.view.tmr_offset);
    try t.expectError(error.Invalid, s.View.create(&F.arena, 0x100300000, 0x220301000));
    try t.expectError(error.Unconfirmed, F.flow.begin(&io, F.view, &F.store, 23, false));
    try t.expectEqual(@as(usize, 0), F.writes);
    try F.begin(&io); try F.until(&io, .firmware_ready);
    try t.expect(F.flow.firmwareReady() and F.loads == 13 and F.commands == 15);
    try t.expect(F.flow.plan.entries[4].span.bytes < fw.specification(.mec).payload_bytes);
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
    // Third interface revisions cannot reach PSP or engine writes.
    try F.reset(); F.smu_if = 8; try F.begin(&io); try F.until(&io, .smu_interface_wait);
    try t.expectError(error.Interface, F.tick(&io)); try F.close(&io); try t.expectEqual(@as(usize, 0), F.commands);
}

test "Picasso startup failures preserve outstanding mailbox, TMR and firmware ownership" {
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
    fn reset() !void {
        try F.reset(); run = .{}; memory = .{}; F.active = &run.flow;
        command = 2; held = false; effects = false; mapped = false; buffer_live = false; cpu_live = false;
        recoveries = 0; fail_unmap = false; fail_finish = false; fail_release = false; fail_pci = false; last_wptr = 0;
        map = try @import("memory_layout.zig").Layout.create(.{ .base = 0x220000000, .bytes = 512 * 1024 * 1024 },
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
        var snapshot: @import("identity.zig").Snapshot = .{ .pci = .{ .bus_kind = 2, .vendor_id = 0x1002, .device_id = 0x15d8, .class_code = 3 }, .pci_revision = 0xc1, .command = 2 };
        snapshot.bars[5] = .{ .raw = 0xf0000000, .base = 0xf0000000, .kind = .memory32 };
        try run.prepare(&ctx, &memory, &snapshot, try @import("identity.zig").chip(0x15d8, 0x010015d8), &F.store, expected, 0x100000);
    }
    fn clock() callconv(.c) u64 { return F.clock; }
    fn resourceQuery(out: *a.DriverResourceApi) callconv(.c) i32 { out.* = .{ .now_ns = @intFromPtr(&clock) }; return 0; }
    fn memoryQuery(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        out.* = .{ .mmio_map = @intFromPtr(&mmioMap), .mmio_unmap = @intFromPtr(&mmioUnmap), .collect = @intFromPtr(&collect),
            .buffer_create = @intFromPtr(&create), .buffer_map = @intFromPtr(&mapBuffer), .buffer_unmap = @intFromPtr(&unmapBuffer), .buffer_release = @intFromPtr(&release) }; return 1;
    }
    fn displayQuery(out: *a.GfxDriverDisplayApi) callconv(.c) i32 { out.* = .{ .boot_info = @intFromPtr(&bootInfo), .boot_hold = @intFromPtr(&hold), .boot_finish = @intFromPtr(&finish) }; return 1; }
    fn config(_: u8, _: u8, _: u8, _: u8, offset: u16) callconv(.c) u32 { return switch (offset) { 0 => 0x15d81002, 4 => command, 8 => 0x030000c1, 0x24 => 0xf0000000, else => 0 }; }
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
    try N.reset(); try N.prepare(); try N.ready();
    F.words[r.dc.primary[0] / 4] += 256;
    try t.expectError(error.Unconfirmed, N.run.advance()); try t.expect(!N.close());
    try t.expect(N.held and N.effects and N.recoveries == 0 and N.memory.start_users == 1);
    F.words[r.dc.primary[0] / 4] -= 256; try t.expect(N.close());
    try N.reset(); N.fail_pci = true;
    try t.expectError(error.Unconfirmed, N.prepare()); try t.expect(N.command == 6 and !N.run.flow.firmwareReady());
    N.fail_pci = false; try t.expect(N.close()); try t.expect(N.command == 2 and N.recoveries == 1);
}
