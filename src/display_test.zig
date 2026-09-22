// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const t = std.testing;
const r4os = @import("r4os");
const a = r4os.abi;
const core = @import("display_core.zig");
const c = core.c;
const hw = @cImport({
    @cInclude("display_test_wire.h");
});
const d = @import("start_registers.zig").dc;
fn reg(comptime name: []const u8) usize {
    const index = @field(hw, "mm" ++ name ++ "_BASE_IDX");
    return @field(hw, std.fmt.comptimePrint("DCE_BASE__INST0_SEG{d}", .{index})) + @field(hw, "mm" ++ name);
}
const limits: c.struct_r4dcn_limits = .{ .channels = 2, .dcf_khz = 600000, .disp_khz = 960000, .dpp_khz = 626000, .fabric_khz = 1066666, .soc_khz = 626000, .ref_khz = 48000, .gb_addr_config = 0x24000042, .reserved = 0 };
const mode: c.struct_r4dcn_mode = .{ .width = 1920, .height = 1080, .h_total = 2200, .v_total = 1125, .h_front = 88, .h_sync = 44, .v_front = 4, .v_sync = 5, .pixel_khz = 148500, .pitch_bytes = 7680, .pipe = 0, .flags = 6, .mc_address = 0x200000000, .buffer_bytes = 7680 * 1080 };
const F = struct {
    var bytes: [5 * 1024 * 1024]u8 align(16) = undefined;
    var words: [@import("memory_registers.zig").required_prefix / 4]u32 align(4096) = undefined;
    var original: [words.len]u32 = undefined;
    var ticks: u64 = 0;
    var writes: usize = 0;
    var reads: usize = 0;
    var fail_write: usize = 0;
    var is_worker = true;
    var clock_ready = true;
    var scanout_model = false;
    var hold_stop = false;
    var tear_frame = false;
    var fail_read: usize = 0;
    fn reset() void {
        @memset(&words, 0);
        ticks = 0;
        writes = 0;
        reads = 0;
        fail_write = 0;
        is_worker = true;
        clock_ready = true;
        scanout_model = false;
        hold_stop = false;
        tear_frame = false;
        fail_read = 0;
    }
    fn read(_: ?*anyopaque, offset: u32, out: [*c]u32) callconv(.c) c_int {
        if (offset % 4 != 0 or offset >= @sizeOf(@TypeOf(words))) return -1;
        reads += 1;
        if (fail_read != 0 and reads == fail_read) return -1;
        out.* = words[offset / 4];
        if (tear_frame and offset / 4 == reg("OTG0_OTG_STATUS_FRAME_COUNT")) words[offset / 4] +%= 1;
        return 0;
    }
    fn write(_: ?*anyopaque, offset: u32, value: u32) callconv(.c) c_int {
        if (offset % 4 != 0 or offset >= @sizeOf(@TypeOf(words))) return -1;
        writes += 1;
        if (fail_write != 0 and writes == fail_write) return -1;
        words[offset / 4] = value;
        if (scanout_model) {
            const idx = offset / 4;
            inline for (0..4) |i| {
            if (idx == d.control[i] / 4) {
                words[idx] &= ~@as(u32, hw.OTG0_OTG_CONTROL__OTG_CURRENT_MASTER_EN_STATE_MASK);
                if (hold_stop or value & hw.OTG0_OTG_CONTROL__OTG_MASTER_EN_MASK != 0) words[idx] |= hw.OTG0_OTG_CONTROL__OTG_CURRENT_MASTER_EN_STATE_MASK;
            }
            if (idx == d.hubp_cntl[i] / 4) {
                words[idx] &= ~@as(u32, hw.HUBP0_DCHUBP_CNTL__HUBP_IN_BLANK_MASK | hw.HUBP0_DCHUBP_CNTL__HUBP_NO_OUTSTANDING_REQ_MASK);
                if (value & hw.HUBP0_DCHUBP_CNTL__HUBP_BLANK_EN_MASK != 0) words[idx] |= hw.HUBP0_DCHUBP_CNTL__HUBP_IN_BLANK_MASK | hw.HUBP0_DCHUBP_CNTL__HUBP_NO_OUTSTANDING_REQ_MASK;
            }
            if (idx == reg(std.fmt.comptimePrint("OTG{d}_OTG_BLANK_CONTROL", .{i}))) {
                words[idx] &= ~@as(u32, hw.OTG0_OTG_BLANK_CONTROL__OTG_CURRENT_BLANK_STATE_MASK);
                if (value & hw.OTG0_OTG_BLANK_CONTROL__OTG_BLANK_DATA_EN_MASK != 0) words[idx] |= hw.OTG0_OTG_BLANK_CONTROL__OTG_CURRENT_BLANK_STATE_MASK;
            }
            if (idx == reg(std.fmt.comptimePrint("OTG{d}_OTG_MASTER_UPDATE_LOCK", .{i}))) {
                words[idx] &= ~@as(u32, hw.OTG0_OTG_MASTER_UPDATE_LOCK__UPDATE_LOCK_STATUS_MASK);
                if (value & 1 != 0) words[idx] |= hw.OTG0_OTG_MASTER_UPDATE_LOCK__UPDATE_LOCK_STATUS_MASK;
            }
            }
        }
        return 0;
    }
    fn now(_: ?*anyopaque) callconv(.c) u64 {
        ticks += 1000;
        return ticks;
    }
    fn delay(_: ?*anyopaque, us: u32) callconv(.c) c_int {
        ticks += @as(u64, us) * 1000;
        return 0;
    }
    fn worker(_: ?*anyopaque) callconv(.c) c_int {
        return @intFromBool(is_worker);
    }
    fn log(_: ?*anyopaque, _: [*c]const u8) callconv(.c) void {}
    fn fatal(_: ?*anyopaque, expr: [*c]const u8, file: [*c]const u8, line: c_uint) callconv(.c) void {
        std.debug.panic("DC ASSERT {s}:{d}: {s}", .{ std.mem.span(file), line, std.mem.span(expr) });
    }
    const io: c.struct_r4dcn_io = .{ .context = null, .read = read, .write = write, .now_ns = now, .delay_us = delay, .worker = worker, .log = log, .fatal = fatal };
    fn init() !void {
        try t.expect(c.r4dcn_size() <= bytes.len);
        try t.expectEqual(@as(c_int, 0), c.r4dcn_init(&bytes, c.r4dcn_size(), &io, &limits));
    }
    fn blank() void {
        for (0..4) |i| {
            words[d.otg[i] / 4] = 0;
            words[d.control[i] / 4] = 0;
            words[d.hubp_cntl[i] / 4] = hw.HUBP0_DCHUBP_CNTL__HUBP_IN_BLANK_MASK | hw.HUBP0_DCHUBP_CNTL__HUBP_BLANK_EN_MASK;
            words[hw.R4DCN_MPC_STATUS(i) / 4] = hw.MPCC0_MPCC_STATUS__MPCC_IDLE_MASK;
        }
        words[hw.R4DCN_TG_CLOCK_0 / 4] = if (clock_ready) hw.OTG0_OTG_CLOCK_CONTROL__OTG_CLOCK_ON_MASK else 0;
        words[hw.R4DCN_INPUT_CLOCK_0 / 4] = if (clock_ready) hw.ODM0_OPTC_INPUT_CLOCK_CONTROL__OPTC_INPUT_CLK_ON_MASK else 0;
    }
};
test "DCN1 original bandwidth timing and MMIO reject invalid modes and unconfirmed clocks" {
    F.reset();
    try F.init();
    var plan: c.struct_r4dcn_plan = std.mem.zeroes(c.struct_r4dcn_plan);
    F.is_worker = false;
    try t.expectEqual(@as(c_int, c.R4DCN_STATE), c.r4dcn_prepare(&F.bytes, &mode, 1, &plan));
    F.is_worker = true;
    var invalid = mode;
    invalid.h_total = mode.width;
    try t.expectEqual(@as(c_int, c.R4DCN_INVALID), c.r4dcn_prepare(&F.bytes, &invalid, 1, &plan));
    try t.expectEqual(@as(c_int, 0), c.r4dcn_prepare(&F.bytes, &mode, 1, &plan));
    try t.expect(plan.count == 1 and plan.pipe_mask == 1 and plan.disp_khz >= mode.pixel_khz and plan.disp_khz <= limits.disp_khz and
        plan.dcf_khz == limits.dcf_khz and plan.urgent_ns >= 4000 and plan.pte_ns != 0);
    try t.expect(F.reads == 0 and F.writes == 0);
    try t.expectEqual(@as(c_int, c.R4DCN_STATE), c.r4dcn_program(&F.bytes));
    try t.expectEqual(@as(usize, 0), F.writes);
    F.blank();
    F.words[d.control[3] / 4] = hw.OTG0_OTG_CONTROL__OTG_MASTER_EN_MASK;
    try t.expectEqual(@as(c_int, c.R4DCN_STATE), c.r4dcn_program(&F.bytes));
    try t.expectEqual(@as(usize, 0), F.writes);
    F.clock_ready = false;
    F.blank();
    try t.expectEqual(@as(c_int, c.R4DCN_TIMEOUT), c.r4dcn_program(&F.bytes));
    const stopped = F.writes;
    try t.expect(stopped > 0);
    try t.expectEqual(@as(c_int, c.R4DCN_STATE), c.r4dcn_program(&F.bytes));
    try t.expectEqual(stopped, F.writes);
    F.words[d.control[0] / 4] = hw.OTG0_OTG_CONTROL__OTG_CURRENT_MASTER_EN_STATE_MASK;
    try t.expectEqual(@as(c_int, c.R4DCN_STATE), c.r4dcn_quiesce(&F.bytes));
    F.blank();
    try t.expectEqual(@as(c_int, 0), c.r4dcn_quiesce(&F.bytes));
    c.r4dcn_destroy(&F.bytes);

    F.reset();
    try F.init();
    try t.expectEqual(@as(c_int, 0), c.r4dcn_prepare(&F.bytes, &mode, 1, &plan));
    F.blank();
    try t.expectEqual(@as(c_int, 0), c.r4dcn_program(&F.bytes));
    try t.expect(F.writes > 80 and F.words[d.htotal[0] / 4] == 2199);
    try t.expectEqual(@as(u32, 0), F.words[hw.R4DCN_MPC_MUX_0 / 4] & hw.MPC_OUT0_MUX__MPC_OUT_MUX_MASK);
    try t.expectEqual(@as(u32, 0), F.words[d.control[0] / 4] & hw.OTG0_OTG_CONTROL__OTG_MASTER_EN_MASK);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_quiesce(&F.bytes));
    c.r4dcn_destroy(&F.bytes);

    F.reset();
    try F.init();
    try t.expectEqual(@as(c_int, 0), c.r4dcn_prepare(&F.bytes, &mode, 1, &plan));
    F.blank();
    F.fail_write = 5;
    try t.expectEqual(@as(c_int, c.R4DCN_IO), c.r4dcn_program(&F.bytes));
    try t.expectEqual(@as(usize, 5), F.writes);
    try t.expectEqual(@as(c_int, c.R4DCN_STATE), c.r4dcn_program(&F.bytes));
    try t.expectEqual(@as(usize, 5), F.writes);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_quiesce(&F.bytes));
    c.r4dcn_destroy(&F.bytes);

    F.reset();
    var low = limits;
    low.dcf_khz = 100000;
    low.disp_khz = 100000;
    low.dpp_khz = 100000;
    low.fabric_khz = 100000;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_init(&F.bytes, c.r4dcn_size(), &F.io, &low));
    plan.count = 123;
    try t.expect(c.r4dcn_prepare(&F.bytes, &mode, 1, &plan) != 0);
    try t.expect(plan.count == 123 and F.writes == 0);
    c.r4dcn_destroy(&F.bytes);
    std.debug.print("[amd-dcn1] real DML/RQ/DLG, timing and frontend MMIO; clock timeout retained; 1080p planning; no physical device\n", .{});
}

const Runtime = struct {
    var owner: core.Owner = .{};
    var memory: @import("memory_owner.zig").Owner = .{};
    var native: @import("start_runtime.zig").Owner = .{};
    var board: @import("bios.zig").Board = undefined;
    var api: a.DriverApi = undefined;
    var request: a.DriverThreadRequest = .{};
    var running = false;
    var ran = false;
    var live = false;
    var heap_live = false;
    var panel_heap_live = false;
    var hdmi_heap_live = false;
    var candidate_heap_live = false;
    var candidate_bytes: [F.bytes.len]u8 align(16) = undefined;
    var hdmi_bytes: [@sizeOf(@import("hdmi_runtime.zig").Runtime)]u8 align(16) = undefined;
    var panel_bytes: [@sizeOf(@import("panel_runtime.zig").Runtime)]u8 align(16) = undefined;
    var rom: [4096]u8 = undefined;
    var thread_result: i32 = 0;
    var fail_join = false;
    var fail_release = false;
    var fail_heap = false;
    var partial_heap = false;
    var fail_restore = false;
    var fail_prepare = false;
    fn reset() !void {
        F.reset();
        owner = .{};
        memory = .{};
        native = .{};
        request = .{};
        running = false;
        ran = false;
        live = false;
        heap_live = false;
        panel_heap_live = false; hdmi_heap_live = false;
        candidate_heap_live = false;
        thread_result = 0;
        fail_join = false;
        fail_release = false;
        fail_heap = false;
        partial_heap = false;
        fail_restore = false;
        fail_prepare = false;
        api = undefined;
        api.magic = a.driver_magic;
        api.version = a.driver_api_version;
        api.size = @sizeOf(a.DriverApi);
        api.thread_query = threadQuery;
        api.heap_query = heapQuery;
        api.resource_query = resourceQuery;
        api.timer_frequency = frequency;
        api.log_error = log;
        memory.self_address = @intFromPtr(&memory);
        memory.prepared = true;
        memory.epoch = 7;
        memory.adapter = 1;
        memory.engine_users = 1;
        memory.registers.window.value = .{ .handle = .{ .id = 1, .generation = 1 }, .cpu_address = @intFromPtr(&F.words), .byte_length = @sizeOf(@TypeOf(F.words)) };
        native.self_address = @intFromPtr(&native);
        native.memory = &memory;
        native.flow.phase = .firmware_ready;
        native.flow.plan.count = native.flow.plan.entries.len;
        for (&native.flow.plan.entries) |*entry| {
            entry.* = std.mem.zeroes(@TypeOf(entry.*));
            entry.confirmed = true;
        }
        native.flow.psp.ring_ready = true;
        native.flow.psp.tmr_ready = true;
        native.flow.psp.asd_ready = true;
        native.flow.engines.confirmed = true;
        native.flow.smu_version = 1;
        native.flow.smu_interface = @import("start_registers.zig").smu_driver_if;
        native.hold.effects = true;
        native.hold.held_generation = 12;
        native.hold.boot = .{ .generation = 11, .width = mode.width, .height = mode.height, .pitch = mode.pitch_bytes, .byte_length = mode.buffer_bytes, .format = a.gfx_buffer_format_xrgb8888 };
        F.words[d.format[0] / 4] = 8;
        F.words[d.pitch[0] / 4] = mode.pitch_bytes / 4 - 1;
        F.words[d.primary[0] / 4] = @truncate(mode.mc_address);
        F.words[d.primary_hi[0] / 4] = @truncate(mode.mc_address >> 32);
        F.words[d.inuse[0] / 4] = @truncate(mode.mc_address);
        F.words[d.inuse_hi[0] / 4] = @truncate(mode.mc_address >> 32);
        F.words[d.otg[0] / 4] = hw.OTG0_OTG_CONTROL__OTG_MASTER_EN_MASK;
        F.words[d.control[0] / 4] = hw.OTG0_OTG_CONTROL__OTG_MASTER_EN_MASK | hw.OTG0_OTG_CONTROL__OTG_CURRENT_MASTER_EN_STATE_MASK;
        try native.guard.capture(&memory.registers, mode.mc_address, mode.pitch_bytes);
        @memcpy(&F.original, &F.words);
        board = .{ .image = &.{}, .tables = @splat(std.mem.zeroes(@import("bios.zig").Table)) };
        board.integrated = std.mem.zeroes(@import("bios.zig").Integrated);
        board.integrated.?.uma_channels = 2;
    }
    fn frequency() callconv(.c) u32 {
        return 1000;
    }
    fn log(_: [*:0]const u8) callconv(.c) void {}
    fn threadQuery(out: *a.DriverThreadApi) callconv(.c) i32 {
        out.* = .{ .start = @intFromPtr(&launch), .join = @intFromPtr(&join), .release = @intFromPtr(&release), .current = @intFromPtr(&current), .current_request = @intFromPtr(&currentRequest), .sleep_ticks = @intFromPtr(&sleep), .abort_current = @intFromPtr(&abort) };
        return 0;
    }
    fn heapQuery(out: *a.DriverHeapApi) callconv(.c) i32 {
        out.* = .{ .allocate = @intFromPtr(&allocate), .release = @intFromPtr(&free) };
        return 0;
    }
    fn resourceQuery(out: *a.DriverResourceApi) callconv(.c) i32 {
        out.* = .{ .now_ns = @intFromPtr(&clock) };
        return 0;
    }
    fn launch(req: *const a.DriverThreadRequest, out: *u64) callconv(.c) i32 {
        std.debug.assert(!live);
        request = req.*;
        out.* = 99;
        live = true;
        ran = false;
        return 0;
    }
    fn run() void {
        std.debug.assert(live and !ran);
        running = true;
        const callback: *const fn (usize) callconv(.c) i32 = @ptrFromInt(request.handler);
        thread_result = callback(request.context);
        running = false;
        ran = true;
    }
    fn join(_: u64, _: u64, out: *i32) callconv(.c) i32 {
        if (!ran or fail_join) return -1;
        out.* = thread_result;
        return 0;
    }
    fn release(_: u64) callconv(.c) i32 {
        if (fail_release) return -1;
        live = false;
        return 0;
    }
    fn current() callconv(.c) u64 {
        return if (running) 99 else 0;
    }
    fn currentRequest(out: *a.DriverThreadRequest) callconv(.c) i32 {
        out.* = request;
        return if (running) 0 else -1;
    }
    fn sleep(ticks: u64) callconv(.c) i32 {
        F.ticks += ticks * 1000000;
        Pipeline.tick();
        return 0;
    }
    fn abort(_: i32) callconv(.c) i32 {
        @panic("unexpected fatal DC assertion");
    }
    fn clock() callconv(.c) u64 {
        Pipeline.tick();
        return F.now(null);
    }
    fn allocate(bytes: u64, alignment: u32, out: *a.DriverHeapAllocation) callconv(.c) i32 {
        if (heap_live and bytes == owner.allocation.byte_length) {
            std.debug.assert(running and !candidate_heap_live and bytes <= candidate_bytes.len);
            candidate_heap_live = true;
            out.* = .{ .handle = 4, .cpu_address = @intFromPtr(&candidate_bytes), .byte_length = bytes, .alignment = alignment }; return 0;
        }
        if (heap_live and bytes == hdmi_bytes.len) {
            std.debug.assert(running and !hdmi_heap_live);
            hdmi_heap_live = true;
            // Exercise a partial live handle with no accessible CPU pointer.
            out.* = .{ .handle = 3, .cpu_address = if (partial_heap) 0 else @intFromPtr(&hdmi_bytes), .byte_length = bytes, .alignment = alignment };
            return if (partial_heap) -1 else 0;
        }
        if (heap_live) {
            std.debug.assert(running and !panel_heap_live and bytes == panel_bytes.len);
            panel_heap_live = true;
            out.* = .{ .handle = 2, .cpu_address = @intFromPtr(&panel_bytes), .byte_length = bytes, .alignment = alignment };
            return if (partial_heap) -1 else 0;
        }
        std.debug.assert(running and bytes <= F.bytes.len);
        heap_live = true;
        out.* = .{ .handle = 1, .cpu_address = @intFromPtr(&F.bytes), .byte_length = bytes, .alignment = alignment };
        return if (partial_heap) -1 else 0;
    }
    fn free(handle: u64) callconv(.c) i32 {
        if (fail_heap) return -1;
        if (handle == 4) { candidate_heap_live = false; return 0; }
        if (handle == 3) { hdmi_heap_live = false; return 0; }
        if (handle == 2) { panel_heap_live = false; return 0; }
        std.debug.assert(!panel_heap_live and !hdmi_heap_live);
        heap_live = false;
        return 0;
    }
    fn prepare(_: usize, plan: *const c.struct_r4dcn_plan, point: *const c.struct_r4dcn_limits) bool {
        std.debug.assert(running and plan.disp_khz <= point.disp_khz);
        if (fail_prepare) return false;
        F.blank();
        return true;
    }
    fn restore(_: usize) bool {
        std.debug.assert(running);
        if (fail_restore) return false;
        @memcpy(&F.words, &F.original);
        return true;
    }
    const hooks: core.Hooks = .{ .context = 0, .prepare = prepare, .restore = restore };
    fn open() !void {
        const ctx = r4os.r4dev.DriverContext.init(&api);
        try owner.prepareBoot(&ctx, &memory, &native, &board, limits, mode);
    }
};
test "DCN1 SIMD task holds boot memory across prepare commit abort and failed releases" {
    var pipeline: @import("display_pipeline.zig").Owner = .{};
    var detached: core.Owner = .{};
    try t.expectError(error.State, pipeline.bind(&detached, .{ .dcf_khz = 600000, .soc_khz = 626000, .fabric_khz = 1066666, .memory_khz = 1200000 }));

    const R = Runtime;
    try R.reset();
    // Runtime-owned state forces all production hook bodies through the host
    // linker. The missing board data must reject before any hardware effect.
    R.owner.self_address = @intFromPtr(&R.owner);
    R.owner.phase = .planned;
    R.owner.panel_allocation.cpu_address = @intFromPtr(&R.panel_bytes);
    R.owner.native = &R.native; R.owner.board = &R.board;
    try t.expectError(error.Unsupported, pipeline.bind(&R.owner, .{ .dcf_khz = 600000, .soc_khz = 626000, .fabric_khz = 1066000, .memory_khz = 1200000 }));
    try R.reset();
    try R.open();
    try t.expect(!R.owner.poll());
    R.run();
    R.fail_join = true;
    try t.expect(!R.owner.poll());
    R.fail_join = false;
    R.fail_release = true;
    try t.expect(!R.owner.poll());
    R.fail_release = false;
    try t.expect(R.owner.poll());
    try t.expectEqual(core.Phase.planned, R.owner.phase);
    try t.expect(R.memory.engine_users == 2 and R.heap_live);
    try R.owner.commit(R.hooks);
    R.run();
    try t.expect(R.owner.poll());
    try t.expectEqual(@as(i32, 0), R.owner.result);
    try t.expect(R.owner.effects and R.owner.phase == .programmed);
    // Scanout work crosses the same real task/join boundary. Hardware changes
    // in this fixture are explicit register-model events, never timer receipts.
    const epoch: core.scanout.Epoch = .{ .backend = .{ .adapter_id = 1, .device_generation = 3, .reset_generation = 1 },
        .output = .{ .adapter_id = 1, .connector_id = 0x3114, .device_generation = 3, .connection_generation = 1 }, .memory = 7, .display = 13, .mode = 1 };
    const first: core.scanout.Image = .{ .reference = .{ .id = 44, .generation = 2 }, .address = mode.mc_address, .bytes = mode.buffer_bytes };
    latchScanout(mode.mc_address, 0);
    try R.owner.scanoutCommand(.{ .operation = .bind, .epoch = epoch, .image = first });
    R.run(); try t.expect(R.owner.poll()); try t.expectEqual(@as(i32, 0), R.owner.result);
    try R.owner.scanoutCommand(.{ .operation = .enable, .epoch = epoch, .sequence = 1, .deadline_ns = F.ticks + std.time.ns_per_s });
    R.run(); try t.expect(R.owner.poll()); try t.expectEqual(@as(i32, 0), R.owner.result);
    F.words[d.control[0] / 4] |= hw.OTG0_OTG_CONTROL__OTG_CURRENT_MASTER_EN_STATE_MASK;
    F.words[d.hubp_cntl[0] / 4] &= ~@as(u32, hw.HUBP0_DCHUBP_CNTL__HUBP_IN_BLANK_MASK);
    try R.owner.scanoutCommand(.{ .operation = .sample, .epoch = epoch });
    R.run(); try t.expect(R.owner.poll()); try t.expectEqual(@as(i32, c.R4DCN_BUSY), R.owner.result);
    latchScanout(mode.mc_address, 1);
    try R.owner.scanoutCommand(.{ .operation = .sample, .epoch = epoch });
    R.run(); R.fail_join = true; try t.expect(!R.owner.poll());
    R.fail_join = false; try t.expect(R.owner.poll()); try t.expectEqual(@as(i32, 0), R.owner.result);
    try t.expectEqual(@as(u64, 1), R.owner.scanout_owner.receipt.?.sequence);
    try R.owner.scanoutCommand(.{ .operation = .acknowledge, .epoch = epoch, .sequence = 1 });
    R.run(); try t.expect(R.owner.poll()); try t.expectEqual(@as(i32, 0), R.owner.result);
    F.words[d.control[0] / 4] &= ~@as(u32, hw.OTG0_OTG_CONTROL__OTG_CURRENT_MASTER_EN_STATE_MASK);
    F.words[d.hubp_cntl[0] / 4] |= hw.HUBP0_DCHUBP_CNTL__HUBP_IN_BLANK_MASK | hw.HUBP0_DCHUBP_CNTL__HUBP_NO_OUTSTANDING_REQ_MASK;
    try R.owner.scanoutCommand(.{ .operation = .stop, .epoch = epoch });
    R.run(); try t.expect(R.owner.poll()); try t.expectEqual(@as(i32, 0), R.owner.result);
    R.fail_restore = true;
    try t.expect(!R.owner.close());
    R.run();
    try t.expect(R.owner.poll());
    try t.expect(R.owner.effects and R.heap_live and R.memory.engine_users == 2);
    R.fail_restore = false;
    try t.expect(!R.owner.close());
    R.run();
    R.fail_heap = true;
    try t.expect(!R.owner.close());
    try t.expect(!R.owner.effects and R.heap_live and R.memory.engine_users == 2);
    R.fail_heap = false;
    try t.expect(R.owner.close());
    try t.expect(!R.heap_live and R.memory.engine_users == 1);
    try t.expect(try R.native.guard.matches(&R.memory.registers));

    try R.reset();
    R.partial_heap = true;
    try R.open();
    R.run();
    try t.expect(R.owner.poll());
    try t.expect(R.owner.result != 0 and R.heap_live);
    try t.expect(R.owner.close());
    try t.expect(!R.heap_live and R.memory.engine_users == 1);
    try R.reset();
    try R.open();
    R.run();
    try t.expect(R.owner.poll());
    R.fail_prepare = true;
    try R.owner.commit(R.hooks);
    R.run();
    try t.expect(R.owner.poll());
    try t.expect(R.owner.effects and !R.owner.frontend_attempted);
    try t.expect(!R.owner.close());
    R.run();
    try t.expect(R.owner.close());
    // Panel allocation is independent, task-owned and released first even
    // when parsing or the allocator fails after returning a live handle.
    for ([_]bool{ false, true }) |partial| {
        try R.reset(); try R.open(); R.run(); try t.expect(R.owner.poll());
        R.partial_heap = partial;
        try R.owner.bindPanel(); R.run(); try t.expect(R.owner.poll());
        try t.expect(R.owner.result != 0 and R.panel_heap_live and R.heap_live);
        R.fail_heap = true;
        try t.expect(!R.owner.close() and R.memory.engine_users == 2 and R.heap_live);
        R.fail_heap = false;
        try t.expect(R.owner.close() and !R.panel_heap_live and !R.heap_live and R.memory.engine_users == 1);
    }
    for ([_]bool{ false, true }) |partial| {
        try R.reset(); try R.open(); R.run(); try t.expect(R.owner.poll());
        R.partial_heap = partial;
        try R.owner.bindHdmi(); R.run(); try t.expect(R.owner.poll());
        try t.expect(R.owner.result != 0 and R.hdmi_heap_live and R.heap_live);
        R.fail_heap = true;
        try t.expect(!R.owner.close() and R.memory.engine_users == 2);
        R.fail_heap = false;
        try t.expect(R.owner.close() and !R.hdmi_heap_live and !R.heap_live and R.memory.engine_users == 1);
    }
    std.debug.print("[amd-dcn1-owner] actual driver Task/heap boundary; delayed joins/releases; partial allocation; failed clock/link prepare; restore ACK retains boot hold\n", .{});
}

fn latchScanout(address: u64, frame: u32) void {
    F.words[d.inuse[0] / 4] = @truncate(address);
    F.words[d.inuse_hi[0] / 4] = @truncate(address >> 32);
    F.words[reg("HUBPREQ0_DCSURF_SURFACE_EARLIEST_INUSE")] = @truncate(address);
    F.words[reg("HUBPREQ0_DCSURF_SURFACE_EARLIEST_INUSE_HIGH")] = @truncate(address >> 32);
    F.words[reg("HUBPREQ0_DCSURF_FLIP_CONTROL")] &= ~@as(u32, hw.HUBPREQ0_DCSURF_FLIP_CONTROL__SURFACE_FLIP_PENDING_MASK);
    F.words[reg("OTG0_OTG_STATUS_FRAME_COUNT")] = frame;
}
test "DCN1 real scanout flip cursor registers require coherent hardware receipts and stopped DMA" {
    F.reset(); F.scanout_model = true;
    try F.init();
    var plan: c.struct_r4dcn_plan = undefined;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_prepare(&F.bytes, &mode, 1, &plan));
    F.blank();
    try t.expectEqual(@as(c_int, 0), c.r4dcn_program(&F.bytes));
    latchScanout(mode.mc_address, 0xfffffe);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_scanout_enable(&F.bytes, 0));
    var sample: c.struct_r4dcn_scanout_sample = undefined;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_scanout_sample(&F.bytes, 0, &sample));
    try t.expect(sample.running == 1 and sample.blank == 0 and sample.pending == 0 and sample.frame == 0xfffffe);
    try t.expect(sample.inuse_address == mode.mc_address and sample.end_ns >= sample.begin_ns);
    const next = mode.mc_address + 0x1000000;
    const writes = F.writes;
    try t.expectEqual(@as(c_int, c.R4DCN_INVALID), c.r4dcn_scanout_flip(&F.bytes, 0, next + 1, mode.buffer_bytes));
    try t.expectEqual(@as(c_int, c.R4DCN_INVALID), c.r4dcn_scanout_flip(&F.bytes, 0, next, mode.buffer_bytes - 1));
    try t.expectEqual(writes, F.writes);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_scanout_flip(&F.bytes, 0, next, mode.buffer_bytes));
    try t.expectEqual(@as(u32, 0), F.words[reg("HUBPREQ0_DCSURF_FLIP_CONTROL")] & hw.HUBPREQ0_DCSURF_FLIP_CONTROL__SURFACE_FLIP_TYPE_MASK);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_scanout_sample(&F.bytes, 0, &sample));
    try t.expect(sample.pending == 1 and sample.requested_address == next and sample.inuse_address == mode.mc_address and sample.locked == 0);
    const pending_writes = F.writes;
    try t.expectEqual(@as(c_int, c.R4DCN_BUSY), c.r4dcn_scanout_flip(&F.bytes, 0, mode.mc_address, mode.buffer_bytes));
    try t.expectEqual(pending_writes, F.writes);
    latchScanout(next, 0);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_scanout_sample(&F.bytes, 0, &sample));
    try t.expect(sample.pending == 0 and sample.frame == 0 and sample.inuse_address == next);
    const unchanged = sample;
    F.tear_frame = true;
    try t.expectEqual(@as(c_int, c.R4DCN_BUSY), c.r4dcn_scanout_sample(&F.bytes, 0, &sample));
    try t.expect(std.meta.eql(unchanged, sample));
    F.tear_frame = false;

    var cursor: c.struct_r4dcn_cursor = .{ .mc_address = next + 0x1000000, .buffer_bytes = 16384, .width = 32, .height = 32, .pitch_pixels = 64, .hot_x = 3, .hot_y = 4, .enable = 1, .x = -2, .y = 1 };
    const before_cursor = F.writes;
    // Vertical position is still in blank: no cursor lock or address write.
    F.words[reg("OTG0_OTG_STATUS_POSITION")] = 0;
    try t.expectEqual(@as(c_int, c.R4DCN_BUSY), c.r4dcn_scanout_cursor(&F.bytes, 0, &cursor));
    try t.expectEqual(before_cursor, F.writes);
    F.words[reg("OTG0_OTG_STATUS_POSITION")] = 200 << hw.OTG0_OTG_STATUS_POSITION__OTG_VERT_COUNT__SHIFT;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_scanout_cursor(&F.bytes, 0, &cursor));
    try t.expect(F.words[reg("CURSOR0_CURSOR_CONTROL")] & hw.CURSOR0_CURSOR_CONTROL__CURSOR_ENABLE_MASK != 0);
    try t.expectEqual(@as(u32, 0), F.words[reg("CURSOR0_CURSOR_POSITION")]);
    try t.expectEqual(@as(u32, (5 << hw.CURSOR0_CURSOR_HOT_SPOT__CURSOR_HOT_SPOT_X__SHIFT) | (3 << hw.CURSOR0_CURSOR_HOT_SPOT__CURSOR_HOT_SPOT_Y__SHIFT)), F.words[reg("CURSOR0_CURSOR_HOT_SPOT")]);
    cursor.x = std.math.minInt(i32);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_scanout_cursor(&F.bytes, 0, &cursor));
    try t.expectEqual(@as(u32, 0), F.words[reg("CURSOR0_CURSOR_CONTROL")] & hw.CURSOR0_CURSOR_CONTROL__CURSOR_ENABLE_MASK);
    cursor.x = 50; cursor.y = 50;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_scanout_cursor(&F.bytes, 0, &cursor));
    F.hold_stop = true;
    try t.expectEqual(@as(c_int, c.R4DCN_BUSY), c.r4dcn_scanout_stop(&F.bytes, 1));
    F.hold_stop = false;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_scanout_stop(&F.bytes, 1));
    try t.expectEqual(@as(u32, 0), F.words[reg("CURSOR0_CURSOR_CONTROL")] & hw.CURSOR0_CURSOR_CONTROL__CURSOR_ENABLE_MASK);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_scanout_sample(&F.bytes, 0, &sample));
    try t.expect(sample.running == 0 and sample.blank == 1);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_quiesce(&F.bytes)); c.r4dcn_destroy(&F.bytes);

    // Partial TG-lock/address writes retain the owner until an explicit stop.
    F.reset(); F.scanout_model = true; try F.init();
    try t.expectEqual(@as(c_int, 0), c.r4dcn_prepare(&F.bytes, &mode, 1, &plan)); F.blank();
    try t.expectEqual(@as(c_int, 0), c.r4dcn_program(&F.bytes)); latchScanout(mode.mc_address, 1);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_scanout_enable(&F.bytes, 0));
    F.fail_write = F.writes + 3;
    try t.expectEqual(@as(c_int, c.R4DCN_IO), c.r4dcn_scanout_flip(&F.bytes, 0, next, mode.buffer_bytes));
    F.fail_write = 0;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_scanout_stop(&F.bytes, 1));
    try t.expectEqual(@as(u32, 0), F.words[reg("OTG0_OTG_MASTER_UPDATE_LOCK")]);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_quiesce(&F.bytes)); c.r4dcn_destroy(&F.bytes);
    std.debug.print("[amd-scanout] original DCN1 start/stop, asynchronous flip, coherent frame/address sample, MPC cursor/clipping and retained faults; model only\n", .{});
}

test "DCN1 scanout BO lifetime rejects timer-only visibility stale epochs and retains failed publication" {
    const life = @import("scanout_lifetime.zig");
    F.reset(); F.scanout_model = true; try F.init();
    var plan: c.struct_r4dcn_plan = undefined;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_prepare(&F.bytes, &mode, 1, &plan)); F.blank();
    try t.expectEqual(@as(c_int, 0), c.r4dcn_program(&F.bytes));
    const epoch: life.Epoch = .{ .backend = .{ .adapter_id = 7, .device_generation = 3, .reset_generation = 2 },
        .output = .{ .adapter_id = 7, .connector_id = 0x3114, .device_generation = 3, .connection_generation = 1 }, .memory = 7, .display = 8, .mode = 1 };
    const first: life.Image = .{ .reference = .{ .id = 30, .generation = 2 }, .address = mode.mc_address, .bytes = mode.buffer_bytes };
    const second: life.Image = .{ .reference = .{ .id = 31, .generation = 4 }, .address = mode.mc_address + 0x1000000, .bytes = mode.buffer_bytes };
    var owner: life.Owner = .{};
    latchScanout(mode.mc_address, 20);
    try owner.bind(&F.bytes, epoch, mode, first);
    try owner.enable(epoch, 1, F.ticks + std.time.ns_per_s);
    // Reset at TG enable is admitted only as a fresh domain, never as a flip.
    latchScanout(mode.mc_address, 0);
    try t.expectEqual(null, try owner.poll(epoch, F.ticks));
    F.ticks += 20 * std.time.ns_per_ms;
    try t.expectEqual(null, try owner.poll(epoch, F.ticks));
    latchScanout(mode.mc_address, 1);
    const enabled = (try owner.poll(epoch, F.ticks)).?;
    try t.expect(enabled.frame == 1 and enabled.image.reference.id == 30 and owner.phase == .receipt);
    try t.expectError(error.Busy, owner.flip(epoch, 2, second, F.ticks + std.time.ns_per_s));
    try t.expect(std.meta.eql(enabled, (try owner.poll(epoch, F.ticks)).?)); // publication retry
    try owner.acknowledge(epoch, 1);
    var stale = epoch; stale.mode += 1;
    const writes = F.writes;
    try t.expectError(error.Stale, owner.flip(stale, 2, second, F.ticks + std.time.ns_per_s));
    try t.expectEqual(writes, F.writes);
    try owner.flip(epoch, 2, second, F.ticks + std.time.ns_per_s);
    latchScanout(second.address, 1);
    try t.expectEqual(null, try owner.poll(epoch, F.ticks));
    latchScanout(mode.mc_address, 2);
    try t.expectEqual(null, try owner.poll(epoch, F.ticks));
    // Both the current address and progress since submission are now proved.
    latchScanout(second.address, 2);
    const flipped = (try owner.poll(epoch, F.ticks)).?;
    try t.expect(flipped.previous.?.reference.id == 30 and flipped.image.reference.id == 31);
    try t.expectError(error.Stale, owner.acknowledge(epoch, 1));
    try owner.acknowledge(epoch, 2);
    const cursor: life.Cursor = .{ .image = .{ .reference = .{ .id = 45, .generation = 3 }, .address = 0x207000000, .bytes = 16384 },
        .width = 32, .height = 32, .x = -4, .y = 10, .hot_x = 1, .hot_y = 2 };
    F.words[reg("OTG0_OTG_STATUS_POSITION")] = 200 << hw.OTG0_OTG_STATUS_POSITION__OTG_VERT_COUNT__SHIFT;
    try t.expectError(error.Stale, owner.cursor(stale, 1, cursor, F.ticks + std.time.ns_per_s));
    try owner.cursor(epoch, 1, cursor, F.ticks + std.time.ns_per_s);
    try t.expectError(error.Busy, owner.flip(epoch, 3, second, F.ticks + std.time.ns_per_s));
    F.ticks += 20 * std.time.ns_per_ms;
    try t.expectEqual(null, try owner.pollCursor(epoch, F.ticks)); // Timer and shadow registers alone are insufficient.
    latchScanout(second.address, 3);
    const shown = (try owner.pollCursor(epoch, F.ticks)).?;
    try t.expect(shown.update.image.?.reference.id == 45 and shown.previous.image == null);
    try t.expect(std.meta.eql(shown, (try owner.pollCursor(epoch, F.ticks)).?));
    try t.expectError(error.Stale, owner.acknowledgeCursor(epoch, 2));
    try owner.acknowledgeCursor(epoch, 1);
    try owner.cursor(epoch, 2, .{}, F.ticks + std.time.ns_per_s);
    try t.expect(owner.cursor_current.image.?.reference.id == 45);
    try t.expectEqual(null, try owner.pollCursor(epoch, F.ticks));
    latchScanout(second.address, 4);
    const hidden = (try owner.pollCursor(epoch, F.ticks)).?;
    try t.expect(hidden.update.image == null and hidden.previous.image.?.reference.id == 45);
    try owner.acknowledgeCursor(epoch, 2);
    try t.expect(owner.cursor_current.image == null);
    try owner.flip(epoch, 3, second, F.ticks + std.time.ns_per_s);
    try t.expectEqual(null, try owner.poll(epoch, F.ticks));
    F.ticks += 2 * std.time.ns_per_s;
    try t.expectError(error.Timeout, owner.poll(epoch, F.ticks));
    try t.expect(owner.phase == .retained and owner.pending.?.image.reference.id == 31 and owner.current.?.reference.id == 31);
    F.hold_stop = true;
    try t.expectError(error.Busy, owner.stop(epoch));
    try t.expectEqual(life.Phase.retained, owner.phase);
    F.hold_stop = false;
    try owner.stop(epoch);
    try t.expect(owner.phase == .stopped and owner.pending != null and owner.current != null);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_quiesce(&F.bytes)); c.r4dcn_destroy(&F.bytes);
    std.debug.print("[amd-scanout-life] BO receipts require actual address and counter progress; reset domains, stale modes, publication retry, timeout retention and confirmed stop; model only\n", .{});
}

const ClockIo = struct {
    const clocks = @import("display_clocks.zig");
    const v = clocks.Vbios;
    const smu = @import("start_registers.zig").smu;
    words: [@import("memory_registers.zig").required_prefix / 4]u32 = @splat(0),
    ticks: u64 = 0, writes: u32 = 0, fail_write: u32 = 0, hold: bool = false,
    response: u32 = 1, actual_mhz: u32 = 0,
    messages: [12]u32 = @splat(0), parameters: [12]u32 = @splat(0), count: usize = 0,
    fn init(self: *ClockIo) void {
        self.* = .{};
        self.words[smu.MP1_SMN_C2PMSG_90 / 4] = 1;
        self.words[v.response_register / 4] = 1;
    }
    pub fn read(self: *ClockIo, address: u32) clocks.Error!u32 { return self.words[address / 4]; }
    pub fn write(self: *ClockIo, address: u32, value: u32) clocks.Error!void {
        self.writes += 1;
        if (self.fail_write != 0 and self.fail_write == self.writes) return error.Disconnected;
        self.words[address / 4] = value;
        const driver_channel = address == smu.MP1_SMN_C2PMSG_66;
        if (driver_channel or address == v.message_register) {
            const response_reg = if (driver_channel) smu.MP1_SMN_C2PMSG_90 else v.response_register;
            const argument_reg = if (driver_channel) smu.MP1_SMN_C2PMSG_82 else v.argument_register;
            self.messages[self.count] = value; self.parameters[self.count] = self.words[argument_reg / 4]; self.count += 1;
            if (!self.hold) self.words[response_reg / 4] = self.response;
            if (!driver_channel and self.actual_mhz != 0) self.words[argument_reg / 4] = self.actual_mhz;
        }
    }
    pub fn barrier(_: *ClockIo) clocks.Error!void {}
    pub fn nowNs(self: *ClockIo) u64 { return self.ticks; }
};
var clock_io: ClockIo = .{};
test "SMU10 original clock table DMA and separate RV1 VBIOS channel require exact acknowledgements" {
    const clocks = @import("display_clocks.zig");
    const w = clocks.wire;
    const v = clocks.Vbios;
    var raw: w.DpmClocks_t = std.mem.zeroes(w.DpmClocks_t);
    raw.DcefClocks[0].Freq = 300; raw.DcefClocks[1].Freq = 600;
    raw.SocClocks[0].Freq = 400; raw.SocClocks[1].Freq = 626;
    raw.FClocks[0].Freq = 400; raw.FClocks[1].Freq = 1067;
    raw.MemClocks[0].Freq = 1200;
    const point = try clocks.Table.parse(std.mem.asBytes(&raw));
    try t.expect(point.dcf_khz == 600000 and point.soc_khz == 626000 and point.fabric_khz == 1067000 and point.memory_khz == 1200000);
    raw.SocClocks[3].Freq = 700;
    try t.expectError(error.Invalid, clocks.Table.parse(std.mem.asBytes(&raw)));
    raw.SocClocks[3].Freq = 0; raw.DcefClocks[0].Freq = 0;
    try t.expectError(error.Invalid, clocks.Table.parse(std.mem.asBytes(&raw)));
    raw.DcefClocks[1].Freq = 0;
    try t.expectError(error.Unsupported, clocks.Table.parse(std.mem.asBytes(&raw)));
    const io = &clock_io; io.init();
    var acquire: clocks.Acquisition = .{};
    try acquire.begin(io, 0x8_00004000, 4096);
    try t.expect(!acquire.releasable());
    try t.expect(!try acquire.step(io));
    try t.expect(!try acquire.step(io));
    try t.expect(try acquire.step(io));
    try t.expect(acquire.releasable() and acquire.dma_completed);
    try t.expectEqualSlices(u32, &.{ w.PPSMC_MSG_SetDriverDramAddrHigh, w.PPSMC_MSG_SetDriverDramAddrLow, w.PPSMC_MSG_TransferTableSmu2Dram }, io.messages[0..io.count]);
    try t.expectEqualSlices(u32, &.{ 8, 0x4000, w.TABLE_DPMCLOCKS }, io.parameters[0..io.count]);
    io.init(); acquire = .{};
    try acquire.begin(io, 0x8_00004000, 4096);
    try t.expect(!try acquire.step(io)); io.hold = true;
    try t.expect(!try acquire.step(io)); io.ticks = std.time.ns_per_s;
    try t.expectError(error.Deadline, acquire.step(io));
    try t.expect(!acquire.releasable());
    try t.expect(!try acquire.drain(io));
    const count = io.count;
    io.words[ClockIo.smu.MP1_SMN_C2PMSG_90 / 4] = 1;
    try t.expect(try acquire.drain(io));
    try t.expectEqual(count, io.count); // no resubmission after timeout

    io.init(); var policy: clocks.Point = .{};
    try t.expectError(error.Unconfirmed, policy.begin(io, point, 148501, false));
    try t.expectEqual(@as(u32, 0), io.writes);
    try policy.begin(io, point, 148501, true);
    for (0..4) |_| try t.expect(!try policy.step(io));
    try t.expect(try policy.step(io));
    try t.expectEqual(@as(u32, 149000), policy.actual_disp_khz);
    try t.expectEqualSlices(u32, &.{ w.PPSMC_MSG_SetHardMinFclkByFreq, w.PPSMC_MSG_SetHardMinSocclkByFreq, w.PPSMC_MSG_SetHardMinDcefclkByFreq, w.PPSMC_MSG_SetMinDeepSleepDcefclk, 4 }, io.messages[0..io.count]);
    try t.expectEqualSlices(u32, &.{ 1067, 626, 600, 600, 149 }, io.parameters[0..io.count]);
    try t.expect(v.message_register != ClockIo.smu.MP1_SMN_C2PMSG_66 and v.response_register != ClockIo.smu.MP1_SMN_C2PMSG_90);
    io.init(); var mailbox: v = .{}; io.actual_mhz = 148;
    try mailbox.begin(io, 148501);
    try t.expectError(error.Unconfirmed, mailbox.poll(io, false));
    try t.expectEqual(@as(u32, 0), mailbox.actual_khz);
    io.init(); mailbox = .{}; io.words[v.response_register / 4] = 0;
    try t.expectError(error.Busy, mailbox.begin(io, 150000)); try t.expectEqual(@as(u32, 0), io.writes);
    io.init(); mailbox = .{}; io.fail_write = 3;
    try t.expectError(error.Disconnected, mailbox.begin(io, 150000));
    io.words[v.response_register / 4] = 1;
    try t.expectError(error.State, mailbox.poll(io, true));
    try t.expect(mailbox.active and !mailbox.sent); // an old ACK cannot retire an uncertain write
    io.init(); var driver_mailbox: @import("start_smu.zig").Mailbox = .{}; io.fail_write = 3;
    try t.expectError(error.Disconnected, driver_mailbox.begin(io, w.PPSMC_MSG_TransferTableSmu2Dram, w.TABLE_DPMCLOCKS));
    io.words[ClockIo.smu.MP1_SMN_C2PMSG_90 / 4] = 1;
    try t.expectError(error.State, driver_mailbox.poll(io, true));
    try t.expect(driver_mailbox.active and !driver_mailbox.sent);
    try ClockMemory.check();
    try Pipeline.check();
    try Integration.check();
    std.debug.print("[amd-display-clocks] original 160-byte SMU table, retained DMA, ordered clock-floor ACKs and distinct RV1 VBIOS DISPCLK feedback; no physical measurement\n", .{});
}

const DpStream = struct {
    var pixel: [4]u32 = @splat(0);
    var pixel_count: usize = 0;
    fn atom(_: ?*anyopaque, command: u32, words: [*c]u32, count: u32) callconv(.c) c_int {
        const b = @import("bios.zig").c;
        if (command == @offsetOf(b.struct_atom_master_list_of_command_functions_v2_1, "setdceclock") / 2 and count == 4) {
            std.debug.assert(words[0] == 0 and words[1] == 0x0801 and words[2] == 0 and words[3] == 0);
            words[0] = 60000; return 0;
        }
        if (command == @offsetOf(b.struct_atom_master_list_of_command_functions_v2_1, "setpixelclock") / 2 and count == 4) {
            pixel = words[0..4].*; pixel_count += 1; return 0;
        }
        if (command == @offsetOf(b.struct_atom_master_list_of_command_functions_v2_1, "dig1transmittercontrol") / 2 and count == 8) return 0;
        return -1;
    }
    const callback: c.struct_r4dcn_atom = .{ .context = null, .execute = atom };
    const route: c.struct_r4dcn_route = .{ .connector = 0x3114, .encoder = 0x211e, .phy = 0, .aux = 0, .hpd = 0, .caps = 0xa,
        .ddc_a = reg("DC_GPIO_DDC1_A"), .hpd_a = reg("DC_GPIO_HPD_A"), .hpd_shift = 0, .hpd_active = 1 };
};
test "DCN1 eDP SST programs six and eight bit streams and retains unconfirmed stop" {
    for ([_]u32{6, 8}) |bpc| {
        F.reset(); try F.init(); F.scanout_model = true;
        DpStream.pixel_count = 0;
        var selected = mode;
        if (bpc == 6) selected.flags |= 8;
        var plan: c.struct_r4dcn_plan = undefined;
        try t.expectEqual(@as(c_int, 0), c.r4dcn_prepare(&F.bytes, &selected, 1, &plan));
        try t.expectEqual(@as(c_int, 0), c.r4dcn_link_bind(&F.bytes, 0, &DpStream.route, &DpStream.callback));
        try t.expectEqual(@as(c_int, 0), c.r4dcn_dp_stream_bind(&F.bytes, 0));
        try t.expectEqual(@as(usize, 0), F.writes);
        try t.expectEqual(@as(c_int, 0), c.r4dcn_link_action(&F.bytes, 0, c.R4DCN_LINK_INIT));
        try t.expectEqual(@as(c_int, 0), c.r4dcn_pixel_clock_bind(&F.bytes, 0, 48000));
        try t.expectEqual(@as(c_int, c.R4DCN_STATE), c.r4dcn_pixel_clock_program(&F.bytes, 0, 0));
        var reference_khz: u32 = 0;
        try t.expectEqual(@as(c_int, 0), c.r4dcn_reference_clock_program(&F.bytes, 0, &reference_khz));
        try t.expectEqual(@as(u32, 600000), reference_khz);
        try t.expectEqual(@as(c_int, 0), c.r4dcn_pixel_clock_program(&F.bytes, 0, 0));
        try t.expectEqual(@as(usize, 1), DpStream.pixel_count);
        try t.expectEqualSlices(u32, &.{1485000, 0x001e0b, 0, 0}, &DpStream.pixel);
        const before = F.writes;
        try t.expectEqual(@as(c_int, c.R4DCN_INVALID), c.r4dcn_dp_stream_configure(&F.bytes, 0, 0, if (bpc == 6) 8 else 6));
        try t.expectEqual(before, F.writes);
        try t.expectEqual(@as(c_int, 0), c.r4dcn_dp_stream_configure(&F.bytes, 0, 0, bpc));
        try t.expectEqual(@as(u32, if (bpc == 6) 0 else 1),
            (F.words[reg("DP0_DP_PIXEL_FORMAT")] & hw.DP0_DP_PIXEL_FORMAT__DP_COMPONENT_DEPTH_MASK) >> hw.DP0_DP_PIXEL_FORMAT__DP_COMPONENT_DEPTH__SHIFT);
        try t.expectEqual(@as(u32, (2200 << 16) | 1125), F.words[reg("DP0_DP_MSA_TIMING_PARAM1")]);
        try t.expectEqual(@as(c_int, c.R4DCN_STATE), c.r4dcn_dp_stream_start(&F.bytes, 0));
        F.blank();
        try t.expectEqual(@as(c_int, 0), c.r4dcn_program(&F.bytes));
        try t.expectEqual(@as(c_int, 0), c.r4dcn_link_enable(&F.bytes, 0, 20, 4, 0));
        try t.expectEqual(@as(c_int, 0), c.r4dcn_link_train(&F.bytes, 0, 0, &[_]u8{0, 0, 0, 0}));
        try t.expectEqual(@as(c_int, c.R4DCN_STATE), c.r4dcn_dp_stream_start(&F.bytes, 0)); // TG still stopped.
        try t.expectEqual(@as(c_int, 0), c.r4dcn_scanout_enable(&F.bytes, 0));
        F.words[reg("DIG0_DIG_BE_EN_CNTL")] |= hw.DIG0_DIG_BE_EN_CNTL__DIG_ENABLE_MASK;
        try t.expectEqual(@as(c_int, 0), c.r4dcn_dp_stream_start(&F.bytes, 0));
        try t.expectEqual(@as(u32, 0x8000), F.words[reg("DP0_DP_VID_N")]);
        try t.expectEqual(@as(u32, 0x8000 * 148500 / 540000), F.words[reg("DP0_DP_VID_M")]);
        var active: u32 = 99;
        try t.expectEqual(@as(c_int, 0), c.r4dcn_link_video(&F.bytes, 0, 0, &active));
        try t.expectEqual(@as(u32, 0), active); // Submitted enable is not active-video evidence.
        F.words[reg("DP0_DP_VID_STREAM_CNTL")] |= hw.DP0_DP_VID_STREAM_CNTL__DP_VID_STREAM_STATUS_MASK;
        try t.expectEqual(@as(c_int, 0), c.r4dcn_link_video(&F.bytes, 0, 0, &active));
        try t.expectEqual(@as(u32, 1), active);
        try t.expectEqual(@as(c_int, c.R4DCN_TIMEOUT), c.r4dcn_dp_stream_stop(&F.bytes, 0));
        try t.expect(F.words[reg("DP0_DP_STEER_FIFO")] & hw.DP0_DP_STEER_FIFO__DP_STEER_FIFO_RESET_MASK == 0);
        // Late hardware stream retirement, then the idempotent cleanup retry.
        F.words[reg("DP0_DP_VID_STREAM_CNTL")] &= ~@as(u32, hw.DP0_DP_VID_STREAM_CNTL__DP_VID_STREAM_STATUS_MASK);
        try t.expectEqual(@as(c_int, 0), c.r4dcn_dp_stream_stop(&F.bytes, 0));
        try t.expectEqual(@as(c_int, 0), c.r4dcn_scanout_stop(&F.bytes, 1));
        try t.expectEqual(@as(c_int, 0), c.r4dcn_quiesce(&F.bytes));
        c.r4dcn_destroy(&F.bytes);
    }
    std.debug.print("[amd-edp-stream] original RGB6/8 MSA and M/N, ATOM pixel clock, submitted-versus-active video, bounded blank and late retirement; model only\n", .{});
}

const ClockMemory = struct {
    const Owner = @import("display_clock_owner.zig").Owner;
    const l = @import("memory_layout.zig");
    const smu = @import("start_registers.zig").smu;
    var owner: Owner = .{};
    var map: l.Layout = undefined;
    var bytes: [4096]u8 align(4096) = undefined;
    var live = false;
    var fail_map = false;
    var fail_unmap = false;
    var clears: u32 = 0;
    fn mapping(req: *const a.GfxMmioRequest, out: *a.GfxMmioWindow) callconv(.c) i32 {
        std.debug.assert(!live and req.resource_base == map.physical.offset and req.byte_length == 4096 and
            req.cache_policy == a.gfx_buffer_cache_write_combining and req.resource_flags == 1);
        live = true;
        out.* = .{ .handle = .{ .id = 71, .generation = 3 }, .cpu_address = @intFromPtr(&bytes),
            .physical_address = req.resource_base + req.byte_offset, .byte_length = 4096, .cache_policy = req.cache_policy };
        return if (fail_map) -1 else 1;
    }
    fn unmap(handle: *const a.GfxBufferHandle, quiesced: u32) callconv(.c) i32 {
        std.debug.assert(live and handle.id == 71 and quiesced == 1);
        if (fail_unmap) return -1;
        live = false; return 1;
    }
    fn collect() callconv(.c) i32 { return 1; }
    fn acknowledge() void { F.words[smu.MP1_SMN_C2PMSG_90 / 4] = 1; }
    fn init() !void {
        try Runtime.reset();
        owner = .{}; live = false; fail_map = false; fail_unmap = false; clears = 0;
        map = try l.Layout.create(.{ .base = 0x220000000, .bytes = 512 * 1024 * 1024 },
            .{ .base = 0x100000000, .bytes = 512 * 1024 * 1024 }, 0x100000, 8 * 1024 * 1024, null);
        Runtime.memory.layout = &map;
        Runtime.memory.memory = .{ .table = .{ .mmio_map = @intFromPtr(&mapping), .mmio_unmap = @intFromPtr(&unmap), .collect = @intFromPtr(&collect) } };
        Runtime.memory.registers.clock = .{ .table = .{ .now_ns = @intFromPtr(&Runtime.clock) } };
        acknowledge();
    }
    fn rawTable() void {
        @memset(&bytes, 0);
        // Populated prefixes; firmware DMA fills these words in the model.
        std.mem.writeInt(u32, bytes[0..4], 600, .little);
        std.mem.writeInt(u32, bytes[32..36], 626, .little);
        std.mem.writeInt(u32, bytes[96..100], 1067, .little);
        std.mem.writeInt(u32, bytes[128..132], 1200, .little);
    }
    fn check() !void {
        try init();
        const baseline = map.pool.allocated_bytes;
        try owner.prepare(&Runtime.memory, &Runtime.native);
        try t.expect(live and Runtime.memory.engine_users == 2 and map.pool.allocated_bytes == baseline + 4096);
        const address = try map.mcAddress(owner.allocation.span);
        try t.expectEqual(@as(u32, @intCast(address >> 32)), F.words[smu.MP1_SMN_C2PMSG_82 / 4]);
        try t.expect(!try owner.poll());
        acknowledge(); try t.expect(!try owner.poll());
        try t.expectEqual(@as(u32, @truncate(address)), F.words[smu.MP1_SMN_C2PMSG_82 / 4]);
        acknowledge(); try t.expect(!try owner.poll());
        try t.expect(owner.acquire.dma_attempted and owner.table == null);
        rawTable(); acknowledge(); try t.expect(try owner.poll());
        try t.expectEqual(@as(u32, 600000), owner.table.?.dcf_khz);
        try t.expect(!owner.close()); // Start clearing firmware address, retain the page.
        F.words[smu.MP1_SMN_C2PMSG_90 / 4] = 0; // unrelated channel busy before clear can begin
        try t.expect(!owner.close());
        try t.expect(!owner.cleanup.active and live);
        acknowledge(); try t.expect(!owner.close());
        try t.expect(owner.cleanup.active);
        acknowledge(); try t.expect(!owner.close());
        try t.expect(!owner.close());
        fail_unmap = true; acknowledge();
        try t.expect(!owner.close());
        try t.expect(live and map.pool.allocated_bytes == baseline + 4096 and Runtime.memory.engine_users == 2);
        fail_unmap = false; try t.expect(owner.close());
        try t.expect(!live and map.pool.allocated_bytes == baseline and Runtime.memory.engine_users == 1);
        try init(); fail_map = true;
        const second_baseline = map.pool.allocated_bytes;
        try t.expectError(error.Unsupported, owner.prepare(&Runtime.memory, &Runtime.native));
        try t.expect(live and owner.allocation.serial != 0 and owner.acquire.stage == .empty);
        try t.expect(owner.close());
        try t.expect(!live and map.pool.allocated_bytes == second_baseline);
        try init(); try owner.prepare(&Runtime.memory, &Runtime.native);
        acknowledge(); try t.expect(!try owner.poll());
        acknowledge(); try t.expect(!try owner.poll());
        F.ticks += std.time.ns_per_s;
        try t.expectError(error.Deadline, owner.poll());
        try t.expect(!owner.close() and live and owner.allocation.serial != 0);
        // Late DMA ACK only permits ordered address clear; it never bypasses it.
        rawTable(); acknowledge(); try t.expect(!owner.close());
        for (0..8) |_| { acknowledge(); if (owner.close()) break; }
        try t.expect(!live and owner.self_address == 0);
    }
};

// Composite task test: original native DCN code and the ATOM interpreter run
// against a synthetic register/receiver model. No physical timing is claimed.
const Pipeline = struct {
    const b = @import("bios.zig");
    const fixture = @import("bios_fixture.zig");
    const atom = @import("atom_vm.zig");
    const panel = @import("panel.zig");
    const smu = @import("start_registers.zig").smu;
    const clocks = @import("display_clocks.zig");
    const R = Runtime;
    var owner: @import("display_pipeline.zig").Owner = .{};
    var current: *@import("display_pipeline.zig").Owner = &owner;
    var receiver: [0x800]u8 = undefined;
    var edid: [128]u8 = undefined;
    var pointer: usize = 0;
    var active = false;
    var hold_frames = false;
    var hold_video = false;
    var next_frame: u64 = 0;
    var next_hdmi_frame: u64 = 0;
    var hold_hdmi_frames = false;
    fn nativeRead(raw: ?*anyopaque, address: u32, out: [*c]u32) callconv(.c) c_int {
        if (Integration.hdmi_model and @import("hdmi_test.zig").SharedI2c.handles(address)) return @import("hdmi_test.zig").SharedI2c.read(raw, address, out);
        return F.read(raw, address, out);
    }
    fn nativeWrite(raw: ?*anyopaque, address: u32, value: u32) callconv(.c) c_int {
        const result = F.write(raw, address, value);
        if (result != 0) return result;
        if (Integration.hdmi_model and @import("hdmi_test.zig").SharedI2c.handles(address)) return @import("hdmi_test.zig").SharedI2c.write(raw, address, value);
        if (address / 4 == reg("DP0_DP_VID_STREAM_CNTL")) {
            F.words[address / 4] &= ~@as(u32, hw.DP0_DP_VID_STREAM_CNTL__DP_VID_STREAM_STATUS_MASK);
            if (hold_video or value & hw.DP0_DP_VID_STREAM_CNTL__DP_VID_STREAM_ENABLE_MASK != 0)
                F.words[address / 4] |= hw.DP0_DP_VID_STREAM_CNTL__DP_VID_STREAM_STATUS_MASK;
        }
        if (address / 4 == reg("OTG0_OTG_CONTROL")) F.words[d.otg[0] / 4] = @intFromBool(value & hw.OTG0_OTG_CONTROL__OTG_MASTER_EN_MASK != 0);
        return 0;
    }
    fn tick() void {
        if (!active) return;
        // Firmware ACKs are explicit effects of submitted mailbox messages.
        if (current.point.driver.active and current.point.driver.sent) F.words[smu.MP1_SMN_C2PMSG_90 / 4] = 1;
        if (current.point.vbios.active and current.point.vbios.sent) F.words[clocks.Vbios.response_register / 4] = 1;
        if (!hold_frames and F.ticks >= next_frame and F.words[d.control[0] / 4] & hw.OTG0_OTG_CONTROL__OTG_CURRENT_MASTER_EN_STATE_MASK != 0) {
            next_frame = F.ticks + 17 * std.time.ns_per_ms;
            const address = (@as(u64, F.words[d.primary_hi[0] / 4]) << 32) | F.words[d.primary[0] / 4];
            latchScanout(address, (F.words[reg("OTG0_OTG_STATUS_FRAME_COUNT")] + 1) & 0xffffff);
        }
        if (Integration.hdmi_model and !hold_hdmi_frames and F.ticks >= next_hdmi_frame and
            F.words[d.control[1] / 4] & hw.OTG0_OTG_CONTROL__OTG_CURRENT_MASTER_EN_STATE_MASK != 0) {
            next_hdmi_frame = F.ticks + 33 * std.time.ns_per_ms;
            const address = (@as(u64, F.words[d.primary_hi[1] / 4]) << 32) | F.words[d.primary[1] / 4];
            F.words[d.inuse[1] / 4] = @truncate(address); F.words[d.inuse_hi[1] / 4] = @truncate(address >> 32);
            F.words[reg("HUBPREQ1_DCSURF_SURFACE_EARLIEST_INUSE")] = @truncate(address);
            F.words[reg("HUBPREQ1_DCSURF_SURFACE_EARLIEST_INUSE_HIGH")] = @truncate(address >> 32);
            F.words[reg("HUBPREQ1_DCSURF_FLIP_CONTROL")] &= ~@as(u32, hw.HUBPREQ0_DCSURF_FLIP_CONTROL__SURFACE_FLIP_PENDING_MASK);
            F.words[reg("OTG1_OTG_STATUS_FRAME_COUNT")] = (F.words[reg("OTG1_OTG_STATUS_FRAME_COUNT")] + 1) & 0xffffff;
        }
    }
    fn read(_: usize, space: atom.Space, index: u32) atom.Error!u32 {
        if (space != .mmio or index >= F.words.len) return error.Bounds;
        return F.words[index];
    }
    fn write(_: usize, space: atom.Space, index: u32, value: u32) atom.Error!void {
        if (space != .mmio or index != 0x100) return error.Unsupported;
        // The synthetic transmitter table forwards its first PS DWORD into
        // this modeled firmware doorbell. The production interpreter still
        // validates/replays the real PS format and command revisions.
        const command = (value >> 8) & 255;
        const encoder = if (value & 255 == 1) reg("DIG1_DIG_BE_EN_CNTL") else reg("DIG0_DIG_BE_EN_CNTL");
        switch (command) {
            0 => F.words[encoder] &= ~@as(u32, hw.DIG0_DIG_BE_EN_CNTL__DIG_ENABLE_MASK),
            1 => F.words[encoder] |= hw.DIG0_DIG_BE_EN_CNTL__DIG_ENABLE_MASK,
            2 => F.words[reg("LVTMA_PWRSEQ_CNTL")] &= ~@as(u32, hw.LVTMA_PWRSEQ_CNTL__LVTMA_BLON_MASK),
            3 => F.words[reg("LVTMA_PWRSEQ_CNTL")] |= hw.LVTMA_PWRSEQ_CNTL__LVTMA_BLON_MASK,
            12 => F.words[reg("LVTMA_PWRSEQ_STATE")] = hw.LVTMA_PWRSEQ_STATE__LVTMA_PWRSEQ_TARGET_STATE_R_MASK,
            13 => F.words[reg("LVTMA_PWRSEQ_STATE")] = 0,
            7, 11 => {},
            else => return error.Unsupported,
        }
    }
    fn now(_: usize) u64 { tick(); return F.now(null); }
    fn delay(_: usize, us: u32) atom.Error!void { F.ticks += @as(u64, us) * 1000; tick(); }
    fn worker(_: usize) bool { return R.running; }
    fn transfer(_: usize, p: *c.struct_r4dcn_aux) panel.Error!void {
        p.reply = 0; p.transferred = 0;
        if (p.flags & 2 != 0) {
            if (p.address != 0x50) return error.Nack;
            if (p.flags & 1 != 0) {
                if (pointer + p.length > edid.len) return error.Io;
                @memcpy(p.data[0..p.length], edid[pointer..][0..p.length]); pointer += p.length; p.transferred = p.length;
            } else if (p.length == 1) pointer = p.data[0];
            return;
        }
        if (p.address + p.length > receiver.len) return error.Invalid;
        if (p.flags & 1 != 0) {
            if (p.address == 0x202 and p.length == 6) p.data[0..6].* = if (receiver[0x102] & 3 == 1) .{ 0x11, 0x11, 0, 0, 0, 0 } else .{ 0x77, 0x77, 1, 0, 0, 0 }
            else @memcpy(p.data[0..p.length], receiver[p.address..][0..p.length]);
            p.transferred = p.length;
        } else @memcpy(receiver[p.address..][0..p.length], p.data[0..p.length]);
    }
    fn table(comptime name: []const u8, at: u16, major: u8, minor: u8, ps: u8, code: []const u8) void {
        fixture.put(u16, &R.rom, 0xb04 + @offsetOf(b.c.struct_atom_master_list_of_command_functions_v2_1, name), at);
        fixture.header(R.rom[at..], @intCast(code.len + 6), major, minor);
        R.rom[at + 4] = 0; R.rom[at + 5] = ps;
        @memcpy(R.rom[at + 6 ..][0..code.len], code);
    }
    fn environment() !void {
        active = false; owner = .{}; hold_frames = false; hold_video = false; next_frame = 0; pointer = 0;
        current = &owner; next_hdmi_frame = 0; hold_hdmi_frames = false;
        try R.reset(); fixture.rom(&R.rom);
        fixture.set(b.c.struct_atom_rom_header_v2_2, "masterhwfunction_offset", R.rom[0x100..], 0xb00);
        fixture.header(R.rom[0xb00..], @sizeOf(b.c.struct_atom_master_list_of_command_functions_v2_1) + 4, 2, 1);
        table("dig1transmittercontrol", 0xc00, 1, 6, 32, &.{1, 1, 0, 1, 0, 91}); // MOVE_REG from PS0, EOT
        table("setpixelclock", 0xc40, 1, 7, 16, &.{91});
        table("setdceclock", 0xc80, 2, 1, 16, &.{2, 5, 0, 0x60, 0xea, 0, 0, 91}); // PS0=60000*10kHz
        table("digxencodercontrol", 0xcc0, 1, 5, 12, &.{91});
        fixture.entry(&R.rom, "dce_info", 0xd00);
        fixture.header(R.rom[0xd00..], @sizeOf(b.c.struct_atom_display_controller_info_v4_1), 4, 1);
        fixture.set(b.c.struct_atom_display_controller_info_v4_1, "dce_refclk_10khz", R.rom[0xd00..], 4800);
        try b.parse(&R.rom, fixture.device, &R.board);
        R.board.paths[0].encoder = 0x211e; R.board.paths[0].encoder_caps = 0xa; R.board.paths[0].aux_ddc_line = 0;
        R.board.paths[0].i2c_pin.?.register = @intCast(reg("DC_GPIO_DDC1_A")); R.board.paths[0].i2c_pin.?.shift = 0; R.board.paths[0].i2c_pin.?.mask_shift = 0;
        R.board.paths[0].hpd_pin.?.register = @intCast(reg("DC_GPIO_HPD_A")); R.board.paths[0].hpd_pin.?.shift = 0; R.board.paths[0].hpd_pin.?.mask_shift = 0;
        for (1..4) |i| F.words[d.hubp_cntl[i] / 4] = hw.HUBP0_DCHUBP_CNTL__HUBP_BLANK_EN_MASK | hw.HUBP0_DCHUBP_CNTL__HUBP_IN_BLANK_MASK;
        F.words[reg("LVTMA_PWRSEQ_STATE")] = hw.LVTMA_PWRSEQ_STATE__LVTMA_PWRSEQ_TARGET_STATE_R_MASK;
        F.words[reg("LVTMA_PWRSEQ_CNTL")] = hw.LVTMA_PWRSEQ_CNTL__LVTMA_BLON_MASK | hw.LVTMA_PWRSEQ_CNTL__LVTMA_BLON_OVRD_MASK;
        F.words[reg("DC_GPIO_HPD_Y")] = 1;
        F.words[reg("DP0_DP_VID_STREAM_CNTL")] = hw.DP0_DP_VID_STREAM_CNTL__DP_VID_STREAM_ENABLE_MASK | hw.DP0_DP_VID_STREAM_CNTL__DP_VID_STREAM_STATUS_MASK;
        F.words[reg("DIG0_DIG_BE_EN_CNTL")] = hw.DIG0_DIG_BE_EN_CNTL__DIG_ENABLE_MASK;
        F.words[smu.MP1_SMN_C2PMSG_90 / 4] = 1; F.words[clocks.Vbios.response_register / 4] = 1;
        for (0..4) |i| F.words[hw.R4DCN_MPC_STATUS(i) / 4] = hw.MPCC0_MPCC_STATUS__MPCC_IDLE_MASK;
        inline for (0..4) |i| {
            F.words[reg(std.fmt.comptimePrint("OTG{d}_OTG_CLOCK_CONTROL", .{i}))] = hw.OTG0_OTG_CLOCK_CONTROL__OTG_CLOCK_ON_MASK;
            F.words[reg(std.fmt.comptimePrint("ODM{d}_OPTC_INPUT_CLOCK_CONTROL", .{i}))] = hw.ODM0_OPTC_INPUT_CLOCK_CONTROL__OPTC_INPUT_CLK_ON_MASK;
        }
        R.native.guard = .{}; try R.native.guard.capture(&R.memory.registers, mode.mc_address, mode.pitch_bytes);
        R.memory.registers.clock = .{ .table = .{ .now_ns = @intFromPtr(&R.clock) } };
    }
    fn setup() !void {
        try environment();
        var selected_limits = limits; selected_limits.fabric_khz = 1066000;
        var selected = mode; selected.mc_address += 16 * 1024 * 1024;
        const ctx = r4os.r4dev.DriverContext.init(&R.api);
        // The task preparation is genuine; the outer BO fixture is exercised
        // separately. This private model plans the alternate retained address.
        try R.open(); R.owner.mode = selected; R.owner.limits = selected_limits;
        _ = ctx;
        R.run(); try t.expect(R.owner.poll()); try t.expectEqual(@as(i32, 0), R.owner.result);
        // r4dcn's first field is its host transport (dcn_internal.h). Replace
        // that test-local transport; all original native algorithms stay live.
        const native_io: *c.struct_r4dcn_io = @ptrFromInt(R.owner.allocation.cpu_address);
        native_io.* = F.io; native_io.read = nativeRead; native_io.write = nativeWrite;
        F.scanout_model = true;
        try R.owner.bindPanel(); R.run(); try t.expect(R.owner.poll()); try t.expectEqual(@as(i32, 0), R.owner.result);
        const runtime: *@import("panel_runtime.zig").Runtime = @ptrFromInt(R.owner.panel_allocation.cpu_address);
        runtime.vm.io = .{ .context = 0, .read = read, .write = write, .now = now, .delay = delay, .worker = worker };
        runtime.protocol.?.io.transfer = transfer;
        initReceiver();
        const hooks = try owner.bind(&R.owner, .{ .dcf_khz = 600000, .soc_khz = 626000, .fabric_khz = 1066000, .memory_khz = 1200000 });
        active = true;
        try R.owner.commit(hooks); R.run(); try t.expect(R.owner.poll());
        if (R.owner.result != 0) std.debug.print("pipeline prepare: result={d} failure={?} atom={?} panel={?}\n", .{R.owner.result, owner.failure, runtime.last_atom_error, runtime.last_panel_error});
        try t.expectEqual(@as(i32, 0), R.owner.result);
        try t.expect(owner.touched and R.owner.phase == .programmed and runtime.protocol.?.phase == .trained);
    }
    fn initReceiver() void {
        @memset(&receiver, 0); receiver[0..16].* = .{ 0x14, 20, 0xc4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0 };
        receiver[0x700..0x705].* = .{3, 5, 6, 0, 0}; receiver[0x724] = 16; receiver[0x722] = 0x80;
        @memset(&edid, 0); edid[0..8].* = .{0,255,255,255,255,255,255,0}; edid[8] = 4; edid[9] = 0x43;
        edid[18] = 1; edid[19] = 4; edid[20] = 0xa5; edid[24] = 2; @memset(edid[38..54], 1);
        edid[54..72].* = .{2,0x3a,0x80,0x18,0x71,0x38,0x2d,0x40,0x58,0x2c,0x45,0,0,0,0,0,0,0x1e}; fixture.checksum(&edid,127);
    }
    fn check() !void {
        try setup();
        // No visible-frame receipt is synthesized from elapsed time. A
        // stopped model retains every owner until actual counters resume.
        hold_frames = true;
        try t.expect(!R.owner.close()); R.run(); try t.expect(R.owner.poll());
        if (owner.failure == null or owner.failure.? != error.Timeout) std.debug.print("pipeline restore failure={?}\n", .{owner.failure});
        try t.expect(R.owner.effects and R.heap_live and !owner.restored);
        try t.expectEqual(error.Timeout, owner.failure.?);
        hold_frames = false;
        try t.expect(!R.owner.close()); R.run(); try t.expect(R.owner.poll());
        if (!owner.restored) std.debug.print("pipeline restore retry failure={?}\n", .{owner.failure});
        try t.expect(owner.restored and owner.restore_frame != 0 and !R.owner.effects and R.native.restored_guard != null);
        try t.expect(R.native.bootMatches());
        try t.expect(!try R.native.guard.matches(&R.memory.registers)); // Original evidence remains immutable.
        try t.expect(R.owner.close()); active = false;
        try t.expect(R.memory.engine_users == 1 and !R.heap_live and !R.panel_heap_live);
        std.debug.print("[amd-pipeline] actual task, ATOM VM, clocks, eDP training, native frontend and bounded boot reconstruction; no physical device\n", .{});
    }
};

// Integrated common facade model. It supplies distinct references, leases,
// UMA blocks and explicit GPU stimuli to the production output/SDMA owners.
const Integration = struct {
    const R = Runtime;
    const storage = @import("queue_storage.zig");
    const buffers = @import("display_buffers.zig");
    const Ref = struct { buffer: usize = 0, live: bool = false };
    const Lease = struct { buffer: usize = 0, access: u32 = 0, live: bool = false };
    const BO = struct { descriptor: a.GfxBufferDescriptor = .{}, ticket: a.GfxOwnedBufferReservation = .{},
        committed: bool = false, claimed: bool = false, live: bool = false };
    var output: @import("display_output.zig").Owner = .{};
    var presentation: @import("display_present.zig").Owner = .{};
    var pipe: @import("display_pipeline.zig").Owner = .{};
    var engine: @import("sdma_jobs.zig").Owner = .{};
    var queue: @import("queue_runtime.zig").Owner = .{};
    var images: [2]buffers.Image = .{ .{}, .{} };
    var mode_images: [2]buffers.Image = .{ .{}, .{} };
    var mode_copy: @import("display_copy.zig").Owner = .{};
    var layout: @import("memory_layout.zig").Layout = undefined;
    var tables: [128 * 512]u64 align(4096) = undefined;
    var bos: [16]BO = @splat(.{});
    var data: [16][8 * 1024 * 1024]u8 align(4096) = undefined;
    var refs: [64]Ref = @splat(.{});
    var leases: [64]Lease = @splat(.{});
    var window_live: [16]bool = @splat(false);
    var boot_bytes: [7680 * 1080]u8 align(4096) = undefined;
    var arena: [storage.bytes / 4]u32 align(4096) = undefined;
    var bells: [1024]u32 align(4096) = undefined;
    var registration: a.GfxNativeRegistration = .{};
    var source: a.GfxBufferReference = .{};
    var job: a.GfxDriverJob = .{};
    var active_job = false;
    var hdmi_source: a.GfxBufferReference = .{};
    var hdmi_job: a.GfxDriverJob = .{};
    var hdmi_active_job = false;
    var hdmi_completed: u32 = 0;
    var completed: u32 = 0;
    var complete_busy = false;
    var reported: a.DisplayPresentationStats = .{};
    var info: a.DisplayPresentationInfo = .{};
    var cursor_job: ?a.GfxDriverCursorJob = null;
    var cursor_reply: a.GfxDriverCursorCompletion = .{};
    var cursor_busy = false;
    var prepare_calls: u32 = 0;
    var partial_prepare = false;
    var commit_calls: u32 = 0;
    var stats_calls: u32 = 0;
    var release_busy = false;
    var reset_begin_calls: u32 = 0;
    var reset_retire_calls: u32 = 0;
    var common_reset_retired = false;
    var mode_job: ?a.GfxDriverModeJob = null;
    var mode_reply: a.GfxDriverModeCompletion = .{};
    var mode_complete_busy = false;
    var mode_enable_calls: u32 = 0;
    var publication_calls: u32 = 0;
    var hdmi_model = false;
    var hdmi_publications: u32 = 0;
    var hdmi_withdrawals: u32 = 0;
    var hdmi_identity: a.GfxOutputId = .{};
    var hdmi_withdraw_busy = false;
    var common_mode_retained = false;
    var reset_mode_source: a.GfxBufferReference = .{};
    const binding: a.GfxBackendBinding = .{ .adapter_id = 1, .device_generation = 21, .reset_generation = 4, .milestone = a.gfx_queue_milestone_device_execution };
    fn reference(buffer_index: usize) a.GfxBufferReference {
        for (&refs, 0..) |*ref, n| if (!ref.live) {
            ref.* = .{ .buffer = buffer_index, .live = true };
            return .{ .buffer = .{ .id = @intCast(buffer_index + 100), .generation = 19 }, .reference = .{ .id = @intCast(n + 1000), .generation = 19 } };
        };
        unreachable;
    }
    fn index(ref: a.GfxBufferHandle) usize {
        std.debug.assert(ref.id >= 1000 and ref.id < 1000 + refs.len and ref.generation == 19 and refs[ref.id - 1000].live);
        return refs[ref.id - 1000].buffer;
    }
    fn newLease(i: usize, access: u32) a.GfxBufferHandle {
        for (&leases, 0..) |*lease, n| if (!lease.live) { lease.* = .{ .buffer = i, .access = access, .live = true }; return .{ .id = @intCast(n + 2000), .generation = 19 }; };
        unreachable;
    }
    fn dropLease(handle: a.GfxBufferHandle) void {
        std.debug.assert(handle.id >= 2000 and handle.id < 2000 + leases.len and handle.generation == 19 and leases[handle.id - 2000].live);
        leases[handle.id - 2000].live = false;
    }
    fn memoryQuery(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        out.* = .{ .buffer_reserve = @intFromPtr(&reserve), .buffer_commit = @intFromPtr(&commitBuffer), .buffer_abort = @intFromPtr(&abortBuffer),
            .buffer_take_release = @intFromPtr(&takeRelease), .buffer_finish_release = @intFromPtr(&finishRelease),
            .buffer_import = @intFromPtr(&importBuffer), .buffer_create = @intFromPtr(&create), .buffer_release = @intFromPtr(&release),
            .buffer_describe = @intFromPtr(&describe), .buffer_map = @intFromPtr(&mapCpu), .buffer_unmap = @intFromPtr(&unmapCpu),
            .device_acquire = @intFromPtr(&acquire), .device_segment = @intFromPtr(&segment), .device_release = @intFromPtr(&deviceRelease),
            .mmio_map = @intFromPtr(&mapWindow), .mmio_unmap = @intFromPtr(&unmapWindow), .collect = @intFromPtr(&collect) }; return 1;
    }
    fn collect() callconv(.c) i32 { return if (release_busy) -4 else 1; }
    fn reserve(desc: *const a.GfxBufferDescriptor, cookie: u64, out: *a.GfxOwnedBufferReservation) callconv(.c) i32 {
        for (&bos, 0..) |*bo, i| if (!bo.live) {
            std.debug.assert(desc.byte_length <= data[i].len and desc.device_generation == R.memory.epoch);
            const ref = reference(i);
            bo.* = .{ .live = true, .descriptor = desc.*,
                .ticket = .{ .buffer = ref.buffer, .reference = ref.reference, .cookie = cookie, .allocation_bytes = desc.byte_length,
                    .adapter_id = 1, .device_generation = R.memory.epoch, .driver_owner = 9, .driver_generation = 31 } };
            bo.descriptor.driver_owner = 9; out.* = bo.ticket; return 1;
        };
        return -3;
    }
    fn commitBuffer(ticket: *const a.GfxOwnedBufferReservation, out: *a.GfxBufferReference) callconv(.c) i32 {
        const i = index(ticket.reference); std.debug.assert(std.meta.eql(ticket.*, bos[i].ticket));
        bos[i].committed = true; out.* = .{ .reference = ticket.reference, .buffer = ticket.buffer }; return 1;
    }
    fn abortBuffer(ticket: *const a.GfxOwnedBufferReservation, _: u32) callconv(.c) i32 {
        bos[index(ticket.reference)] = .{}; refs[ticket.reference.id - 1000].live = false; return 1;
    }
    fn takeRelease(_: u32, _: u64, out: *a.GfxOwnedBufferRelease) callconv(.c) i32 {
        outer: for (&bos, 0..) |*bo, i| {
            if (!bo.live or !bo.committed or bo.claimed) continue;
            for (&refs) |*ref| if (ref.live and ref.buffer == i) continue :outer;
            for (&leases) |*lease| if (lease.live and lease.buffer == i) continue :outer;
            bo.claimed = true;
            out.* = .{ .buffer = bo.ticket.buffer, .cookie = bo.ticket.cookie, .byte_length = bo.descriptor.byte_length, .attempt = 1,
                .adapter_id = 1, .device_generation = R.memory.epoch, .driver_owner = 9, .driver_generation = 31 }; return 1;
        }
        return a.gfx_buffer_error_busy;
    }
    fn finishRelease(ticket: *const a.GfxOwnedBufferRelease, q: u32) callconv(.c) i32 {
        const i = ticket.buffer.id - 100; std.debug.assert(q == 1 and bos[i].claimed and !window_live[i]);
        if (release_busy) return -4;
        bos[i] = .{}; return 1;
    }
    fn importBuffer(ref: *const a.GfxBufferHandle, out: *a.GfxBufferReference) callconv(.c) i32 { out.* = reference(index(ref.*)); return 1; }
    fn create(desc: *const a.GfxBufferDescriptor, out: *a.GfxBufferReference) callconv(.c) i32 {
        for (&bos, 0..) |*bo, i| if (!bo.live) {
            std.debug.assert(desc.location == a.gfx_buffer_location_system and desc.byte_length <= data[i].len);
            bo.* = .{ .live = true, .descriptor = desc.* }; out.* = reference(i); return 1;
        }; return -3;
    }
    fn describe(ref: *const a.GfxBufferHandle, out: *a.GfxBufferDescriptor) callconv(.c) i32 { out.* = bos[index(ref.*)].descriptor; return 1; }
    fn release(ref: *const a.GfxBufferHandle) callconv(.c) i32 {
        const i = index(ref.*); if (release_busy) return -4;
        refs[ref.id - 1000].live = false;
        if (!bos[i].committed) {
            for (&refs) |*live| if (live.live and live.buffer == i) return 1;
            for (&leases) |*lease| std.debug.assert(!lease.live or lease.buffer != i);
            bos[i] = .{};
        }
        return 1;
    }
    fn mapCpu(ref: *const a.GfxBufferHandle, access: u32, offset: u64, bytes: u64, out: *a.GfxBufferMap) callconv(.c) i32 {
        const i = index(ref.*); std.debug.assert(access == a.gfx_buffer_map_read and offset == 0 and bytes <= bos[i].descriptor.byte_length and !bos[i].committed);
        out.* = .{ .lease = newLease(i, 1), .cpu_address = @intFromPtr(&data[i]), .byte_length = bytes, .cache_policy = a.gfx_buffer_cache_write_back }; return 1;
    }
    fn unmapCpu(lease: *const a.GfxBufferHandle) callconv(.c) i32 { if (release_busy) return -4; dropLease(lease.*); return 1; }
    fn acquire(ref: *const a.GfxBufferHandle, req: *const a.GfxDeviceRequest, out: *a.GfxDeviceLease) callconv(.c) i32 {
        const i = index(ref.*); std.debug.assert(req.adapter_id == 1 and req.device_generation == R.memory.epoch and req.byte_length == bos[i].descriptor.byte_length);
        out.* = .{ .lease = newLease(i, req.access), .byte_length = req.byte_length, .gpu_virtual_address = req.gpu_virtual_address,
            .adapter_id = 1, .driver_owner = 9, .device_generation = R.memory.epoch, .access = req.access, .address_space = req.address_space, .dma_mask = req.dma_mask }; return 1;
    }
    fn segment(lease: *const a.GfxDeviceLease, offset: u64, out: *a.GfxDmaSegment) callconv(.c) i32 {
        const i = leases[lease.lease.id - 2000].buffer; const bytes = @min(@as(u64, 4096), bos[i].descriptor.byte_length - offset);
        out.* = .{ .dma_address = 0x10000000 + i * 0x1000000 + offset, .byte_length = bytes, .next_offset = offset + bytes }; return 1;
    }
    fn deviceRelease(lease: *const a.GfxDeviceLease, q: u32) callconv(.c) i32 {
        std.debug.assert(q == 1); if (release_busy) return -4; dropLease(lease.lease); return 1;
    }
    fn mapWindow(req: *const a.GfxMmioRequest, out: *a.GfxMmioWindow) callconv(.c) i32 {
        std.debug.assert(req.resource_base == layout.physical.offset);
        for (&bos, 0..) |*bo, i| if (bo.committed) {
            const span = R.memory.backing(bo.ticket.buffer) catch continue;
            if (span.offset != req.resource_base + req.byte_offset) continue;
            std.debug.assert(!window_live[i] and req.byte_length == span.bytes);
            window_live[i] = true;
            out.* = .{ .handle = .{ .id = @intCast(i + 3000), .generation = 19 }, .cpu_address = @intFromPtr(&data[i]),
                .physical_address = span.offset, .byte_length = span.bytes, .cache_policy = req.cache_policy }; return 1;
        }; return -1;
    }
    fn unmapWindow(handle: *const a.GfxBufferHandle, q: u32) callconv(.c) i32 {
        const i = handle.id - 3000; std.debug.assert(window_live[i] and q == 1);
        if (release_busy) return -4; window_live[i] = false; return 1;
    }
    fn displayQuery(out: *a.GfxDriverDisplayApi) callconv(.c) i32 {
        out.* = .{ .prepare_held = @intFromPtr(&prepare), .transition = @intFromPtr(&transition), .schedule = @intFromPtr(&schedule),
            .presentation_stats = @intFromPtr(&stats), .presentation_info = @intFromPtr(&presentInfo), .cursor_configure = @intFromPtr(&cursorConfigure),
            .cursor_take = @intFromPtr(&cursorTake), .cursor_complete = @intFromPtr(&cursorComplete),
            .device_reset = @intFromPtr(&deviceReset), .prepare_reset = @intFromPtr(&prepareReset),
            .output_register = @intFromPtr(&additionalRegister), .output_transition = @intFromPtr(&additionalTransition) }; return 1;
    }
    var extra_active = false;
    var extra_retired = false;
    fn additionalRegister(input: *const a.GfxAdditionalOutput, out: *a.GfxOutputTarget) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(input.output, hdmi_identity) and input.head_id == 1 and !extra_active);
        out.* = .{ .adapter_id = input.backend.adapter_id, .device_generation = input.backend.device_generation,
            .connector_id = input.output.connector_id, .connection_generation = input.output.connection_generation,
            .head_id = 1, .display_generation = (@as(u64, 1) << 63) + input.output.connection_generation };
        extra_retired = false; return 1;
    }
    fn additionalTransition(target: *const a.GfxOutputTarget, operation: u32, quiet: u32) callconv(.c) i32 {
        std.debug.assert(target.head_id == 1 and std.meta.eql(target.*, output.additional.target));
        if (operation == 0) {
            std.debug.assert(quiet == 0 and output.additional.initial_receipt != null and R.owner.extra_scanout.phase == .active);
            extra_active = true;
        } else if (operation == 2) {
            std.debug.assert(quiet == 1 and output.additional.hardware_stopped and output.additional.presentation.input == null);
            extra_active = false; extra_retired = true;
        } else extra_active = false;
        return 1;
    }
    fn prepareReset(_: *const a.GfxNativeRegistration, _: u64, _: u64, _: *a.GfxNativeState) callconv(.c) i32 { return a.gfx_output_error_unsupported; }
    fn deviceReset(backend: *const a.GfxBackendBinding, generation: u64, quiet: u32, state: *a.GfxNativeState) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(backend.*, binding) and queue.thread == 0);
        if (quiet == 0) {
            reset_begin_calls += 1; std.debug.assert(generation == output.reset_original and generation >= 12 and generation <= 13);
            if (reset_begin_calls == 1) return a.gfx_output_error_busy;
        } else {
            reset_retire_calls += 1;
            std.debug.assert(quiet == 1 and generation == output.reset_original + 1 and output.restore_ready == 1 and R.owner.self_address == 0 and engine.closed and
                R.memory.mapping_users == 0 and R.memory.engine_users == 0 and !R.memory.controller.enabled and R.native.bootMatches());
            if (reset_retire_calls == 1) return a.gfx_output_error_busy;
            if (reset_mode_source.reference.id != 0) {
                std.debug.assert(release(&reset_mode_source.reference) == 1); reset_mode_source = .{};
            }
            common_mode_retained = false;
            common_reset_retired = true;
        }
        state.* = .{ .generation = output.reset_original + 1, .retained = 1, .state = a.display_state_recovering, .outcome = a.gfx_output_outcome_lost };
        return 1;
    }
    fn outputQuery(out: *a.GfxDriverOutputApi) callconv(.c) i32 {
        out.* = .{ .publish = @intFromPtr(&publish), .withdraw = @intFromPtr(&withdraw), .output_pause = @intFromPtr(&pause),
            .mode_restore = @intFromPtr(&restoreMode), .mode_status = @intFromPtr(&modeStatus), .mode_enable = @intFromPtr(&modeEnable),
            .mode_take = @intFromPtr(&modeTake), .mode_complete = @intFromPtr(&modeComplete) }; return 1;
    }
    fn modeEnable(backend: *const a.GfxBackendBinding) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(backend.*, binding) and output.callback_confirmed and R.owner.scanout_owner.phase == .active);
        mode_enable_calls += 1; return if (mode_enable_calls == 1) a.gfx_output_error_busy else 1;
    }
    fn modeTake(backend: *const a.GfxBackendBinding, out: *a.GfxDriverModeJob) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(backend.*, binding));
        out.* = mode_job orelse return 0; mode_job = null;
        if (out.operation == a.gfx_mode_operation_apply) common_mode_retained = true;
        return 1;
    }
    fn modeComplete(value: *const a.GfxDriverModeCompletion) callconv(.c) i32 {
        if (mode_complete_busy) return a.gfx_output_error_busy;
        std.debug.assert(R.owner.thread == 0 and (R.owner.scanout_owner.phase == .active or R.owner.scanout_owner.phase == .stopped));
        std.debug.assert(output.modes.copy.self_address == 0 and output.additional.modes.copy.self_address == 0);
        if (value.operation != a.gfx_mode_operation_apply or value.outcome != a.gfx_output_outcome_applied) common_mode_retained = false;
        mode_reply = value.*; return 1;
    }
    fn restoreMode(_: *const a.GfxAtomicState, _: *a.GfxModeStatus) callconv(.c) i32 { return a.gfx_output_error_unsupported; }
    fn modeStatus(_: u64, _: *a.GfxModeStatus) callconv(.c) i32 { return a.gfx_output_error_unsupported; }
    fn publish(value: *const a.GfxOutputPublication, id: *a.GfxOutputId) callconv(.c) i32 {
        if (value.info.connector_kind == a.gfx_output_kind_hdmi) {
            std.debug.assert(hdmi_model and value.info.flags == a.gfx_output_flag_connected and value.info.identity.connection_generation == 0 and
                value.info.mode_count != 0 and value.info.edid_bytes == 256 and value.info.possible_heads == 2 and value.info.limits.bpc_mask == 1 << 8);
            hdmi_publications += 1; id.* = value.info.identity; id.connection_generation = 10 + hdmi_publications;
            hdmi_identity = id.*; return 1;
        }
        publication_calls += 1;
        std.debug.assert(value.info.mode_count == (if (publication_calls == 1) @as(u32, 1) else 2) and value.info.connector_kind == a.gfx_output_kind_edp);
        std.debug.assert(value.info.flags & (a.gfx_output_flag_active | a.gfx_output_flag_fixed_geometry | a.gfx_output_flag_firmware_snapshot) == 0 and
            value.info.identity.connection_generation == 0);
        if (publication_calls > 1) std.debug.assert(mode_enable_calls == 2 and value.info.limits.flags == a.gfx_output_limit_modeset and
            value.info.limits.bandwidth_bytes_per_second != 0 and value.modes[1].width == 1280);
        id.* = value.info.identity; id.connection_generation = 8 + publication_calls; return 1;
    }
    fn withdraw(id: *const a.GfxOutputId) callconv(.c) i32 {
        if (id.connector_id == 0x310c) {
            std.debug.assert(std.meta.eql(id.*, hdmi_identity));
            if (hdmi_withdraw_busy) return a.gfx_output_error_busy;
            hdmi_withdrawals += 1;
        }
        return 1;
    }
    fn pause(id: *const a.GfxOutputId, value: u32) callconv(.c) i32 {
        if (id.connector_id == 0x310c) std.debug.assert(std.meta.eql(id.*, hdmi_identity) and value == 1);
        return 1;
    }
    fn prepare(value: *const a.GfxNativeRegistration, held: u64, state: *a.GfxNativeState) callconv(.c) i32 {
        prepare_calls += 1; if (prepare_calls == 1) return a.gfx_output_error_busy;
        std.debug.assert(held == 12 and value.output.connection_generation == 9 and index(value.reference) == index(output.shadow.reference.reference));
        registration = value.*; state.* = .{ .generation = held, .retained = 1, .state = a.display_state_preparing,
            .outcome = if (partial_prepare) a.gfx_output_outcome_lost else a.gfx_output_outcome_validated };
        return if (partial_prepare) a.gfx_output_error_capacity else 1;
    }
    fn transition(generation: u64, operation: u32, state: *a.GfxNativeState) callconv(.c) i32 {
        var boot = output.original_boot; boot.generation = generation;
        if (operation == 0) {
            commit_calls += 1; if (commit_calls == 1) return a.gfx_output_error_busy;
            const callback: *const fn (u64, u64, *const a.GfxNativeBootInfo) callconv(.c) i32 = @ptrFromInt(registration.commit_callback);
            std.debug.assert(callback(registration.context, generation, &boot) == 1);
            state.* = .{ .generation = generation, .retained = 1, .state = a.display_state_software_native, .outcome = a.gfx_output_outcome_applied };
        } else {
            std.debug.assert(operation == 2);
            if (reset_begin_calls >= 2) {
                std.debug.assert(generation == output.reset_original + 1);
                if (!common_reset_retired) return a.gfx_output_error_busy;
                boot.state = a.display_state_recovering;
                std.debug.assert(@import("start_runtime.zig").Owner.restore(@intFromPtr(&R.native), generation, &boot) == 1);
                state.* = .{ .generation = generation + 1, .state = a.display_state_bootfb, .outcome = a.gfx_output_outcome_applied };
                return 1;
            }
            if (common_mode_retained) return a.gfx_output_error_busy;
            const callback: *const fn (u64, u64, *const a.GfxNativeBootInfo) callconv(.c) i32 = @ptrFromInt(registration.restore_callback);
            if (callback(registration.context, generation, &boot) != 1) {
                state.* = .{ .generation = generation + 1, .retained = 1, .state = a.display_state_unavailable, .outcome = a.gfx_output_outcome_lost };
            } else state.* = .{ .generation = generation, .state = a.display_state_bootfb, .outcome = a.gfx_output_outcome_applied };
        }
        return 1;
    }
    fn schedule(_: *const a.GfxBackendBinding) callconv(.c) i32 { return 0; }
    fn stats(value: *const a.DisplayPresentationStats) callconv(.c) i32 { stats_calls += 1; reported = value.*; return 1; }
    fn presentInfo(value: *const a.DisplayPresentationInfo) callconv(.c) i32 { info = value.*; return 1; }
    fn cursorConfigure(value: *const a.DisplayCursorInfo) callconv(.c) i32 {
        std.debug.assert(value.flags == 15 and value.display_generation == 12 and value.max_width == 64); return 1;
    }
    fn cursorTake(_: *const a.GfxBackendBinding, out: *a.GfxDriverCursorJob) callconv(.c) i32 {
        out.* = cursor_job orelse return 0; cursor_job = null; return 1;
    }
    fn cursorComplete(value: *const a.GfxDriverCursorCompletion) callconv(.c) i32 {
        if (cursor_busy) return a.gfx_output_error_busy;
        cursor_reply = value.*; return 1;
    }
    fn updateOperations(_: *const a.GfxBackendBinding, operations: u64) callconv(.c) i32 {
        std.debug.assert(operations & (@as(u64, 1) << a.gfx_queue_operation_present) != 0); return 1;
    }
    fn retain(fence: *const a.GfxFence, side: u32, out: *a.GfxBufferReference) callconv(.c) i32 {
        if (hdmi_active_job and std.meta.eql(fence.*, hdmi_job.fence)) {
            std.debug.assert(side == 0); out.* = reference(index(hdmi_source.reference)); out.flags = a.gfx_buffer_reference_mapping_only; return 1;
        }
        std.debug.assert(active_job and side == 0 and std.meta.eql(fence.*, job.fence));
        out.* = reference(index(source.reference)); out.flags = a.gfx_buffer_reference_mapping_only; return 1;
    }
    fn complete(fence: *const a.GfxFence, result: u32, quiet: u32) callconv(.c) i32 {
        if (hdmi_active_job and std.meta.eql(fence.*, hdmi_job.fence)) {
            std.debug.assert(quiet == 1);
            if (result == a.gfx_queue_result_complete) std.debug.assert(output.additional.presentation.receipt != null and R.owner.extra_scanout.phase == .active);
            hdmi_completed += 1; hdmi_active_job = false; return 1;
        }
        std.debug.assert(active_job and quiet == 1 and std.meta.eql(fence.*, job.fence));
        if (complete_busy) return -4;
        if (result == a.gfx_queue_result_complete) std.debug.assert(presentation.receipt != null and R.owner.scanout_owner.phase == .active);
        completed += 1; active_job = false; return 1;
    }
    fn init() !void {
        try Pipeline.environment(); Pipeline.initReceiver();
        Pipeline.edid[72..90].* = .{1,0x1d,0,0x72,0x51,0xd0,0x1e,0x20,0x6e,0x28,0x55,0,0,0,0,0,0,0x1e};
        @import("bios_fixture.zig").checksum(&Pipeline.edid,127);
        output = .{}; presentation = .{}; pipe = .{}; engine = .{}; queue = .{}; images = .{ .{}, .{} };
        bos = @splat(.{}); refs = @splat(.{}); leases = @splat(.{}); window_live = @splat(false);
        source = .{}; job = .{}; active_job = false; hdmi_source = .{}; hdmi_job = .{}; hdmi_active_job = false; hdmi_completed = 0; completed = 0; complete_busy = false; release_busy = false;
        cursor_job = null; cursor_reply = .{}; cursor_busy = false; prepare_calls = 0; partial_prepare = false; commit_calls = 0; stats_calls = 0;
        reset_begin_calls = 0; reset_retire_calls = 0; common_reset_retired = false;
        mode_job = null; mode_reply = .{}; mode_complete_busy = false; mode_enable_calls = 0; publication_calls = 0;
        extra_active = false; extra_retired = false;
        hdmi_publications = 0; hdmi_withdrawals = 0; hdmi_identity = .{}; hdmi_withdraw_busy = false;
        common_mode_retained = false; reset_mode_source = .{};
        if (hdmi_model) {
            @import("hdmi_test.zig").SharedI2c.reset();
            R.board.path_count = 2; R.board.paths[1] = R.board.paths[0];
            R.board.paths[1].connector = 0x310c; R.board.paths[1].encoder = 0x221e; R.board.paths[1].aux_ddc_line = 1;
            R.board.paths[1].i2c_pin.?.register = @intCast(reg("DC_GPIO_DDC2_A"));
            R.board.paths[1].hpd_pin.?.shift = 8; R.board.paths[1].hpd_pin.?.mask_shift = 8;
            F.words[reg("DC_GPIO_HPD_Y")] |= 256;
        }
        R.api.gfx_memory_query = memoryQuery; R.api.gfx_display_query = displayQuery; R.api.gfx_output_query = outputQuery;
        const ctx = r4os.r4dev.DriverContext.init(&R.api);
        layout = try @import("memory_layout.zig").Layout.create(.{ .base = 0x220000000, .bytes = 512 * 1024 * 1024 },
            .{ .base = mode.mc_address, .bytes = 512 * 1024 * 1024 }, 0, mode.buffer_bytes, null);
        R.memory.layout = &layout; R.memory.memory = ctx.memory();
        R.memory.controller = .{ .enabled = true, .epoch = R.memory.epoch };
        try R.memory.virtual.init(&tables, 0x230000000);
        const mr = @import("memory_registers.zig");
        F.words[mr.gfx.VM_INVALIDATE_ENG17_ACK / 4] = 3; F.words[mr.mm.VM_INVALIDATE_ENG17_ACK / 4] = 3;
        @memset(&boot_bytes, 0x35); F.ticks = std.time.ns_per_ms;
        R.native.ctx = ctx; R.native.hold.valid = true; R.native.hold.boot.physical_address = layout.physical.offset;
        R.native.hold.read = .{ .lease = .{ .id = 17, .generation = 2 }, .cpu_address = @intFromPtr(&boot_bytes), .byte_length = boot_bytes.len };
        var display: a.GfxDriverDisplayApi = .{}; _ = displayQuery(&display); R.native.hold.display = .{ .table = display };
        queue.self_address = @intFromPtr(&queue); queue.memory = &R.memory;
        queue.queue = .{ .table = .{ .update_operations = @intFromPtr(&updateOperations), .retain_resource = @intFromPtr(&retain), .complete = @intFromPtr(&complete) } };
        queue.arena = .{ .self_address = @intFromPtr(&queue.arena), .memory = &R.memory, .epoch = R.memory.epoch, .gpu = 0x8000000000, .ready = true,
            .arena = .{ .value = .{ .handle = .{ .id = 5000, .generation = 19 }, .cpu_address = @intFromPtr(&arena), .byte_length = storage.bytes } },
            .doorbell = .{ .value = .{ .handle = .{ .id = 5001, .generation = 19 }, .cpu_address = @intFromPtr(&bells), .byte_length = 4096 } } };
        try queue.timeline.init(binding, try queue.arena.fences(), F.ticks);
        engine.self_address = @intFromPtr(&engine); engine.memory = &R.memory; engine.runtime = &queue; engine.binding = binding;
        engine.queue = queue.queue; engine.registered = true; engine.verified = true;
        engine.engine.ring = try @import("queue_ring.zig").Ring.init(try queue.arena.words32(storage.ringOffset(.sdma), storage.ring_bytes), 8, 0);
        engine.engine.running = true;
        try output.request(&ctx, &R.native, &engine, &R.owner, &pipe, &presentation, .{ &images[0], &images[1] }, &R.board,
            .{ .dcf_khz = 600000, .soc_khz = 626000, .fabric_khz = 1066000, .memory_khz = 1200000 }, limits.gb_addr_config);
        Pipeline.current = &pipe; Pipeline.active = true;
    }
    fn step() void {
        F.ticks += std.time.ns_per_ms; Pipeline.tick();
        if (R.live and !R.ran) {
            R.run();
            if (R.owner.allocation.cpu_address != 0) {
                const transport: *c.struct_r4dcn_io = @ptrFromInt(R.owner.allocation.cpu_address);
                transport.* = F.io; transport.read = Pipeline.nativeRead; transport.write = Pipeline.nativeWrite; F.scanout_model = true;
            }
            if (R.owner.panel_allocation.cpu_address != 0) {
                const panel: *@import("panel_runtime.zig").Runtime = @ptrFromInt(R.owner.panel_allocation.cpu_address);
                panel.vm.io = .{ .context = 0, .read = Pipeline.read, .write = Pipeline.write, .now = Pipeline.now, .delay = Pipeline.delay, .worker = Pipeline.worker };
                if (panel.protocol != null) panel.protocol.?.io.transfer = Pipeline.transfer;
            }
            if (R.owner.hdmi_allocation.cpu_address != 0) {
                const hdmi: *@import("hdmi_runtime.zig").Runtime = @ptrFromInt(R.owner.hdmi_allocation.cpu_address);
                hdmi.vm.io = .{ .context = 0, .read = Pipeline.read, .write = Pipeline.write, .now = Pipeline.now, .delay = Pipeline.delay, .worker = Pipeline.worker };
            }
        }
        queue.timeline.poll(F.ticks); _ = queue.timeline.publish(queue.queue.?);
        const client = engine.client.?; client.work(client.context);
    }
    fn untilActive() !void {
        for (0..2000) |_| { step(); if ((output.phase == .active and output.modes.ready) or output.phase == .failed) break; }
        if (output.phase != .active) std.debug.print("integration start: phase={s} failed={s} err={?} core={d} pipe={?}\n",
            .{@tagName(output.phase), @tagName(output.failed_phase), output.failure, R.owner.result, pipe.failure});
        if (output.phase != .active and R.owner.hdmi_allocation.cpu_address != 0) {
            const hdmi: *@import("hdmi_runtime.zig").Runtime = @ptrFromInt(R.owner.hdmi_allocation.cpu_address);
            std.debug.print("HDMI bind error={?} route={?} bound={x} nativeFault={d}\n", .{hdmi.last_bind_error, hdmi.route, hdmi.self_address, c.r4dcn_fault(&F.bytes)});
        }
        try t.expectEqual(@import("display_output.zig").Phase.active, output.phase);
        try t.expect(output.modes.ready and mode_enable_calls == 2 and output.epoch.output.connection_generation == 10 and
            R.owner.scanout_owner.epoch.output.connection_generation == 10 and output.initial_receipt.?.epoch.output.connection_generation == 9);
        step();
        try queueReady();
    }
    fn queueReady() !void {
        for (0..20) |_| {
            if (engine.client.?.available(engine.client.?.context)) return;
            step();
        }
        try t.expect(engine.client.?.available(engine.client.?.context));
    }
    fn gpuBytes(address: u64, bytes: u64) ![]u8 {
        const pte = try R.memory.virtual.lookup(address & ~@as(u64, 4095));
        const physical = (pte & @import("memory_pages.zig").physical_mask) + address % 4096;
        for (&bos, 0..) |*bo, i| if (bo.live) {
            const start = if (bo.committed) (try R.memory.backing(bo.ticket.buffer)).offset else 0x10000000 + i * 0x1000000;
            if (physical >= start and physical - start < bo.descriptor.byte_length and bytes <= bo.descriptor.byte_length - (physical - start))
                return data[i][@intCast(physical - start)..][0..@intCast(bytes)];
        }; return error.Bounds;
    }
    fn completeDma() !void {
        try completeTicket(presentation.ticket.?);
    }
    fn completeTicket(ticket: @import("queue_timeline.zig").Ticket) !void {
        const commands = try queue.arena.ib(ticket.slot);
        var i: usize = 0;
        while (commands[i] != 0) {
            if (commands[i] == 1) {
                const bytes = @as(u64, commands[i + 1]) + 1;
                const from = (@as(u64, commands[i + 4]) << 32) | commands[i + 3];
                const to = (@as(u64, commands[i + 6]) << 32) | commands[i + 5];
                @memcpy(try gpuBytes(to, bytes), try gpuBytes(from, bytes)); i += 7;
            } else if (commands[i] & 0xff == 11) {
                try t.expect(commands[i + 3] == 0);
                const to = (@as(u64, commands[i + 2]) << 32) | commands[i + 1];
                @memset(try gpuBytes(to, @as(u64, commands[i + 4]) + 1), 0); i += 5;
            } else {
                try t.expectEqual(@as(u32, 1 | (4 << 8)), commands[i] & 0x1fffffff);
                const bpp: u64 = @as(u64, 1) << @intCast(commands[i] >> 29);
                const from = (@as(u64, commands[i + 2]) << 32) | commands[i + 1];
                const to = (@as(u64, commands[i + 7]) << 32) | commands[i + 6];
                const from_pitch = (@as(u64, commands[i + 4] >> 13) + 1) * bpp;
                const to_pitch = (@as(u64, commands[i + 9] >> 13) + 1) * bpp;
                const bytes = (@as(u64, commands[i + 11] & 0xffff) + 1) * bpp;
                const rows = (commands[i + 11] >> 16) + 1;
                for (0..rows) |row| @memcpy(try gpuBytes(to + row * to_pitch, bytes), try gpuBytes(from + row * from_pitch, bytes));
                i += 13;
            }
            try t.expect(i < commands.len);
        }
        queue.timeline.writeback[ticket.slot] = ticket.token;
        try engine.engine.ring.observe(@intCast(engine.engine.ring.write & (engine.engine.ring.words.len - 1)));
    }
    fn check() !void {
        var stage: []const u8 = "initial present";
        errdefer std.debug.print("[amd-integration-failure] stage={s} output={s}/{?} present={s}/{?} head={s}/{?} mode={s}/{?} core={d} pipe={?}\n",
            .{stage, @tagName(output.phase), output.failure, @tagName(presentation.phase), presentation.failure,
              @tagName(output.additional.phase), output.additional.failure, @tagName(output.modes.phase), output.modes.failure, R.owner.result, pipe.failure});
        try init(); try untilActive();
        try t.expect(prepare_calls == 2 and commit_calls == 2 and output.callback_confirmed and R.native.hold.native_adopted);
        try t.expect(info.flags & a.display_presentation_info_visibility != 0 and reported.visible_ns != 0 and reported.gpu_timestamp == 0 and reported.irq_sequence == 0);
        const calls = stats_calls; for (0..3) |_| step(); try t.expectEqual(calls, stats_calls); // idle publishes no fake frames
        source = output.shadow.reference;
        @memset(data[index(source.reference)][0..@intCast(output.shadow.descriptor.byte_length)], 0x71);
        job = .{ .fence = .{ .adapter_id = 1, .device_generation = 21, .reset_generation = 4, .timeline = 3, .point = 1, .slot = 2 },
            .operation = a.gfx_queue_operation_present, .source_buffer = source.buffer, .byte_length = mode.width * 4, .row_count = mode.height,
            .source_pitch = mode.width * 4, .deadline_ns = F.ticks + 2 * std.time.ns_per_s, .display_target = output.target };
        try queueReady(); active_job = true; presentation.accept(job);
        try t.expect(presentation.armed and completed == 0 and presentation.source.ready);
        try completeDma(); Pipeline.hold_frames = true;
        for (0..20) |_| step();
        try t.expect(completed == 0 and !presentation.source.ready and (presentation.phase == .sample_wait or presentation.phase == .sample_retry));
        Pipeline.hold_frames = false; complete_busy = true;
        for (0..80) |_| { step(); if (presentation.retired) break; }
        try t.expect(presentation.retired and completed == 0 and presentation.visible == 1 and !presentation.available());
        try t.expectEqual(@as(u8, 0x71), data[index(images[1].reference.reference)][0]);
        complete_busy = false; for (0..3) |_| step();
        try t.expect(completed == 1 and presentation.available() and reported.source_point == 1 and reported.visible_count == 1);
        stage = "cursorAndDamage"; try cursorAndDamage();
        stage = "internalCopy"; try internalCopy();
        stage = "commonModes"; try commonModes();
        stage = "hardwareMode"; try hardwareMode();
        stage = "cleanup"; try cleanup();
        try init(); partial_prepare = true;
        for (0..2000) |_| { step(); if (output.phase == .failed) break; }
        try t.expect(output.phase == .failed and output.failure.? == error.Prepare and R.native.hold.native_adopted);
        stage = "cleanup"; try cleanup();
        stage = "multihead"; try multihead();
        stage = "connections"; try connections();
        stage = "failedModeReset"; try failedModeReset();
        stage = "nativePresent"; try nativePresent();
        std.debug.print("[amd-display-integration] real output prepare/commit, BO/PTE/SDMA copy, cursor barrier, partial damage, 1080p/720p rollback and retained partial handoff; model only\n", .{});
    }
    fn nativePresent() !void {
        try init(); try untilActive();
        const shape = output.shape;
        source = try R.memory.create(shape.descriptor(&R.memory));
        const source_index = index(source.reference);
        // Explicit completed-render pixel stimulus. The production path below
        // must use native UMA backing/PTEs, not a SYSTEM SG/CPU mapping.
        @memset(data[source_index][0..@intCast(shape.bytes)], 0x5a);
        job = .{ .fence = .{ .adapter_id = 1, .device_generation = 21, .reset_generation = 4, .timeline = 3, .point = 1, .slot = 2 },
            .operation = a.gfx_queue_operation_present, .source_buffer = source.buffer, .byte_length = shape.width * 4,
            .row_count = shape.height, .source_pitch = shape.pitch, .deadline_ns = F.ticks + 2 * std.time.ns_per_s,
            .display_target = output.target };
        try queueReady(); active_job = true; presentation.accept(job);
        try t.expect(presentation.armed and presentation.source.ready and presentation.source.native_owner == 9 and
            presentation.source.dma.lease.id == 0 and presentation.source.cpu.lease.id == 0);
        try t.expect(R.memory.drop(source.reference) and R.memory.collect());
        try t.expect(bos[source_index].live and completed == 0);
        // Caller close and an unrelated earlier counter do not retire the BO.
        step(); try t.expect(bos[source_index].live and completed == 0);
        try completeDma(); Pipeline.hold_frames = true;
        for (0..20) |_| step();
        // The normal GC allocation pump collects release tickets separately
        // from display completion. Exercise that owner here as well.
        try t.expect(R.memory.collect());
        try t.expect(!bos[source_index].live and completed == 0 and (presentation.phase == .sample_wait or presentation.phase == .sample_retry));
        Pipeline.hold_frames = false;
        for (0..100) |_| { step(); if (completed == 1) break; }
        try t.expect(completed == 1 and presentation.visible == 1 and output.failure == null);
        const front = index(presentation.frames[presentation.front].reference.reference);
        try t.expect(std.mem.allEqual(u8, data[front][0..@as(usize, shape.width) * 4], 0x5a));
        try t.expect(std.mem.allEqual(u8, data[front][(@as(usize, shape.height) - 1) * shape.pitch..][0..@as(usize, shape.width) * 4], 0x5a));
        try cleanup();
    }
    fn cleanup() !void {
        // Common restoration refuses before the whole device owner confirms.
        R.native.hold.read = .{}; // This model's immutable pixels have no SDK lease; the capture tests cover that owner.
        const original_generation: u64 = if (common_mode_retained) 12 else 13;
        try t.expect(!R.native.hold.close());
        try t.expect(R.native.hold.native_generation == original_generation and R.native.hold.held_generation == 12 and output.restore_requested == 1);
        output.phase = .closing;
        try t.expect(!output.beginReset() and R.native.hold.native_generation == original_generation);
        try t.expect(output.beginReset() and output.beginReset() and reset_begin_calls == 2 and R.native.hold.native_generation == original_generation + 1);
        try t.expect(!output.retireReset() and reset_retire_calls == 0 and !R.native.hold.close());
        for (0..20) |_| {
            if (R.owner.close()) break;
            if (R.live and !R.ran) R.run();
        }
        try t.expect(R.owner.self_address == 0 and pipe.restored);
        try t.expect(output.cursor.close(&R.memory, true));
        try t.expect(output.additional.reset());
        try t.expect(output.modes.close());
        for (&images) |*image| try t.expect(image.close(true));
        try t.expect(R.memory.mapping_users == 0 and R.memory.engine_users == 1);
        try t.expectError(error.Unconfirmed, output.confirmRestore());
        // Explicit final engine/firmware-stop stimulus; the real individual
        // teardown protocols are exercised by their existing owner tests.
        engine.closed = true; R.memory.engine_users = 0; R.memory.controller.enabled = false; R.native.flow = .{};
        try output.confirmRestore();
        try t.expect(!output.retireReset() and !R.native.hold.close());
        try t.expect(output.retireReset() and output.retireReset() and reset_retire_calls == 2);
        try t.expect(R.native.hold.close() and !R.native.hold.native_adopted and R.native.hold.held_generation == 0);
        try t.expect(output.connector.closeMetadata(&output.outputs.?));
        try t.expect(output.shadow.close());
        for (&refs) |*ref| try t.expect(!ref.live);
        for (&leases) |*lease| try t.expect(!lease.live);
        Pipeline.active = false;
    }
    fn bothActive() !void {
        for (0..1500) |_| {
            step();
            if (output.additional.phase == .active or output.additional.failure != null or output.failure != null) break;
        }
        if (output.additional.phase != .active) std.debug.print("[amd-head-start] phase={s} fail={?} core={d}/{s} pipe={?} HDMI={x} ctl={x}\n",
            .{@tagName(output.additional.phase), output.additional.failure, R.owner.result, @tagName(R.owner.phase), pipe.failure,
              F.words[reg("DIG1_DIG_BE_EN_CNTL")], F.words[d.control[1] / 4]});
        try t.expect(output.additional.phase == .active and extra_active and output.failure == null and output.primary_failure == null);
        try queueReady();
    }
    fn panelJob(point: u64) !void {
        source = output.shadow.reference;
        job = .{ .fence = .{ .adapter_id = 1, .device_generation = 21, .reset_generation = 4, .timeline = 3, .point = point, .slot = 2 },
            .operation = a.gfx_queue_operation_present, .source_buffer = source.buffer, .byte_length = mode.width * 4, .row_count = mode.height,
            .source_pitch = mode.width * 4, .deadline_ns = F.ticks + 2 * std.time.ns_per_s, .display_target = output.target };
        active_job = true; try t.expect(engine.client.?.accept(engine.client.?.context, job));
        for (0..100) |_| { if (presentation.ticket != null) break; step(); }
        try t.expect(presentation.ticket != null); try completeDma();
    }
    fn hdmiJob(point: u64) !void {
        const head = &output.additional;
        hdmi_job = .{ .fence = .{ .adapter_id = 1, .device_generation = 21, .reset_generation = 4, .timeline = 7, .point = point, .slot = 3 },
            .operation = a.gfx_queue_operation_present, .source_buffer = hdmi_source.buffer, .byte_length = head.mode.width * 4, .row_count = head.mode.height,
            .source_pitch = head.shape.pitch, .deadline_ns = F.ticks + 2 * std.time.ns_per_s, .display_target = head.target };
        hdmi_active_job = true; try t.expect(engine.client.?.accept(engine.client.?.context, hdmi_job));
        for (0..100) |_| { if (head.presentation.ticket != null) break; step(); }
        try t.expect(head.presentation.ticket != null); try completeTicket(head.presentation.ticket.?);
    }
    fn multihead() !void {
        hdmi_model = true; defer hdmi_model = false;
        try init(); try untilActive();
        const panel_address = R.owner.scanout_owner.current.?.address;
        try bothActive();
        const head = &output.additional;
        const first_target = head.target;
        try t.expect(R.owner.scanout_owner.current.?.address == panel_address and R.owner.plan.count == 2 and
            head.target.head_id != output.target.head_id and head.epoch.display != output.epoch.display and
            head.frames[0].mc_address != images[0].mc_address and R.owner.fixed_disp_khz >= 600000);
        // Original joint DML and the confirmed shared-clock ceiling reject
        // excess demand before any peer register or image is changed.
        var excessive = head.mode; excessive.pixel_khz = 720000;
        const writes = F.writes;
        try R.owner.planMode(excessive);
        for (0..20) |_| { if (R.live and !R.ran) R.run(); if (R.owner.poll()) break; }
        try t.expect(R.owner.thread == 0 and R.owner.result != 0 and !R.owner.candidate_valid and
            F.writes == writes and R.owner.scanout_owner.current.?.address == panel_address and R.owner.extra_scanout.phase == .active);
        hdmi_source = try R.memory.create(head.shape.descriptor(&R.memory));
        @memset(data[index(hdmi_source.reference)][0..@intCast(head.shape.bytes)], 0xa6);
        Pipeline.hold_hdmi_frames = true;
        try hdmiJob(1);
        for (0..40) |_| step();
        try t.expect(hdmi_completed == 0 and !head.presentation.source.ready and head.presentation.input != null);
        const before = completed;
        try panelJob(1);
        for (0..150) |_| { step(); if (completed > before) break; }
        try t.expect(completed == before + 1 and hdmi_completed == 0 and head.presentation.input != null and output.failure == null);
        try panelJob(2);
        for (0..150) |_| { step(); if (completed > before + 1) break; }
        try t.expect(completed == before + 2 and hdmi_completed == 0);
        Pipeline.hold_hdmi_frames = false;
        for (0..150) |_| { step(); if (hdmi_completed == 1 and head.presentation.input == null) break; }
        try t.expect(hdmi_completed == 1 and head.presentation.visible == 1 and head.presentation.source_fence.timeline == 7 and presentation.source_fence.timeline == 3);
        try t.expectEqual(@as(u8, 0xa6), data[index(head.frames[head.presentation.front].reference.reference)][0]);
        try hdmiModeRoundtrip(false);
        const panel_sequence = presentation.sequence;
        // The physical HDMI stop and canonical target retirement precede
        // withdrawal. Busy withdrawal retains its private images and peer.
        hdmi_withdraw_busy = true; F.words[reg("DC_GPIO_HPD_Y")] &= ~@as(u32, 256);
        for (0..1400) |_| { step(); if (head.hardware_stopped and extra_retired) break; }
        try t.expect(head.hardware_stopped and extra_retired and head.images[0].self_address != 0 and
            R.owner.scanout_owner.phase == .active and presentation.sequence == panel_sequence and output.failure == null);
        try panelJob(3);
        for (0..100) |_| { step(); if (!active_job) break; }
        try t.expect(!active_job and hdmi_withdrawals == 0);
        hdmi_withdraw_busy = false;
        for (0..700) |_| { step(); if (head.self_address == 0) break; }
        try t.expect(head.self_address == 0 and hdmi_withdrawals == 1);
        F.words[reg("DC_GPIO_HPD_Y")] |= 256;
        try bothActive();
        try t.expect(head.target.connection_generation > first_target.connection_generation and head.target.display_generation != first_target.display_generation);
        // Conversely, loss of the internal panel leaves HDMI scanning. No
        // device reset or timer-based release of the primary images occurs.
        F.words[reg("DC_GPIO_HPD_Y")] &= ~@as(u32, 1);
        for (0..700) |_| { step(); if (output.primary_stopped) break; }
        try t.expect(output.primary_stopped and output.primary_failure != null and output.restore_requested == 0 and output.failure == null and
            head.phase == .active and R.owner.extra_scanout.phase == .active and images[0].self_address != 0);
        try hdmiJob(2);
        for (0..150) |_| { step(); if (hdmi_completed == 2 and head.presentation.input == null) break; }
        try t.expect(hdmi_completed == 2 and output.failure == null);
        // The surviving HDMI mode owner must still join its own tasks after
        // primary isolation, including the common apply/confirm transaction.
        try hdmiModeRoundtrip(true);
        F.words[reg("DC_GPIO_HPD_Y")] |= 1;
        try t.expectEqual(@as(i32, 1), release(&hdmi_source.reference)); hdmi_source = .{};
        try cleanup();
        std.debug.print("[amd-multihead] actual joint DML and native dual-head programming, independent 60/30Hz stimuli, peer presents during held HDMI receipt, unplug/retained-withdraw/reconnect and isolated panel stop; model only\n", .{});
    }
    fn hdmiModeRoundtrip(confirm: bool) !void {
        const head = &output.additional;
        errdefer std.debug.print("[amd-hdmi-mode] confirm={} phase={s} failure={?} head={?} core={d} pipe={?} reply={d}/{d}/{d} epoch={d}\n",
            .{confirm, @tagName(head.modes.phase), head.modes.failure, head.failure, R.owner.result, pipe.failure,
              mode_reply.ticket, mode_reply.sequence, mode_reply.outcome, head.epoch.mode});
        try queueReady();
        const before = head.epoch.mode;
        const peer_mode = output.epoch.mode;
        const peer_address = R.owner.scanout_owner.current.?.address;
        const selected = for (head.publication.modes[0..head.publication.info.mode_count]) |candidate| {
            if (candidate.width == head.mode.width and candidate.height == head.mode.height) break candidate;
        } else return error.TestUnexpectedResult;
        // The common mode owner lends a tightly packed SYSTEM alias; native
        // presentation sources are a separate contract exercised above.
        var mode_source: a.GfxBufferReference = .{};
        try t.expectEqual(@as(i32, 1), create(&.{ .width = selected.width, .height = selected.height,
            .byte_length = @as(u64, selected.width) * selected.height * 4, .format = a.gfx_buffer_format_xrgb8888,
            .plane_count = 1, .plane_pitches = .{selected.width * 4, 0, 0, 0},
            .usage = a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_scanout }, &mode_source));
        var request: a.GfxDriverModeJob = .{ .ticket = if (confirm) 302 else 301, .sequence = 1,
            .operation = a.gfx_mode_operation_apply, .backend = binding, .mode = selected, .reference = mode_source,
            .deadline_ns = F.ticks + 5 * std.time.ns_per_s,
            .assignment = .{ .output = head.output, .mode_id = selected.mode_id, .head_id = head.mode.pipe,
                .plane_id = head.mode.pipe, .pll_id = head.mode.pipe, .source_width = selected.width, .source_height = selected.height,
                .destination_width = selected.width, .destination_height = selected.height, .bits_per_color = 8, .buffer = mode_source.buffer } };
        mode_job = request;
        var token: u64 = 0;
        for (0..1000) |_| {
            step();
            if (head.modes.copy.ticket) |ticket| if (head.modes.copy.armed and ticket.token != token) {
                try completeTicket(ticket); token = ticket.token;
            };
            if (mode_reply.ticket == request.ticket or head.failure != null or output.failure != null) break;
        }
        try t.expect(mode_reply.ticket == request.ticket and mode_reply.outcome == a.gfx_output_outcome_applied and
            head.epoch.mode == before + 1 and head.modes.pending != null and output.epoch.mode == peer_mode and
            R.owner.scanout_owner.current.?.address == peer_address);
        request.sequence = 2; request.operation = if (confirm) a.gfx_mode_operation_confirm else a.gfx_mode_operation_rollback;
        request.deadline_ns = F.ticks + 5 * std.time.ns_per_s; mode_job = request;
        for (0..1000) |_| {
            step();
            if ((mode_reply.ticket == request.ticket and mode_reply.sequence == 2) or head.failure != null or output.failure != null) break;
        }
        try t.expect(mode_reply.ticket == request.ticket and mode_reply.sequence == 2 and
            mode_reply.outcome == (if (confirm) a.gfx_output_outcome_applied else a.gfx_output_outcome_old_preserved) and
            head.modes.pending == null and head.modes.phase == .idle and output.failure == null and head.failure == null and
            output.epoch.mode == peer_mode and R.owner.scanout_owner.current.?.address == peer_address);
        try t.expectEqual(@as(i32, 1), release(&mode_source.reference));
    }
    fn connections() !void {
        hdmi_model = true; defer hdmi_model = false;
        try init(); try untilActive();
        for (0..500) |_| { step(); if (hdmi_publications == 1 and !output.connector.waiting() and output.connector.phase == .idle) break; }
        try t.expect(output.failure == null and hdmi_publications == 1 and @import("hdmi_test.zig").SharedI2c.requests() >= 3);
        const runtime: *@import("hdmi_runtime.zig").Runtime = @ptrFromInt(R.owner.hdmi_allocation.cpu_address);
        try t.expect(runtime.connection.phase == .connected and runtime.output.connection_generation == 11 and !runtime.activation_attempted and !runtime.configured);
        try queueReady();
        // Simultaneously due HDMI and eDP work must serialize on the actual
        // task owner instead of treating the second launch's Busy as loss.
        output.connector.next_sample = 0; output.connector.next_probe = std.math.maxInt(u64); output.next_health = 0;
        step();
        try t.expect(output.connector.waiting() and !output.health_pending and output.failure == null);
        step();
        try t.expect(!output.connector.waiting() and output.health_pending and output.failure == null);
        try queueReady();
        hdmi_withdraw_busy = true; F.words[reg("DC_GPIO_HPD_Y")] &= ~@as(u32, 256);
        for (0..900) |_| { step(); if (runtime.connection.phase == .retiring and runtime.connection.step == .withdraw) break; }
        try t.expect(runtime.connection.step == .withdraw and hdmi_withdrawals == 0 and runtime.output.connection_generation == 11 and output.failure == null);
        hdmi_withdraw_busy = false;
        for (0..400) |_| { step(); if (runtime.output.adapter_id == 0) break; }
        try t.expect(runtime.output.adapter_id == 0 and hdmi_withdrawals == 1);
        F.words[reg("DC_GPIO_HPD_Y")] |= 256;
        for (0..900) |_| { step(); if (hdmi_publications == 2 and runtime.connection.phase == .connected) break; }
        try t.expect(runtime.connection.generation == 2 and runtime.output.connection_generation == 12);
        // Receiver replacement without an HPD pulse is detected by the full
        // periodic EDID probe and also retires the previous common identity.
        @import("hdmi_test.zig").SharedI2c.changed();
        output.connector.next_probe = 0;
        for (0..3500) |_| { step(); if (hdmi_publications == 3 and runtime.connection.phase == .connected) break; }
        try t.expect(hdmi_withdrawals == 2 and runtime.connection.generation == 3 and runtime.output.connection_generation == 13 and output.failure == null);
        // Once the replacement HDMI head is active, eDP loss pauses only its
        // own consumer. The single-output recovery case remains covered above.
        try bothActive();
        F.words[reg("DC_GPIO_HPD_Y")] &= ~@as(u32, 1);
        for (0..700) |_| { step(); if (output.primary_stopped) break; }
        try t.expect(output.phase == .active and output.primary_failure.? == error.Visibility and
            output.primary_stopped and output.restore_requested == 0 and R.owner.extra_scanout.phase == .active);
        F.words[reg("DC_GPIO_HPD_Y")] |= 1;
        try cleanup();
        try t.expect(hdmi_withdrawals == 3 and !R.hdmi_heap_live);
    }
    fn failedModeReset() !void {
        try init(); try untilActive();
        try t.expectEqual(@as(i32, 1), create(&.{ .width = 1280, .height = 720, .byte_length = 1280 * 720 * 4,
            .format = a.gfx_buffer_format_xrgb8888, .plane_count = 1, .plane_pitches = .{5120,0,0,0},
            .usage = a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_scanout }, &reset_mode_source));
        mode_job = modeRequest(201, 1, reset_mode_source);
        var token: u64 = 0;
        for (0..200) |_| {
            step();
            if (output.modes.copy.ticket) |ticket| if (output.modes.copy.armed and ticket.token != token) {
                try completeTicket(ticket); token = ticket.token;
            };
            if (output.modes.phase == .apply) break;
        }
        try t.expect(output.modes.phase == .apply and common_mode_retained);
        F.fail_write = F.writes + 2;
        for (0..10) |_| { step(); if (output.phase == .failed) break; }
        try t.expect(output.phase == .failed and output.modes.hardware_armed and R.owner.phase == .retained and
            mode_reply.ticket == 0 and output.modes.spare[0].self_address != 0 and reset_mode_source.reference.id != 0);
        F.fail_write = 0;
        try cleanup();
        try t.expect(!common_mode_retained and reset_mode_source.reference.id == 0);
    }
    fn cursorRequest(sequence: u64, operation: u32, image_sequence: u64) a.GfxDriverCursorJob {
        return .{ .backend = binding, .sequence = sequence, .deadline_ns = F.ticks + 3 * std.time.ns_per_s,
            .request = .{ .display_generation = output.epoch.display, .head_id = output.mode.pipe, .operation = operation, .image_sequence = image_sequence } };
    }
    fn cursorDone(sequence: u64) !void {
        for (0..500) |_| { step(); if (cursor_reply.sequence == sequence or output.phase == .failed) break; }
        if (cursor_reply.sequence != sequence) std.debug.print("cursor sequence={d} phase={s} failure={?} output={?}\n", .{sequence, @tagName(output.cursor.phase), output.cursor.failure, output.failure});
        try t.expectEqual(sequence, cursor_reply.sequence);
        try t.expectEqual(a.gfx_output_outcome_applied, cursor_reply.outcome);
        try t.expect(output.cursor.phase == .idle);
    }
    fn cursorAndDamage() !void {
        var cursor_source: a.GfxBufferReference = .{};
        try t.expectEqual(@as(i32, 1), create(&.{ .width = 32, .height = 16, .byte_length = 2048, .format = a.gfx_buffer_format_argb8888,
            .plane_count = 1, .plane_pitches = .{128,0,0,0}, .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write }, &cursor_source));
        @memset(data[index(cursor_source.reference)][0..2048], 0x80);
        var request = cursorRequest(1, a.display_cursor_operation_prepare, 0);
        request.request.reference = cursor_source.reference; request.request.width = 32; request.request.height = 16;
        request.request.pitch = 128; request.request.byte_length = 2048; request.request.hotspot_x = 3; request.request.hotspot_y = 4;
        cursor_job = request; try cursorDone(1);
        try t.expect(!output.cursor.visible and output.cursor.image_sequence == 1 and R.owner.scanout_owner.cursor_current.image == null);
        try t.expectEqual(@as(i32, 1), release(&cursor_source.reference));
        request = cursorRequest(2, a.display_cursor_operation_show, 1);
        request.barrier_timeline = 3; request.barrier_point = 2; request.request.x = 1; request.request.y = 2;
        cursor_job = request;
        for (0..5) |_| step();
        try t.expect(output.cursor.phase == .barrier and engine.client.?.available(engine.client.?.context));
        // Only the rectangle belongs to this CPU upload. Bytes outside it in
        // the source are deliberately different from the previous scanout.
        @memset(data[index(source.reference)][0..@intCast(output.shadow.descriptor.byte_length)], 0x99);
        job.fence.point = 2; job.operation = a.gfx_queue_operation_upload; job.source_offset = 2 * mode.width * 4 + 8;
        job.byte_length = mode.width * 4 + 12; job.row_count = 0; job.source_pitch = 0; job.deadline_ns = F.ticks + 2 * std.time.ns_per_s;
        try queueReady(); active_job = true; presentation.accept(job); try completeDma();
        for (0..120) |_| step();
        try t.expect(completed == 2 and presentation.visible == 2 and cursor_reply.sequence == 1 and output.failure == null);
        const pixels = &data[index(images[presentation.front].reference.reference)];
        try t.expectEqual(@as(u8, 0x71), pixels[0]);
        for (2..4) |row| {
            try t.expectEqual(@as(u8, 0x71), pixels[row * mode.pitch_bytes + 7]);
            try t.expectEqual(@as(u8, 0x99), pixels[row * mode.pitch_bytes + 8]);
            try t.expectEqual(@as(u8, 0x99), pixels[row * mode.pitch_bytes + 19]);
            try t.expectEqual(@as(u8, 0x71), pixels[row * mode.pitch_bytes + 20]);
        }
        // Native Busy near VUPDATE is write-free and must retry the request.
        try t.expect(output.cursor.job.?.sequence == 2 and !output.cursor.lost);
        F.words[reg("OTG0_OTG_STATUS_POSITION")] = 200 << hw.OTG0_OTG_STATUS_POSITION__OTG_VERT_COUNT__SHIFT;
        cursor_busy = true;
        for (0..120) |_| { step(); if (output.cursor.phase == .reply) break; }
        try t.expect(output.cursor.visible and output.cursor.phase == .reply and cursor_reply.sequence == 1);
        cursor_busy = false; try cursorDone(2);
        try t.expect(R.owner.scanout_owner.cursor_current.x == 1 and R.owner.scanout_owner.cursor_current.hot_x == 3);
        request = cursorRequest(3, a.display_cursor_operation_move, 1); request.request.x = -4000; request.request.y = 20;
        cursor_job = request; try cursorDone(3);
        try t.expect(cursor_reply.visibility == a.display_cursor_visibility_visible and F.words[reg("CURSOR0_CURSOR_CONTROL")] & hw.CURSOR0_CURSOR_CONTROL__CURSOR_ENABLE_MASK == 0);
        cursor_job = cursorRequest(4, a.display_cursor_operation_hide, 0); try cursorDone(4);
        try t.expect(!output.cursor.visible and R.owner.scanout_owner.cursor_current.image == null);
        release_busy = true; cursor_job = cursorRequest(5, a.display_cursor_operation_release, 0);
        for (0..40) |_| step();
        try t.expect(cursor_reply.sequence == 4 and output.cursor.images[output.cursor.front].self_address != 0);
        release_busy = false; try cursorDone(5);
        try t.expect(output.cursor.image_sequence == 0 and output.cursor.images[output.cursor.front].self_address == 0);
        job.fence.point = 3; job.display_target.connection_generation -= 1; job.deadline_ns = F.ticks + std.time.ns_per_s;
        try queueReady(); active_job = true; presentation.accept(job);
        try t.expect(!presentation.armed and presentation.ticket == null);
        for (0..3) |_| step();
        try t.expect(completed == 3 and presentation.available() and presentation.rejected == 1 and output.failure == null);
    }
    fn internalCopy() !void {
        const shape = try buffers.Shape.make(65, 17, false);
        var source_ref: a.GfxBufferReference = .{};
        try t.expectEqual(@as(i32, 1), create(&.{ .width = 65, .height = 17, .byte_length = 65 * 17 * 4, .format = a.gfx_buffer_format_xrgb8888,
            .plane_count = 1, .plane_pitches = .{260,0,0,0}, .usage = a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_scanout }, &source_ref));
        @memset(data[index(source_ref.reference)][0..65 * 17 * 4], 0x53);
        for (&mode_images, 0..) |*image, i| {
            try image.allocate(&R.memory, shape, @intCast(4 + i));
            try image.publishGpuTarget();
            try t.expectError(error.Stale, image.scanout());
        }
        try mode_copy.begin(&engine, .{ &mode_images[0], &mode_images[1] }, source_ref, F.ticks + std.time.ns_per_s);
        const ticket = mode_copy.ticket.?;
        try t.expect((try queue.timeline.entry(ticket)).internal and std.meta.eql((try queue.timeline.entry(ticket)).fence, a.GfxFence{}));
        try t.expect(!try mode_copy.poll() and !mode_images[0].close(true));
        try t.expectEqual(@as(i32, 1), release(&source_ref.reference));
        release_busy = true; try completeTicket(ticket);
        for (0..3) |_| step();
        try t.expect(!try mode_copy.poll() and !mode_images[1].close(true) and mode_images[0].copy_token == ticket.token);
        release_busy = false; for (0..3) |_| step();
        try t.expect(try mode_copy.poll());
        try t.expectEqual(@as(u32, 3), completed); // Internal token never becomes a common queue completion.
        for (&mode_images) |*image| {
            const pixels = &data[index(image.reference.reference)];
            for (0..17) |row| {
                try t.expectEqual(@as(u8, 0x53), pixels[row * shape.pitch + 259]);
                try t.expectEqual(@as(u8, 0), pixels[row * shape.pitch + 260]);
            }
            try t.expectEqual(@as(u8, 0), pixels[@intCast(shape.bytes - 1)]);
            try t.expect(image.initialized and image.copy_token == 0 and image.close(true));
        }
        try t.expect(mode_copy.close());
    }
    fn modeRequest(ticket: u64, mode_index: usize, ref: a.GfxBufferReference) a.GfxDriverModeJob {
        const selected = output.publication.modes[mode_index];
        return .{ .ticket = ticket, .sequence = 1, .operation = a.gfx_mode_operation_apply, .backend = binding, .mode = selected,
            .reference = ref, .deadline_ns = F.ticks + 5 * std.time.ns_per_s,
            .assignment = .{ .output = output.output, .mode_id = selected.mode_id, .head_id = mode.pipe, .plane_id = mode.pipe, .pll_id = mode.pipe,
                .source_width = selected.width, .source_height = selected.height, .destination_width = selected.width, .destination_height = selected.height,
                .bits_per_color = 8, .buffer = ref.buffer } };
    }
    fn modeUntilReply() !void {
        var token: u64 = 0;
        for (0..2000) |_| {
            step();
            if (output.modes.copy.ticket) |ticket| if (output.modes.copy.armed and ticket.token != token) {
                try completeTicket(ticket); token = ticket.token;
            };
            if (output.modes.phase == .reply or output.phase == .failed) break;
        }
        if (output.modes.phase != .reply) std.debug.print("common mode: phase={s} job={?} error={?} output={?}\n",
            .{@tagName(output.modes.phase), output.modes.job, output.modes.failure, output.failure});
        try t.expect(output.modes.phase == .reply and output.phase == .active);
    }
    fn modeFinish(sequence: u64, outcome: u32) !void {
        mode_complete_busy = false;
        for (0..5) |_| { step(); if (output.modes.phase == .idle) break; }
        try t.expect(output.modes.phase == .idle and mode_reply.sequence == sequence and mode_reply.outcome == outcome and output.failure == null);
        try queueReady();
    }
    fn commonModes() !void {
        var mode_source: a.GfxBufferReference = .{};
        try t.expectEqual(@as(i32, 1), create(&.{ .width = 1280, .height = 720, .byte_length = 1280 * 720 * 4,
            .format = a.gfx_buffer_format_xrgb8888, .plane_count = 1, .plane_pitches = .{5120,0,0,0},
            .usage = a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_scanout }, &mode_source));
        @memset(data[index(mode_source.reference)][0..1280 * 720 * 4], 0x5c);
        var request = modeRequest(100, 1, mode_source);
        var stale = request; stale.assignment.output.connection_generation -= 1;
        mode_job = stale; const writes = F.writes;
        try modeUntilReply(); try modeFinish(1, a.gfx_output_outcome_old_preserved);
        try t.expectEqual(writes, F.writes);
        try t.expect(output.modes.pending == null and output.modes.spare[0].self_address == 0);
        // Apply is acknowledged only after actual SDMA and scanout receipts.
        const old = .{ presentation.frames[presentation.front], presentation.frames[1 - presentation.front] };
        const old_address = old[0].mc_address; const old_epoch = output.epoch.mode;
        mode_complete_busy = true; mode_job = request; try modeUntilReply();
        for (0..3) |_| step();
        try t.expect(output.mode.width == 1280 and output.epoch.mode == old_epoch + 1 and mode_reply.ticket == 100 and
            output.modes.pending != null and old[0].self_address != 0 and old[1].self_address != 0 and
            presentation.receipt.?.image.address == output.frames[0].mc_address and output.modes.copy.self_address == 0);
        try t.expectEqual(@as(u8, 0x5c), data[index(output.frames[0].reference.reference)][0]);
        try modeFinish(1, a.gfx_output_outcome_applied);
        // The confirmed candidate can present while the old bank is retained
        // for the user's decision. This upload must not alter the old image.
        const original_source = source; source = mode_source;
        job.fence.point = 4; job.operation = a.gfx_queue_operation_present; job.source_buffer = source.buffer;
        job.byte_length = 5120; job.source_pitch = 5120; job.row_count = 720; job.source_offset = 0;
        job.display_target = output.target; job.deadline_ns = F.ticks + 2 * std.time.ns_per_s;
        try queueReady(); active_job = true; presentation.accept(job); try completeDma();
        for (0..120) |_| { step(); if (!active_job) break; }
        try t.expect(!active_job and presentation.available() and presentation.visible == 3 and old[0].mc_address == old_address);
        request.sequence = 2; request.operation = a.gfx_mode_operation_rollback; request.deadline_ns = F.ticks + 5 * std.time.ns_per_s;
        mode_job = request; try modeUntilReply(); try modeFinish(2, a.gfx_output_outcome_old_preserved);
        try t.expect(output.mode.width == 1920 and output.epoch.mode == old_epoch + 2 and output.frames[0].mc_address == old_address and
            output.modes.pending == null and output.modes.spare[0].self_address == 0 and output.modes.spare[1].self_address == 0);
        source = original_source;
        // Confirm retires the old bank, then a later transaction can reuse
        // its two bounded GPU-VA slots with new BO references.
        request = modeRequest(101, 1, mode_source); mode_job = request; try modeUntilReply(); try modeFinish(1, a.gfx_output_outcome_applied);
        request.sequence = 2; request.operation = a.gfx_mode_operation_confirm; request.deadline_ns = F.ticks + 5 * std.time.ns_per_s;
        release_busy = true; mode_job = request;
        for (0..5) |_| step();
        try t.expect(output.modes.phase == .retire_previous and output.modes.pending != null and old[0].self_address != 0);
        release_busy = false; try modeUntilReply(); try modeFinish(2, a.gfx_output_outcome_applied);
        try t.expect(images[0].self_address == 0 and images[1].self_address == 0 and output.modes.pending == null);
        try t.expectEqual(@as(i32, 1), release(&mode_source.reference));
        request = modeRequest(102, 0, original_source); mode_job = request; try modeUntilReply(); try modeFinish(1, a.gfx_output_outcome_applied);
        request.sequence = 2; request.operation = a.gfx_mode_operation_confirm; request.deadline_ns = F.ticks + 5 * std.time.ns_per_s;
        mode_job = request; try modeUntilReply(); try modeFinish(2, a.gfx_output_outcome_applied);
        try t.expect(output.mode.width == 1920 and output.modes.active_bank == 0 and output.modes.pending == null and
            std.meta.eql(presentation.epoch, output.epoch) and R.owner.scanout_owner.current.?.address == presentation.frames[presentation.front].mc_address);
    }
    fn hardwareMode() !void {
        try queueReady();
        const shape = try buffers.Shape.make(1280, 720, false);
        var source_ref: a.GfxBufferReference = .{};
        try t.expectEqual(@as(i32, 1), create(&.{ .width = shape.width, .height = shape.height, .byte_length = 1280 * 720 * 4,
            .format = a.gfx_buffer_format_xrgb8888, .plane_count = 1, .plane_pitches = .{5120,0,0,0},
            .usage = a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_scanout }, &source_ref));
        @memset(data[index(source_ref.reference)][0..1280 * 720 * 4], 0x5c);
        for (&mode_images, 0..) |*image, i| { try image.allocate(&R.memory, shape, @intCast(4 + i)); try image.publishGpuTarget(); }
        try mode_copy.begin(&engine, .{ &mode_images[0], &mode_images[1] }, source_ref, F.ticks + std.time.ns_per_s);
        try completeTicket(mode_copy.ticket.?); for (0..3) |_| step();
        try t.expect(try mode_copy.poll()); try t.expect(mode_copy.close());
        try t.expectEqual(@as(i32, 1), release(&source_ref.reference));
        const selected: c.struct_r4dcn_mode = .{ .width = 1280, .height = 720, .h_total = 1650, .v_total = 750,
            .h_front = 110, .h_sync = 40, .v_front = 5, .v_sync = 5, .pixel_khz = 74250, .flags = 6, .pipe = mode.pipe,
            .pitch_bytes = shape.pitch, .buffer_bytes = shape.bytes, .mc_address = mode_images[0].mc_address };
        var old = R.owner.mode; old.mc_address = presentation.frames[presentation.front].mc_address;
        const writes = F.writes;
        try R.owner.planMode(selected); R.run(); try t.expect(R.owner.poll());
        try t.expect(R.owner.result == 0 and R.owner.candidate_valid and R.candidate_heap_live and R.owner.phase == .programmed);
        try t.expectEqual(writes, F.writes); // Read-only candidate DML leaves the live frontend untouched.
        var epoch = output.epoch; epoch.mode += 1;
        try R.owner.applyMode(.{ .mode = selected, .epoch = epoch, .image = try mode_images[0].scanout(),
            .sequence = R.owner.scanout_owner.sequence + 1, .deadline_ns = F.ticks + 3 * std.time.ns_per_s });
        R.run(); try t.expect(R.owner.poll());
        if (R.owner.result != 0) std.debug.print("mode switch failure={?} core={d}\n", .{pipe.failure,R.owner.result});
        try t.expectEqual(@as(i32, 0), R.owner.result);
        try t.expect(R.owner.mode.width == 1280 and R.owner.mode_receipt.?.image.address == mode_images[0].mc_address and R.owner.mode_receipt.?.epoch.mode == epoch.mode);
        try t.expect(!mode_images[0].close(false));
        try R.owner.planMode(old); R.run(); try t.expect(R.owner.poll()); try t.expectEqual(@as(i32, 0), R.owner.result);
        epoch.mode += 1;
        try R.owner.applyMode(.{ .mode = old, .epoch = epoch, .image = try presentation.frames[presentation.front].scanout(),
            .sequence = R.owner.scanout_owner.sequence + 1, .deadline_ns = F.ticks + 3 * std.time.ns_per_s });
        R.run(); try t.expect(R.owner.poll());
        if (R.owner.result != 0) std.debug.print("mode rollback failure={?} core={d}\n", .{pipe.failure,R.owner.result});
        try t.expectEqual(@as(i32, 0), R.owner.result);
        try t.expect(R.owner.mode.width == 1920 and R.owner.mode_receipt.?.image.address == old.mc_address);
        for (&mode_images) |*image| try t.expect(image.close(true));
    }
};
