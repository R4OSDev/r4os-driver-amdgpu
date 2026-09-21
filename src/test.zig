// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const t = std.testing;
const a = @import("r4os").abi;
const driver = @import("main.zig");
const identity = @import("identity.zig");
const boot = @import("boot.zig");
const regs = @import("registers.zig");

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

    fn reset() void {
        config = @splat(0); page = @splat(0);
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
        // All other callbacks are intentionally undefined: the actual module
        // must not touch bus-mastering, writes, firmware, queues or display hold.
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
        output.* = .{ .boot_info = @intFromPtr(&bootInfo) };
        return a.gfx_output_ok;
    }
    fn bootInfo(output: *a.GfxNativeBootInfo) callconv(.c) i32 {
        boot_reads += 1;
        if (fail_boot) return -1;
        output.* = boot_info;
        if (boot_loss and boot_reads > 1) output.generation += 1;
        return a.gfx_output_ok;
    }
    fn memoryQuery(output: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        output.* = .{ .mmio_map = @intFromPtr(&map), .mmio_unmap = @intFromPtr(&unmap), .collect = @intFromPtr(&collect) };
        return a.gfx_buffer_result_ok;
    }
    fn map(request: *const a.GfxMmioRequest, output: *a.GfxMmioWindow) callconv(.c) i32 {
        std.debug.assert(!live and !partial and request.resource_base == 0xf0000000 and request.resource_bytes == regs.required_prefix and
            request.byte_length == 4096 and request.cache_policy == a.gfx_buffer_cache_uncached and request.resource_flags == 0);
        maps += 1;
        if (maps == fail_map) { partial = true; return -1; }
        page = @splat(0);
        if (request.byte_offset == regs.strap & ~@as(u64, 0xfff)) {
            page[regs.strap % 4096 / 4] = if (unstable and maps >= 3) strap + 0x1000000 else strap;
            page[regs.memsize % 4096 / 4] = megabytes;
        } else {
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
    fn stop() !void {
        try t.expectEqual(@as(i32, 0), driver.amdgpu_shutdown());
        try t.expectEqual(@as(i32, 0), driver.amdgpu_shutdown());
        try t.expect(!live and !partial and driver.boot_association == null);
    }
};

test "AMD actual init and unbind preserve software boot and bound source-backed identity/UMA probes" {
    const f = Fixture;
    defer { f.fail_unmap = false; f.fail_collect = false; _ = driver.amdgpu_shutdown(); }
    // PCI revision C8 is not ASIC revision 8: the two identities are separate.
    f.reset();
    try t.expectEqual(@as(i32, 0), driver.amdgpu_init(&f.api));
    try t.expect(f.saw_picasso and !f.saw_raven2 and f.maps == 3 and f.unmaps == 3 and !f.live);
    try t.expectEqual(boot.Path.uma_direct, driver.boot_association.?.path);
    try t.expectEqual(@as(u64, 0x100000), driver.boot_association.?.uma_offset);
    try t.expectEqual(@as(i32, -1), driver.amdgpu_init(&f.api));
    try f.stop();
    for ([_]u32{ 1, 2 }) |policy| {
        f.reset(); f.boot_info.policy = policy; f.mode = "native";
        try t.expectEqual(@as(i32, 0), driver.amdgpu_init(&f.api));
        try t.expect(f.config_reads == 0 and f.maps == 0);
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
    try t.expectEqual(@as(i32, -6), driver.amdgpu_init(&f.api)); try t.expect(!f.live and f.unmaps == 3); try f.stop();
    f.reset(); f.pci_loss = true;
    try t.expectEqual(@as(i32, -5), driver.amdgpu_init(&f.api)); try t.expect(!f.live); try f.stop();
    f.reset(); f.pm_loss = true;
    try t.expectEqual(@as(i32, -5), driver.amdgpu_init(&f.api)); try t.expect(!f.live); try f.stop();
    f.reset(); f.boot_loss = true;
    try t.expectEqual(@as(i32, -3), driver.amdgpu_init(&f.api)); try t.expect(driver.boot_association == null); try f.stop();
    for (1..4) |failure| {
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
    try t.expectEqual(@as(i32, -7), driver.amdgpu_init(&f.api)); try t.expect(driver.boot_association == null and f.maps == 6); try f.stop();
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
