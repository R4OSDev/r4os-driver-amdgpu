// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std"); const t = std.testing;
const r4os = @import("r4os"); const a = r4os.abi;
const l = @import("memory_layout.zig"); const pages = @import("memory_pages.zig");
const hubs = @import("memory_hubs.zig"); const r = @import("memory_registers.zig");
const Owner = @import("memory_owner.zig").Owner;
const Mapping = @import("memory_mapping.zig").Mapping;
fn plan() !l.Layout { return l.Layout.create(.{ .base = 0x220000000, .bytes = 512 * 1024 * 1024 }, .{ .base = 0x100000000, .bytes = 512 * 1024 * 1024 }, 0x100000, 2 * 1024 * 1024, .{ .offset = 0x1fe00000, .bytes = 2 * 1024 * 1024, .driver_scratch_bytes = 4096 }); }
const Hardware = struct {
    words: [r.required_prefix / 4]u32 = @splat(0), writes: usize = 0, polls: usize = 0, barriers: usize = 0,
    missing_ack: bool = false, clock: u64 = 1000, backward: bool = false, disconnected: bool = false,
    pub fn read(self: *@This(), offset: u32) hubs.Error!u32 {
        if (self.disconnected) return 0xffffffff;
        if (offset == r.gfx.VM_INVALIDATE_ENG17_ACK or offset == r.mm.VM_INVALIDATE_ENG17_ACK) {
            self.polls += 1;
            const req = if (offset == r.gfx.VM_INVALIDATE_ENG17_ACK) r.gfx.VM_INVALIDATE_ENG17_REQ else r.mm.VM_INVALIDATE_ENG17_REQ;
            return if (!self.missing_ack and self.polls % 3 == 0) self.words[req / 4] & 0xffff else 0;
        }
        return self.words[offset / 4];
    }
    pub fn write(self: *@This(), offset: u32, value: u32) hubs.Error!void { self.words[offset / 4] = value; self.writes += 1; }
    pub fn barrier(self: *@This()) hubs.Error!void { self.barriers += 1; }
    pub fn nowNs(self: *@This()) u64 { self.clock += 100; return if (self.backward and self.clock > 1200) 1 else self.clock; }
};
var hw: Hardware = .{};
var flat_words: [512]u64 align(4096) = undefined;
var vm_words: [8 * 512]u64 align(4096) = undefined;

test "Picasso UMA partitions conserve capacity and GPU page tables reject holes and mixed addresses" {
    var map = try plan();
    try t.expect(map.physical.offset != map.mc.offset and !map.gart.overlaps(map.mc));
    try t.expectEqual(map.physical.bytes, map.pool.reserved_bytes + map.pool.allocated_bytes + map.native_budget);
    var pool: l.Pool = .{ .bytes = 32 * 4096 };
    try pool.reserve(4096, 3 * 4096); try pool.reserve(2 * 4096, 4 * 4096); try pool.reserve(6 * 4096, 4096);
    try t.expectEqual(@as(u64, 6 * 4096), pool.reserved_bytes);
    const block = try pool.allocate(5000, 8192, .buffer); try t.expectEqual(@as(u64, 32768), block.span.offset);
    try t.expectError(error.Invalid, pool.allocate(1, 0, .buffer));
    try t.expectError(error.Busy, pool.reserve(0, 4096));
    try pool.release(block); try t.expectError(error.Stale, pool.release(block));
    try t.expectEqual(@as(u64, 0), pool.allocated_bytes);
    try t.expectError(error.Invalid, l.Layout.create(.{ .base = 4096, .bytes = l.address_limit }, .{ .base = 0, .bytes = l.address_limit }, 4096, 4096, null));
}

test "Picasso PTE and hub state uses hardware fields, bounded ACK waits and confirmed teardown" {
    try t.expectError(error.Invalid, l.aligned(12, 0)); try t.expectError(error.Overflow, l.aligned(std.math.maxInt(u64), 4096));
    try t.expectError(error.Invalid, pages.pte(0x1001, .{ .system = true }));
    try t.expectError(error.Invalid, pages.pte(l.address_limit, .{ .system = true }));
    const sys = try pages.pte(0x12345000, .{ .system = true, .write = true });
    try t.expectEqual(@as(u64, 0x0600000012345067), sys);
    try t.expectEqual(@as(u64, 0x220000001), try pages.pde(0x220000000, false));
    var flat = try pages.Flat.init(&flat_words, .{ .offset = 0x40000000, .bytes = 2 * 1024 * 1024 });
    try t.expectError(error.Sparse, flat.map(0x40001000, &.{ 0x5000, 0 }, .{ .system = true })); try t.expectEqual(@as(u64, 0), flat_words[1]);
    try flat.map(0x40001000, &.{ 0x5000, 0x9000 }, .{ .system = true, .write = true });
    try t.expectError(error.Busy, flat.map(0x40001000, &.{0x11000}, .{ .system = true }));
    try t.expectError(error.Sparse, flat.unmap(0x40000000, 3)); try t.expectEqual(@as(usize, 2), flat.mapped_pages);
    try flat.unmap(0x40001000, 2); try t.expectEqual(@as(usize, 0), flat.mapped_pages);
    var vm: pages.Virtual = .{}; try vm.init(&vm_words, 0x225000000);
    const va: u64 = 0x7fff_ffff_e000;
    try vm.map(va, &.{ 0x222000000, 0x222001000 }, .{ .system = false, .write = true });
    try t.expectEqual(@as(u64, 0x222000000), (try vm.lookup(va)) & pages.physical_mask);
    try t.expectEqual(@as(u64, 0), (try vm.lookup(va)) & 6);
    try t.expectError(error.Invalid, vm.map(l.address_limit - 4096, &.{0x5000, 0x6000}, .{ .system = true }));
    try vm.unmap(va, 2); try t.expectEqual(@as(u64, 0), try vm.lookup(va));
    hw = .{}; var controller: hubs.Controller = .{}; var map = try plan();
    const root = try pages.pde(try map.physicalAddress(map.contexts.span), false);
    const scratch = try map.physicalAddress(.{ .offset = map.contexts.span.end() - 4096, .bytes = 4096 });
    const gate: hubs.Gate = .{ .memory_epoch = 23, .boot_held = true, .engines_quiesced = true };
    try t.expectError(error.Unconfirmed, controller.enable(&hw, &map, root, scratch, .{ .memory_epoch = 23, .boot_held = false, .engines_quiesced = true }));
    try t.expectEqual(@as(usize, 0), hw.writes);
    try controller.enable(&hw, &map, root, scratch, gate); try t.expect(controller.enabled and controller.touched);
    try t.expectEqual(@as(u32, @truncate(root)), hw.words[r.mm.VM_CONTEXT1_PAGE_TABLE_BASE_ADDR_LO32 / 4]);
    try t.expectEqual(@as(u32, 0), hw.words[(r.gfx.VM_CONTEXT0_CNTL + 8) / 4]);
    hw.missing_ack = true; try t.expectError(error.Deadline, controller.disable(&hw, gate)); try t.expect(controller.touched and !controller.enabled);
    hw.missing_ack = false; try controller.disable(&hw, gate); try t.expect(!controller.touched);
    hw = .{}; hw.backward = true; try t.expectError(error.Deadline, hubs.flush(&hw, 1));
    hw = .{}; hw.disconnected = true; try t.expectError(error.Disconnected, hubs.flush(&hw, 0));
}
const F = struct {
    var api: a.DriverApi = undefined; var owner: Owner = .{}; var layout: l.Layout = undefined;
    var regs: [r.required_prefix / 4]u32 align(4096) = undefined;
    var table: [l.table_bytes / 8]u64 align(4096) = undefined;
    var contexts: [2 * 1024 * 1024 / 8]u64 align(4096) = undefined;
    var cpu: [8192]u8 align(4096) = undefined;
    var cpu_live = false; var shared = false; var dma = false; var gpu = false;
    var descriptor: a.GfxBufferDescriptor = .{}; var native: a.GfxBufferDescriptor = .{};
    var ticket: a.GfxOwnedBufferReservation = .{}; var native_refs: usize = 0;
    var committed = false; var claimed = false; var release_fail = false; var map_fail = false;
    var segment_hole = false; var segment_duplicate = false; var span_fail = false;
    var windows: usize = 0; var charged: u64 = 0; var closed = false;
    fn reset() void {
        owner = .{}; layout = plan() catch unreachable; regs = @splat(0); cpu = @splat(0xff);
        cpu_live = false; shared = false; dma = false; gpu = false; ticket = .{}; native_refs = 0; committed = false; claimed = false;
        release_fail = false; map_fail = false; segment_hole = false; segment_duplicate = false; span_fail = false;
        windows = 0; charged = 0; closed = false;
        api = undefined; api.magic = a.driver_magic; api.version = a.driver_api_version; api.size = @sizeOf(a.DriverApi);
        api.gfx_memory_query = query; api.resource_query = resources;
    }
    fn query(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        out.* = .{ .reserved_span = @intFromPtr(&reserved), .mmio_map = @intFromPtr(&mapWindow), .mmio_unmap = @intFromPtr(&unmapWindow),
            .collect = @intFromPtr(&collect), .memory_budget = @intFromPtr(&budget), .device_lost = @intFromPtr(&lost),
            .buffer_create = @intFromPtr(&create), .buffer_import = @intFromPtr(&import), .buffer_describe = @intFromPtr(&describe),
            .buffer_map = @intFromPtr(&mapCpu), .buffer_unmap = @intFromPtr(&unmapCpu), .buffer_release = @intFromPtr(&release),
            .device_acquire = @intFromPtr(&acquire), .device_segment = @intFromPtr(&segment), .device_release = @intFromPtr(&deviceRelease),
            .buffer_reserve = @intFromPtr(&reserve), .buffer_commit = @intFromPtr(&commit), .buffer_abort = @intFromPtr(&abort),
            .buffer_take_release = @intFromPtr(&take), .buffer_finish_release = @intFromPtr(&finish) }; return 1;
    }
    fn resources(out: *a.DriverResourceApi) callconv(.c) i32 { out.* = .{ .now_ns = @intFromPtr(&now) }; return 0; }
    fn now() callconv(.c) u64 { return 1000; }
    fn reserved(base: u64, bytes: u64) callconv(.c) i32 { return if (!span_fail and base == layout.physical.offset and bytes == layout.physical.bytes) 1 else -6; }
    fn mapWindow(req: *const a.GfxMmioRequest, out: *a.GfxMmioWindow) callconv(.c) i32 {
        if (map_fail) return -6;
        const address: usize = if (req.resource_base == 0xf0000000) @intFromPtr(&regs) else if (req.byte_offset == layout.tables.span.offset) @intFromPtr(&table) else @intFromPtr(&contexts);
        windows += 1;
        out.* = .{ .handle = .{ .id = @intCast(windows), .generation = 19 }, .cpu_address = address,
            .physical_address = req.resource_base + req.byte_offset, .byte_length = req.byte_length, .cache_policy = req.cache_policy }; return 1;
    }
    fn unmapWindow(_: *const a.GfxBufferHandle, quiesced: u32) callconv(.c) i32 { std.debug.assert(quiesced == 1 and windows != 0); if (release_fail) return -4; windows -= 1; return 1; }
    fn collect() callconv(.c) i32 { return if (release_fail) -4 else 1; }
    fn budget(req: *const a.GfxDeviceBudgetRequest, out: *a.GfxDeviceBudgetState) callconv(.c) i32 {
        std.debug.assert(req.memory_generation == 23 and req.adapter_id == 7 and req.limit_bytes == layout.native_budget);
        out.* = .{ .adapter_id = 7, .memory_generation = 23, .limit_bytes = req.limit_bytes, .charged_bytes = charged,
            .shared_limit_bytes = 64 * 1024 * 1024, .shared_charged_bytes = 0, .shared_producer_limit_bytes = 32 * 1024 * 1024 }; return 1;
    }
    fn lost(adapter: u32, epoch: u64, quiesced: u32) callconv(.c) i32 { std.debug.assert(adapter == 7 and epoch == 23 and quiesced == 1); closed = true; return 1; }
    fn create(desc: *const a.GfxBufferDescriptor, out: *a.GfxBufferReference) callconv(.c) i32 {
        std.debug.assert(!shared and desc.byte_length == cpu.len); shared = true; descriptor = desc.*;
        out.* = .{ .buffer = .{ .id = 1, .generation = 19 }, .reference = .{ .id = 2, .generation = 19 } }; return 1;
    }
    fn import(ref: *const a.GfxBufferHandle, out: *a.GfxBufferReference) callconv(.c) i32 {
        std.debug.assert(ref.id == 101 and committed); native_refs += 1;
        out.* = .{ .buffer = ticket.buffer, .reference = .{ .id = 102, .generation = 19 } }; return 1;
    }
    fn describe(ref: *const a.GfxBufferHandle, out: *a.GfxBufferDescriptor) callconv(.c) i32 { out.* = if (ref.id >= 100) native else descriptor; return 1; }
    fn mapCpu(_: *const a.GfxBufferHandle, access: u32, offset: u64, bytes: u64, out: *a.GfxBufferMap) callconv(.c) i32 {
        std.debug.assert(shared and !dma and !gpu and access == a.gfx_buffer_map_write and offset == 0 and bytes == cpu.len);
        cpu_live = true; out.* = .{ .lease = .{ .id = 3, .generation = 19 }, .cpu_address = @intFromPtr(&cpu), .byte_length = cpu.len, .cache_policy = a.gfx_buffer_cache_write_back }; return 1;
    }
    fn unmapCpu(_: *const a.GfxBufferHandle) callconv(.c) i32 { if (release_fail) return -4; cpu_live = false; return 1; }
    fn release(ref: *const a.GfxBufferHandle) callconv(.c) i32 {
        if (release_fail) return -4;
        if (ref.id >= 100) { std.debug.assert(native_refs > 0); native_refs -= 1; } else { std.debug.assert(!dma and !gpu and !cpu_live); shared = false; }
        return 1;
    }
    fn acquire(_: *const a.GfxBufferHandle, req: *const a.GfxDeviceRequest, out: *a.GfxDeviceLease) callconv(.c) i32 {
        std.debug.assert(!cpu_live and req.adapter_id == 7 and req.device_generation == 23);
        if (req.access == 4) { std.debug.assert(!dma); dma = true; } else { std.debug.assert(!gpu and req.access == 3); gpu = true; }
        out.* = .{ .lease = .{ .id = 10 + req.access, .generation = 19 }, .byte_length = req.byte_length, .gpu_virtual_address = req.gpu_virtual_address,
            .adapter_id = req.adapter_id, .driver_owner = 9, .device_generation = req.device_generation, .access = req.access, .address_space = req.address_space, .dma_mask = req.dma_mask }; return 1;
    }
    fn segment(_: *const a.GfxDeviceLease, offset: u64, out: *a.GfxDmaSegment) callconv(.c) i32 {
        std.debug.assert(dma and offset < cpu.len);
        out.* = .{ .dma_address = if (segment_hole and offset != 0) 0 else 0x1000000 + (if (segment_duplicate) 0 else offset * 3), .byte_length = 4096, .next_offset = offset + 4096 }; return 1;
    }
    fn deviceRelease(lease: *const a.GfxDeviceLease, q: u32) callconv(.c) i32 {
        std.debug.assert(q == 1); if (release_fail) return -4;
        if (lease.access == 3) { std.debug.assert(gpu); gpu = false; } else { std.debug.assert(dma and !gpu); dma = false; } return 1;
    }
    fn reserve(desc: *const a.GfxBufferDescriptor, cookie: u64, out: *a.GfxOwnedBufferReservation) callconv(.c) i32 {
        std.debug.assert(ticket.cookie == 0); native = desc.*; native.driver_owner = 9; charged = desc.byte_length;
        ticket = .{ .buffer = .{ .id = 100, .generation = 19 }, .reference = .{ .id = 101, .generation = 19 },
            .allocation_bytes = desc.byte_length, .cookie = cookie, .device_generation = 23, .driver_generation = 31, .adapter_id = 7, .driver_owner = 9 };
        out.* = ticket; return 1;
    }
    fn commit(_: *const a.GfxOwnedBufferReservation, out: *a.GfxBufferReference) callconv(.c) i32 { committed = true; native_refs = 1; out.* = .{ .buffer = ticket.buffer, .reference = ticket.reference }; return 1; }
    fn abort(_: *const a.GfxOwnedBufferReservation, _: u32) callconv(.c) i32 { if (release_fail) return -4; ticket = .{}; charged = 0; return 1; }
    fn take(_: u32, _: u64, out: *a.GfxOwnedBufferRelease) callconv(.c) i32 {
        if (!committed or native_refs != 0 or gpu or claimed) return a.gfx_buffer_error_busy;
        claimed = true; out.* = .{ .buffer = ticket.buffer, .cookie = ticket.cookie, .byte_length = ticket.allocation_bytes, .attempt = 17,
            .device_generation = 23, .driver_generation = 31, .adapter_id = 7, .driver_owner = 9 }; return 1;
    }
    fn finish(_: *const a.GfxOwnedBufferRelease, _: u32) callconv(.c) i32 { if (release_fail) return -4; committed = false; claimed = false; ticket = .{}; charged = 0; return 1; }
    fn prepare() !void { const ctx = r4os.r4dev.DriverContext.init(&api); try owner.prepare(&ctx, &layout, 0xf0000000, 7, 23); }
};

test "AMD actual memory facades retain SG/UMA backing until fence and both TLB acknowledgements" {
    F.reset(); try F.prepare(); try t.expectEqual(@as(usize, 3), F.windows);
    const gate: hubs.Gate = .{ .memory_epoch = 23, .boot_held = true, .engines_quiesced = true };
    // Real register facade over a RAM register fixture; no physical GPU.
    try t.expectError(error.Deadline, F.owner.enable(gate));
    try t.expect(F.owner.controller.touched and !F.owner.controller.enabled);
    F.regs[r.gfx.VM_INVALIDATE_ENG17_ACK / 4] = 3; F.regs[r.mm.VM_INVALIDATE_ENG17_ACK / 4] = 3;
    try t.expect(F.owner.close(gate)); F.reset(); try F.prepare();
    F.regs[r.gfx.VM_INVALIDATE_ENG17_ACK / 4] = 3; F.regs[r.mm.VM_INVALIDATE_ENG17_ACK / 4] = 3;
    try F.owner.enable(gate);
    var mapping: Mapping = .{}; var physical: [2]u64 = undefined;
    try mapping.prepare(&F.owner, null, F.layout.gart.offset + 4096, 8192, 0, &physical);
    try t.expect(physical[0] != @intFromPtr(&F.cpu) and physical[1] != physical[0] + 4096 and !F.cpu_live);
    try t.expect(std.mem.allEqual(u8, &F.cpu, 0));
    hw = .{}; try mapping.publish(&F.owner.gart.?, &hw, true, false);
    const fence: a.GfxFence = .{ .adapter_id = 7, .timeline = 99, .point = 3, .device_generation = 11, .reset_generation = 5 };
    try mapping.retain(fence); try t.expect(!mapping.close(&F.owner.gart.?, &hw)); try t.expect(F.dma and F.gpu);
    var stale = fence; stale.device_generation += 1; try t.expectError(error.Stale, mapping.complete(stale));
    try mapping.complete(fence); hw.missing_ack = true;
    try t.expect(!mapping.close(&F.owner.gart.?, &hw)); try t.expect(F.dma and F.gpu and mapping.flush_pending and !mapping.translated);
    try t.expect(!F.owner.close(gate)); hw.missing_ack = false; F.release_fail = true;
    try t.expect(!mapping.close(&F.owner.gart.?, &hw)); try t.expect(F.dma and F.gpu);
    F.release_fail = false; try t.expect(mapping.close(&F.owner.gart.?, &hw)); try t.expect(!F.shared and !F.dma and !F.gpu);
    try t.expectError(error.Invalid, F.owner.create(.{ .byte_length = 8191, .usage = 12, .location = a.gfx_buffer_location_device_local, .adapter_id = 7, .device_generation = 23 }));
    const ref = try F.owner.create(.{ .byte_length = 8192, .usage = 12, .location = a.gfx_buffer_location_device_local, .adapter_id = 7, .device_generation = 23 });
    try mapping.prepareNative(&F.owner, ref.reference, 0x1000000000, &physical);
    try t.expect(physical[0] >= F.layout.physical.offset and physical[0] != F.layout.mc.offset);
    try mapping.publish(&F.owner.virtual, &hw, true, false); try t.expect(F.owner.drop(ref.reference));
    try t.expect(F.owner.collect()); try t.expect(F.committed and F.charged == 8192);
    try t.expect(mapping.close(&F.owner.virtual, &hw)); F.release_fail = true;
    try t.expect(!F.owner.collect()); try t.expect(F.claimed and F.charged == 8192);
    F.release_fail = false; try t.expect(F.owner.collect()); try t.expect(F.charged == 0 and !F.committed);
    try t.expect(F.owner.close(gate)); try t.expect(F.closed and F.windows == 0);
    for (0..2) |i| {
        F.reset(); try F.prepare(); F.segment_hole = i == 0; F.segment_duplicate = i == 1;
        const result = mapping.prepare(&F.owner, null, F.layout.gart.offset + 4096, 8192, 0, &physical);
        if (i == 0) try t.expectError(error.Sparse, result) else try t.expectError(error.Invalid, result);
        try t.expect(!mapping.prepared); try t.expect(mapping.close(&F.owner.gart.?, &hw)); try t.expect(F.owner.close(gate));
    }
    F.reset(); F.span_fail = true; try t.expectError(error.Unsupported, F.prepare()); try t.expect(F.windows == 0);
    F.reset(); F.map_fail = true; try t.expectError(error.Unsupported, F.prepare()); F.map_fail = false; try t.expect(F.owner.close(gate));
    var table: a.GfxDriverMemoryApi = .{ .size = 240, .reserved_span = @intFromPtr(&F.reserved) };
    var memory: r4os.driver_memory.Context = .{ .table = table }; try t.expectEqual(a.err_no_fn, memory.reservedSpan(1, 1));
    table.size = 248; table.reserved_span = 0; memory.table = table; try t.expectEqual(a.err_no_fn, memory.reservedSpan(1, 1));
}
