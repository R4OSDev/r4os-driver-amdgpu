// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const r4os = @import("r4os");
const std = @import("std");
const a = r4os.abi;
const identity = @import("identity.zig");
const boot = @import("boot.zig");
var driver_api: ?*const a.DriverApi = null;
var probe: @import("probe.zig").Capture = .{};
pub var firmware_package: @import("firmware_store.zig").Store = .{};
pub var firmware: @import("bios_source.zig").Capture = .{};
pub var memory_runtime: @import("memory_owner.zig").Owner = .{};
pub var memory_layout: ?@import("memory_layout.zig").Layout = null;
pub var boot_snapshot: @import("boot_snapshot.zig").Snapshot = .{};
// Resident bounded snapshots never copy a large pool onto the init stack.
var devices: [8]boot.Device = undefined;
var device_count: usize = 0;
pub var boot_association: ?boot.Association = null;

comptime {
    if (!@import("builtin").is_test) asm (r4os.r4dev.driverEntriesAsm("amdgpu_init", "amdgpu_shutdown"));
}
pub export fn amdgpu_init(api: *const a.DriverApi) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api);
    if (!ctx.apiCompatible() or driver_api != null) return -1;
    driver_api = api;
    device_count = 0; boot_association = null; memory_layout = null;
    // This is the effective kernel policy, including the one-shot software
    // boot-menu override. Never reconstruct it from a configuration string.
    const display = ctx.graphicsDisplay() orelse return reject("boot-policy-unavailable", -3);
    var initial: a.GfxNativeBootInfo = .{};
    if (display.bootInfo(&initial) != a.gfx_output_ok or initial.version != 1 or initial.size < @sizeOf(a.GfxNativeBootInfo))
        return reject("boot-policy-unavailable", -3);
    if (initial.policy != 0) {
        ctx.logInfo("AMDGPU bind: software-policy pci-reads=0 mmio=0 native-writes=0 fallback=preserved");
        return 0;
    }
    const mode = std.mem.span(ctx.getOption("AMDGPU", "mode"));
    if (std.ascii.eqlIgnoreCase(mode, "native")) return reject("native-runtime-not-implemented", -8);
    if (mode.len != 0 and !std.ascii.eqlIgnoreCase(mode, "auto") and !std.ascii.eqlIgnoreCase(mode, "passive"))
        return reject("unsupported-mode", -2);
    boot.validate(initial) catch return reject("boot-framebuffer-unavailable", -3);
    const inventory = ctx.pciDeviceCount();
    if (inventory > 4096) return reject("inventory-limit", -4);
    for (0..inventory) |index| {
        var pci: a.PciDeviceInfo = .{};
        if (ctx.pciDeviceAt(@intCast(index), &pci) != 0) return reject("inventory-incomplete", -4);
        if (!identity.target(pci)) continue;
        if (device_count == devices.len) return reject("adapter-limit", -4);
        var reader: Reader = .{ .ctx = ctx, .pci = pci };
        const snapshot = identity.capture(pci, &reader) catch |err| {
            log("AMDGPU pci={x:0>2}:{x:0>2}.{x} rejected={s} writes=0 fallback=preserved", .{ pci.bus, pci.device, pci.function, @errorName(err) });
            return -5;
        };
        const measurement = probe.measure(&ctx, &snapshot) catch |err| {
            log("AMDGPU probe: rejected={s} cleanup={s} writes=0 fallback=preserved", .{ @errorName(err), if (probe.close(&ctx)) @as([]const u8, "OK") else "retained" });
            return -6;
        };
        if (!identity.stable(&snapshot, &reader)) return reject("pci-changed-during-probe", -5);
        devices[device_count] = .{ .snapshot = snapshot, .measured = measurement };
        device_count += 1;
        log("AMDGPU pci={x:0>2}:{x:0>2}.{x} id=1002:15d8 subsystem={x:0>4}:{x:0>4} pci-rev={x:0>2} asic-rev={x} external-rev={x} family={s}",
            .{ pci.bus, pci.device, pci.function, snapshot.subsystem_vendor, snapshot.subsystem_device, snapshot.pci_revision,
                measurement.chip.asic_revision, measurement.chip.external_revision, @tagName(measurement.chip.family) });
        const chip = measurement.chip;
        log("AMDGPU ip: gc={x} sdma={x} dcn={x} nbio={x} psp={x} smu={x} vcn={x} compiler={s} hardware-verified=no",
            .{ chip.gc, chip.sdma, chip.dcn, chip.nbio, chip.psp, chip.smu, chip.vcn, chip.compiler });
        log("AMDGPU bar5={x} measured-bytes={d} probe-prefix=memory-hubs mappings=0 native-writes=0", .{ snapshot.bars[5].base, snapshot.bars[5].bytes });
        if (measurement.uma) |uma| log("AMDGPU uma: physical={x} bytes={d} source=mc-fb-offset+rcc-memsize allocation=not-started", .{ uma.base, uma.bytes });
    }
    if (device_count == 0) return reject("target-absent", -4);
    for (devices[0..device_count]) |*device| {
        var reader: Reader = .{ .ctx = ctx, .pci = device.snapshot.pci };
        if (!identity.stable(&device.snapshot, &reader)) return reject("pci-changed-before-selection", -5);
    }
    var final: a.GfxNativeBootInfo = .{};
    if (display.bootInfo(&final) != a.gfx_output_ok or !std.meta.eql(initial, final)) return reject("boot-framebuffer-changed", -3);
    const selected = boot.select(devices[0..device_count], final) catch |err| {
        log("AMDGPU boot: rejected={s} writes=0 fallback=preserved", .{@errorName(err)});
        return -7;
    };
    boot_association = selected;
    log("AMDGPU boot: adapter={x} generation={d} source={s} uma-offset={x} boot-writers=untouched", .{ selected.adapter, selected.generation, @tagName(selected.path), selected.uma_offset });
    const device = &devices[selected.index];
    firmware.capture(&ctx, &device.snapshot) catch |err| {
        log("AMDGPU board: rejected={s} acpi={s} native-writes=0 fallback=preserved", .{ @errorName(err), @tagName(firmware.acpi) });
        return -9;
    };
    // Reconfirm the complete device and boot identity after source acquisition.
    var reader: Reader = .{ .ctx = ctx, .pci = device.snapshot.pci };
    if (!identity.stable(&device.snapshot, &reader)) return reject("pci-changed-after-vbios", -5);
    if (firmware.board.reservation) |reservation| {
        const uma = device.measured.uma orelse return reject("board-uma-unavailable", -9);
        if (reservation.bytes != 0 and (reservation.offset >= uma.bytes or reservation.bytes > uma.bytes - reservation.offset)) return reject("board-reservation-outside-uma", -9);
    }
    firmware_package.load(&ctx, &device.snapshot, device.measured.chip) catch |err| {
        log("AMDGPU firmware: rejected={s} resource={s} native-writes=0", .{ @errorName(err), firmware_package.last_resource });
        return -11;
    };
    if (!identity.stable(&device.snapshot, &reader)) return reject("pci-changed-after-firmware", -5);
    log("AMDGPU firmware: revision={s} profile=picasso-{s} files=12 bytes={d} epoch={d} CPU-only uploaded=0", .{
        @import("firmware.zig").lock.revision, @tagName(firmware_package.profile.?.socket), firmware_package.bytes, firmware_package.generation });
    memory_layout = @import("memory_layout.zig").Layout.create(device.measured.uma.?, device.measured.mc.?, selected.uma_offset, final.byte_length, firmware.board.reservation) catch |err| {
        log("AMDGPU memory plan: rejected={s} native-writes=0", .{@errorName(err)}); return -12;
    };
    const layout = &memory_layout.?;
    const memory = ctx.memory() orelse return reject("memory-contract-unavailable", -12);
    if (memory.reservedSpan(layout.physical.offset, layout.physical.bytes) != a.gfx_buffer_result_ok)
        return reject("uma-not-fully-reserved", -12);
    log("AMDGPU memory plan: cpu-physical={x} mc={x} gart={x} reserved={d} work={d} native-budget={d} physical-ram-added=0", .{
        layout.physical.offset, layout.mc.offset, layout.gart.offset, layout.pool.reserved_bytes, layout.pool.allocated_bytes, layout.native_budget });
    boot_snapshot.capture(&ctx, selected.adapter, final) catch |err| {
        log("AMDGPU boot capture: rejected={s} cleanup={s} native-writes=0", .{ @errorName(err), if (boot_snapshot.close()) @as([]const u8, "OK") else "retained" });
        return -10;
    };
    log("AMDGPU board: source={s} bytes={d} paths={d} panel={s} integrated={s} checksum={x}",
        .{ @tagName(firmware.source), firmware.board.image.len, firmware.board.path_count,
            if (firmware.board.panel != null) @as([]const u8, "present") else "absent",
            if (firmware.board.integrated != null) @as([]const u8, "present") else "absent", firmware.sha256 });
    log("AMDGPU boot capture: generation={d} bytes={d} hash={x} writers=resumed snapshot=retained effects=0", .{
        boot_snapshot.boot.generation, boot_snapshot.read.byte_length, boot_snapshot.sha256 });
    ctx.logInfo("AMDGPU bind: board-and-firmware-admission mappings=0 queues=0 firmware=unsubmitted native-writes=0 fallback=preserved");
    return 0;
}
pub export fn amdgpu_shutdown() callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(driver_api orelse return 0);
    if (!memory_runtime.close(.{ .memory_epoch = memory_runtime.epoch, .boot_held = false, .engines_quiesced = false }) or !boot_snapshot.close() or !firmware_package.close() or !firmware.close() or !probe.close(&ctx)) {
        ctx.logError("AMDGPU unbind: cleanup=retained module-release=blocked");
        return -1;
    }
    device_count = 0; boot_association = null; memory_layout = null;
    driver_api = null;
    return 0;
}
const Reader = struct {
    ctx: r4os.r4dev.DriverContext, pci: a.PciDeviceInfo,
    pub fn read(self: *Reader, offset: u16) u32 { return self.ctx.pciReadConfig32(self.pci, offset); }
};
fn log(comptime format: []const u8, args: anytype) void {
    const ctx = r4os.r4dev.DriverContext.init(driver_api orelse return);
    var buffer: [384]u8 = undefined;
    const message = std.fmt.bufPrintZ(&buffer, format, args) catch return;
    ctx.logInfo(message);
}
fn reject(reason: []const u8, status: i32) i32 {
    log("AMDGPU bind: rejected={s} native-writes=0 fallback=preserved", .{reason});
    return status;
}
