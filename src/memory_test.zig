// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const t = std.testing;
const r4os = @import("r4os");
const a = r4os.abi;
const l = @import("memory_layout.zig");
const pages = @import("memory_pages.zig");
const hubs = @import("memory_hubs.zig");
const r = @import("memory_registers.zig");
const Owner = @import("memory_owner.zig").Owner;
const Mapping = @import("memory_mapping.zig").Mapping;
fn plan() !l.Layout {
    return l.Layout.create(.{ .base = 0x220000000, .bytes = 512 * 1024 * 1024 }, .{ .base = 0x100000000, .bytes = 512 * 1024 * 1024 }, 0x100000, 2 * 1024 * 1024, .{ .offset = 0x1fe00000, .bytes = 2 * 1024 * 1024, .driver_scratch_bytes = 4096 });
}
const Hardware = struct {
    words: [r.required_prefix / 4]u32 = @splat(0),
    writes: usize = 0,
    polls: usize = 0,
    barriers: usize = 0,
    missing_ack: bool = false,
    clock: u64 = 1000,
    backward: bool = false,
    disconnected: bool = false,
    pub fn read(self: *@This(), offset: u32) hubs.Error!u32 {
        if (self.disconnected) return 0xffffffff;
        if (offset == r.gfx.VM_INVALIDATE_ENG17_ACK or offset == r.mm.VM_INVALIDATE_ENG17_ACK) {
            self.polls += 1;
            const req = if (offset == r.gfx.VM_INVALIDATE_ENG17_ACK) r.gfx.VM_INVALIDATE_ENG17_REQ else r.mm.VM_INVALIDATE_ENG17_REQ;
            return if (!self.missing_ack and self.polls % 3 == 0) self.words[req / 4] & 0xffff else 0;
        }
        return self.words[offset / 4];
    }
    pub fn write(self: *@This(), offset: u32, value: u32) hubs.Error!void {
        self.words[offset / 4] = value;
        self.writes += 1;
    }
    pub fn barrier(self: *@This()) hubs.Error!void {
        self.barriers += 1;
    }
    pub fn nowNs(self: *@This()) u64 {
        self.clock += 100;
        return if (self.backward and self.clock > 1200) 1 else self.clock;
    }
};
var hw: Hardware = .{};
var flat_words: [512]u64 align(4096) = undefined;
var vm_words: [8 * 512]u64 align(4096) = undefined;

test "Picasso UMA partitions conserve capacity and GPU page tables reject holes and mixed addresses" {
    var map = try plan();
    try t.expect(map.physical.offset != map.mc.offset and !map.gart.overlaps(map.mc));
    try t.expectEqual(map.physical.bytes, map.pool.reserved_bytes + map.pool.allocated_bytes + map.native_budget);
    try t.expectEqual(@as(u64, 65536), map.render.span.bytes);
    try t.expect(!map.render.span.overlaps(map.contexts.span) and !map.render.span.overlaps(map.rings.span));
    var pool: l.Pool = .{ .bytes = 32 * 4096 };
    try pool.reserve(4096, 3 * 4096);
    try pool.reserve(2 * 4096, 4 * 4096);
    try pool.reserve(6 * 4096, 4096);
    try t.expectEqual(@as(u64, 6 * 4096), pool.reserved_bytes);
    const block = try pool.allocate(5000, 8192, .buffer);
    try t.expectEqual(@as(u64, 32768), block.span.offset);
    try t.expectError(error.Invalid, pool.allocate(1, 0, .buffer));
    try t.expectError(error.Busy, pool.reserve(0, 4096));
    try pool.release(block);
    try t.expectError(error.Stale, pool.release(block));
    try t.expectEqual(@as(u64, 0), pool.allocated_bytes);
    try t.expectError(error.Invalid, l.Layout.create(.{ .base = 4096, .bytes = l.address_limit }, .{ .base = 0, .bytes = l.address_limit }, 4096, 4096, null));
}

test "Picasso PTE and hub state uses hardware fields, bounded ACK waits and confirmed teardown" {
    try t.expectError(error.Invalid, l.aligned(12, 0));
    try t.expectError(error.Overflow, l.aligned(std.math.maxInt(u64), 4096));
    try t.expectError(error.Invalid, pages.pte(0x1001, .{ .system = true }));
    try t.expectError(error.Invalid, pages.pte(l.address_limit, .{ .system = true }));
    const sys = try pages.pte(0x12345000, .{ .system = true, .write = true });
    try t.expectEqual(@as(u64, 0x0600000012345067), sys);
    try t.expectEqual(@as(u64, 0x220000001), try pages.pde(0x220000000, false));
    var flat = try pages.Flat.init(&flat_words, .{ .offset = 0x40000000, .bytes = 2 * 1024 * 1024 });
    try t.expectError(error.Sparse, flat.map(0x40001000, &.{ 0x5000, 0 }, .{ .system = true }));
    try t.expectEqual(@as(u64, 0), flat_words[1]);
    try flat.map(0x40001000, &.{ 0x5000, 0x9000 }, .{ .system = true, .write = true });
    try t.expectError(error.Busy, flat.map(0x40001000, &.{0x11000}, .{ .system = true }));
    try t.expectError(error.Sparse, flat.unmap(0x40000000, 3));
    try t.expectEqual(@as(usize, 2), flat.mapped_pages);
    try flat.unmap(0x40001000, 2);
    try t.expectEqual(@as(usize, 0), flat.mapped_pages);
    var vm: pages.Virtual = .{};
    try vm.init(&vm_words, 0x225000000);
    const va: u64 = 0x7fff_ffff_e000;
    try vm.map(va, &.{ 0x222000000, 0x222001000 }, .{ .system = false, .write = true });
    try t.expectEqual(@as(u64, 0x222000000), (try vm.lookup(va)) & pages.physical_mask);
    try t.expectEqual(@as(u64, 0), (try vm.lookup(va)) & 6);
    try t.expectError(error.Invalid, vm.map(l.address_limit - 4096, &.{ 0x5000, 0x6000 }, .{ .system = true }));
    try vm.unmap(va, 2);
    try t.expectEqual(@as(u64, 0), try vm.lookup(va));
    hw = .{};
    hw.words[r.gfx.MC_VM_AGP_BASE / 4] = 0x1234;
    hw.words[r.mm.VM_CONTEXT1_PAGE_TABLE_BASE_ADDR_LO32 / 4] = 0x4567;
    hw.words[r.at.ATC_VMID0_PASID_MAPPING / 4] = 0x89;
    var controller: hubs.Controller = .{};
    var map = try plan();
    const root = try pages.pde(try map.physicalAddress(map.contexts.span), false);
    const scratch = try map.physicalAddress(.{ .offset = map.contexts.span.end() - 4096, .bytes = 4096 });
    const gate: hubs.Gate = .{ .memory_epoch = 23, .boot_held = true, .engines_quiesced = true };
    try t.expectError(error.Unconfirmed, controller.enable(&hw, &map, root, scratch, .{ .memory_epoch = 23, .boot_held = false, .engines_quiesced = true }));
    try t.expectEqual(@as(usize, 0), hw.writes);
    try controller.enable(&hw, &map, root, scratch, gate);
    try t.expect(controller.enabled and controller.touched);
    try t.expectEqual(@as(u32, @truncate(root)), hw.words[r.mm.VM_CONTEXT1_PAGE_TABLE_BASE_ADDR_LO32 / 4]);
    try t.expectEqual(@as(u32, 0), hw.words[(r.gfx.VM_CONTEXT0_CNTL + 8) / 4]);
    hw.missing_ack = true;
    try t.expectError(error.Deadline, controller.disable(&hw, gate));
    try t.expect(controller.touched and !controller.enabled);
    hw.missing_ack = false;
    try controller.disable(&hw, gate);
    try t.expect(!controller.touched);
    try t.expectEqual(@as(u32, 0x1234), hw.words[r.gfx.MC_VM_AGP_BASE / 4]);
    try t.expectEqual(@as(u32, 0x4567), hw.words[r.mm.VM_CONTEXT1_PAGE_TABLE_BASE_ADDR_LO32 / 4]);
    try t.expectEqual(@as(u32, 0x89), hw.words[r.at.ATC_VMID0_PASID_MAPPING / 4]);
    // Failure before the first enable write still requires stop to preserve
    // every BIOS register which only the shutdown path subsequently touches.
    hw = .{};
    hw.words[r.gfx.VM_CONTEXT0_CNTL / 4] = 0x01234567;
    hw.words[r.mm.VM_L2_CNTL3 / 4] = 0x76543210;
    controller = .{ .epoch = 23, .touched = true };
    try controller.disable(&hw, gate);
    try t.expectEqual(@as(u32, 0x01234567), hw.words[r.gfx.VM_CONTEXT0_CNTL / 4]);
    try t.expectEqual(@as(u32, 0x76543210), hw.words[r.mm.VM_L2_CNTL3 / 4]);
    hw = .{};
    hw.backward = true;
    try t.expectError(error.Deadline, hubs.flush(&hw, 1));
    hw = .{};
    hw.disconnected = true;
    try t.expectError(error.Disconnected, hubs.flush(&hw, 0));
}
const F = struct {
    var api: a.DriverApi = undefined;
    var owner: Owner = .{};
    var layout: l.Layout = undefined;
    var regs: [r.required_prefix / 4]u32 align(4096) = undefined;
    var table: [l.table_bytes / 8]u64 align(4096) = undefined;
    var contexts: [l.context_bytes / 8]u64 align(4096) = undefined;
    var heap_slots: [64]?[]align(16) u8 = @splat(null);
    var heap_fail = false;
    var heap_release_fail = false;
    var render_data: [65536]u8 align(4096) = undefined;
    var frame_data: [65536]u8 align(4096) = undefined;
    var cpu: [8192]u8 align(4096) = undefined;
    var cpu_live = false;
    var shared = false;
    var dma = false;
    var gpu = false;
    var descriptor: a.GfxBufferDescriptor = .{};
    var native: a.GfxBufferDescriptor = .{};
    var ticket: a.GfxOwnedBufferReservation = .{};
    var native_refs: usize = 0;
    var committed = false;
    var claimed = false;
    var release_fail = false;
    var map_fail = false;
    var segment_hole = false;
    var segment_duplicate = false;
    var span_fail = false;
    var windows: usize = 0;
    var charged: u64 = 0;
    var closed = false;
    fn reset() void {
        for (&heap_slots) |*slot| std.debug.assert(slot.* == null);
        heap_fail = false; heap_release_fail = false;
        owner = .{};
        layout = plan() catch unreachable;
        regs = @splat(0);
        cpu = @splat(0xff);
        cpu_live = false;
        shared = false;
        dma = false;
        gpu = false;
        ticket = .{};
        native_refs = 0;
        committed = false;
        claimed = false;
        release_fail = false;
        map_fail = false;
        segment_hole = false;
        segment_duplicate = false;
        span_fail = false;
        windows = 0;
        charged = 0;
        closed = false;
        api = undefined;
        api.magic = a.driver_magic;
        api.version = a.driver_api_version;
        api.size = @sizeOf(a.DriverApi);
        api.gfx_memory_query = query;
        api.resource_query = resources;
        api.heap_query = heapQuery;
    }
    fn heapQuery(out: *a.DriverHeapApi) callconv(.c) i32 {
        out.* = .{ .allocate = @intFromPtr(&heapAllocate), .release = @intFromPtr(&heapRelease) };
        return a.driver_heap_ok;
    }
    fn heapAllocate(bytes: u64, alignment: u32, out: *a.DriverHeapAllocation) callconv(.c) i32 {
        if (heap_fail or alignment != 16) return a.err_no_fn;
        for (&heap_slots, 0..) |*slot, i| if (slot.* == null) {
            const data = t.allocator.alignedAlloc(u8, .@"16", @intCast(bytes)) catch return a.err_no_fn;
            slot.* = data;
            out.* = .{ .handle = i + 1, .cpu_address = @intFromPtr(data.ptr), .byte_length = bytes, .alignment = 16 };
            return a.driver_heap_ok;
        };
        return a.err_no_fn;
    }
    fn heapRelease(handle: u64) callconv(.c) i32 {
        if (heap_release_fail) return a.err_no_fn;
        const slot = &heap_slots[handle - 1];
        t.allocator.free(slot.*.?); slot.* = null;
        return a.driver_heap_ok;
    }
    fn query(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        out.* = .{ .reserved_span = @intFromPtr(&reserved), .mmio_map = @intFromPtr(&mapWindow), .mmio_unmap = @intFromPtr(&unmapWindow), .collect = @intFromPtr(&collect), .memory_budget = @intFromPtr(&budget), .device_lost = @intFromPtr(&lost), .buffer_create = @intFromPtr(&create), .buffer_import = @intFromPtr(&import), .buffer_describe = @intFromPtr(&describe), .buffer_map = @intFromPtr(&mapCpu), .buffer_unmap = @intFromPtr(&unmapCpu), .buffer_release = @intFromPtr(&release), .device_acquire = @intFromPtr(&acquire), .device_segment = @intFromPtr(&segment), .device_release = @intFromPtr(&deviceRelease), .buffer_reserve = @intFromPtr(&reserve), .buffer_commit = @intFromPtr(&commit), .buffer_abort = @intFromPtr(&abort), .buffer_take_release = @intFromPtr(&take), .buffer_finish_release = @intFromPtr(&finish) };
        return 1;
    }
    fn resources(out: *a.DriverResourceApi) callconv(.c) i32 {
        out.* = .{ .now_ns = @intFromPtr(&now) };
        return 0;
    }
    fn now() callconv(.c) u64 {
        return 1000;
    }
    fn reserved(base: u64, bytes: u64) callconv(.c) i32 {
        return if (!span_fail and base == layout.physical.offset and bytes == layout.physical.bytes) 1 else -6;
    }
    fn mapWindow(req: *const a.GfxMmioRequest, out: *a.GfxMmioWindow) callconv(.c) i32 {
        if (map_fail) return -6;
        const address: usize = if (req.resource_base == 0xf0000000) @intFromPtr(&regs) else if (req.byte_offset == layout.tables.span.offset) @intFromPtr(&table) else if (req.byte_offset == layout.render.span.offset) @intFromPtr(&render_data) else if (req.byte_offset == layout.contexts.span.offset) @intFromPtr(&contexts) else @intFromPtr(&frame_data);
        windows += 1;
        out.* = .{ .handle = .{ .id = @intCast(windows), .generation = 19 }, .cpu_address = address, .physical_address = req.resource_base + req.byte_offset, .byte_length = req.byte_length, .cache_policy = req.cache_policy };
        return 1;
    }
    fn unmapWindow(_: *const a.GfxBufferHandle, quiesced: u32) callconv(.c) i32 {
        std.debug.assert(quiesced == 1 and windows != 0);
        if (release_fail) return -4;
        windows -= 1;
        return 1;
    }
    fn collect() callconv(.c) i32 {
        return if (release_fail) -4 else 1;
    }
    fn budget(req: *const a.GfxDeviceBudgetRequest, out: *a.GfxDeviceBudgetState) callconv(.c) i32 {
        std.debug.assert(req.memory_generation == 23 and req.adapter_id == 7 and req.limit_bytes == layout.native_budget);
        out.* = .{ .adapter_id = 7, .memory_generation = 23, .limit_bytes = req.limit_bytes, .charged_bytes = charged, .shared_limit_bytes = 64 * 1024 * 1024, .shared_charged_bytes = 0, .shared_producer_limit_bytes = 32 * 1024 * 1024 };
        return 1;
    }
    fn lost(adapter: u32, epoch: u64, quiesced: u32) callconv(.c) i32 {
        std.debug.assert(adapter == 7 and epoch == 23 and quiesced == 1);
        closed = true;
        return 1;
    }
    fn create(desc: *const a.GfxBufferDescriptor, out: *a.GfxBufferReference) callconv(.c) i32 {
        std.debug.assert(!shared and desc.byte_length == cpu.len);
        shared = true;
        descriptor = desc.*;
        out.* = .{ .buffer = .{ .id = 1, .generation = 19 }, .reference = .{ .id = 2, .generation = 19 } };
        return 1;
    }
    fn import(ref: *const a.GfxBufferHandle, out: *a.GfxBufferReference) callconv(.c) i32 {
        if (ref.id == 1 and shared) {
            out.* = .{ .buffer = .{ .id = 1, .generation = 19 }, .reference = .{ .id = 2, .generation = 19 } };
            return 1;
        }
        std.debug.assert(ref.id == 101 and committed);
        native_refs += 1;
        out.* = .{ .buffer = ticket.buffer, .reference = .{ .id = 102, .generation = 19 } };
        return 1;
    }
    fn describe(ref: *const a.GfxBufferHandle, out: *a.GfxBufferDescriptor) callconv(.c) i32 {
        out.* = if (ref.id >= 100) native else descriptor;
        return 1;
    }
    fn mapCpu(_: *const a.GfxBufferHandle, access: u32, offset: u64, bytes: u64, out: *a.GfxBufferMap) callconv(.c) i32 {
        std.debug.assert(shared and !dma and !gpu and access == a.gfx_buffer_map_write and offset == 0 and bytes == cpu.len);
        cpu_live = true;
        out.* = .{ .lease = .{ .id = 3, .generation = 19 }, .cpu_address = @intFromPtr(&cpu), .byte_length = cpu.len, .cache_policy = a.gfx_buffer_cache_write_back };
        return 1;
    }
    fn unmapCpu(_: *const a.GfxBufferHandle) callconv(.c) i32 {
        if (release_fail) return -4;
        cpu_live = false;
        return 1;
    }
    fn release(ref: *const a.GfxBufferHandle) callconv(.c) i32 {
        if (release_fail) return -4;
        if (ref.id >= 100) {
            std.debug.assert(native_refs > 0);
            native_refs -= 1;
        } else {
            std.debug.assert(!dma and !gpu and !cpu_live);
            shared = false;
        }
        return 1;
    }
    fn acquire(_: *const a.GfxBufferHandle, req: *const a.GfxDeviceRequest, out: *a.GfxDeviceLease) callconv(.c) i32 {
        std.debug.assert(!cpu_live and req.adapter_id == 7 and req.device_generation == 23);
        if (req.access == 4) {
            std.debug.assert(!dma);
            dma = true;
        } else {
            std.debug.assert(!gpu and req.access == 3);
            gpu = true;
        }
        out.* = .{ .lease = .{ .id = 10 + req.access, .generation = 19 }, .byte_length = req.byte_length, .gpu_virtual_address = req.gpu_virtual_address, .adapter_id = req.adapter_id, .driver_owner = 9, .device_generation = req.device_generation, .access = req.access, .address_space = req.address_space, .dma_mask = req.dma_mask };
        return 1;
    }
    fn segment(_: *const a.GfxDeviceLease, offset: u64, out: *a.GfxDmaSegment) callconv(.c) i32 {
        std.debug.assert(dma and offset < descriptor.byte_length);
        out.* = .{ .dma_address = if (segment_hole and offset != 0) 0 else 0x1000000 + (if (segment_duplicate) 0 else offset * 3), .byte_length = 4096, .next_offset = offset + 4096 };
        return 1;
    }
    fn deviceRelease(lease: *const a.GfxDeviceLease, q: u32) callconv(.c) i32 {
        std.debug.assert(q == 1);
        if (release_fail) return -4;
        if (lease.access == 3) {
            std.debug.assert(gpu);
            gpu = false;
        } else {
            std.debug.assert(dma and !gpu);
            dma = false;
        }
        return 1;
    }
    fn reserve(desc: *const a.GfxBufferDescriptor, cookie: u64, out: *a.GfxOwnedBufferReservation) callconv(.c) i32 {
        std.debug.assert(ticket.cookie == 0);
        native = desc.*;
        native.driver_owner = 9;
        charged = desc.byte_length;
        ticket = .{ .buffer = .{ .id = 100, .generation = 19 }, .reference = .{ .id = 101, .generation = 19 }, .allocation_bytes = desc.byte_length, .cookie = cookie, .device_generation = 23, .driver_generation = 31, .adapter_id = 7, .driver_owner = 9 };
        out.* = ticket;
        return 1;
    }
    fn commit(_: *const a.GfxOwnedBufferReservation, out: *a.GfxBufferReference) callconv(.c) i32 {
        committed = true;
        native_refs = 1;
        out.* = .{ .buffer = ticket.buffer, .reference = ticket.reference };
        return 1;
    }
    fn abort(_: *const a.GfxOwnedBufferReservation, _: u32) callconv(.c) i32 {
        if (release_fail) return -4;
        ticket = .{};
        charged = 0;
        return 1;
    }
    fn take(_: u32, _: u64, out: *a.GfxOwnedBufferRelease) callconv(.c) i32 {
        if (!committed or native_refs != 0 or gpu or claimed) return a.gfx_buffer_error_busy;
        claimed = true;
        out.* = .{ .buffer = ticket.buffer, .cookie = ticket.cookie, .byte_length = ticket.allocation_bytes, .attempt = 17, .device_generation = 23, .driver_generation = 31, .adapter_id = 7, .driver_owner = 9 };
        return 1;
    }
    fn finish(_: *const a.GfxOwnedBufferRelease, _: u32) callconv(.c) i32 {
        if (release_fail) return -4;
        committed = false;
        claimed = false;
        ticket = .{};
        charged = 0;
        return 1;
    }
    fn prepare() !void {
        const ctx = r4os.r4dev.DriverContext.init(&api);
        try owner.prepare(&ctx, &layout, 0xf0000000, 7, 23);
    }
};

// Reuse the canonical memory facade fixture above. RAM register/fence writes
// are explicit test stimuli, never evidence of a physical GPU rendering.
const Render = struct {
    const renderer = @import("render_jobs.zig");
    const amd = @import("r4amd");
    const storage = @import("queue_storage.zig");
    var owner: renderer.Owner = .{};
    var contexts: @import("gc_contexts.zig").Owner = .{};
    var rt: @import("queue_runtime.zig").Owner = .{};
    var engine: @import("gc_engine.zig").Owner = .{};
    var data: [storage.bytes / 4]u32 align(4096) = undefined;
    var bells: [1024]u32 align(4096) = undefined;
    var allocation_pending = false;
    var virtual_pending = false;
    var virtual_job: a.GfxVirtualJob = .{};
    var virtual_done: a.GfxVirtualCompletion = .{};
    var virtual_ack_fail = false;
    var complete_fail = false;
    var completed: u32 = 0;
    var allocation_ack: u32 = 0;
    var raw_mode = false;
    var native_binding: a.GfxNativeBinding = .{};
    var native_packet: extern struct { header: amd.R4AmdNativeSubmit, ib: amd.R4AmdNativeIb } = undefined;
    var native_fail = false;
    var native_result: u32 = a.gfx_queue_result_complete;
    var native_registered = false;
    var virtual_registered = false;
    const binding: a.GfxBackendBinding = .{ .adapter_id = 7, .device_generation = 11, .reset_generation = 5 };
    const fence: a.GfxFence = .{ .adapter_id = 7, .device_generation = 11, .reset_generation = 5, .timeline = 3, .point = 1, .slot = 0 };
    fn registerNative(input: *const a.GfxNativeProvider, out: *a.GfxBufferHandle) callconv(.c) i32 {
        std.debug.assert(input.adapter_id == 7 and input.memory_generation == 23 and !native_registered);
        native_registered = true;
        out.* = .{ .id = 200, .generation = 31 };
        return 1;
    }
    fn registerVirtual(input: *const a.GfxNativeProvider, out: *a.GfxBufferHandle) callconv(.c) i32 {
        std.debug.assert(input.adapter_id == 7 and input.memory_generation == 23 and !virtual_registered);
        virtual_registered = true;
        out.* = .{ .id = 201, .generation = 31 };
        return 1;
    }
    fn unregisterNative(_: *const a.GfxBufferHandle) callconv(.c) i32 {
        std.debug.assert(!allocation_pending);
        native_registered = false;
        return 1;
    }
    fn unregisterVirtual(_: *const a.GfxBufferHandle) callconv(.c) i32 {
        std.debug.assert(!virtual_pending and !F.gpu);
        virtual_registered = false;
        return 1;
    }
    fn takeNative(_: *const a.GfxBufferHandle, out: *a.GfxNativeJob) callconv(.c) i32 {
        if (!allocation_pending) return a.gfx_buffer_error_busy;
        allocation_pending = false;
        out.* = .{ .request = .{ .id = 299, .generation = 31 }, .allocation = .{ .adapter_id = 7, .memory_generation = 23, .kind = 1, .width = 256, .height = 128, .format = a.gfx_buffer_format_argb8888, .usage = 28, .deadline_ns = 1_000_000 } };
        return 1;
    }
    fn completeNative(_: *const a.GfxBufferHandle, _: *const a.GfxBufferHandle, result: i32, reference: *const a.GfxBufferHandle) callconv(.c) i32 {
        std.debug.assert(result == 1 and reference.id == 101 and F.native_refs == 1);
        F.native_refs += 1;
        allocation_ack += 1;
        return 1;
    }
    fn takeVirtual(_: *const a.GfxBufferHandle, out: *a.GfxVirtualJob) callconv(.c) i32 {
        if (!virtual_pending) return a.gfx_buffer_error_busy;
        virtual_pending = false;
        out.* = virtual_job;
        return 1;
    }
    fn completeVirtual(_: *const a.GfxBufferHandle, input: *const a.GfxVirtualCompletion) callconv(.c) i32 {
        if (input.result != 1) std.debug.assert(input.address == 0 and std.meta.eql(input.token, a.GfxVirtualToken{}));
        if (virtual_ack_fail) return a.gfx_buffer_error_busy;
        virtual_done = input.*;
        return 1;
    }
    fn retain(exact: *const a.GfxFence, side: u32, out: *a.GfxBufferReference) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(exact.*, fence) and side == 1 and F.committed);
        F.native_refs += 1;
        out.* = .{ .buffer = F.ticket.buffer, .reference = .{ .id = 105, .generation = 19 }, .flags = a.gfx_buffer_reference_mapping_only };
        return 1;
    }
    fn complete(exact: *const a.GfxFence, result: u32, quiet: u32) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(exact.*, fence) and result == native_result and quiet == 1 and
            (if (raw_mode) F.gpu and F.native_refs == 2 else !F.gpu and F.native_refs == 1));
        if (complete_fail) return a.gfx_queue_error_busy;
        completed += 1;
        return 1;
    }
    fn nativeInfo(exact: *const a.GfxFence, out: *a.GfxNativeJobInfo) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(exact.*, fence) and raw_mode);
        out.* = .{ .interface_id_lo = amd.backend_v1_header.interface_id_lo, .interface_id_hi = amd.backend_v1_header.interface_id_hi,
            .revision = 1, .command_bytes = @sizeOf(@TypeOf(native_packet)), .resource_count = 1 };
        return 1;
    }
    fn nativeData(exact: *const a.GfxFence, offset: u32, output: [*]u8, length: u32) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(exact.*, fence) and raw_mode);
        const bytes = std.mem.asBytes(&native_packet);
        if (native_fail or offset > bytes.len or length > bytes.len - offset) return -1;
        @memcpy(output[0..length], bytes[offset..][0..length]);
        return 1;
    }
    fn nativeBinding(exact: *const a.GfxFence, index: u32, output: *a.GfxNativeBinding) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(exact.*, fence) and raw_mode and index == 0);
        output.* = native_binding;
        return 1;
    }
    fn checkPm4() !void {
        for (0..2) |kind| {
            try reset();
            raw_mode = true;
            rt.queue.?.table.size = @sizeOf(a.GfxDriverQueueApi);
            rt.queue.?.table.read_native_info = @intFromPtr(&nativeInfo);
            rt.queue.?.table.read_native_data = @intFromPtr(&nativeData);
            rt.queue.?.table.read_native_binding = @intFromPtr(&nativeBinding);
            engine.rings[1] = try @import("queue_ring.zig").Ring.init(try rt.arena.words32(storage.ringOffset(.compute), storage.ring_bytes), 8, 0);
            allocation_pending = true;
            try t.expect(owner.allocations.step());
            virtual_job = .{ .resource = .{ .id = 300, .generation = 31 }, .request = .{ .kind = 1, .adapter_id = 7,
                .memory_generation = 23, .byte_length = 131072, .alignment = 4096, .deadline_ns = 1_000_000, .location = 1 } };
            virtual_pending = true; try t.expect(owner.virtual.step());
            const range = virtual_done;
            virtual_job = .{ .resource = .{ .id = 301, .generation = 31 }, .request = .{ .kind = 2, .adapter_id = 7,
                .memory_generation = 23, .parent = range.resource, .reference = .{ .id = 101, .generation = 19 }, .byte_length = 131072,
                .deadline_ns = 1_000_000 }, .parent_token = range.token,
                .reference = .{ .buffer = F.ticket.buffer, .reference = .{ .id = 101, .generation = 19 } } };
            virtual_pending = true; try t.expect(owner.virtual.step());
            const bound = virtual_done;
            native_binding = .{ .binding = bound.resource, .token = bound.token, .address = bound.address, .byte_length = 131072, .access = 1 };
            try t.expect((try F.owner.virtual.lookup(bound.address)) & 16 != 0); // Executable PTE for actual IB/shader fetch.
            native_packet = std.mem.zeroes(@TypeOf(native_packet));
            native_packet.header = .{ .version = 1, .size = @sizeOf(amd.R4AmdNativeSubmit), .engine = @intCast(kind), .ib_count = 1, .flags = 0, .reserved0 = 0, .reserved1 = 0 };
            native_packet.ib = .{ .address = bound.address, .dwords = 8, .binding_index = 0 };
            const job: a.GfxDriverJob = .{ .operation = a.gfx_queue_operation_native, .fence = fence, .deadline_ns = 1_000_000 };
            native_fail = true; native_result = a.gfx_queue_result_failed;
            owner.accept(job); try t.expect(owner.collect());
            try t.expect(!contexts.contains(fence) and completed == 1);
            native_fail = false; native_binding.token.opaque0 += 1;
            owner.accept(job); try t.expect(owner.collect());
            try t.expect(!contexts.contains(fence) and completed == 2);
            native_binding.token.opaque0 -= 1; native_result = a.gfx_queue_result_complete;
            owner.accept(job);
            try t.expect(contexts.contains(fence));
            contexts.step(&rt, &engine);
            try t.expectEqual(@import("queue_timeline.zig").Phase.submitted, rt.timeline.entries[0].phase);
            const token = rt.timeline.entries[0].token;
            virtual_job.operation = 1; virtual_job.token = bound.token; virtual_pending = true;
            try t.expect(!owner.virtual.step());
            (try rt.arena.fences())[0] = token + 1;
            rt.timeline.poll(1000); _ = rt.timeline.publish(rt.queue.?);
            try t.expect(!owner.virtual.step() and completed == 2);
            (try rt.arena.fences())[0] = token;
            rt.timeline.poll(1000); try t.expect(rt.timeline.publish(rt.queue.?));
            try t.expect(contexts.collect(&rt)); try t.expect(owner.collect());
            try t.expect(completed == 3 and F.gpu);
            try t.expect(owner.virtual.step());
            virtual_job = .{ .resource = range.resource, .operation = 1, .request = .{ .kind = 1 }, .token = range.token };
            virtual_pending = true; try t.expect(owner.virtual.step());
            try t.expect(owner.close());
            try t.expectEqual(@as(i32, 1), F.release(&.{ .id = 101, .generation = 19 }));
            try t.expect(F.owner.collect());
            try t.expect(F.owner.close(.{ .memory_epoch = 23, .boot_held = true, .engines_quiesced = true }));
        }
    }
    fn reset() !void {
        owner = .{};
        contexts = .{};
        rt = .{};
        engine = .{};
        data = @splat(0);
        bells = @splat(0);
        completed = 0;
        allocation_ack = 0;
        allocation_pending = false;
        virtual_pending = false;
        virtual_job = .{};
        virtual_done = .{};
        virtual_ack_fail = false;
        complete_fail = false;
        raw_mode = false; native_binding = .{}; native_fail = false; native_result = a.gfx_queue_result_complete;
        native_registered = false;
        virtual_registered = false;
        F.reset();
        try F.prepare();
        F.regs[r.gfx.VM_INVALIDATE_ENG17_ACK / 4] = 3;
        F.regs[r.mm.VM_INVALIDATE_ENG17_ACK / 4] = 3;
        try F.owner.enable(.{ .memory_epoch = 23, .boot_held = true, .engines_quiesced = true });
        const table = &F.owner.memory.?.table;
        table.native_register = @intFromPtr(&registerNative);
        table.native_unregister = @intFromPtr(&unregisterNative);
        table.native_take = @intFromPtr(&takeNative);
        table.native_complete = @intFromPtr(&completeNative);
        table.virtual_register = @intFromPtr(&registerVirtual);
        table.virtual_unregister = @intFromPtr(&unregisterVirtual);
        table.virtual_take = @intFromPtr(&takeVirtual);
        table.virtual_complete = @intFromPtr(&completeVirtual);
        rt = .{ .self_address = @intFromPtr(&rt), .prepared = true, .memory = &F.owner, .queue = .{ .table = .{ .retain_resource = @intFromPtr(&retain), .complete = @intFromPtr(&complete) } } };
        rt.arena = .{ .self_address = @intFromPtr(&rt.arena), .memory = &F.owner, .epoch = 23, .gpu = 0x120000000, .ready = true, .arena = .{ .value = .{ .handle = .{ .id = 30, .generation = 31 }, .cpu_address = @intFromPtr(&data), .byte_length = storage.bytes } }, .doorbell = .{ .value = .{ .handle = .{ .id = 31, .generation = 31 }, .cpu_address = @intFromPtr(&bells), .byte_length = 4096 } } };
        try rt.timeline.init(binding, try rt.arena.fences(), 1000);
        try contexts.init(rt.timeline.epoch);
        engine.phase = .ready;
        engine.rings[0] = try @import("queue_ring.zig").Ring.init(try rt.arena.words32(storage.ringOffset(.gfx), storage.ring_bytes), 8, 0);
        const arch: amd.R4AmdArchitecture = .{ .version = 1, .size = @sizeOf(amd.R4AmdArchitecture), .vendor_id = amd.vendor_id, .device_id = 0x15d8, .gc_version = amd.gc_9_1_0, .sdma_version = amd.sdma_4_1_0, .gb_addr_config = 0x24000042, .chip_revision = 0x41, .bind_alignment = 4096, .memory_generation = 23, .flags = 0, .reserved = 0, .max_image_bytes = 64 * 1024 * 1024 };
        try owner.prepare(&F.owner, &rt, &contexts, arch);
    }
};

test "AMD renderer crosses real allocation mapping PM4 timeline and canonical retirement facades" {
    const R = Render;
    try R.checkPm4();
    try R.reset();
    try t.expect(R.owner.ready and F.windows == 4 and F.owner.mapping_users == 1);
    try t.expect(F.layout.pool.owns(F.layout.render) and !F.layout.render.span.overlaps(F.layout.contexts.span));
    R.allocation_pending = true;
    try t.expect(R.owner.allocations.step());
    try t.expect(R.allocation_ack == 1 and F.native_refs == 1 and F.native.plane_pitches[0] == 1024 and F.charged == 131072);
    const job: a.GfxDriverJob = .{ .fence = R.fence, .operation = a.gfx_queue_operation_render, .target_buffer = F.ticket.buffer, .deadline_ns = 1_000_000, .render = .{ .target_rect = .{ .width = 256, .height = 128 }, .scissor = .{ .width = 256, .height = 128 }, .color = 0xff112233, .opacity = 255 } };
    R.owner.accept(job);
    try t.expect(R.contexts.contains(R.fence) and F.gpu and F.native_refs == 2);
    const address = @import("render_jobs.zig").resource_va + 0x08000000;
    try t.expect((try F.owner.virtual.lookup(address)) != 0);
    R.contexts.step(&R.rt, &R.engine);
    try t.expect(R.rt.timeline.entries[0].phase == .submitted);
    var copied: [2048]u32 = undefined;
    const emitted = R.contexts.jobs[0].count;
    for ((try R.rt.arena.ib(0))[0..emitted],copied[0..emitted]) |word,*dest| dest.* = word;
    try @import("r4amd_pm4").packetBoundaries(copied[0..emitted]);
    const token = R.rt.timeline.entries[0].token;
    const fences = try R.rt.arena.fences();
    fences[0] = token + 9;
    R.rt.timeline.poll(1000);
    _ = R.rt.timeline.publish(R.rt.queue.?);
    try t.expect(F.gpu and F.native_refs == 2 and R.completed == 0);
    fences[0] = token;
    F.release_fail = true;
    R.rt.timeline.poll(1000);
    try t.expect(!R.rt.timeline.publish(R.rt.queue.?));
    try t.expect(F.gpu and F.native_refs == 2 and R.completed == 0);
    F.release_fail = false;
    R.complete_fail = true;
    try t.expect(!R.rt.timeline.publish(R.rt.queue.?));
    try t.expect(!F.gpu and F.native_refs == 1 and R.contexts.contains(R.fence));
    R.complete_fail = false;
    try t.expect(R.rt.timeline.publish(R.rt.queue.?));
    try t.expect(R.contexts.collect(&R.rt));
    try t.expect(R.owner.collect());
    try t.expectEqual(@as(u32, 1), R.completed);
    try t.expectEqual(@as(u64, 0), try F.owner.virtual.lookup(address));
    // A failed range acknowledgement retains the original serial and address.
    R.virtual_job = .{ .resource = .{ .id = 300, .generation = 31 }, .request = .{ .kind = 1, .adapter_id = 7, .memory_generation = 23, .byte_length = 131072, .alignment = 65536, .deadline_ns = 1_000_000, .location = 1 } };
    R.virtual_pending = true;
    R.virtual_ack_fail = true;
    try t.expect(!R.owner.virtual.step());
    const serial = R.owner.virtual.serial;
    R.virtual_ack_fail = false;
    try t.expect(R.owner.virtual.step());
    try t.expectEqual(serial, R.owner.virtual.serial);
    const range = R.virtual_done;
    R.virtual_job = .{ .resource = .{ .id = 301, .generation = 31 }, .request = .{ .kind = 2, .adapter_id = 7, .memory_generation = 23, .parent = range.resource, .reference = .{ .id = 101, .generation = 19 }, .byte_length = 131072, .deadline_ns = 1_000_000 }, .parent_token = range.token, .reference = .{ .buffer = F.ticket.buffer, .reference = .{ .id = 101, .generation = 19 } } };
    F.heap_fail = true;
    R.virtual_pending = true;
    try t.expect(R.owner.virtual.step());
    try t.expectEqual(a.gfx_buffer_error_oom, R.virtual_done.result);
    try t.expect(!F.gpu and F.native_refs == 1);
    F.heap_fail = false;
    R.virtual_pending = true;
    try t.expect(R.owner.virtual.step());
    const bound = R.virtual_done;
    try t.expect(F.gpu and F.native_refs == 2);
    const snapshot: a.GfxNativeBinding = .{ .binding = bound.resource, .token = bound.token, .address = bound.address, .byte_length = 131072, .access = 1 };
    const part = try R.owner.virtual.execution(snapshot);
    try part.map.retain(R.fence);
    var stale = snapshot;
    stale.token.opaque0 += 1;
    try t.expectError(error.Stale, R.owner.virtual.execution(stale));
    R.virtual_job.operation = 1;
    R.virtual_job.token = bound.token;
    R.virtual_pending = true;
    try t.expect(!R.owner.virtual.step());
    try t.expect(F.gpu and F.native_refs == 2);
    try part.map.complete(R.fence);
    F.release_fail = true;
    try t.expect(!R.owner.virtual.step());
    F.release_fail = false;
    F.heap_release_fail = true;
    try t.expect(!R.owner.virtual.step());
    try t.expect(!F.gpu and F.native_refs == 1);
    F.heap_release_fail = false;
    try t.expect(R.owner.virtual.step());
    try t.expect(!F.gpu and F.native_refs == 1);
    R.virtual_job = .{ .resource = range.resource, .operation = 1, .request = .{ .kind = 1 }, .token = range.token };
    R.virtual_pending = true;
    try t.expect(R.owner.virtual.step());
    try t.expect(R.owner.close());
    try t.expect(!R.native_registered and !R.virtual_registered and F.owner.mapping_users == 0);
    try t.expectEqual(@as(i32, 1), F.release(&.{ .id = 101, .generation = 19 }));
    try t.expect(F.owner.collect());
    try t.expectEqual(@as(u64, 0), F.charged);
    try t.expect(F.owner.close(.{ .memory_epoch = 23, .boot_held = true, .engines_quiesced = true }));
    try t.expectEqual(@as(usize, 0), F.windows);
}

test "AMD actual memory facades retain SG/UMA backing until fence and both TLB acknowledgements" {
    try DisplayBuffers.check();
    F.reset();
    try F.prepare();
    try t.expectEqual(@as(usize, 3), F.windows);
    const gate: hubs.Gate = .{ .memory_epoch = 23, .boot_held = true, .engines_quiesced = true };
    // Real register facade over a RAM register fixture; no physical GPU.
    try t.expectError(error.Deadline, F.owner.enable(gate));
    try t.expect(F.owner.controller.touched and !F.owner.controller.enabled);
    F.regs[r.gfx.VM_INVALIDATE_ENG17_ACK / 4] = 3;
    F.regs[r.mm.VM_INVALIDATE_ENG17_ACK / 4] = 3;
    try t.expect(F.owner.close(gate));
    F.reset();
    try F.prepare();
    F.regs[r.gfx.VM_INVALIDATE_ENG17_ACK / 4] = 3;
    F.regs[r.mm.VM_INVALIDATE_ENG17_ACK / 4] = 3;
    try F.owner.enable(gate);
    var mapping: Mapping = .{};
    var physical: [2]u64 = undefined;
    try mapping.prepare(&F.owner, null, F.layout.gart.offset + 4096, 8192, 0, &physical);
    try t.expect(physical[0] != @intFromPtr(&F.cpu) and physical[1] != physical[0] + 4096 and !F.cpu_live);
    try t.expect(std.mem.allEqual(u8, &F.cpu, 0));
    hw = .{};
    try mapping.publish(&F.owner.gart.?, &hw, true, false);
    const fence: a.GfxFence = .{ .adapter_id = 7, .timeline = 99, .point = 3, .device_generation = 11, .reset_generation = 5 };
    try mapping.retain(fence);
    try t.expect(!mapping.close(&F.owner.gart.?, &hw));
    try t.expect(F.dma and F.gpu);
    var stale = fence;
    stale.device_generation += 1;
    try t.expectError(error.Stale, mapping.complete(stale));
    try mapping.complete(fence);
    hw.missing_ack = true;
    try t.expect(!mapping.close(&F.owner.gart.?, &hw));
    try t.expect(F.dma and F.gpu and mapping.flush_pending and !mapping.translated);
    try t.expect(!F.owner.close(gate));
    hw.missing_ack = false;
    F.release_fail = true;
    try t.expect(!mapping.close(&F.owner.gart.?, &hw));
    try t.expect(F.dma and F.gpu);
    F.release_fail = false;
    try t.expect(mapping.close(&F.owner.gart.?, &hw));
    try t.expect(!F.shared and !F.dma and !F.gpu);
    try t.expectError(error.Invalid, F.owner.create(.{ .byte_length = 8191, .usage = 12, .location = a.gfx_buffer_location_device_local, .adapter_id = 7, .device_generation = 23 }));
    const ref = try F.owner.create(.{ .byte_length = 8192, .usage = 12, .location = a.gfx_buffer_location_device_local, .adapter_id = 7, .device_generation = 23 });
    try mapping.prepareNative(&F.owner, ref.reference, 0x1000000000, &physical);
    try t.expect(physical[0] >= F.layout.physical.offset and physical[0] != F.layout.mc.offset);
    try mapping.publish(&F.owner.virtual, &hw, true, false);
    try t.expect(F.owner.drop(ref.reference));
    try t.expect(F.owner.collect());
    try t.expect(F.committed and F.charged == 8192);
    try t.expect(mapping.close(&F.owner.virtual, &hw));
    F.release_fail = true;
    try t.expect(!F.owner.collect());
    try t.expect(F.claimed and F.charged == 8192);
    F.release_fail = false;
    try t.expect(F.owner.collect());
    try t.expect(F.charged == 0 and !F.committed);
    try t.expect(F.owner.close(gate));
    try t.expect(F.closed and F.windows == 0);
    for (0..2) |i| {
        F.reset();
        try F.prepare();
        F.segment_hole = i == 0;
        F.segment_duplicate = i == 1;
        const result = mapping.prepare(&F.owner, null, F.layout.gart.offset + 4096, 8192, 0, &physical);
        if (i == 0) try t.expectError(error.Sparse, result) else try t.expectError(error.Invalid, result);
        try t.expect(!mapping.prepared);
        try t.expect(mapping.close(&F.owner.gart.?, &hw));
        try t.expect(F.owner.close(gate));
    }
    F.reset();
    F.span_fail = true;
    try t.expectError(error.Unsupported, F.prepare());
    try t.expect(F.windows == 0);
    F.reset();
    F.map_fail = true;
    try t.expectError(error.Unsupported, F.prepare());
    F.map_fail = false;
    try t.expect(F.owner.close(gate));
    var table: a.GfxDriverMemoryApi = .{ .size = 240, .reserved_span = @intFromPtr(&F.reserved) };
    var memory: r4os.driver_memory.Context = .{ .table = table };
    try t.expectEqual(a.err_no_fn, memory.reservedSpan(1, 1));
    table.size = 248;
    table.reserved_span = 0;
    memory.table = table;
    try t.expectEqual(a.err_no_fn, memory.reservedSpan(1, 1));
}

const DisplayBuffers = struct {
    const buffers = @import("display_buffers.zig");
    var image: buffers.Image = .{};
    fn check() !void {
        const gate: hubs.Gate = .{ .memory_epoch = 23, .boot_held = true, .engines_quiesced = true };
        F.reset(); try F.prepare();
        F.regs[r.gfx.VM_INVALIDATE_ENG17_ACK / 4] = 3; F.regs[r.mm.VM_INVALIDATE_ENG17_ACK / 4] = 3;
        try F.owner.enable(gate);
        const shape = try buffers.Shape.make(17, 17, false);
        try t.expect(shape.pitch == 256 and shape.bytes == 8192);
        const Present = @import("display_present.zig");
        const source_desc: a.GfxBufferDescriptor = .{ .width = 17, .height = 17, .format = a.gfx_buffer_format_xrgb8888, .plane_count = 1,
            .plane_pitches = .{68, 0, 0, 0}, .byte_length = 68 * 17, .usage = a.gfx_buffer_usage_transfer_source };
        var upload: a.GfxDriverJob = .{ .operation = a.gfx_queue_operation_upload, .source_offset = 68 * 4 + 12, .byte_length = 68 * 2 + 20 };
        const damage = try Present.Plan.make(upload, source_desc, shape);
        try t.expect(damage.preserve and damage.row_bytes == 20 and damage.rows == 3 and damage.target == 256 * 4 + 12);
        upload.source_offset = 64; upload.byte_length = 8;
        try t.expectError(error.Invalid, Present.Plan.make(upload, source_desc, shape));
        upload.source_offset = 0; upload.byte_length = 68 * 17;
        try t.expect(!(try Present.Plan.make(upload, source_desc, shape)).preserve);
        upload.operation = a.gfx_queue_operation_present; upload.row_count = 17; upload.source_pitch = 68; upload.byte_length = 68;
        try t.expect(!(try Present.Plan.make(upload, source_desc, shape)).preserve);

        try image.allocate(&F.owner, shape, 0);
        try t.expect(F.owner.engine_users == 1 and F.native_refs == 1 and F.charged == 8192);
        const snapshot: @import("boot_snapshot.zig").Snapshot = .{ .valid = true, .effects = true, .held_generation = 4,
            .boot = .{ .width = 17, .height = 17, .pitch = 72, .format = a.gfx_buffer_format_xrgb8888 },
            .read = .{ .lease = .{ .id = 20, .generation = 19 }, .cpu_address = @intFromPtr(&F.cpu), .byte_length = F.cpu.len } };
        try t.expect(try image.copyBoot(&snapshot));
        try t.expectEqual(@as(u8, 255), F.frame_data[16 * 256 + 67]);
        try t.expectEqual(@as(u8, 0), F.frame_data[16 * 256 + 68]);
        try t.expect(std.mem.allEqual(u8, F.frame_data[17 * 256 .. 8192], 0));
        F.release_fail = true;
        try t.expectError(error.Busy, image.publish());
        try t.expect(image.window.value.handle.id != 0 and image.map.self_address == 0);
        F.release_fail = false;
        try image.publish();
        try t.expect(F.native_refs == 2 and F.gpu and F.owner.mapping_users == 1);
        const frame = try image.scanout();
        try t.expectEqual(F.ticket.reference, frame.reference);
        try t.expectEqual(F.layout.mc.offset + (try F.owner.backing(F.ticket.buffer)).offset - F.layout.physical.offset, frame.address);
        try t.expect(!image.close(false));
        const fence: a.GfxFence = .{ .adapter_id = 7, .timeline = 99, .point = 3, .device_generation = 11, .reset_generation = 5 };
        try image.map.retain(fence);
        try t.expect(!image.close(true)); // Stopped scanout cannot retire a live SDMA transfer.
        try image.map.complete(fence);
        F.regs[r.mm.VM_INVALIDATE_ENG17_ACK / 4] = 0;
        try t.expect(!image.close(true));
        try t.expect(F.native_refs == 2 and F.gpu and F.charged == 8192);
        F.regs[r.mm.VM_INVALIDATE_ENG17_ACK / 4] = 3;
        try t.expect(image.close(true));
        try t.expect(F.owner.engine_users == 0 and F.owner.mapping_users == 0 and F.native_refs == 0 and F.charged == 0);
        const cursor = try buffers.Shape.make(3, 2, true);
        try image.allocate(&F.owner, cursor, 4);
        try image.copyCursor(&.{0xff010203, 0x80010203, 0, 4, 5, 6});
        try t.expectEqual(@as(u32, 0xff010203), std.mem.readInt(u32, F.frame_data[0..4], .little));
        try t.expectEqual(@as(u32, 6), std.mem.readInt(u32, F.frame_data[264..268], .little));
        try t.expect(std.mem.allEqual(u8, F.frame_data[268..4096], 0));
        try image.publish(); _ = try image.scanout();
        try t.expect(image.close(true));
        var shadow: buffers.Shadow = .{};
        try shadow.create(F.owner.memory.?, 32, 64);
        try t.expect(shadow.ready and F.descriptor.location == a.gfx_buffer_location_system and F.descriptor.adapter_id == 0 and
            F.descriptor.plane_pitches[0] == 128 and F.descriptor.usage & a.gfx_buffer_usage_transfer_source != 0);
        F.release_fail = true; try t.expect(!shadow.close()); F.release_fail = false; try t.expect(shadow.close());
        try t.expect(F.owner.close(gate));
    }
};


test "AMD native VA extents fit 1 GB plus SMEM padding, preserve holes and retain failed acknowledgements" {
    const R = Render;
    const amd = @import("r4amd");
    const large = @import("render_virtual.zig").max_backing_bytes;
    try R.reset();
    R.virtual_job = .{ .resource = .{ .id = 700, .generation = 31 }, .request = .{ .kind = 1, .adapter_id = 7, .memory_generation = 23, .byte_length = large, .alignment = 65536, .deadline_ns = 1_000_000 } };
    R.virtual_pending = true; R.virtual_ack_fail = true;
    try t.expect(!R.owner.virtual.step());
    const serial = R.owner.virtual.serial;
    R.virtual_ack_fail = false; try t.expect(R.owner.virtual.step());
    const first = R.virtual_done;
    try t.expect(first.result == 1 and first.address == amd.native_va_start and R.owner.virtual.serial == serial);
    R.virtual_job.resource.id += 1; R.virtual_job.request.byte_length = 65536;
    R.virtual_pending = true; try t.expect(R.owner.virtual.step());
    const second = R.virtual_done;
    try t.expect(second.result == 1 and second.address >= first.address + large and second.address % 65536 == 0);
    R.virtual_job.resource.id += 1; R.virtual_job.request.fixed_address = first.address;
    R.virtual_pending = true; try t.expect(R.owner.virtual.step());
    try t.expectEqual(a.gfx_buffer_error_oom, R.virtual_done.result);
    R.virtual_job = .{ .resource = first.resource, .operation = 1, .request = .{ .kind = 1 }, .token = first.token };
    R.virtual_pending = true; try t.expect(R.owner.virtual.step());
    R.virtual_job = .{ .resource = .{ .id = 704, .generation = 31 }, .request = .{ .kind = 1, .adapter_id = 7, .memory_generation = 23, .byte_length = 65536, .alignment = 65536, .deadline_ns = 1_000_000 } };
    R.virtual_pending = true; try t.expect(R.owner.virtual.step());
    const reused = R.virtual_done;
    try t.expect(reused.result == 1 and reused.address == first.address and !std.meta.eql(reused.token, first.token));
    for ([_]a.GfxVirtualCompletion{second, reused}) |range| {
        R.virtual_job = .{ .resource = range.resource, .operation = 1, .request = .{ .kind = 1 }, .token = range.token };
        R.virtual_pending = true; try t.expect(R.owner.virtual.step());
    }
    // Use the real page-table algorithm over RAM, without allocating fake
    // payload backing or treating these page entries as a hardware proof.
    const physical = try t.allocator.alloc(u64, large / 4096);
    defer t.allocator.free(physical);
    for (physical, 0..) |*page, i| page.* = 0x400000000 + i * 8192;
    const mapped_before = F.owner.virtual.mapped_pages;
    try F.owner.virtual.map(amd.native_va_start, physical, .{ .system = true, .write = true });
    try t.expectEqual(physical[physical.len - 1], (try F.owner.virtual.lookup(amd.native_va_start + large - 4096)) & pages.physical_mask);
    try F.owner.virtual.unmap(amd.native_va_start, physical.len);
    try t.expectEqual(mapped_before, F.owner.virtual.mapped_pages);
    try t.expect(R.owner.close());
    try t.expect(F.owner.close(.{ .memory_epoch = 23, .boot_held = true, .engines_quiesced = true }));
}

test "AMD large SG admission preserves page order and retains validation metadata after OOM or failed free" {
    const count = 1024 * 1024 * 1024 / 4096 + 1;
    const physical = try t.allocator.alloc(u64, count);
    defer t.allocator.free(physical);
    for (0..4) |attempt| {
        F.reset(); try F.prepare();
        F.shared = true;
        F.descriptor = .{ .byte_length = count * 4096, .usage = 15 };
        F.heap_fail = attempt == 1;
        F.heap_release_fail = attempt == 2;
        F.segment_duplicate = attempt == 3;
        var mapping: Mapping = .{};
        const result = mapping.prepare(&F.owner, .{ .id = 1, .generation = 19 }, @import("r4amd").native_va_start, count * 4096, 1, physical);
        if (attempt == 0) {
            try result;
            try t.expect(mapping.prepared and F.dma and !F.gpu);
            for (physical, 0..) |value, i| try t.expectEqual(@as(u64, 0x1000000) + i * 4096 * 3, value);
        } else if (attempt == 1) try t.expectError(error.Capacity, result)
        else if (attempt == 2) {
            try t.expectError(error.Busy, result);
            try t.expect(mapping.validation.handle != 0 and !mapping.prepared);
            try t.expect(!mapping.close(&F.owner.virtual, &hw));
        } else try t.expectError(error.Invalid, result);
        F.heap_fail = false; F.heap_release_fail = false;
        try t.expect(mapping.close(&F.owner.virtual, &hw));
        try t.expect(!F.shared and !F.dma and !F.gpu and F.owner.mapping_users == 0);
        for (&F.heap_slots) |*slot| try t.expect(slot.* == null);
        try t.expect(F.owner.close(.{ .memory_epoch = 23, .boot_held = true, .engines_quiesced = true }));
    }
}
