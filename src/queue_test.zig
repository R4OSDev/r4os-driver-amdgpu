// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std"); const t = std.testing;
const r4os = @import("r4os"); const a = r4os.abi;
const q = @import("queue_timeline.zig"); const r = @import("queue_registers.zig");
const ih = @import("queue_ih.zig"); const store = @import("queue_storage.zig");
const Runtime = @import("queue_runtime.zig").Owner;
const Ring = @import("queue_ring.zig").Ring;
const binding: a.GfxBackendBinding = .{ .adapter_id = 7, .device_generation = 11, .reset_generation = 5 };
const epoch: q.Epoch = .{ .adapter = 7, .device = 11, .reset = 5 };
fn fence(point: u64) a.GfxFence { return .{ .slot = @intCast(point % 128), .adapter_id = 7, .timeline = 3, .point = point, .device_generation = 11, .reset_generation = 5 }; }
const F = struct {
    var api: a.DriverApi = undefined;
    var memory: @import("memory_owner.zig").Owner = .{};
    var layout: @import("memory_layout.zig").Layout = undefined;
    var run: Runtime = .{};
    var regs: [@import("memory_registers.zig").required_prefix / 4]u32 align(4096) = @splat(0);
    var arena: [store.bytes / 4]u32 align(4096) = @splat(0);
    var bells: [1024]u32 align(4096) = @splat(0);
    var dummy: [4096]u8 align(4096) = @splat(0xff);
    var dummy_live = false; var dummy_dma = false; var dummy_cpu = false; var dma_release_fail = false;
    var dummy_address: u64 = 0x334400000;
    var clock: u64 = 100;
    var mapped: u32 = 0; var unmap_fail = false; var map_fail = false;
    var msi_result: i32 = 24; var msi_live = false; var msi_close_fail = false;
    var irq_handler: ?a.IrqHandler = null; var irq_context: usize = 0; var irq_number: u8 = 0; var irq_flags: u32 = 0;
    var irq_register_fail = false; var irq_close_fail = false;
    var sem_live = false; var sem_permit = false; var sem_destroy_fail = false; var sem_acquire_error: i32 = 0;
    var request: a.DriverThreadRequest = .{}; var thread_live = false; var thread_join_busy = false; var thread_release_fail = false;
    var completed: usize = 0; var last_fence: a.GfxFence = .{}; var last_result: u32 = 0;
    var complete_fail = false; var retire_fail = false; var retired: usize = 0;
    var worker_stop = false; var worker_calls: usize = 0; var event_calls: usize = 0; var prove_quiescence = false;
    fn reset() void {
        run = .{}; memory = .{}; regs = @splat(0); arena = @splat(0); bells = @splat(0); clock = 100;
        dummy = @splat(0xff); dummy_live = false; dummy_dma = false; dummy_cpu = false; dma_release_fail = false; dummy_address = 0x334400000;
        mapped = 0; unmap_fail = false; map_fail = false; msi_result = 24; msi_live = false; msi_close_fail = false;
        irq_handler = null; irq_context = 0; irq_number = 0; irq_flags = 0; irq_register_fail = false; irq_close_fail = false;
        sem_live = false; sem_permit = false; sem_destroy_fail = false; sem_acquire_error = 0; request = .{}; thread_live = false; thread_join_busy = false; thread_release_fail = false;
        completed = 0; last_fence = .{}; last_result = 0; complete_fail = false; retire_fail = false; retired = 0;
        worker_stop = false; worker_calls = 0; event_calls = 0; prove_quiescence = false;
        api = undefined; api.magic = a.driver_magic; api.version = a.driver_api_version; api.size = @sizeOf(a.DriverApi);
        api.gfx_memory_query = memoryQuery; api.gfx_queue_query = queueQuery; api.resource_query = resourceQuery;
        api.thread_query = threadQuery; api.semaphore_query = semQuery; api.timer_frequency = frequency;
        api.pci_read_config32 = config; api.pci_enable_msi = msiEnable; api.pci_disable_msi = msiDisable;
        api.irq_register = irqRegister; api.irq_unregister = irqUnregister;
        layout = @import("memory_layout.zig").Layout.create(.{ .base = 0x220000000, .bytes = 512 * 1024 * 1024 },
            .{ .base = 0x100000000, .bytes = 512 * 1024 * 1024 }, 0x100000, 2 * 1024 * 1024, null) catch unreachable;
        const memctx: r4os.driver_memory.Context = .{ .table = .{ .mmio_map = @intFromPtr(&map), .mmio_unmap = @intFromPtr(&unmap), .collect = @intFromPtr(&collect),
            .buffer_create = @intFromPtr(&createDummy), .buffer_describe = @intFromPtr(&describeDummy), .buffer_map = @intFromPtr(&mapDummy), .buffer_unmap = @intFromPtr(&unmapDummy),
            .buffer_release = @intFromPtr(&releaseDummy), .device_acquire = @intFromPtr(&acquireDummy), .device_segment = @intFromPtr(&segmentDummy), .device_release = @intFromPtr(&releaseDma) } };
        memory = .{ .self_address = @intFromPtr(&memory), .prepared = true, .memory = memctx, .layout = &layout, .adapter = 7, .epoch = 23,
            .registers = .{ .window = .{ .value = .{ .handle = .{ .id = 100, .generation = 1 }, .cpu_address = @intFromPtr(&regs), .byte_length = @sizeOf(@TypeOf(regs)) } },
                .clock = .{ .table = .{ .now_ns = @intFromPtr(&now) } } }, .controller = .{ .enabled = true } };
    }
    fn snapshot() @import("identity.zig").Snapshot {
        var value: @import("identity.zig").Snapshot = .{ .pci = .{ .vendor_id = 0x1002, .device_id = 0x15d8, .bus_kind = 1, .bus = 3, .device = 0, .function = 0 } };
        value.bars[2] = .{ .kind = .memory64, .base = 0xe0000000, .bytes = 4096 }; return value;
    }
    fn prepare() !void {
        const ctx = r4os.r4dev.DriverContext.init(&api);
        try run.prepare(&ctx, &memory, &snapshot(), binding, .{ .memory_epoch = 23, .boot_held = true, .engines_quiesced = true });
    }
    fn start() !void { try run.start(&snapshot(), .{ .context = 7, .work = work, .event = event, .quiesce = quiesce }); }
    fn work(_: *Runtime, context: usize) void { std.debug.assert(context == 7); worker_calls += 1; if (worker_stop) @atomicStore(u32, &run.stop, 1, .release); }
    fn event(context: usize, _: ih.Event) void { std.debug.assert(context == 7); event_calls += 1; }
    fn quiesce(_: usize, current: q.Epoch, mask: q.EngineMask) ?q.Quiescence { return if (prove_quiescence) .{ .epoch = current, .engines = mask } else null; }
    fn retire(_: usize, value: a.GfxFence) bool { std.debug.assert(value.timeline == 3 and @atomicLoad(u32, &run.irq.gate, .acquire) != 2); if (retire_fail) return false; retired += 1; return true; }
    fn queueContext() r4os.driver_queue.Context { return .{ .table = .{ .complete = @intFromPtr(&complete) } }; }
    fn complete(value: *const a.GfxFence, result: u32, quiesced: u32) callconv(.c) i32 {
        std.debug.assert(quiesced == 1 and retired > completed and @atomicLoad(u32, &run.irq.gate, .acquire) != 2); if (complete_fail) return -4;
        completed += 1; last_fence = value.*; last_result = result; return 1;
    }
    fn memoryQuery(out: *a.GfxDriverMemoryApi) callconv(.c) i32 { out.* = memory.memory.?.table; return 1; }
    fn queueQuery(out: *a.GfxDriverQueueApi) callconv(.c) i32 { out.* = queueContext().table; return 1; }
    fn resourceQuery(out: *a.DriverResourceApi) callconv(.c) i32 { out.* = .{ .now_ns = @intFromPtr(&now) }; return 0; }
    fn now() callconv(.c) u64 { return clock; }
    fn frequency() callconv(.c) u32 { return 1000; }
    fn map(req: *const a.GfxMmioRequest, out: *a.GfxMmioWindow) callconv(.c) i32 {
        if (map_fail) return -6;
        const cpu: u64 = if (req.resource_base == 0xe0000000) blk: {
            std.debug.assert(req.byte_length == 4096 and req.cache_policy == a.gfx_buffer_cache_uncached); break :blk @intFromPtr(&bells);
        } else blk: {
            std.debug.assert(req.resource_base == layout.physical.offset and req.byte_offset == layout.rings.span.offset and req.byte_length == store.bytes and req.cache_policy == a.gfx_buffer_cache_write_combining); break :blk @intFromPtr(&arena);
        };
        mapped += 1; out.* = .{ .handle = .{ .id = mapped, .generation = 1 }, .cpu_address = cpu,
            .physical_address = req.resource_base + req.byte_offset, .byte_length = req.byte_length, .cache_policy = req.cache_policy }; return 1;
    }
    fn unmap(_: *const a.GfxBufferHandle, quiesced: u32) callconv(.c) i32 {
        std.debug.assert(quiesced == 1 and mapped != 0 and irq_handler == null and !thread_live and !msi_live);
        if (unmap_fail) return -4; mapped -= 1; return 1;
    }
    fn collect() callconv(.c) i32 { return 1; }
    fn createDummy(desc: *const a.GfxBufferDescriptor, out: *a.GfxBufferReference) callconv(.c) i32 {
        std.debug.assert(!dummy_live and desc.byte_length == 4096); dummy_live = true;
        out.* = .{ .buffer = .{ .id = 10, .generation = 1 }, .reference = .{ .id = 11, .generation = 1 } }; return 1;
    }
    fn describeDummy(_: *const a.GfxBufferHandle, out: *a.GfxBufferDescriptor) callconv(.c) i32 { out.* = .{ .byte_length = 4096 }; return 1; }
    fn mapDummy(_: *const a.GfxBufferHandle, access: u32, offset: u64, bytes: u64, out: *a.GfxBufferMap) callconv(.c) i32 {
        std.debug.assert(dummy_live and !dummy_dma and access == a.gfx_buffer_map_write and offset == 0 and bytes == 4096); dummy_cpu = true;
        out.* = .{ .lease = .{ .id = 12, .generation = 1 }, .cpu_address = @intFromPtr(&dummy), .byte_length = 4096, .cache_policy = a.gfx_buffer_cache_write_back }; return 1;
    }
    fn unmapDummy(_: *const a.GfxBufferHandle) callconv(.c) i32 { std.debug.assert(dummy_cpu); dummy_cpu = false; return 1; }
    fn releaseDummy(_: *const a.GfxBufferHandle) callconv(.c) i32 { std.debug.assert(dummy_live and !dummy_dma and !dummy_cpu); dummy_live = false; return 1; }
    fn acquireDummy(_: *const a.GfxBufferHandle, req: *const a.GfxDeviceRequest, out: *a.GfxDeviceLease) callconv(.c) i32 {
        std.debug.assert(dummy_live and !dummy_cpu and req.access == 4 and req.byte_length == 4096); dummy_dma = true;
        out.* = .{ .lease = .{ .id = 13, .generation = 1 }, .byte_length = req.byte_length, .adapter_id = req.adapter_id,
            .device_generation = req.device_generation, .access = 4, .driver_owner = 1, .dma_mask = req.dma_mask }; return 1;
    }
    fn segmentDummy(_: *const a.GfxDeviceLease, offset: u64, out: *a.GfxDmaSegment) callconv(.c) i32 { std.debug.assert(dummy_dma and offset == 0); out.* = .{ .dma_address = dummy_address, .byte_length = 4096, .next_offset = 4096 }; return 1; }
    fn releaseDma(_: *const a.GfxDeviceLease, quiesced: u32) callconv(.c) i32 {
        std.debug.assert(dummy_dma and quiesced == 1 and irq_handler == null and !thread_live and !msi_live);
        if (dma_release_fail) return -4; dummy_dma = false; return 1;
    }
    fn config(_: u8, _: u8, _: u8, _: u8, offset: u16) callconv(.c) u32 { return if (offset == 4) 6 else if (offset == 0x3c) 0x10b else 0; }
    fn msiEnable(_: u8, _: u8, _: u8, _: u8) callconv(.c) i32 { if (msi_result >= 0) msi_live = true; return msi_result; }
    fn msiDisable(_: u8, _: u8, _: u8, _: u8) callconv(.c) i32 { if (msi_close_fail) return -3; msi_live = false; return 0; }
    fn irqRegister(number: u8, handler: a.IrqHandler, context: usize, flags: u32) callconv(.c) i32 {
        if (irq_register_fail) return -1;
        irq_handler = handler; irq_context = context; irq_number = number; irq_flags = flags; return 0;
    }
    fn irqUnregister(number: u8, handler: a.IrqHandler, context: usize) callconv(.c) i32 {
        std.debug.assert(number == irq_number and handler == irq_handler and context == irq_context);
        if (irq_close_fail) return -1; irq_handler = null; return 0;
    }
    fn threadQuery(out: *a.DriverThreadApi) callconv(.c) i32 {
        out.* = .{ .start = @intFromPtr(&threadStart), .stop = @intFromPtr(&threadStop), .join = @intFromPtr(&threadJoin), .release = @intFromPtr(&threadRelease) }; return 0;
    }
    fn threadStart(req: *const a.DriverThreadRequest, out: *u64) callconv(.c) i32 { std.debug.assert(!thread_live and req.flags == a.driver_thread_flag_parallel); thread_live = true; request = req.*; out.* = 91; return 0; }
    fn threadStop(handle: u64) callconv(.c) i32 { std.debug.assert(handle == 91 and thread_live); return 0; }
    fn threadJoin(handle: u64, ticks: u64, result: *i32) callconv(.c) i32 { std.debug.assert(handle == 91 and thread_live and ticks == 0); if (thread_join_busy) return -8; result.* = 0; return 0; }
    fn threadRelease(handle: u64) callconv(.c) i32 { std.debug.assert(handle == 91 and thread_live); if (thread_release_fail) return -12; thread_live = false; return 0; }
    fn semQuery(out: *a.DriverSemaphoreApi) callconv(.c) i32 { out.* = .{ .create = @intFromPtr(&semCreate), .acquire = @intFromPtr(&semAcquire), .release = @intFromPtr(&semRelease), .destroy = @intFromPtr(&semDestroy) }; return 0; }
    fn semCreate(initial: u32, maximum: u32, out: *u64) callconv(.c) i32 { std.debug.assert(initial == 0 and maximum == 1 and !sem_live); sem_live = true; out.* = 81; return 0; }
    fn semAcquire(handle: u64, ticks: u64) callconv(.c) i32 { std.debug.assert(handle == 81 and ticks == 10); if (sem_acquire_error != 0) return sem_acquire_error; const signaled = sem_permit; sem_permit = false; return if (signaled) 0 else a.driver_semaphore_error_timeout; }
    fn semRelease(handle: u64) callconv(.c) i32 { std.debug.assert(handle == 81 and sem_live); if (sem_permit) return a.driver_semaphore_error_overflow; sem_permit = true; return 0; }
    fn semDestroy(handle: u64) callconv(.c) i32 { std.debug.assert(handle == 81 and sem_live and !thread_live and irq_handler == null); if (sem_destroy_fail) return -11; sem_live = false; return 0; }
};

test "AMD bounded ring and fixed queue arenas preserve wrap, staged ownership and native lifetime" {
    var words: [32]u32 = @splat(0);
    try t.expectError(error.Invalid, Ring.init(&words, 0, 0));
    var ring = try Ring.init(&words, 4, 0xffff1000);
    const first = try ring.stage(&.{ 10, 11, 12 }); try t.expectEqual(@as(u32, 0xffff1000), words[3]);
    try t.expectEqual(@as(u64, 0), ring.write); try t.expectError(error.Busy, ring.stage(&.{1}));
    try t.expectEqual(@as(u64, 4), try ring.commit(first)); try t.expectError(error.Stale, ring.commit(first));
    try t.expectError(error.Stale, ring.observe(5)); try ring.observe(4);
    var block: [24]u32 = @splat(17); const second = try ring.stage(&block); _ = try ring.commit(second);
    try t.expectEqual(@as(usize, 7), ring.available()); try t.expectError(error.Capacity, ring.stage(&.{ 1,2,3,4,5,6,7,8 }));
    try ring.observe(28); const wrap = try ring.stage(&.{ 20,21,22,23,24 }); _ = try ring.commit(wrap);
    try t.expectEqual(@as(u64, 36), ring.write); try t.expectEqual(@as(u32, 24), words[0]); try ring.observe(4);
    const cancel = try ring.stage(&.{9}); try ring.cancel(cancel); try t.expectEqual(@as(u64, 36), ring.write);
    ring.serial = std.math.maxInt(u64); try t.expectError(error.Overflow, ring.stage(&.{1}));
    F.reset(); try F.prepare(); try t.expectEqual(@as(u32, 1), F.memory.engine_users);
    try t.expect(F.dummy_dma and !F.dummy_cpu and F.memory.mapping_users == 1);
    for (F.dummy) |byte| try t.expectEqual(@as(u8, 0), byte);
    try t.expect(F.run.arena.dummy.dma_only and F.run.arena.dummy.address == 0);
    try t.expectError(error.Busy, F.run.arena.dummy.publish(&F.memory.virtual, &F.memory.registers, false, false));
    try t.expect(!F.memory.close(.{ .memory_epoch = 23, .boot_held = true, .engines_quiesced = true }));
    try t.expectEqual(@as(usize, store.ib_bytes/4), (try F.run.arena.ib(63)).len); try t.expectError(error.Invalid, F.run.arena.ib(64));
    try t.expect(try F.run.arena.address(0, 4) != F.layout.physical.offset + F.layout.rings.span.offset);
    try F.run.arena.doorbell64(.sdma, 0x123456789abcdef0);
    try t.expectEqual(@as(u32, 0x9abcdef0), F.bells[r.sdma_doorbell]); try t.expectEqual(@as(u32, 0x12345678), F.bells[r.sdma_doorbell + 1]);
    F.unmap_fail = true; try t.expect(!F.run.close(null)); try t.expectEqual(@as(u32, 1), F.memory.engine_users);
    F.unmap_fail = false; try t.expect(F.run.close(null)); try t.expectEqual(@as(u32, 0), F.mapped); try t.expectEqual(@as(u32, 0), F.memory.engine_users);
    F.reset(); F.map_fail = true; try t.expectError(error.Unsupported, F.prepare()); try t.expect(F.run.close(null)); try t.expectEqual(@as(u32, 0), F.memory.engine_users);
    F.reset(); F.dummy_address = @as(u64, 1) << 40; try t.expectError(error.Unsupported, F.prepare());
    F.dma_release_fail = true; try t.expect(!F.run.close(null)); try t.expect(F.dummy_dma and F.memory.mapping_users == 1);
    F.dma_release_fail = false; try t.expect(F.run.close(null));
}

test "AMD IH routes MSI and INTx, decodes bounded epoch metadata and retains uncertain teardown" {
    F.reset(); try F.prepare(); try F.start(); try t.expectEqual(a.irq_flag_msi, F.irq_flags);
    try t.expectEqual(@as(u32, @intCast(F.dummy_address >> 8)), F.regs[r.nb.INTERRUPT_CNTL2 / 4]);
    try t.expect(F.dummy_address != F.run.arena.gpu);
    try t.expectEqual(@as(u32, 4), (F.regs[r.ih.IH_RB_CNTL / 4] & r.ih.IH_RB_CNTL__MC_SPACE_MASK) >> r.ih.IH_RB_CNTL__MC_SPACE__SHIFT);
    F.arena[0..8].* = .{ r.client_GRBM_CP | (@as(u32, r.gfx_CP_EOP_INTERRUPT) << 8) | (3 << 16) | (1 << 24), 0x87654321, 0x80001234, 0x550123, 1,2,3,4 };
    F.regs[r.ih.IH_RB_WPTR / 4] = 32;
    try t.expectEqual(a.irq_result_handled, F.irq_handler.?(F.irq_number, F.irq_context));
    try t.expectEqual(@as(usize, 0), F.completed); try t.expectEqual(@as(u32, 32), F.bells[r.ih_doorbell]);
    const event = F.run.irq.mailbox.pop().?;
    try t.expect(std.meta.eql(epoch, event.epoch)); try t.expectEqual(@as(u48, 0x123487654321), event.timestamp);
    try t.expect(event.timestamp_source and event.vmid == 1 and event.pasid == 0x123 and event.node == 0x55 and event.data[3] == 4);
    // Ring wraps at a complete IV boundary; IRQ capture cannot exceed 32 IVs.
    F.run.irq.controller.rptr = store.ih_bytes - 32; F.arena[store.ih_bytes/4-8 .. store.ih_bytes/4].* = F.arena[0..8].*;
    F.regs[r.ih.IH_RB_WPTR / 4] = 0; try t.expectEqual(@as(u32, 1), F.run.irq.poll()); _ = F.run.irq.mailbox.pop();
    F.regs[r.ih.IH_RB_WPTR / 4] = 40 * 32; try t.expectEqual(@as(u32, 32), F.run.irq.poll());
    while (F.run.irq.mailbox.pop() != null) {} try t.expectEqual(@as(u32, 8), F.run.irq.poll());
    // Full CPU mailbox keeps unread IVs in the hardware ring, no fake ACK.
    while (F.run.irq.mailbox.pop() != null) {}
    for (0..128) |_| try t.expect(F.run.irq.mailbox.push(event));
    const before = F.run.irq.controller.rptr; F.regs[r.ih.IH_RB_WPTR / 4] += 32;
    try t.expectEqual(@as(u32, 0), F.run.irq.poll()); try t.expectEqual(before, F.run.irq.controller.rptr);
    _ = F.run.irq.mailbox.pop(); try t.expectEqual(@as(u32, 1), F.run.irq.poll());
    F.regs[r.ih.IH_RB_WPTR / 4] = 1; _ = F.irq_handler.?(F.irq_number, F.irq_context); try t.expect(F.run.irq.failed());
    try t.expectEqual(@as(u32, 0), F.regs[r.ih.IH_RB_CNTL / 4] & r.ih.IH_RB_CNTL__ENABLE_INTR_MASK);
    const proof: q.Quiescence = .{ .epoch = epoch, .engines = 63 };
    Runtime.notify(@intFromPtr(&F.run)); Runtime.notify(@intFromPtr(&F.run)); try t.expectEqual(@as(u32, 0), F.run.wake_fault);
    @atomicStore(u32, &F.run.notify_state, 1, .release);
    try t.expect(!F.run.close(proof)); try t.expect(F.thread_live);
    _ = @atomicRmw(u32, &F.run.notify_state, .Sub, 1, .release);
    F.thread_join_busy = true; try t.expect(!F.run.close(proof)); try t.expect(F.thread_live and F.irq_handler != null and F.mapped == 2);
    F.thread_join_busy = false; F.thread_release_fail = true; try t.expect(!F.run.close(proof)); F.thread_release_fail = false;
    try t.expect(!F.run.close(null)); try t.expect(!F.run.close(proof)); // first IH disable starts the 1ms drain
    F.clock += 999999; try t.expect(!F.run.close(proof)); F.clock += 1;
    F.irq_close_fail = true; try t.expect(!F.run.close(proof)); try t.expect(F.sem_live and F.mapped == 2);
    F.irq_close_fail = false; F.msi_close_fail = true; try t.expect(!F.run.close(proof));
    F.msi_close_fail = false; F.sem_destroy_fail = true; try t.expect(!F.run.close(proof));
    F.sem_destroy_fail = false; try t.expect(F.run.close(proof)); try t.expect(!F.sem_live and F.mapped == 0);
    Runtime.notify(@intFromPtr(&F.run)); try t.expectEqual(@as(u32, 0), F.run.wake_fault); try t.expect(F.run.close(proof));
    F.reset(); F.msi_result = -2; try F.prepare(); try F.start();
    try t.expectEqual(a.irq_flag_shared | a.irq_flag_level_low, F.irq_flags); try t.expectEqual(@as(u8, 11), F.irq_number);
    try t.expect(!F.run.close(proof)); F.clock += 1_000_000; try t.expect(F.run.close(proof));
    F.reset(); F.irq_register_fail = true; try F.prepare(); try t.expectError(error.Unsupported, F.start());
    try t.expect(!F.run.close(null)); F.clock += 1_000_000; try t.expect(F.run.close(null));
    F.reset(); F.msi_result = -5; try F.prepare(); try t.expectError(error.Unconfirmed, F.start());
    try t.expect(!F.run.close(proof)); try t.expect(F.run.irq.routing_uncertain and F.mapped == 2);
    // Counter wrap is independent of a GPU's 48-bit timestamp wrap.
    var mailbox: ih.Mailbox = .{ .producer = std.math.maxInt(u32) - 63, .consumer = std.math.maxInt(u32) - 63 };
    for (0..128) |i| { var value = event; value.data[0] = @intCast(i); try t.expect(mailbox.push(value)); }
    try t.expect(!mailbox.push(event));
    for (0..128) |i| try t.expectEqual(@as(u32, @intCast(i)), mailbox.pop().?.data[0]);
    try t.expect(mailbox.pop() == null);
}

test "AMD worker publishes exact writebacks, polls lost IRQs and retains timeout and failed releases" {
    F.reset(); try F.prepare(); try F.start();
    const resources: q.Resources = .{ .context = 0, .retire = F.retire };
    const ticket = try F.run.timeline.reserve(fence(1), .sdma, 1000, resources);
    F.run.timeline.writeback[ticket.slot] = ticket.token; F.run.timeline.poll(101);
    try t.expectEqual(q.Phase.reserved, (try F.run.timeline.entry(ticket)).phase);
    try t.expectError(error.Stale, F.run.timeline.arm(ticket));
    F.run.timeline.writeback[ticket.slot] = std.math.maxInt(u64); try F.run.timeline.arm(ticket);
    F.run.timeline.writeback[ticket.slot] = 999; F.clock = 102; F.run.step();
    try t.expectEqual(@as(usize, 0), F.completed); try t.expect(F.run.timeline.stale_writebacks > 0);
    F.run.timeline.writeback[ticket.slot] = ticket.token; F.retire_fail = true; F.clock = 103; F.run.step();
    try t.expectEqual(q.Phase.retiring, (try F.run.timeline.entry(ticket)).phase); try t.expectEqual(@as(usize, 0), F.completed);
    F.retire_fail = false; F.complete_fail = true; F.run.step(); try t.expectEqual(@as(usize, 1), F.retired);
    F.complete_fail = false; F.run.step(); try t.expectEqual(@as(usize, 1), F.retired); try t.expectEqual(@as(usize, 1), F.completed);
    try t.expectEqual(a.gfx_queue_result_complete, F.last_result); try t.expect(std.meta.eql(fence(1), F.last_fence));
    try t.expectError(error.Stale, F.run.timeline.entry(ticket));
    const next = try F.run.timeline.reserve(fence(2), .sdma, 1000, resources); try t.expect(next.token != ticket.token);
    try F.run.timeline.arm(next); F.run.timeline.writeback[next.slot] = ticket.token; F.clock = 104; F.run.step(); try t.expectEqual(@as(usize, 1), F.completed);
    var stale = next; stale.epoch.reset += 1; try t.expectError(error.Stale, F.run.timeline.entry(stale));
    F.clock = 1000; F.run.step(); try t.expectEqual(q.Phase.submitted, (try F.run.timeline.entry(next)).phase);
    try t.expectEqual(@as(usize, 1), F.retired); try t.expectEqual(@as(usize, 1), F.completed);
    try t.expectError(error.Unconfirmed, F.run.timeline.abort(.{ .epoch = stale.epoch, .engines = 63 }, a.gfx_queue_result_device_lost));
    F.prove_quiescence = true; F.run.step(); try t.expectEqual(a.gfx_queue_result_timeout, F.last_result); try t.expect(F.run.timeline.empty());
    const proof: q.Quiescence = .{ .epoch = epoch, .engines = 63 };
    try t.expect(!F.run.close(proof)); F.clock += 1_000_000; try t.expect(F.run.close(proof));
    // Execute the actual dedicated worker entry via the host fixture's saved
    // callback; no host fixture is represented as an R4OS scheduler/GPU test.
    F.reset(); try F.prepare(); try F.start(); F.worker_stop = true;
    const callback: *const fn (usize) callconv(.c) i32 = @ptrFromInt(F.request.handler);
    try t.expectEqual(@as(i32, 0), callback(F.request.context)); try t.expectEqual(@as(usize, 1), F.worker_calls);
    try t.expect(!F.run.close(proof)); F.clock += 1_000_000; try t.expect(F.run.close(proof));
    F.reset(); try F.prepare(); try F.start();
    const cancelled = try F.run.timeline.reserve(fence(4), .gfx, 1000, resources);
    try F.run.timeline.cancelUnsubmitted(cancelled); try t.expect(F.run.timeline.publish(F.queueContext()));
    try t.expectEqual(a.gfx_queue_result_cancelled, F.last_result);
    const error_job = try F.run.timeline.reserve(fence(5), .compute, 1000, resources); try F.run.timeline.arm(error_job);
    F.sem_acquire_error = a.driver_semaphore_error_context; F.prove_quiescence = true;
    const fail_callback: *const fn (usize) callconv(.c) i32 = @ptrFromInt(F.request.handler);
    try t.expectEqual(a.driver_semaphore_error_context, fail_callback(F.request.context));
    try t.expectEqual(a.gfx_queue_result_device_lost, F.last_result); try t.expect(F.run.timeline.empty() and F.run.timeline.stopping);
    try t.expect(!F.run.close(proof)); F.clock += 1_000_000; try t.expect(F.run.close(proof));
    F.reset(); try F.prepare();
    for (0..q.capacity) |i| _ = try F.run.timeline.reserve(fence(i + 1), .gfx, 1000, resources);
    try t.expectError(error.Capacity, F.run.timeline.reserve(fence(100), .gfx, 1000, resources));
    F.run.timeline.poll(99); try t.expectEqual(@as(q.EngineMask, 63), F.run.timeline.failed_engines);
    try t.expect(!F.run.close(null)); try t.expect(F.run.close(proof)); try t.expectEqual(@as(usize, q.capacity), F.completed);
}
