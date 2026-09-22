// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const t = std.testing;
const a = @import("r4os").abi;
const c = @import("start_common.zig");
const l = @import("gc_layout.zig");
const r = l.r;
const p = l.p;
const w = l.w;
const s = @import("queue_storage.zig");
const q = @import("queue_timeline.zig");
const contexts = @import("gc_contexts.zig");
const core = @import("gc_engine.zig");
const F = struct {
    var engine: core.Owner = .{};
    var owner: contexts.Owner = .{};
    var memory: @import("memory_owner.zig").Owner = .{};
    var rt: @import("queue_runtime.zig").Owner = .{};
    var regs: [@import("memory_registers.zig").required_prefix / 4]u32 align(4096) = @splat(0);
    var data: [s.bytes / 4]u32 align(4096) = @splat(0);
    var bells: [1024]u32 align(4096) = @splat(0);
    var time: u64 = 1000;
    var active: [2]u32 = .{ 0, 0 };
    var writes: usize = 0;
    var sdma_writes: usize = 0;
    var fail_write: u32 = 0;
    var auto_dequeue = true;
    var resource_live: [64]bool = @splat(false);
    var release_calls: [64]u32 = @splat(0);
    var completions: [64]u32 = @splat(0);
    var release_fail: usize = 64;
    var complete_fail: usize = 64;
    var fixture: F = .{};
    pub fn nowNs(_: *F) u64 { return time; }
    fn now() callconv(.c) u64 { return time; }
    fn bank() usize { return if (regs[r.GRBM_GFX_CNTL / 4] == l.Queue.kiq.bank()) 1 else 0; }
    pub fn read(_: *F, address: u32) c.Error!u32 { return if (address == r.CP_HQD_ACTIVE) active[bank()] else regs[address / 4]; }
    pub fn write(_: *F, address: u32, value: u32) c.Error!void {
        writes += 1;
        const sdma = @import("start_registers.zig").sdma;
        if (address == sdma.SDMA0_GFX_RB_CNTL or address == sdma.SDMA0_GFX_IB_CNTL or address == sdma.SDMA0_F32_CNTL) sdma_writes += 1;
        if (address == fail_write) { fail_write = 0; return error.Disconnected; }
        if (address == r.CP_HQD_ACTIVE) active[bank()] = value;
        if (address == r.CP_HQD_DEQUEUE_REQUEST and value == 1 and auto_dequeue) active[bank()] = 0;
        regs[address / 4] = value;
    }
    pub fn barrier(_: *F) c.Error!void {}
    fn reset() !void {
        engine = .{}; owner = .{}; memory = .{}; rt = .{}; regs = @splat(0); data = @splat(0); bells = @splat(0);
        resource_live = @splat(false); release_calls = @splat(0); completions = @splat(0);
        time = 1000; active = .{ 0, 0 }; writes = 0; sdma_writes = 0; fail_write = 0; auto_dequeue = true; release_fail = 64; complete_fail = 64;
        regs[r.CP_ME_CNTL / 4] = @import("start_engines.zig").cp_mask;
        regs[r.CP_MEC_CNTL / 4] = @import("start_engines.zig").mec_mask;
        regs[r.CC_GC_SHADER_ARRAY_CONFIG / 4] = 0x700 << r.CC_GC_SHADER_ARRAY_CONFIG__INACTIVE_CUS__SHIFT;
        const sdma = @import("start_registers.zig").sdma;
        regs[sdma.SDMA0_GFX_RB_CNTL / 4] = 1; regs[sdma.SDMA0_GFX_IB_CNTL / 4] = 1;
        memory = .{ .self_address = @intFromPtr(&memory), .prepared = true, .adapter = 7, .epoch = 23,
            .controller = .{ .enabled = true, .epoch = 23 }, .registers = .{ .window = .{ .value = .{ .handle = .{ .id = 1, .generation = 1 },
            .cpu_address = @intFromPtr(&regs), .byte_length = @sizeOf(@TypeOf(regs)) } }, .clock = .{ .table = .{ .now_ns = @intFromPtr(&now) } } } };
        rt = .{ .self_address = @intFromPtr(&rt), .prepared = true, .memory = &memory, .queue = .{ .table = .{ .complete = @intFromPtr(&complete) } } };
        rt.arena = .{ .self_address = @intFromPtr(&rt.arena), .memory = &memory, .epoch = 23, .gpu = 0x120000000, .ready = true,
            .arena = .{ .value = .{ .handle = .{ .id = 2, .generation = 1 }, .cpu_address = @intFromPtr(&data), .byte_length = s.bytes } },
            .doorbell = .{ .value = .{ .handle = .{ .id = 3, .generation = 1 }, .cpu_address = @intFromPtr(&bells), .byte_length = 4096 } } };
        try rt.timeline.init(.{ .adapter_id = 7, .device_generation = 11, .reset_generation = 5 }, try rt.arena.fences(), time);
        try owner.init(rt.timeline.epoch);
    }
    fn fence(index: usize) a.GfxFence { return .{ .adapter_id = 7, .device_generation = 11, .reset_generation = 5, .timeline = 3, .point = index + 1, .slot = @intCast(index) }; }
    fn resources(index: usize) q.Resources { resource_live[index] = true; return .{ .context = index + 1, .retire = retire }; }
    fn retire(raw: usize, exact: a.GfxFence) bool {
        const index = raw - 1;
        std.debug.assert(std.meta.eql(exact, fence(index)) and resource_live[index]);
        release_calls[index] += 1;
        if (index == release_fail) return false;
        resource_live[index] = false; return true;
    }
    fn complete(exact: *const a.GfxFence, result: u32, quiet: u32) callconv(.c) i32 {
        const index = exact.point - 1;
        std.debug.assert(std.meta.eql(exact.*, fence(index)) and !resource_live[index] and quiet == 1 and result != a.gfx_queue_result_pending);
        if (index == complete_fail) return -4;
        completions[index] += 1; return 1;
    }
    fn sample(index: usize, token: u64, marker: u32) void {
        const offset = l.sample_offset / 4 + index * 8;
        data[offset] = @truncate(token); data[offset + 1] = @truncate(token >> 32); data[offset + 2] = marker;
    }
    fn pointers() void {
        inline for (.{ l.Queue.gfx, l.Queue.compute, l.Queue.kiq }) |queue|
            data[queue.readback() / 4] = @truncate(engine.rings[@intFromEnum(queue)].write);
    }
    fn start() !void {
        try engine.begin(&fixture, &rt.arena, .{ .firmware_ready = true, .boot_held = true, .gmc_enabled = true });
        time += 50_000; _ = try engine.advance(&fixture, &rt.arena);
        time += 1_000_000; _ = try engine.advance(&fixture, &rt.arena);
        // Explicit fixture responses, not a Picasso emulator or hardware test.
        active[0] = 1; sample(2, l.sample_tokens[2], 0); pointers();
        _ = try engine.advance(&fixture, &rt.arena);
        for (0..2) |round| {
            sample(0, l.sample_tokens[0] + round * 16, @intCast(0x4100 + round * 16));
            sample(1, l.sample_tokens[1] + round * 16, @intCast(0x4101 + round * 16)); pointers();
            _ = try engine.advance(&fixture, &rt.arena);
        }
        try t.expectEqual(core.Phase.ready, engine.phase);
    }
};

test "AMD GFX9 packet sizes, cache actions, clear state and MQD match the pinned originals" {
    try F.reset();
    var words: [1024]u32 = @splat(0xdeadbeef);
    const amd = @import("r4amd");
    const native = @import("native_pm4.zig");
    var header: amd.R4AmdNativeSubmit = std.mem.zeroes(amd.R4AmdNativeSubmit);
    header.version = 1; header.size = @sizeOf(amd.R4AmdNativeSubmit); header.ib_count = 1;
    var ib: amd.R4AmdNativeIb = .{ .address = amd.native_va_start + 32, .dwords = 8, .binding_index = 0 };
    const bound: a.GfxNativeBinding = .{ .address = amd.native_va_start, .byte_length = 4096 };
    try t.expectEqual(@as(usize, 4), try native.encode(header, &.{ib}, &.{bound}, &words));
    try t.expectEqual(@as(u32, 0xc0023f00), words[0]);
    try t.expectEqual(@as(u32, 8), words[3]);
    header.engine = 1;
    _ = try native.encode(header, &.{ib}, &.{bound}, &words);
    try t.expectEqual(@as(u32, 8 | (1 << 23)), words[3]);
    const native_before = words;
    ib.address = amd.native_va_start + 4096;
    try t.expectError(error.Invalid, native.encode(header, &.{ib}, &.{bound}, &words));
    ib.address = amd.native_va_start + 4064; ib.dwords = 16;
    try t.expectError(error.Invalid, native.encode(header, &.{ib}, &.{bound}, &words));
    ib.dwords = 8; ib.binding_index = 1;
    try t.expectError(error.Invalid, native.encode(header, &.{ib}, &.{bound}, &words));
    ib.binding_index = 0; header.ib_count = 2;
    try t.expectError(error.Invalid, native.encode(header, &.{ib}, &.{bound}, &words));
    header.ib_count = 1; header.flags = 1;
    try t.expectError(error.Invalid, native.encode(header, &.{ib}, &.{bound}, &words));
    try t.expectEqualSlices(u32, &native_before, &words);
    const request: p.Frame = .{ .engine = .gfx, .ib = 0x8000080000, .words = 16, .fence = 0x120010100, .sequence = 0x1234567800000001, .eop_scratch = 0x120075000, .interrupt = true };
    try t.expectEqual(@as(usize, 48), try p.encodeFrame(&words, request));
    try p.packetBoundaries(words[0..48]);
    try t.expectEqual(@as(u32, w.r4amd_pm4_packet(w.PACKET3_WAIT_REG_MEM, 5)), words[0]);
    try t.expectEqual(@as(u32, w.WAIT_REG_MEM_FUNCTION(3) | w.WAIT_REG_MEM_OPERATION(1) | w.WAIT_REG_MEM_ENGINE(1)), words[1]);
    const nb = @import("start_registers.zig").nb;
    try t.expectEqual(nb.GPU_HDP_FLUSH_REQ / 4, words[2]); try t.expectEqual(nb.GPU_HDP_FLUSH_DONE / 4, words[3]);
    try t.expectEqual(@as(u32, w.r4amd_pm4_packet(w.PACKET3_ACQUIRE_MEM, 5)), words[13]);
    try t.expectEqual(@as(u32, w.PACKET3_ACQUIRE_MEM_CP_COHER_CNTL_SH_ICACHE_ACTION_ENA(1) | w.PACKET3_ACQUIRE_MEM_CP_COHER_CNTL_SH_KCACHE_ACTION_ENA(1) |
        w.PACKET3_ACQUIRE_MEM_CP_COHER_CNTL_TC_ACTION_ENA(1) | w.PACKET3_ACQUIRE_MEM_CP_COHER_CNTL_TCL1_ACTION_ENA(1) | w.PACKET3_ACQUIRE_MEM_CP_COHER_CNTL_TC_WB_ACTION_ENA(1)), words[14]);
    try t.expectEqual(@as(u32, w.r4amd_pm4_packet(w.PACKET3_INDIRECT_BUFFER, 2)), words[27]);
    try t.expectEqual(@as(u32, 16 | (1 << 24)), words[30]);
    try t.expectEqual(@as(u32, w.r4amd_pm4_packet(w.PACKET3_EVENT_WRITE, 2)), words[31]); // required ZPASS_DONE directly before EOP
    try t.expectEqual(@as(u32, w.r4amd_pm4_packet(w.PACKET3_RELEASE_MEM, 6)), words[35]);
    try t.expectEqual(@as(u32, w.EOP_TCL1_ACTION_EN | w.EOP_TC_ACTION_EN | w.EOP_TC_MD_ACTION_EN | w.EOP_TC_WB_ACTION_EN | (5 << 8) | 0x14), words[36]);
    try t.expectEqual(@as(u32, w.DATA_SEL(2) | w.INT_SEL(2)), words[37]);
    const before = words;
    var bad = request; bad.fence = bad.ib;
    try t.expectError(error.Invalid, p.encodeFrame(&words, bad)); try t.expectEqualDeep(before, words);
    bad = request; bad.ib = p.limit - 32;
    try t.expectError(error.Invalid, p.encodeFrame(&words, bad));
    try t.expectError(error.Capacity, p.encodeFrame(words[0..47], request));
    var compute = request; compute.engine = .compute; compute.eop_scratch = 0;
    try t.expectEqual(@as(usize, 32), try p.encodeFrame(&words, compute)); try p.packetBoundaries(words[0..32]);
    try t.expectEqual(@as(u32, w.INDIRECT_BUFFER_VALID | 16 | (1 << 24)), words[19]);
    try t.expectEqual(@as(u32, 4), words[4]);
    try t.expectError(error.Invalid, p.packetBoundaries(&.{p.packet(0x3f, 2), 0, 0}));
    try t.expectEqual(@as(usize, 904), try l.clearState(&words)); try p.packetBoundaries(words[0..904]);
    try t.expectEqual(@as(u32, w.PACKET3_PREAMBLE_BEGIN_CLEAR_STATE), words[1]);
    try t.expectEqual(@as(u32, w.PACKET3_PREAMBLE_END_CLEAR_STATE), words[901]);
    try t.expectEqualSlices(u32, w.gfx9_SECT_CONTEXT_def_1[0..212], words[7..219]);
    try F.fixture.write(r.GRBM_GFX_CNTL, l.Queue.kiq.bank());
    const kiq = try l.mqd(&F.fixture, &F.rt.arena, .kiq); const mq = kiq.mqd;
    try t.expectEqual(@as(usize, 2064), @sizeOf(@TypeOf(kiq)));
    try t.expectEqual(@as(u32, 1), mq.cp_hqd_active); try t.expectEqual(@as(u32, 0xc0310800), mq.header);
    try t.expectEqual(@as(u32, @truncate((F.rt.arena.gpu + l.kiq_ring) >> 8)), mq.cp_hqd_pq_base_lo);
    try t.expectEqual(@as(u32, 13), (mq.cp_hqd_pq_control & r.CP_HQD_PQ_CONTROL__QUEUE_SIZE_MASK) >> r.CP_HQD_PQ_CONTROL__QUEUE_SIZE__SHIFT);
    try t.expectEqual(@as(u32, 9), mq.cp_hqd_eop_control & r.CP_HQD_EOP_CONTROL__EOP_SIZE_MASK);
    try t.expectEqual(@as(u32, @truncate(F.rt.arena.gpu + l.mqd_offsets[0] + 2056)), mq.dynamic_cu_mask_addr_lo);
    try t.expectEqual(@as(u32, 0), (try l.mqd(&F.fixture, &F.rt.arena, .compute)).mqd.cp_hqd_active);
    var resource: p.Resources = .{ .scratch = 0x8000100000, .scratch_bytes = 65536, .waves = 32, .bytes_per_wave = 2048, .lds_bytes = 65536, .gds_bytes = 4096 };
    try t.expectEqual(@as(u32, 32 | (2 << 12)), try resource.ringSize());
    resource.gds_bytes = 4352; try t.expectError(error.Invalid, resource.validate()); resource.gds_bytes = 4096;
    resource.waves = 33; try t.expectError(error.Invalid, resource.validate()); resource.waves = 32;
    resource.lds_bytes = 65537; try t.expectError(error.Invalid, resource.validate());
}

test "AMD GFX9 real owner requires ordered startup, exact context fences and GC-only quiescence" {
    try F.reset();
    try t.expectError(error.Unconfirmed, F.engine.begin(&F.fixture, &F.rt.arena, .{ .firmware_ready = false, .boot_held = true, .gmc_enabled = true }));
    try t.expectEqual(@as(usize, 0), F.writes);
    try F.engine.begin(&F.fixture, &F.rt.arena, .{ .firmware_ready = true, .boot_held = true, .gmc_enabled = true });
    try t.expectEqual(@as(u32, 0xff), F.engine.cu_mask); try t.expectEqual(@as(u32, 3), F.engine.rb_mask);
    try t.expect(!try F.engine.advance(&F.fixture, &F.rt.arena)); try t.expectEqual(core.Phase.rlc_delay, F.engine.phase);
    F.time += 50_000; _ = try F.engine.advance(&F.fixture, &F.rt.arena);
    try t.expectEqual(core.Phase.ring_delay, F.engine.phase);
    F.time += 999_999; _ = try F.engine.advance(&F.fixture, &F.rt.arena); try t.expectEqual(core.Phase.ring_delay, F.engine.phase);
    F.time += 1; _ = try F.engine.advance(&F.fixture, &F.rt.arena);
    F.pointers(); try t.expect(!try F.engine.advance(&F.fixture, &F.rt.arena));
    F.sample(2, l.sample_tokens[2] - 1, 0); F.active[0] = 1;
    try t.expect(!try F.engine.advance(&F.fixture, &F.rt.arena));
    F.sample(2, l.sample_tokens[2], 0); _ = try F.engine.advance(&F.fixture, &F.rt.arena);
    try t.expectEqual(core.Phase.test_wait, F.engine.phase);
    F.sample(0, l.sample_tokens[0], 0x4100); F.sample(1, l.sample_tokens[1], 0x4101);
    try t.expect(!try F.engine.advance(&F.fixture, &F.rt.arena)); // fence alone cannot recycle an unread ring
    F.pointers(); _ = try F.engine.advance(&F.fixture, &F.rt.arena);
    try t.expectEqual(@as(u8, 1), F.engine.selftest_round);
    F.sample(0, l.sample_tokens[0] + 16, 0x4110); F.sample(1, l.sample_tokens[1] + 16, 0x4111); F.pointers();
    try t.expect(try F.engine.advance(&F.fixture, &F.rt.arena)); try F.engine.interrupts(&F.fixture);
    // Native CP readback may expose the masked ring index. A wrap advances
    // only published dwords, and an extra stale dword is rejected.
    F.engine.rings[0].read = 16376; F.engine.rings[0].write = 16392;
    F.data[l.Queue.gfx.readback() / 4] = 8; try F.engine.observe(&F.fixture, &F.rt.arena);
    try t.expectEqual(@as(u64, 16392), F.engine.rings[0].read);
    F.data[l.Queue.gfx.readback() / 4] = 9; try t.expectError(error.Stale, F.engine.observe(&F.fixture, &F.rt.arena));
    F.data[l.Queue.gfx.readback() / 4] = 8;
    try t.expect(!try F.engine.stop(&F.fixture, &F.rt.arena)); try t.expectEqual(core.Phase.unmap_wait, F.engine.phase);
    F.active[0] = 0; _ = try F.engine.stop(&F.fixture, &F.rt.arena); F.time += 50_000;
    try t.expect(try F.engine.stop(&F.fixture, &F.rt.arena)); try t.expectEqual(@as(usize, 0), F.sdma_writes);
    try t.expectEqual(@as(u32, 0), F.regs[r.RLC_CSIB_LENGTH / 4]);
    try F.reset(); try F.start(); F.auto_dequeue = false;
    _ = try F.engine.stop(&F.fixture, &F.rt.arena); F.time += 500_000_000;
    try t.expectError(error.Deadline, F.engine.stop(&F.fixture, &F.rt.arena)); try t.expect(F.engine.phase != .closed and F.rt.arena.ready);
    // A partial start, including failure before MEC unhalt, must remain
    // closable from the actual halted/idle state without issuing a fake reset.
    inline for (.{ r.CB_HW_CONTROL, r.RLC_CSIB_LENGTH, r.CP_MQD_BASE_ADDR, r.CP_DEVICE_ID }) |address| {
        try F.reset(); F.fail_write = address;
        F.engine.begin(&F.fixture, &F.rt.arena, .{ .firmware_ready = true, .boot_held = true, .gmc_enabled = true }) catch {};
        for (0..3) |_| { F.time += 1_000_000; _ = F.engine.advance(&F.fixture, &F.rt.arena) catch false; }
        try t.expect(F.engine.faulted);
        _ = try F.engine.stop(&F.fixture, &F.rt.arena); F.time += 50_000;
        try t.expect(try F.engine.stop(&F.fixture, &F.rt.arena)); try t.expectEqual(@as(usize, 0), F.sdma_writes);
    }
}

test "AMD GFX9 contexts preserve priorities, generations and resource ownership through submission errors" {
    try F.reset(); try F.start();
    const low = try F.owner.create(.gfx, .low, .{ .gds_bytes = 256 });
    try t.expectError(error.Busy, F.owner.create(.compute, .normal, .{ .gds_bytes = 256 }));
    const high = try F.owner.create(.gfx, .high, .{ .gds_offset = 256, .gds_bytes = 256 });
    const compute = try F.owner.create(.compute, .normal, .{});
    const commands = [_]u32{ p.nop, p.nop, p.nop, p.nop, p.nop, p.nop, p.nop, p.nop };
    try F.owner.enqueue(low, F.fence(0), F.time, F.time + 100_000_000, &commands, F.resources(0));
    try F.owner.enqueue(high, F.fence(1), F.time, F.time + 100_000_000, &commands, F.resources(1));
    try F.owner.enqueue(compute, F.fence(2), F.time, F.time + 100_000_000, &commands, F.resources(2));
    try t.expectError(error.Busy, F.owner.destroy(high));
    F.owner.step(&F.rt, &F.engine);
    try t.expectEqual(@as(u64, 2), F.rt.timeline.entries[0].fence.point); // high before older low
    try t.expectEqual(q.Engine.compute, F.rt.timeline.entries[1].engine);
    F.rt.timeline.poll(F.time); try t.expect(F.rt.timeline.publish(F.rt.queue.?));
    try t.expect(F.resource_live[1] and F.resource_live[2]);
    const fences = try F.rt.arena.fences(); fences[0] = F.rt.timeline.entries[0].token + 99;
    F.rt.timeline.poll(F.time); _ = F.rt.timeline.publish(F.rt.queue.?); try t.expect(F.resource_live[1]);
    fences[0] = F.rt.timeline.entries[0].token; fences[1] = F.rt.timeline.entries[1].token;
    F.release_fail = 1; F.rt.timeline.poll(F.time); try t.expect(!F.rt.timeline.publish(F.rt.queue.?));
    try t.expect(F.resource_live[1] and !F.resource_live[2]); try t.expectError(error.Busy, F.owner.destroy(high));
    F.release_fail = 64; F.complete_fail = 1;
    try t.expect(!F.rt.timeline.publish(F.rt.queue.?)); const releases = F.release_calls[1];
    F.complete_fail = 64; try t.expect(F.rt.timeline.publish(F.rt.queue.?)); try t.expectEqual(releases, F.release_calls[1]);
    _ = F.owner.collect(&F.rt); try F.owner.destroy(high);
    const replacement = try F.owner.create(.gfx, .normal, .{ .gds_offset = 256, .gds_bytes = 256 });
    try t.expectError(error.Stale, F.owner.destroy(high)); try t.expect(replacement.generation > high.generation);
    // A failed 64-bit doorbell after ring publication never locally retires
    // the BOs or returns the context to the pool. Actual GC stop is necessary.
    F.rt.arena.doorbell.value.handle.id = 0; F.owner.step(&F.rt, &F.engine);
    try t.expectEqual(@as(u3, 6), F.rt.timeline.failed_engines); try t.expect(F.resource_live[0]);
    try t.expectError(error.Busy, F.owner.destroy(low)); F.rt.arena.doorbell.value.handle.id = 3;
    F.owner.stopping = true; _ = try F.engine.stop(&F.fixture, &F.rt.arena);
    F.active[0] = 0; _ = try F.engine.stop(&F.fixture, &F.rt.arena); F.time += 50_000;
    try t.expect(try F.engine.stop(&F.fixture, &F.rt.arena));
    var stale = F.rt.timeline.epoch; stale.reset += 1;
    try t.expectError(error.Unconfirmed, F.rt.timeline.abort(.{ .epoch = stale, .engines = 6 }, a.gfx_queue_result_device_lost));
    try F.rt.timeline.abort(.{ .epoch = F.rt.timeline.epoch, .engines = 6 }, a.gfx_queue_result_device_lost);
    try t.expect(F.rt.timeline.publish(F.rt.queue.?)); try t.expect(F.owner.collect(&F.rt));
    try t.expect(!F.resource_live[0]); try F.owner.destroy(low); try F.owner.destroy(replacement); try F.owner.destroy(compute);
    try F.reset(); try F.start();
    const scratch = try F.owner.create(.gfx, .normal, .{ .scratch = 0x8001000000, .scratch_bytes = 65536, .waves = 32, .bytes_per_wave = 2048 });
    try t.expectError(error.Busy, F.owner.create(.compute, .normal, .{ .scratch = 0x8001001000, .scratch_bytes = 65536, .waves = 32, .bytes_per_wave = 2048 }));
    try F.owner.destroy(scratch);
    // Continually replenished high-priority work must still dispatch an old
    // low-priority IB after at most eight intervening dispatches.
    const slow = try F.owner.create(.gfx, .low, .{}); const fast = try F.owner.create(.gfx, .high, .{});
    try F.owner.enqueue(slow, F.fence(0), F.time, F.time + 100_000_000, &commands, F.resources(0));
    var low_dispatch: usize = 0;
    for (1..11) |i| {
        try F.owner.enqueue(fast, F.fence(i), F.time, F.time + 100_000_000, &commands, F.resources(i));
        F.owner.step(&F.rt, &F.engine);
        const entry = F.rt.timeline.entries[0];
        if (entry.fence.point == 1) low_dispatch = i;
        (try F.rt.arena.fences())[0] = entry.token;
        F.rt.timeline.poll(F.time); try t.expect(F.rt.timeline.publish(F.rt.queue.?)); _ = F.owner.collect(&F.rt);
    }
    try t.expect(low_dispatch != 0 and low_dispatch <= 9);
    // Drain the one high-priority job left by the fairness workload, then
    // idle worker passes must preserve all ring pointers and doorbells.
    F.owner.step(&F.rt, &F.engine);
    const last = F.rt.timeline.entries[0];
    (try F.rt.arena.fences())[0] = last.token;
    F.rt.timeline.poll(F.time); try t.expect(F.rt.timeline.publish(F.rt.queue.?));
    try t.expect(F.owner.collect(&F.rt));
    const dispatches = F.owner.dispatches;
    const rings = F.engine.rings;
    const doorbells = F.bells;
    for (0..32) |_| F.owner.step(&F.rt, &F.engine);
    try t.expectEqual(dispatches, F.owner.dispatches);
    try t.expectEqualDeep(rings, F.engine.rings);
    try t.expectEqualDeep(doorbells, F.bells);

}
