// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Immutable copied device facts, published only for this bound incarnation.
const std = @import("std");
const amd = @import("r4amd");
const fw = @import("firmware.zig");
const Error = @import("start_common.zig").Error;
pub fn profile(native: *const @import("start_runtime.zig").Owner,
    engine: *const @import("gc_engine.zig").Owner, architecture: amd.R4AmdArchitecture,
    board: *const @import("bios.zig").Board) Error!amd.R4AmdDeviceFactsV3 {
    const copied = try capture(native, engine, architecture);
    return .{ .facts = copied,
        .timestamp_clock_khz = board.picassoTimestampClock() catch 0,
        .native_binding_capacity = @import("render_virtual.zig").capacity,
        .max_backing_bytes = @import("render_virtual.zig").max_backing_bytes };
}
pub fn capture(native: *const @import("start_runtime.zig").Owner,
    engine: *const @import("gc_engine.zig").Owner, architecture: amd.R4AmdArchitecture) Error!amd.R4AmdDeviceFacts {
    const chip = native.chip orelse return error.Unconfirmed;
    const memory = native.memory orelse return error.Unconfirmed;
    const layout = memory.layout orelse return error.Unconfirmed;
    const store = native.flow.store orelse return error.Unconfirmed;
    if (!native.firmwareReady() or !store.valid or engine.phase != .ready or engine.faulted or engine.stop_started or
        chip.family != .picasso or chip.external_revision != architecture.chip_revision or
        architecture.memory_generation != memory.epoch or architecture.gb_addr_config != engine.gb_addr_config or
        engine.cu_mask == 0 or engine.cu_mask & ~@as(u32, 0x7ff) != 0 or engine.rb_mask == 0 or engine.rb_mask & ~@as(u32, 3) != 0 or
        layout.native_budget == 0 or layout.native_budget > layout.physical.bytes or !@import("identity.zig").target(native.snapshot.pci)) return error.Unconfirmed;
    var me_feature: u32 = 0;
    var mec_feature: u32 = 0;
    for (&fw.lock.firmware, &store.layouts) |spec, parsed| {
        if (spec.role == .me) me_feature = parsed.feature;
        if (spec.role == .mec) mec_feature = parsed.feature;
    }
    if (me_feature == 0 or mec_feature == 0) return error.Unconfirmed;
    const topology = store.container(.gpu_info) orelse return error.Unconfirmed;
    const parsed = fw.verify(topology, fw.specification(.gpu_info)) catch return error.Unconfirmed;
    const payload = parsed.payload.slice(topology);
    var limits: [15]u32 = undefined;
    for (&limits, 0..) |*value, i| value.* = std.mem.readInt(u32, payload[i * 4 ..][0..4], .little);
    if (limits[0] != 1 or limits[1] != 11 or limits[2] != 1 or limits[3] != 2 or limits[11] != 64 or
        @popCount(engine.cu_mask) > limits[1] or @popCount(engine.rb_mask) > limits[3]) return error.Unconfirmed;
    return .{ .architecture = architecture, .version = 1, .size = @sizeOf(amd.R4AmdDeviceFacts),
        .pci_domain = 0, .pci_bus = native.snapshot.pci.bus, .pci_device = native.snapshot.pci.device,
        .pci_function = native.snapshot.pci.function, .pci_revision = native.snapshot.pci_revision,
        .asic_revision = chip.asic_revision, .cu_mask = engine.cu_mask, .rb_mask = engine.rb_mask,
        .pfp_fw = fw.specification(.pfp).ucode_version, .me_fw = fw.specification(.me).ucode_version,
        .mec_fw = fw.specification(.mec).ucode_version, .me_feature = me_feature, .mec_feature = mec_feature,
        .ce_fw = fw.specification(.ce).ucode_version, .smu_fw = native.flow.smu_version, .flags = 3,
        .uma_bytes = layout.physical.bytes, .native_budget = layout.native_budget,
        .va_start = amd.native_va_start, .va_end = amd.native_va_end, .max_allocation_bytes = architecture.max_image_bytes,
        .max_se = limits[0],
        .max_cu_per_sh = limits[1],
        .max_sh_per_se = limits[2],
        .max_rb_per_se = limits[3],
        .num_tccs = limits[4],
        .num_gprs = limits[5],
        .max_gs_threads = limits[6],
        .gs_table_depth = limits[7],
        .gs_primitive_depth = limits[8],
        .parameter_cache_depth = limits[9],
        .double_offchip_lds = limits[10],
        .wave_size = limits[11],
        .max_waves_per_simd = limits[12],
        .max_scratch_slots_per_cu = limits[13],
        .lds_bytes = limits[14],
        .reserved = 0 };
}
