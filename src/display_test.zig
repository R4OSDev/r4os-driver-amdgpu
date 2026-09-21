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
    fn reset() void {
        @memset(&words, 0);
        ticks = 0;
        writes = 0;
        reads = 0;
        fail_write = 0;
        is_worker = true;
        clock_ready = true;
    }
    fn read(_: ?*anyopaque, offset: u32, out: [*c]u32) callconv(.c) c_int {
        if (offset % 4 != 0 or offset >= @sizeOf(@TypeOf(words))) return -1;
        reads += 1;
        out.* = words[offset / 4];
        return 0;
    }
    fn write(_: ?*anyopaque, offset: u32, value: u32) callconv(.c) c_int {
        if (offset % 4 != 0 or offset >= @sizeOf(@TypeOf(words))) return -1;
        writes += 1;
        if (fail_write != 0 and writes == fail_write) return -1;
        words[offset / 4] = value;
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
        board = undefined;
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
        return 0;
    }
    fn abort(_: i32) callconv(.c) i32 {
        @panic("unexpected fatal DC assertion");
    }
    fn clock() callconv(.c) u64 {
        return F.now(null);
    }
    fn allocate(bytes: u64, alignment: u32, out: *a.DriverHeapAllocation) callconv(.c) i32 {
        std.debug.assert(running and !heap_live and bytes <= F.bytes.len);
        heap_live = true;
        out.* = .{ .handle = 1, .cpu_address = @intFromPtr(&F.bytes), .byte_length = bytes, .alignment = alignment };
        return if (partial_heap) -1 else 0;
    }
    fn free(_: u64) callconv(.c) i32 {
        if (fail_heap) return -1;
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
    const R = Runtime;
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
    std.debug.print("[amd-dcn1-owner] actual driver Task/heap boundary; delayed joins/releases; partial allocation; failed clock/link prepare; restore ACK retains boot hold\n", .{});
}
