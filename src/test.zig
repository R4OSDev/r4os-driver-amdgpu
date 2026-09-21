// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const t = std.testing;
comptime { _ = @import("queue_test.zig"); }
const a = @import("r4os").abi;
const driver = @import("main.zig");
const identity = @import("identity.zig");
const boot = @import("boot.zig");
const memregs = @import("memory_registers.zig");
const regs = @import("registers.zig");
const fw = @import("firmware.zig");
const package_store = @import("firmware_store.zig");
const samples = @import("firmware_samples");
const bios_fixture = @import("bios_fixture.zig");

const Fixture = struct {
    var api: a.DriverApi = undefined;
    var pci: a.PciDeviceInfo = undefined;
    var config: [1024]u32 = undefined;
    var page: [1024]u32 align(4096) = undefined;
    var boot_info: a.GfxNativeBootInfo = undefined;
    var count: u32 = 1;
    var mode: [*:0]const u8 = "auto";
    var strap: u32 = 0;
    var megabytes: u32 = 512;
    var fb_offset: u32 = 0x220;
    var config_reads: usize = 0;
    var maps: usize = 0;
    var unmaps: usize = 0;
    var collects: usize = 0;
    var live: bool = false;
    var partial: bool = false;
    var fail_map: usize = 0;
    var fail_unmap = false;
    var fail_collect = false;
    var fail_boot = false;
    var fail_inventory = false;
    var bad_window = false;
    var unstable = false;
    var pci_loss = false;
    var pm_loss = false;
    var bar_size_loss = false;
    var boot_loss = false;
    var boot_reads: usize = 0;
    var saw_picasso = false;
    var saw_raven2 = false;
    var saw_retained = false;
    var saw_reason: [384]u8 = undefined;
    var reason_len: usize = 0;

    var vfct: [bios_fixture.vfct_bytes]u8 = undefined;
    var heap_bytes: [1024 * 1024]u8 align(16) = undefined;
    var shadow_bytes: [256 * 1024]u8 align(4096) = undefined;
    var pixels: [4096]u8 = undefined;
    var package_bytes: [fw.max_package_bytes]u8 align(16) = undefined;
    var package_allocated = false;
    var package_missing: ?usize = null;
    var package_bad_size = false;
    var package_bad_generation = false;
    var package_stale = false;
    var package_short_read = false;
    var package_corrupt = false;
    var package_deadline = false;
    var package_clock_regression = false;
    var package_partial_allocation = false;
    var package_fail_release = false;
    var package_duplicate_handle = false;
    var package_reads: usize = 0;
    var package_stats: usize = 0;
    var package_seen: [16]bool = @splat(false);
    var allocated = false;
    var buffer_live = false;
    var lease_live = false;
    var held = false;
    var acpi_status: i32 = 0;
    var fail_read = false;
    var fail_heap_release = false;
    var fail_hold = false;
    var fail_finish = false;
    var fail_buffer_unmap = false;
    var fail_buffer_release = false;
    var fail_buffer_map = false;
    var expire = false;
    var resource_calls: usize = 0;
    var heap_calls: usize = 0;
    var hold_calls: usize = 0;
    var after_read_stale = false;
    fn reset() void {
        config = @splat(0); page = @splat(0);
        bios_fixture.vfct(&vfct); bios_fixture.rom(&shadow_bytes); pixels = @splat(0x5a);
        package_allocated = false; package_missing = null; package_bad_size = false; package_bad_generation = false;
        package_stale = false; package_short_read = false; package_corrupt = false; package_deadline = false;
        package_clock_regression = false; package_partial_allocation = false; package_fail_release = false;
        package_duplicate_handle = false; package_reads = 0; package_stats = 0; package_seen = @splat(false);
        allocated = false; buffer_live = false; lease_live = false; held = false;
        acpi_status = 0; fail_read = false; fail_heap_release = false; fail_hold = false; fail_finish = false;
        fail_buffer_unmap = false; fail_buffer_release = false; fail_buffer_map = false; expire = false;
        resource_calls = 0; heap_calls = 0; hold_calls = 0; after_read_stale = false;
        pci = .{ .bus_kind = 2, .bus = 5, .device = 0, .function = 0, .vendor_id = 0x1002, .device_id = 0x15d8, .class_code = 3 };
        config[0] = 0x15d81002; config[1] = (1 << 20) | 2; config[2] = 0x030000c8;
        config[0x10 / 4] = 0xd000000c; // 64-bit prefetchable BAR0, unmeasured.
        config[0x24 / 4] = 0xf0000000;
        config[0x2c / 4] = 0x381217aa;
        config[0x34 / 4] = 0x50; config[0x50 / 4] = 0x6001; config[0x60 / 4] = 0x10;
        boot_info = .{ .generation = 11, .state = a.display_state_bootfb,
            .physical_address = 0x220100000, .byte_length = 4096, .width = 32, .height = 32, .pitch = 128, .format = a.gfx_buffer_format_xrgb8888 };
        count = 1; mode = "auto"; strap = 0x010015d8; megabytes = 512; fb_offset = 0x220;
        config_reads = 0; maps = 0; unmaps = 0; collects = 0; live = false; partial = false;
        fail_map = 0; fail_unmap = false; fail_collect = false; fail_boot = false; fail_inventory = false;
        bad_window = false; unstable = false; pci_loss = false; pm_loss = false; bar_size_loss = false; boot_loss = false; boot_reads = 0;
        saw_picasso = false; saw_raven2 = false; saw_retained = false; reason_len = 0;
        api = undefined;
        api.magic = a.driver_magic; api.version = a.driver_api_version; api.size = @sizeOf(a.DriverApi);
        api.log_info = log; api.log_warn = log; api.log_error = log;
        api.get_option = option; api.pci_device_count = deviceCount; api.pci_device_at = deviceAt;
        api.pci_read_config32 = readConfig; api.gfx_display_query = displayQuery; api.gfx_memory_query = memoryQuery;
        api.resource_query = resourceQuery; api.heap_query = heapQuery;
        // PCI writes, bus-mastering, DMA, command execution and queues remain
        // undefined: only the bounded read/capture contracts are admitted.
    }
    fn log(message: [*:0]const u8) callconv(.c) void {
        const text = std.mem.span(message);
        saw_picasso = saw_picasso or std.mem.indexOf(u8, text, "family=picasso") != null;
        saw_raven2 = saw_raven2 or std.mem.indexOf(u8, text, "family=raven2") != null;
        saw_retained = saw_retained or std.mem.indexOf(u8, text, "cleanup=retained") != null;
        reason_len = @min(text.len, saw_reason.len); @memcpy(saw_reason[0..reason_len], text[0..reason_len]);
    }
    fn option(name: [*:0]const u8, key: [*:0]const u8) callconv(.c) [*:0]const u8 {
        std.debug.assert(std.mem.eql(u8, std.mem.span(name), "AMDGPU") and std.mem.eql(u8, std.mem.span(key), "mode"));
        return mode;
    }
    fn deviceCount() callconv(.c) u32 { return count; }
    fn deviceAt(index: u32, output: *a.PciDeviceInfo) callconv(.c) i32 {
        if (fail_inventory or index >= count) return -1;
        output.* = pci; output.bus +%= @intCast(index);
        return 0;
    }
    fn readConfig(kind: u8, _: u8, _: u8, _: u8, offset: u16) callconv(.c) u32 {
        std.debug.assert(offset % 4 == 0 and offset < 4096 and (kind == 2 or offset < 256));
        config_reads += 1;
        if (pci_loss and maps != 0 and offset == 0) return 0xffffffff;
        if (pm_loss and maps != 0 and offset == 0x54) return 3;
        if (bar_size_loss and maps != 0 and offset == 0x108) return (7 << 8) | (1 << 5);
        return config[offset / 4];
    }
    pub fn read(_: *@This(), offset: u16) u32 { return readConfig(pci.bus_kind, pci.bus, pci.device, pci.function, offset); }
    fn displayQuery(output: *a.GfxDriverDisplayApi) callconv(.c) i32 {
        output.* = .{ .boot_info = @intFromPtr(&bootInfo), .boot_hold = @intFromPtr(&bootHold), .boot_finish = @intFromPtr(&bootFinish) };
        return a.gfx_output_ok;
    }
    fn bootInfo(output: *a.GfxNativeBootInfo) callconv(.c) i32 {
        boot_reads += 1;
        if (fail_boot) return -1;
        output.* = boot_info;
        if (held) output.state = a.display_state_preparing;
        if (boot_loss and boot_reads > 1) output.generation += 1;
        return a.gfx_output_ok;
    }
    fn memoryQuery(output: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        output.* = .{ .mmio_map = @intFromPtr(&map), .mmio_unmap = @intFromPtr(&unmap), .collect = @intFromPtr(&collect),
            .reserved_span = @intFromPtr(&reservedSpan), .buffer_create = @intFromPtr(&bufferCreate), .buffer_map = @intFromPtr(&bufferMap),
            .buffer_unmap = @intFromPtr(&bufferUnmap), .buffer_release = @intFromPtr(&bufferRelease) };
        return a.gfx_buffer_result_ok;
    }
    fn reservedSpan(base: u64, bytes: u64) callconv(.c) i32 {
        return if (base == @as(u64, fb_offset) << 24 and bytes == @as(u64, megabytes) * 1024 * 1024) 1 else -1;
    }
    fn map(request: *const a.GfxMmioRequest, output: *a.GfxMmioWindow) callconv(.c) i32 {
        if (request.resource_base == 0xd0000000) {
            std.debug.assert(!live and !partial and request.resource_bytes == 256 * 1024 * 1024 and request.byte_length == shadow_bytes.len and
                request.resource_flags == 1 and request.cache_policy == a.gfx_buffer_cache_write_combining);
            maps += 1;
            if (fail_map == maps) { partial = true; return -1; }
            live = true;
            output.* = .{ .handle = .{ .id = 99, .generation = 7 }, .cpu_address = @intFromPtr(&shadow_bytes),
                .physical_address = request.resource_base, .byte_length = shadow_bytes.len, .cache_policy = request.cache_policy };
            return a.gfx_buffer_result_ok;
        }
        std.debug.assert(!live and !partial and request.resource_base == 0xf0000000 and request.resource_bytes == memregs.required_prefix and
            request.byte_length == 4096 and request.cache_policy == a.gfx_buffer_cache_uncached and request.resource_flags == 0);
        maps += 1;
        if (maps == fail_map) { partial = true; return -1; }
        page = @splat(0);
        if (request.byte_offset == regs.strap & ~@as(u64, 0xfff)) {
            page[regs.strap % 4096 / 4] = if (unstable and maps >= 3) strap + 0x1000000 else strap;
            page[regs.memsize % 4096 / 4] = megabytes;
        } else if (request.byte_offset == memregs.mm.MC_VM_FB_LOCATION_BASE & ~@as(u64, 0xfff)) {
            page[memregs.mm.MC_VM_FB_LOCATION_BASE % 4096 / 4] = 0x100;
            page[memregs.mm.MC_VM_FB_LOCATION_TOP % 4096 / 4] = 0x11f;
        } else {
            page[memregs.gfx.MC_VM_FB_LOCATION_BASE % 4096 / 4] = 0x100;
            page[memregs.gfx.MC_VM_FB_LOCATION_TOP % 4096 / 4] = 0x11f;
            std.debug.assert(request.byte_offset == regs.fb_offset & ~@as(u64, 0xfff));
            page[regs.fb_offset % 4096 / 4] = fb_offset;
        }
        live = true;
        output.* = .{ .handle = .{ .id = 99, .generation = 7 }, .cpu_address = @intFromPtr(&page),
            .physical_address = request.resource_base + request.byte_offset, .byte_length = 4096, .cache_policy = a.gfx_buffer_cache_uncached };
        if (bad_window) output.physical_address += 4096;
        return a.gfx_buffer_result_ok;
    }
    fn unmap(handle: *const a.GfxBufferHandle, quiesced: u32) callconv(.c) i32 {
        std.debug.assert(live and handle.id == 99 and handle.generation == 7 and quiesced == 1);
        unmaps += 1;
        if (fail_unmap) return -1;
        live = false;
        return a.gfx_buffer_result_ok;
    }
    fn collect() callconv(.c) i32 {
        collects += 1;
        if (fail_collect) return -1;
        partial = false;
        return a.gfx_buffer_result_ok;
    }
    fn heapQuery(out: *a.DriverHeapApi) callconv(.c) i32 {
        out.* = .{ .allocate = @intFromPtr(&allocate), .release = @intFromPtr(&heapRelease) }; return 0;
    }
    fn allocate(bytes: u64, alignment: u32, out: *a.DriverHeapAllocation) callconv(.c) i32 {
        if (bytes > heap_bytes.len) {
            std.debug.assert(!package_allocated and bytes <= package_bytes.len and alignment == 16);
            package_allocated = true; heap_calls += 1;
            out.* = .{ .handle = 0x100000002, .cpu_address = @intFromPtr(&package_bytes), .byte_length = bytes, .alignment = 16 };
            return if (package_partial_allocation) -1 else 0;
        }
        std.debug.assert(!allocated and bytes <= heap_bytes.len and alignment == 16); allocated = true; heap_calls += 1;
        out.* = .{ .handle = 0x100000001, .cpu_address = @intFromPtr(&heap_bytes), .byte_length = bytes, .alignment = 16 }; return 0;
    }
    fn heapRelease(handle: u64) callconv(.c) i32 {
        if (handle == 0x100000002) {
            std.debug.assert(package_allocated);
            if (package_fail_release) return -1;
            package_allocated = false; return 0;
        }
        std.debug.assert(allocated and handle == 0x100000001); if (fail_heap_release) return -1; allocated = false; return 0;
    }
    fn resourceQuery(out: *a.DriverResourceApi) callconv(.c) i32 {
        out.* = .{ .stat = @intFromPtr(&fileStat), .read_at = @intFromPtr(&fileRead), .now_ns = @intFromPtr(&now), .acpi_stat = @intFromPtr(&acpiStat), .acpi_read_at = @intFromPtr(&acpiRead) }; return 0;
    }
    fn now() callconv(.c) u64 {
        if (package_reads > 0) {
            if (package_deadline) return 3000001000;
            if (package_clock_regression) return 500;
        }
        return if (expire and resource_calls > 2) 999999999 else 1000;
    }
    fn fileStat(name: [*]const u8, bytes: u32, out: *a.DriverResourceInfo) callconv(.c) i32 {
        package_stats += 1;
        for (0..package_store.count) |i| {
            if (!std.mem.eql(u8, name[0..bytes], package_store.artifact(i).resource)) continue;
            package_seen[i] = true;
            if (package_missing == i) return a.driver_resource_error_not_found;
            out.* = .{ .handle = 0x300000001 + @as(u64, if (package_duplicate_handle) 0 else i), .byte_length = samples.files[i].len,
                .module_generation = if ((package_bad_generation and i == 3) or (package_stale and package_reads > 0)) 4 else 3 };
            if (package_bad_size) out.byte_length += 1;
            return 0;
        }
        return a.driver_resource_error_not_found;
    }
    fn fileRead(handle: u64, offset: u64, out: [*]u8, bytes: u32, deadline: u64) callconv(.c) i32 {
        std.debug.assert(handle >= 0x300000001 and handle < 0x300000001 + package_store.count and bytes > 0 and bytes <= 65536 and deadline == 2000001000);
        const i: usize = @intCast(handle - 0x300000001);
        std.debug.assert(offset <= samples.files[i].len and bytes <= samples.files[i].len - offset);
        package_reads += 1;
        @memcpy(out[0..bytes], samples.files[i][offset..][0..bytes]);
        if (package_corrupt and offset == 0) out[0] ^= 1;
        return @intCast(if (package_short_read) bytes - 1 else bytes);
    }
    fn acpiStat(signature: u32, index: u32, out: *a.DriverFirmwareTableInfo) callconv(.c) i32 {
        std.debug.assert(signature == std.mem.readInt(u32, "VFCT", .little)); resource_calls += 1;
        if (acpi_status != 0) return acpi_status;
        if (index != 0) return a.driver_resource_error_not_found;
        out.* = .{ .handle = 0x200000001, .generation = 2, .byte_length = vfct.len, .signature = signature, .revision = 1 };
        if (after_read_stale and resource_calls > 3) out.generation += 1;
        return 0;
    }
    fn acpiRead(handle: u64, offset: u64, out: [*]u8, bytes: u32, deadline: u64) callconv(.c) i32 {
        std.debug.assert(handle == 0x200000001 and offset + bytes <= vfct.len and deadline > 1000); resource_calls += 1;
        if (fail_read) return a.driver_resource_error_io;
        @memcpy(out[0..bytes], vfct[offset..][0..bytes]); return @intCast(bytes);
    }
    fn bufferCreate(input: *const a.GfxBufferDescriptor, out: *a.GfxBufferReference) callconv(.c) i32 {
        std.debug.assert(!buffer_live and input.byte_length == pixels.len); buffer_live = true;
        out.* = .{ .buffer = .{ .id = 12, .generation = 13 }, .reference = .{ .id = 14, .generation = 15 } }; return a.gfx_buffer_result_ok;
    }
    fn bufferMap(reference: *const a.GfxBufferHandle, map_mode: u32, offset: u64, bytes: u64, out: *a.GfxBufferMap) callconv(.c) i32 {
        std.debug.assert(buffer_live and held and !lease_live and reference.id == 14 and map_mode == a.gfx_buffer_map_read and offset == 0 and bytes == pixels.len);
        if (fail_buffer_map) return -1;
        lease_live = true; out.* = .{ .lease = .{ .id = 16, .generation = 17 }, .cpu_address = @intFromPtr(&pixels), .byte_length = pixels.len }; return a.gfx_buffer_result_ok;
    }
    fn bufferUnmap(lease: *const a.GfxBufferHandle) callconv(.c) i32 {
        std.debug.assert(lease_live and lease.id == 16); if (fail_buffer_unmap) return -1; lease_live = false; return a.gfx_buffer_result_ok;
    }
    fn bufferRelease(reference: *const a.GfxBufferHandle) callconv(.c) i32 {
        std.debug.assert(buffer_live and !held and !lease_live and reference.id == 14); if (fail_buffer_release) return -1; buffer_live = false; return a.gfx_buffer_result_ok;
    }
    fn bootHold(input: *const a.GfxBootHoldRequest, out: *a.GfxNativeState) callconv(.c) i32 {
        std.debug.assert(buffer_live and !held and input.adapter_id == identity.adapter(pci) and input.generation == boot_info.generation and input.restore_callback != 0);
        held = true; hold_calls += 1;
        out.* = .{ .generation = boot_info.generation + 1, .state = a.display_state_preparing, .retained = 1, .outcome = a.gfx_output_outcome_validated };
        return if (fail_hold) -1 else a.gfx_output_ok;
    }
    fn bootFinish(generation: u64, operation: u32, out: *a.GfxNativeState) callconv(.c) i32 {
        std.debug.assert(held and generation == boot_info.generation + 1 and operation == 0);
        if (fail_finish) { out.* = .{ .generation = generation, .retained = 1 }; return -1; }
        held = false; out.* = .{ .generation = generation, .state = a.display_state_bootfb, .outcome = a.gfx_output_outcome_old_preserved }; return a.gfx_buffer_result_ok;
    }
    fn measuredBar() void { config[0x100 / 4] = 0x00010015; config[0x104 / 4] = 1 << 12; config[0x108 / 4] = (8 << 8) | (1 << 5); }
    fn stop() !void {
        try t.expectEqual(@as(i32, 0), driver.amdgpu_shutdown());
        try t.expectEqual(@as(i32, 0), driver.amdgpu_shutdown());
        try t.expect(!live and !partial and !allocated and !package_allocated and !buffer_live and !lease_live and !held and driver.boot_association == null);
    }
};

test "AMD actual init and unbind preserve software boot and bound source-backed identity/UMA probes" {
    const f = Fixture;
    defer { f.fail_unmap = false; f.fail_collect = false; _ = driver.amdgpu_shutdown(); }
    // PCI revision C8 is not ASIC revision 8: the two identities are separate.
    f.reset();
    try t.expectEqual(@as(i32, 0), driver.amdgpu_init(&f.api));
    try t.expect(f.saw_picasso and !f.saw_raven2 and f.maps == 4 and f.unmaps == 4 and !f.live);
    try t.expectEqual(boot.Path.uma_direct, driver.boot_association.?.path);
    try t.expectEqual(@as(u64, 0x100000), driver.boot_association.?.uma_offset);
    try t.expectEqual(@as(i32, -1), driver.amdgpu_init(&f.api));
    try f.stop();
    for ([_]u32{ 1, 2 }) |policy| {
        f.reset(); f.boot_info.policy = policy; f.mode = "native";
        try t.expectEqual(@as(i32, 0), driver.amdgpu_init(&f.api));
        try t.expect(f.config_reads == 0 and f.maps == 0 and f.heap_calls == 0 and f.resource_calls == 0 and f.hold_calls == 0);
        try f.stop();
    }
    f.reset(); f.fail_boot = true;
    try t.expectEqual(@as(i32, -3), driver.amdgpu_init(&f.api));
    try t.expect(f.config_reads == 0 and f.maps == 0); try f.stop();
    f.reset(); f.mode = "native";
    try t.expectEqual(@as(i32, -8), driver.amdgpu_init(&f.api)); try t.expect(f.maps == 0); try f.stop();
    f.reset(); f.mode = "bogus";
    try t.expectEqual(@as(i32, -2), driver.amdgpu_init(&f.api)); try t.expect(f.maps == 0); try f.stop();
    f.reset(); f.pci.device_id = 0x15dd;
    try t.expectEqual(@as(i32, -4), driver.amdgpu_init(&f.api)); try t.expect(f.config_reads == 0); try f.stop();
    f.reset(); f.pci.vendor_id = 0x10de;
    try t.expectEqual(@as(i32, -4), driver.amdgpu_init(&f.api)); try t.expect(f.config_reads == 0); try f.stop();
    f.reset(); f.count = 4097;
    try t.expectEqual(@as(i32, -4), driver.amdgpu_init(&f.api)); try t.expect(f.config_reads == 0); try f.stop();
    f.reset(); f.fail_inventory = true;
    try t.expectEqual(@as(i32, -4), driver.amdgpu_init(&f.api)); try t.expect(f.config_reads == 0); try f.stop();
    f.reset(); f.config[0x54 / 4] = 3;
    try t.expectEqual(@as(i32, -5), driver.amdgpu_init(&f.api)); try t.expect(f.maps == 0); try f.stop();
    f.reset(); f.config[0x50 / 4] = 0x5001;
    try t.expectEqual(@as(i32, -5), driver.amdgpu_init(&f.api)); try t.expect(f.config_reads < 30 and f.maps == 0); try f.stop();
    f.reset(); f.config[1] &= ~@as(u32, 2);
    try t.expectEqual(@as(i32, -5), driver.amdgpu_init(&f.api)); try t.expect(f.maps == 0); try f.stop();
    f.reset(); f.config[0x24 / 4] |= 1;
    try t.expectEqual(@as(i32, -5), driver.amdgpu_init(&f.api)); try t.expect(f.maps == 0); try f.stop();
    f.reset(); f.strap = 0x080015d8;
    try t.expectEqual(@as(i32, -7), driver.amdgpu_init(&f.api));
    try t.expect(f.saw_raven2 and !f.saw_picasso and f.maps == 1); try f.stop();
    f.reset(); f.strap = 0xffffffff;
    try t.expectEqual(@as(i32, -6), driver.amdgpu_init(&f.api)); try t.expect(!f.live); try f.stop();
    f.reset(); f.unstable = true;
    try t.expectEqual(@as(i32, -6), driver.amdgpu_init(&f.api)); try t.expect(!f.live and f.unmaps == 4); try f.stop();
    f.reset(); f.pci_loss = true;
    try t.expectEqual(@as(i32, -5), driver.amdgpu_init(&f.api)); try t.expect(!f.live); try f.stop();
    f.reset(); f.pm_loss = true;
    try t.expectEqual(@as(i32, -5), driver.amdgpu_init(&f.api)); try t.expect(!f.live); try f.stop();
    f.reset(); f.boot_loss = true;
    try t.expectEqual(@as(i32, -3), driver.amdgpu_init(&f.api)); try t.expect(driver.boot_association == null); try f.stop();
    for (1..5) |failure| {
        f.reset(); f.fail_map = failure;
        try t.expectEqual(@as(i32, -6), driver.amdgpu_init(&f.api));
        try t.expect(!f.live and !f.partial and f.maps == failure); try f.stop();
    }
    f.reset(); f.bad_window = true;
    try t.expectEqual(@as(i32, -6), driver.amdgpu_init(&f.api)); try t.expect(!f.live and f.unmaps == 1); try f.stop();
    f.reset(); f.fail_unmap = true;
    try t.expectEqual(@as(i32, -6), driver.amdgpu_init(&f.api));
    try t.expect(f.live and f.saw_retained); try t.expectEqual(@as(i32, -1), driver.amdgpu_shutdown());
    try t.expectEqual(@as(i32, -1), driver.amdgpu_init(&f.api));
    f.fail_unmap = false; try f.stop();
    f.reset(); f.fail_map = 1; f.fail_collect = true;
    try t.expectEqual(@as(i32, -6), driver.amdgpu_init(&f.api));
    try t.expect(f.partial and !f.live and f.saw_retained); try t.expectEqual(@as(i32, -1), driver.amdgpu_shutdown());
    f.fail_collect = false; try f.stop();
    f.reset(); f.count = 2;
    try t.expectEqual(@as(i32, -7), driver.amdgpu_init(&f.api)); try t.expect(driver.boot_association == null and f.maps == 8); try f.stop();
    f.reset(); f.boot_info.physical_address = 0xd0100000;
    try t.expectEqual(@as(i32, -7), driver.amdgpu_init(&f.api)); try f.stop(); // BAR base alone is no proof.
    f.reset(); f.config[0x100 / 4] = 0x00010015; f.config[0x104 / 4] = 1 << 12; f.config[0x108 / 4] = (8 << 8) | (1 << 5);
    f.boot_info.physical_address = 0xd0100000;
    try t.expectEqual(@as(i32, 0), driver.amdgpu_init(&f.api));
    try t.expectEqual(boot.Path.measured_bar0_alias, driver.boot_association.?.path); try f.stop();
    f.reset(); f.config[0x100 / 4] = 0x00010015; f.config[0x104 / 4] = 1 << 12; f.config[0x108 / 4] = (8 << 8) | (1 << 5);
    f.boot_info.physical_address = 0xd0100000; f.bar_size_loss = true;
    try t.expectEqual(@as(i32, -5), driver.amdgpu_init(&f.api)); try t.expect(driver.boot_association == null); try f.stop();
    f.reset(); f.config[0x100 / 4] = (0x100 << 20) | 0x10001;
    try t.expectEqual(@as(i32, -5), driver.amdgpu_init(&f.api)); try t.expect(f.config_reads < 35); try f.stop();

    const raven = try identity.chip(0x15dd, 1 << 24);
    const picasso = try identity.chip(0x15d8, 1 << 24);
    const raven2 = try identity.chip(0x15d8, 8 << 24);
    try t.expect(raven.family == .raven and raven.external_revision == 0x21);
    try t.expect(picasso.gc == 0x090100 and picasso.sdma == 0x040100 and picasso.external_revision == 0x42);
    try t.expect(raven2.gc == 0x090202 and raven2.sdma == 0x040101 and raven2.external_revision == 0x81);
    try t.expectError(error.Revision, identity.chip(0x1636, 0));
    try t.expectError(error.Uma, boot.uma(0xffffffff, 512));
    try t.expectError(error.Uma, boot.uma(0x220, 0));
    try t.expectError(error.Uma, boot.uma(0x10000000, 512));
    const range = try boot.uma(0x220, 512);
    try t.expect(range.contains(0x220000000, 512 * 1024 * 1024));
    try t.expect(!range.contains(0x23ffff000, 8192));
    f.reset(); f.boot_info.pitch = 1;
    try t.expectError(error.BootUnavailable, boot.select(&.{}, f.boot_info));
    try t.expectEqual(@as(i32, -3), driver.amdgpu_init(&f.api)); try t.expect(f.maps == 0); try f.stop();
}

test { _ = @import("bios_test.zig"); _ = @import("firmware_test.zig"); _ = @import("memory_test.zig"); }

test "AMD board acquisition and boot capture retain failed cleanup and never execute firmware" {
    const f = Fixture;
    defer {
        f.fail_unmap = false; f.fail_collect = false; f.fail_heap_release = false;
        f.fail_finish = false; f.fail_buffer_unmap = false; f.fail_buffer_release = false;
        _ = driver.amdgpu_shutdown();
    }
    f.reset(); try t.expectEqual(@as(i32, 0), driver.amdgpu_init(&f.api));
    try t.expect(driver.firmware.valid and driver.boot_snapshot.valid and f.buffer_live and f.lease_live and !f.held);
    try t.expect(driver.firmware.source == .vfct and driver.firmware.board.paths[0].aux_ddc_line.? == 2);
    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&f.pixels, &expected_hash, .{});
    try t.expectEqualSlices(u8, &expected_hash, &driver.boot_snapshot.sha256);
    f.fail_buffer_unmap = true; try t.expectEqual(@as(i32, -1), driver.amdgpu_shutdown());
    try t.expect(f.allocated and f.buffer_live and f.lease_live);
    try t.expectEqual(@as(i32, -1), driver.amdgpu_init(&f.api));
    f.fail_buffer_unmap = false; f.fail_buffer_release = true;
    try t.expectEqual(@as(i32, -1), driver.amdgpu_shutdown()); try t.expect(f.buffer_live and !f.lease_live and f.allocated);
    f.fail_buffer_release = false; f.fail_heap_release = true;
    try t.expectEqual(@as(i32, -1), driver.amdgpu_shutdown()); try t.expect(!f.buffer_live and f.allocated);
    f.fail_heap_release = false; try f.stop();
    f.reset(); f.acpi_status = a.driver_resource_error_not_found;
    try t.expectEqual(@as(i32, -9), driver.amdgpu_init(&f.api)); try t.expect(driver.firmware.acpi == .missing and f.heap_calls == 0 and f.hold_calls == 0); try f.stop();
    f.reset(); f.api.resource_query = null;
    try t.expectEqual(@as(i32, -9), driver.amdgpu_init(&f.api)); try t.expect(driver.firmware.acpi == .unavailable and f.heap_calls == 0); try f.stop();
    f.reset(); f.api.heap_query = null;
    try t.expectEqual(@as(i32, -9), driver.amdgpu_init(&f.api)); try t.expect(f.resource_calls == 0); try f.stop();
    f.reset(); f.acpi_status = a.driver_resource_error_source; f.measuredBar();
    try t.expectEqual(@as(i32, -9), driver.amdgpu_init(&f.api)); try t.expect(f.maps == 4 and f.hold_calls == 0); try f.stop(); // damaged ACPI never falls through
    f.reset(); f.acpi_status = a.driver_resource_error_not_found; f.measuredBar();
    try t.expectEqual(@as(i32, 0), driver.amdgpu_init(&f.api)); try t.expect(driver.firmware.source == .measured_bar0_shadow and f.maps == 5 and f.unmaps == 5); try f.stop();
    f.reset(); f.acpi_status = a.driver_resource_error_not_found; f.measuredBar(); f.shadow_bytes[0] = 0;
    try t.expectEqual(@as(i32, -9), driver.amdgpu_init(&f.api)); try t.expect(f.live and f.hold_calls == 0); try f.stop();
    f.reset(); f.acpi_status = a.driver_resource_error_not_found; f.measuredBar(); f.fail_map = 5;
    try t.expectEqual(@as(i32, -9), driver.amdgpu_init(&f.api)); try t.expect(f.partial and f.allocated); f.fail_collect = true;
    try t.expectEqual(@as(i32, -1), driver.amdgpu_shutdown()); try t.expect(f.partial and f.allocated);
    f.fail_collect = false; try f.stop();
    f.reset(); f.fail_read = true;
    try t.expectEqual(@as(i32, -9), driver.amdgpu_init(&f.api)); try t.expect(f.allocated and f.hold_calls == 0); try f.stop();
    f.reset(); f.after_read_stale = true;
    try t.expectEqual(@as(i32, -9), driver.amdgpu_init(&f.api)); try t.expect(f.hold_calls == 0); try f.stop();
    f.reset(); f.expire = true;
    try t.expectEqual(@as(i32, -9), driver.amdgpu_init(&f.api)); try t.expect(f.hold_calls == 0); try f.stop();
    f.reset(); f.vfct[9] +%= 1;
    try t.expectEqual(@as(i32, -9), driver.amdgpu_init(&f.api)); try t.expect(f.hold_calls == 0); try f.stop();
    f.reset(); f.vfct[104 + 0x103] = 3; bios_fixture.checksum(&f.vfct, 9);
    try t.expectEqual(@as(i32, -9), driver.amdgpu_init(&f.api)); try t.expect(f.hold_calls == 0); try f.stop();
    f.reset(); f.fail_hold = true;
    try t.expectEqual(@as(i32, -10), driver.amdgpu_init(&f.api)); try t.expect(!f.held and !f.buffer_live); try f.stop();
    f.reset(); f.fail_buffer_map = true;
    try t.expectEqual(@as(i32, -10), driver.amdgpu_init(&f.api)); try t.expect(!f.held and !f.buffer_live); try f.stop();
    f.reset(); f.fail_finish = true;
    try t.expectEqual(@as(i32, -10), driver.amdgpu_init(&f.api)); try t.expect(f.held and f.buffer_live and driver.boot_snapshot.held_generation != 0);
    try t.expectEqual(@as(i32, -1), driver.amdgpu_shutdown());
    f.fail_finish = false; try f.stop();
}


test "AMD actual firmware package admission enforces profile, bytes, epochs, deadlines and retained ownership" {
    const f = Fixture;
    defer { f.package_fail_release = false; f.fail_heap_release = false; _ = driver.amdgpu_shutdown(); }
    for ([_]u8{ 0xa1, 0xc7, 0xc8, 0xcf, 0xd0, 0xd7, 0xd8, 0xdf, 0xe0 }) |revision| {
        f.reset(); f.config[2] = 0x03000000 | @as(u32, revision);
        try t.expectEqual(@as(i32, 0), driver.amdgpu_init(&f.api));
        const store = &driver.firmware_package;
        try t.expect(store.valid and store.generation == 3 and f.package_allocated);
        const am4 = (revision >= 0xc8 and revision <= 0xcf) or (revision >= 0xd8 and revision <= 0xdf);
        try t.expectEqual(if (am4) fw.Socket.am4 else .fp5, store.profile.?.socket);
        try t.expect((store.container(.rlc_am4) != null) == am4);
        try t.expect((store.container(.rlc) != null) != am4);
        for (fw.lock.firmware, 0..) |entry, i| try t.expectEqual(store.profile.?.includes(entry.role), f.package_seen[i + 3]);
        try f.stop();
    }
    // Every selected entry, including both legal files and the package lock,
    // must be present before any CPU allocation/hold. The unused RLC is not read.
    for (0..package_store.count) |missing| {
        if (missing >= 3 and fw.lock.firmware[missing - 3].role == .rlc) continue;
        f.reset(); f.package_missing = missing;
        try t.expectEqual(@as(i32, -11), driver.amdgpu_init(&f.api));
        try t.expect(!driver.firmware_package.valid and f.hold_calls == 0 and !f.package_allocated and f.package_reads == 0);
        try t.expect(std.mem.indexOf(u8, f.saw_reason[0..f.reason_len], package_store.artifact(missing).resource) != null);
        try f.stop();
    }
    inline for (.{ "package_bad_size", "package_bad_generation", "package_stale", "package_short_read", "package_corrupt", "package_deadline", "package_clock_regression", "package_partial_allocation", "package_duplicate_handle" }) |fault| {
        f.reset(); @field(f, fault) = true;
        try t.expectEqual(@as(i32, -11), driver.amdgpu_init(&f.api));
        try t.expect(!driver.firmware_package.valid and driver.firmware_package.container(.asd) == null and f.hold_calls == 0);
        try f.stop();
    }
    f.reset(); f.package_partial_allocation = true; f.package_fail_release = true;
    try t.expectEqual(@as(i32, -11), driver.amdgpu_init(&f.api));
    try t.expectEqual(@as(i32, -1), driver.amdgpu_shutdown());
    try t.expect(f.package_allocated and f.allocated and driver.firmware_package.allocation.handle != 0);
    try t.expectEqual(@as(i32, -1), driver.amdgpu_init(&f.api));
    f.package_fail_release = false; try f.stop();
    f.reset(); f.strap = 0x080015d8;
    try t.expectEqual(@as(i32, -7), driver.amdgpu_init(&f.api));
    try t.expect(f.package_stats == 0 and f.package_reads == 0); try f.stop();
    f.reset(); f.boot_info.policy = 1;
    try t.expectEqual(@as(i32, 0), driver.amdgpu_init(&f.api));
    try t.expect(f.package_stats == 0 and f.package_reads == 0 and f.heap_calls == 0); try f.stop();
}
