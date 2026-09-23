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
pub var native_start: @import("start_runtime.zig").Owner = .{};
pub var sdma_runtime: @import("sdma_jobs.zig").Owner = .{};
pub var vcn_runtime: @import("vcn_runtime.zig").Owner = .{};
pub var gc_runtime: @import("gc_runtime.zig").Owner = .{};
pub var queue_runtime: @import("queue_runtime.zig").Owner = .{};
pub var display_runtime: @import("display_core.zig").Owner = .{};
pub var display_present: @import("display_present.zig").Owner = .{};
pub var display_images: [2]@import("display_buffers.zig").Image = .{ .{}, .{} };
pub var display_pipeline: @import("display_pipeline.zig").Owner = .{};
pub var display_clock_runtime: @import("display_clock_owner.zig").Owner = .{};
pub var display_output: @import("display_output.zig").Owner = .{};
pub var native_worker: @import("native_worker.zig").Owner = .{};
pub var memory_layout: ?@import("memory_layout.zig").Layout = null;
pub var boot_snapshot: @import("boot_snapshot.zig").Snapshot = .{};
// Resident bounded snapshots never copy a large pool onto the init stack.
var devices: [8]boot.Device = undefined;
var device_count: usize = 0;
var audio_peer: ?@import("display_audio.zig").Peer = null;
pub var boot_association: ?boot.Association = null;

comptime {
    if (!@import("builtin").is_test) asm (r4os.r4dev.driverEntriesAsm("amdgpu_init", "amdgpu_shutdown"));
}
pub export fn amdgpu_init(api: *const a.DriverApi) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api);
    if (!ctx.apiCompatible() or driver_api != null) return -1;
    driver_api = api;
    device_count = 0;
    boot_association = null;
    audio_peer = null;
    memory_layout = null;
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
    const native_requested = std.ascii.eqlIgnoreCase(mode, "native");
    if (mode.len != 0 and !native_requested and !std.ascii.eqlIgnoreCase(mode, "auto") and !std.ascii.eqlIgnoreCase(mode, "passive"))
        return reject("unsupported-mode", -2);
    if (native_requested and !@import("native_worker.zig").supported(&ctx)) return reject("native-worker-unavailable", -8);
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
        log("AMDGPU pci={x:0>2}:{x:0>2}.{x} id=1002:15d8 subsystem={x:0>4}:{x:0>4} pci-rev={x:0>2} asic-rev={x} external-rev={x} family={s}", .{ pci.bus, pci.device, pci.function, snapshot.subsystem_vendor, snapshot.subsystem_device, snapshot.pci_revision, measurement.chip.asic_revision, measurement.chip.external_revision, @tagName(measurement.chip.family) });
        const chip = measurement.chip;
        log("AMDGPU ip: gc={x} sdma={x} dcn={x} nbio={x} psp={x} smu={x} vcn={x} compiler={s} hardware-verified=no", .{ chip.gc, chip.sdma, chip.dcn, chip.nbio, chip.psp, chip.smu, chip.vcn, chip.compiler });
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
    if (native_requested and !@import("asic_profile.zig").Profile.nativeBoard(device.snapshot, device.measured.chip))
        return reject("native-board-profile-unavailable", -13);
    firmware.capture(&ctx, &device.snapshot) catch |err| {
        log("AMDGPU board: rejected={s} stage={s} acpi={s} native-writes=0 fallback=preserved", .{ @errorName(err), @tagName(firmware.stage), @tagName(firmware.acpi) });
        return -9;
    };
    // Reconfirm the complete device and boot identity after source acquisition.
    var reader: Reader = .{ .ctx = ctx, .pci = device.snapshot.pci };
    if (!identity.stable(&device.snapshot, &reader)) return reject("pci-changed-after-vbios", -5);
    if (firmware.board.reservation) |reservation| {
        const uma = device.measured.uma orelse return reject("board-uma-unavailable", -9);
        if (reservation.bytes != 0 and (reservation.offset >= uma.bytes or reservation.bytes > uma.bytes - reservation.offset)) return reject("board-reservation-outside-uma", -9);
    }
    log("AMDGPU board: source={s} bytes={d} paths={d} panel={s} integrated={s} checksum={x}", .{ @tagName(firmware.source), firmware.board.image.len, firmware.board.path_count, if (firmware.board.panel != null) @as([]const u8, "present") else "absent", if (firmware.board.integrated != null) @as([]const u8, "present") else "absent", firmware.sha256 });
    if (firmware.board.integrated) |info| if (info.external) |external|
        log("AMDGPU board: external-connection-checksum={s} wiring=preserved", .{@tagName(external.checksum)});
    for (firmware.board.paths[0..firmware.board.path_count]) |path| {
        if (path.connector & 0x7000 != 0x3000) continue;
        log("AMDGPU board path: connector={x} encoder={x} external={x} i2c={?x} hpd={?x} active={d} caps={?x}",
            .{ path.connector, path.encoder, path.external_encoder, path.i2c_id, path.hpd_id, path.hpd_active, path.encoder_caps });
    }
    firmware_package.load(&ctx, &device.snapshot, device.measured.chip) catch |err| {
        log("AMDGPU firmware: rejected={s} resource={s} native-writes=0", .{ @errorName(err), firmware_package.last_resource });
        return -11;
    };
    if (!identity.stable(&device.snapshot, &reader)) return reject("pci-changed-after-firmware", -5);
    log("AMDGPU firmware: revision={s} profile={s}-{s} files=12 bytes={d} epoch={d} CPU-only uploaded=0", .{ @import("firmware.zig").lock.revision, @tagName(firmware_package.profile.?.family), @tagName(firmware_package.profile.?.socket), firmware_package.bytes, firmware_package.generation });
    log("AMDGPU firmware sources: baseline={s} raven2-rlc={s}", .{ @import("firmware.zig").lock.revision, @import("firmware.zig").lock.raven2_rlc_revision });
    const asic_profile = @import("asic_profile.zig").Profile.select(device.measured.chip) catch return reject("asic-profile-mismatch", -12);
    memory_layout = @import("memory_layout.zig").Layout.create(asic_profile, device.measured.uma.?, device.measured.mc.?, selected.uma_offset, final.byte_length, firmware.board.reservation) catch |err| {
        log("AMDGPU memory plan: rejected={s} native-writes=0", .{@errorName(err)});
        return -12;
    };
    const layout = &memory_layout.?;
    const memory = ctx.memory() orelse return reject("memory-contract-unavailable", -12);
    if (memory.unmanagedSpan(layout.physical.offset, layout.physical.bytes) != a.gfx_buffer_result_ok)
        return reject("uma-system-memory-exclusion-unproven", -12);
    log("AMDGPU memory plan: cpu-physical={x} mc={x} gart={x} reserved={d} work={d} native-budget={d} physical-ram-added=0", .{ layout.physical.offset, layout.mc.offset, layout.gart.offset, layout.pool.reserved_bytes, layout.pool.allocated_bytes, layout.native_budget });
    boot_snapshot.capture(&ctx, selected.adapter, final) catch |err| {
        log("AMDGPU boot capture: rejected={s} cleanup={s} native-writes=0", .{ @errorName(err), if (boot_snapshot.close()) @as([]const u8, "OK") else "retained" });
        return -10;
    };
    log("AMDGPU boot capture: generation={d} bytes={d} hash={x} writers=resumed snapshot=retained effects=0", .{ boot_snapshot.boot.generation, boot_snapshot.read.byte_length, boot_snapshot.sha256 });
    if (device.measured.chip.family == .raven2)
        ctx.logInfo("AMDGPU bind: raven2-board-admission mappings=0 queues=0 firmware=unsubmitted native-writes=0 fallback=preserved")
    else
        ctx.logInfo("AMDGPU bind: board-and-firmware-admission mappings=0 queues=0 firmware=unsubmitted native-writes=0 fallback=preserved");
    if (native_requested) {
        audio_peer = @import("display_audio.zig").capture(&ctx, device.snapshot.pci);
        log("AMDGPU display audio: HDA companion={s} format=48000-stereo-S16 physical-verified=no", .{if (audio_peer != null) @as([]const u8, "1002:15de") else "unavailable"});
        native_worker.start(&ctx, &display_output, .{ .advance = advanceNative, .recover = recoverNative, .restart = restartNative, .fault = nativeWorkerFault }) catch return reject("native-worker-unavailable", -8);
        ctx.logInfo("AMDGPU native start: asynchronous worker admitted; output ownership awaits confirmed scanout");
    }
    return 0;
}
/// Start worker entry used by the subsequent SDMA/GFX/display integration.
/// The passive bind has already pinned one exact board/firmware generation.
var native_step: []const u8 = "idle";
pub fn beginNative(memory_epoch: u64) !void {
    const ctx = r4os.r4dev.DriverContext.init(driver_api orelse return error.State);
    const selected = boot_association orelse return error.State;
    if (!boot_snapshot.valid or memory_layout == null) return error.State;
    const device = &devices[selected.index];
    if (!@import("asic_profile.zig").Profile.nativeBoard(device.snapshot, device.measured.chip) or !firmware_package.valid) return error.Unsupported;
    native_step = "memory-prepare";
    try memory_runtime.prepare(&ctx, &memory_layout.?, device.snapshot.bars[5].base, selected.adapter, memory_epoch);
    native_step = "start-prepare";
    const pitch_policy = @import("boot_pitch.zig").select(device.snapshot, device.measured.chip, firmware.sha256, boot_snapshot.boot);
    log("AMDGPU boot guard: pitch-policy={s} captured-registers-must-remain-stable=yes", .{@tagName(pitch_policy)});
    try native_start.prepare(&ctx, &memory_runtime, &device.snapshot, device.measured.chip, &firmware_package, boot_snapshot.boot, selected.uma_offset, pitch_policy);
    native_start.flow.allow_restore_degraded = @import("start_firmware.zig").restoreQuirk(device.snapshot, device.measured.chip, firmware.sha256);
}
/// Preemptible native-start pump. Physical activation stays behind the normal
/// bind policy until the display milestones integrate the full transition.
fn nativeWorkerFault() bool { return @atomicLoad(u32, &queue_runtime.wake_fault, .acquire) != 0; }
pub fn advanceNative() !bool {
    errdefer |failure| diagnoseNative(failure);
    if (native_start.self_address == 0) {
        if (boot_snapshot.boot.generation == std.math.maxInt(u64)) return error.State;
        try beginNative(boot_snapshot.boot.generation + 1);
    }
    if (!native_start.flow.firmwareReady()) {
        native_step = "firmware-advance";
        try native_start.advance();
        if (native_start.firmwareReady()) log("AMDGPU firmware admission: core=confirmed ASD=confirmed restore-lists={s} GC-power-saving={s}",
            .{ if (native_start.flow.plan.restoreConfirmed()) @as([]const u8, "confirmed") else "rejected",
            if (native_start.flow.plan.restoreConfirmed()) @as([]const u8, "eligible") else "disabled" });
        return false;
    }
    if (sdma_runtime.self_address == 0) {
        native_step = "memory-enable";
        try memory_runtime.enable(.{ .memory_epoch = memory_runtime.epoch, .boot_held = true, .engines_quiesced = true });
        native_step = "sdma-prepare";
        try sdma_runtime.prepare(&memory_runtime, &queue_runtime, &native_start);
    }
    native_step = "sdma-selftest";
    if (!try sdma_runtime.pollSelftest()) return false;
    // The fixed queue arena requires the first engine-storage lease. The
    // independent DPM table adds its lease only after SDMA owns that arena.
    native_step = "display-clock-prepare";
    if (display_clock_runtime.self_address == 0) try display_clock_runtime.prepare(&memory_runtime, &native_start);
    native_step = "display-clock-poll";
    if (!try display_clock_runtime.poll()) return false;
    native_step = "gc-prepare";
    if (gc_runtime.self_address == 0) try gc_runtime.prepare(&memory_runtime, &queue_runtime, &native_start, &sdma_runtime);
    native_step = "gc-advance";
    if (gc_runtime.engine.phase != .ready and !try gc_runtime.advance()) return false;
    if (vcn_runtime.self_address == 0) {
        sdma_runtime.media = &vcn_runtime;
        gc_runtime.renderer.media = &vcn_runtime;
        native_step = "vcn-prepare";
        try vcn_runtime.prepare(&memory_runtime, &queue_runtime, &native_start, &gc_runtime);
    }
    native_step = "vcn-advance";
    if (!try vcn_runtime.advance()) return false;
    native_step = "power-prepare";
    if (!try sdma_runtime.power.prepare(&sdma_runtime, &native_start)) return false;
    if (!sdma_runtime.active) {
        const ctx = r4os.r4dev.DriverContext.init(driver_api orelse return error.State);
        if (display_runtime.self_address == 0) display_runtime.audio_peer = audio_peer;
        native_step = "display-request";
        if (display_output.self_address == 0) try display_output.request(&ctx, &native_start, &sdma_runtime, &display_runtime, &display_pipeline,
            &display_present, .{ &display_images[0], &display_images[1] }, &firmware.board, display_clock_runtime.table.?, gc_runtime.engine.gb_addr_config);
        native_step = "sdma-activate";
        try sdma_runtime.activate(&native_start, &firmware.board);
    }
    return sdma_runtime.active;
}
/// Resident snapshots only, before recovery erases them. No extra device
/// reads/writes and no caller pointers outlive this bounded owner callback.
fn diagnoseNative(failure: anyerror) void {
    log("AMDGPU native failure: error={s} step={s} prepare={s} firmware={s} failed={s} upload={d}",
        .{ @errorName(failure), native_step, @tagName(native_start.prepare_step), @tagName(native_start.flow.phase), @tagName(native_start.flow.failed_phase), native_start.flow.upload });
    diagnoseGc();
    log("AMDGPU display request: step={s} caps={x} display-bytes={d} output-bytes={d} boot={d}x{d} format={d}",
        .{ @tagName(display_output.request_step), display_output.request_caps, display_output.request_display_bytes, display_output.request_output_bytes,
        native_start.hold.boot.width, native_start.hold.boot.height, native_start.hold.boot.format });
    if (firmware.board.panel) |panel| log("AMDGPU display panel: size={d}x{d} bpc={d} misc={x} clock={d} blank={d}/{d} sync={d}/{d}/{d}/{d}",
        .{ panel.width, panel.height, panel.bpc, panel.misc, panel.pixel_clock_khz, panel.h_blank, panel.v_blank,
        panel.h_sync_offset, panel.h_sync_width, panel.v_sync_offset, panel.v_sync_width });
    const gc = &gc_runtime.engine;
    inline for (.{ gc.completion_before, gc.completion_failure }, 0..) |sample, index| {
        log("AMDGPU GC completion {d}: valid={x} vm-status={x} vm-page={x}:{x} cp={x} stalls={x}/{x}/{x} grbm={x}",
            .{ index, sample.valid, sample.values[0], sample.values[2], sample.values[1], sample.values[3],
            sample.values[4], sample.values[5], sample.values[6], sample.values[7] });
    }
    const park = &native_start.flow.engines;
    log("AMDGPU park: wait={s} polls={d} sampled={x} smu-version={x} interface={d} response={x}",
        .{ @tagName(park.wait), park.polls, park.sampled, native_start.flow.smu_version_raw, native_start.flow.smu_interface, native_start.flow.smu.response });
    log("AMDGPU park controls: cp={x} halt={x} mec={x} halt={x} rlc={x} sdma-halt={x} rb={x} ib={x}",
        .{ park.samples[0], @import("start_engines.zig").cp_halt_mask, park.samples[1], @import("start_engines.zig").mec_halt_mask,
        park.samples[2], park.samples[3], park.samples[4], park.samples[5] });
    log("AMDGPU park status: sdma={x} grbm={x} grbm2={x} serdes-cu={x} serdes-noncu={x}",
        .{ park.samples[6], park.samples[7], park.samples[8], park.samples[9], park.samples[10] });
    const flow = &native_start.flow;
    log("AMDGPU PSP receipt: response={x} token={d} address={x} ring={d} tmr={d} asd={d}",
        .{ flow.psp.response, flow.psp.token, flow.psp.firmware_address, @intFromBool(flow.psp.ring_ready),
        @intFromBool(flow.psp.tmr_ready), @intFromBool(flow.psp.asd_ready) });
    if (flow.upload < flow.plan.count) {
        const entry = &flow.plan.entries[flow.upload];
        log("AMDGPU PSP entry: index={d} role={s} type={x} offset={d} bytes={d} version={d} confirmed={d}",
            .{ flow.upload, @tagName(entry.role), entry.fw_type, entry.span.offset, entry.span.bytes, entry.version, @intFromBool(entry.confirmed) });
    }
    for (flow.plan.entries[0..flow.plan.count], 0..) |*entry, i| {
        if (!entry.receipt) continue;
        log("AMDGPU PSP upload: index={d} type={x} bytes={d} response={x} confirmed={d} address={x}",
            .{ i, entry.fw_type, entry.span.bytes, entry.response, @intFromBool(entry.confirmed), entry.address });
    }
    log("AMDGPU PSP restore rejects: {d}; exact-board-awake-policy={d} restore-confirmed={d}",
        .{ flow.restore_rejected, @intFromBool(flow.allow_restore_degraded), @intFromBool(flow.plan.restoreConfirmed()) });
    const sdma = &sdma_runtime.engine;
    log("AMDGPU SDMA admission: prepare={s} gate={s} sampled={x} touched={d} running={d} selftest={d}",
        .{ @tagName(sdma_runtime.prepare_step), @tagName(sdma.admission), sdma.sampled,
        @intFromBool(sdma.touched), @intFromBool(sdma.running), @intFromBool(sdma_runtime.selftest_submitted) });
    log("AMDGPU SDMA registers: before halt={x} status={x} rb={x} ib={x}; after halt={x} rb={x} ib={x}",
        .{ sdma.samples[0], sdma.samples[1], sdma.samples[2], sdma.samples[3], sdma.samples[4], sdma.samples[5], sdma.samples[6] });
    log("AMDGPU native guard: memory={d} guard={d} effects={d} hold={d} pci-changed={d} mc=0x{x} offset=0x{x} pitch={d} firmware-pitch={d}",
        .{ @intFromBool(memory_runtime.prepared), @intFromBool(native_start.guard.valid), @intFromBool(native_start.hold.effects), native_start.hold.held_generation,
        @intFromBool(native_start.pci_changed), if (memory_layout) |layout| layout.mc.offset else 0,
        if (boot_association) |selected| selected.uma_offset else 0, boot_snapshot.boot.pitch, @intFromBool(native_start.guard.firmware_pitch) });
    for (&native_start.guard.values, 0..) |*v, pipe| {
        log("AMDGPU guard pipe{d}: cntl={x} fmt={x} tile={x} pitch={x} primary={x}:{x} inuse={x}:{x} flip={x} surface={x}",
            .{ pipe, v[0], v[1], v[2], v[3], v[5], v[4], v[7], v[6], v[8], v[9] });
        log("AMDGPU guard pipe{d}: top={x} bottom={x} opp={x} otg={x} control={x} htotal={x} vtotal={x} blank={x}",
            .{ pipe, v[10], v[11], v[12], v[13], v[14], v[15], v[16], v[17] });
    }
}
fn diagnoseGc() void {
    const gc = &gc_runtime.engine;
    log("AMDGPU GC: phase={s} faulted={d} round={d} kiq={d} mapped={d} stopping={d} dequeue={d} stop-error={s} polls={d}",
        .{ @tagName(gc.phase), @intFromBool(gc.faulted), gc.selftest_round, @intFromBool(gc.kiq_live), @intFromBool(gc.compute_mapped),
        @intFromBool(gc.stop_started), @intFromBool(gc.kiq_dequeue), if (gc.stop_failure) |failure| @errorName(failure) else "none", gc.deadline.polls });
    log("AMDGPU GC rings: gfx={d}/{d}/{x} compute={d}/{d}/{x} kiq={d}/{d}/{x} hqd={x} sampled={d}",
        .{ gc.rings[0].read, gc.rings[0].write, gc.sampled_rptr[0], gc.rings[1].read, gc.rings[1].write, gc.sampled_rptr[1],
        gc.rings[2].read, gc.rings[2].write, gc.sampled_rptr[2], gc.sampled_hqd, @intFromBool(gc.hqd_sampled) });
    log("AMDGPU GC fences: gfx={x}/{x} compute={x}/{x} kiq={x}/{x}; park={s} polls={d} sampled={x}",
        .{ gc.sampled_fence[0][0], gc.sampled_fence[0][1], gc.sampled_fence[1][0], gc.sampled_fence[1][1],
        gc.sampled_fence[2][0], gc.sampled_fence[2][1], @tagName(gc.park.wait), gc.park.polls, gc.park.sampled });
    log("AMDGPU GC samples: valid={x} markers={x}/{x}/{x} completion-grbm={x}",
        .{ gc.sampled_mask, gc.sampled_marker[0], gc.sampled_marker[1], gc.sampled_marker[2], gc.completion_status });
    log("AMDGPU GC park status: cp={x} mec={x} rlc={x} grbm={x} grbm2={x} cu={x} noncu={x}",
        .{ gc.park.samples[0], gc.park.samples[1], gc.park.samples[2], gc.park.samples[7], gc.park.samples[8], gc.park.samples[9], gc.park.samples[10] });
}
pub export fn amdgpu_shutdown() callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(driver_api orelse return 0);
    native_worker.requestStop();
    if (native_worker.self_address == 0) {
        if (!recoverNative()) return -1;
    } else {
        // Shutdown is called once by the R4D owner. A nonblocking join or
        // firmware cleanup phase being pending is not a terminal failure.
        // Keep all receipts and allocations retained while callbacks retire;
        // never widen the lower-level hardware deadlines or force release.
        var io: ShutdownIo = .{ .ctx = ctx, .clock = native_worker.clock orelse return -1 };
        if (!@import("shutdown_drain.zig").run(&io, shutdownNativeStep)) {
            ctx.logError("AMDGPU shutdown: bounded native drain failed; resources retained");
            return -1;
        }
    }
    if (!boot_snapshot.close() or !firmware_package.close() or !firmware.close() or !probe.close(&ctx)) {
        ctx.logError("AMDGPU unbind: cleanup=retained module-release=blocked");
        return -1;
    }
    device_count = 0;
    boot_association = null;
    memory_layout = null;
    native_worker = .{};
    driver_api = null;
    return 0;
}
const ShutdownIo = struct {
    ctx: r4os.r4dev.DriverContext,
    // Captured during init: querying a new resource service after the
    // kernel's admission close may already be forbidden.
    clock: r4os.r4dev.DriverResourceContext,
    pub fn nowNs(self: *@This()) u64 { return self.clock.nowNs(); }
    pub fn wait(self: *@This()) void { self.ctx.waitTicks(1); }
};
fn shutdownNativeStep() bool { return native_worker.join() and recoverNative(); }
var recovery_last_block: []const u8 = "";
var recovery_last_firmware: @import("start_flow.zig").Phase = .empty;
var recovery_last_gc_phase: ?@import("gc_engine.zig").Phase = null;
var recovery_last_gc_wait: u8 = 255;
var recovery_last_gc_failure: ?anyerror = null;
fn recoverNative() bool {
    var step: []const u8 = "admission";
    var complete = false;
    defer {
        if (complete) {
            recovery_last_block = "";
            recovery_last_firmware = .empty;
            recovery_last_gc_phase = null; recovery_last_gc_wait = 255; recovery_last_gc_failure = null;
        } else if (!std.mem.eql(u8, step, recovery_last_block) or recovery_last_firmware != native_start.flow.phase or
            recovery_last_gc_phase != gc_runtime.engine.phase or recovery_last_gc_wait != @intFromEnum(gc_runtime.engine.park.wait) or
            recovery_last_gc_failure != gc_runtime.engine.stop_failure) {
            recovery_last_block = step;
            recovery_last_firmware = native_start.flow.phase;
            recovery_last_gc_phase = gc_runtime.engine.phase; recovery_last_gc_wait = @intFromEnum(gc_runtime.engine.park.wait);
            recovery_last_gc_failure = gc_runtime.engine.stop_failure;
            diagnoseGc();
            log("AMDGPU recovery pending: step={s} firmware={s} clock={s} gc-stop={s} engine-users={d} mappings={d} gmc={d}/{d}",
                .{ step, @tagName(native_start.flow.phase), @tagName(display_clock_runtime.phase), @tagName(sdma_runtime.gc_stop.wait),
                memory_runtime.engine_users, memory_runtime.mapping_users, @intFromBool(memory_runtime.controller.touched), @intFromBool(memory_runtime.controller.enabled) });
            log("AMDGPU recovery firmware: failure={s} failed={s} park={s} PSP-operation={s} response={x} token={d} ring={d} tmr={d} asd={d}",
                .{ if (native_start.flow.failure) |failure| @errorName(failure) else "none", @tagName(native_start.flow.failed_phase),
                @tagName(native_start.flow.engines.wait), @tagName(native_start.flow.psp.operation), native_start.flow.psp.response,
                native_start.flow.psp.token, @intFromBool(native_start.flow.psp.ring_ready), @intFromBool(native_start.flow.psp.tmr_ready), @intFromBool(native_start.flow.psp.asd_ready) });
            if (native_start.flow.phase == .cleanup_parked or native_start.flow.phase == .retained) {
                const park = &native_start.flow.engines;
                log("AMDGPU recovery park: sampled={x} polls={d} cp={x} mec={x} rlc={x} sdma={x}/{x}/{x}/{x}",
                    .{ park.sampled, park.polls, park.samples[0], park.samples[1], park.samples[2],
                    park.samples[3], park.samples[4], park.samples[5], park.samples[6] });
                log("AMDGPU recovery park idle: grbm={x} grbm2={x} serdes-cu={x} serdes-noncu={x}",
                    .{ park.samples[7], park.samples[8], park.samples[9], park.samples[10] });
            }
        }
    }
    // Stop application admission even if the worker cannot yet be joined.
    // Binding/queue are immutable from activation until this owner retires it.
    const memory_closed = memory_runtime.closeAdmission();
    const announced = sdma_runtime.closeAdmission() and memory_closed;
    // Stop and join the sole BO/queue owner before starting independent DCN
    // restoration tasks or mutating any of its retained maps and pools.
    step = "queue-worker";
    if (!queue_runtime.stopWorker() or !announced) return false;
    if (display_output.self_address != 0) display_output.phase = .closing;
    step = "display-reset"; if (!display_output.beginReset()) return false;
    step = "power";
    if (!sdma_runtime.power.close(&sdma_runtime)) return false;
    step = "display-close"; if (!display_runtime.close()) return false;
    step = "sdma-close"; if (!sdma_runtime.close()) return false;
    step = "display-resources";
    if (!display_output.additional.reset()) return false;
    if (!display_output.modes.close()) return false;
    if (!display_output.cursor.close(&memory_runtime, true)) return false;
    for (&display_images) |*frame| if (!frame.close(true)) return false;
    step = "display-clock-close"; if (!display_clock_runtime.close()) return false;
    step = "memory-disable";
    if (memory_runtime.controller.touched) memory_runtime.controller.disable(&memory_runtime.registers,
        .{ .memory_epoch = memory_runtime.epoch, .boot_held = native_start.hold.held_generation != 0,
            .engines_quiesced = sdma_runtime.closed or (sdma_runtime.self_address == 0 and native_start.firmwareReady()) }) catch return false;
    step = "queue-close"; if (!queue_runtime.close(null)) return false;
    // SDMA.close already parked every engine before releasing its arena.
    // GMC restoration changes no GC/SDMA execution controls. Re-read the
    // full stop receipt, but do not inject a second CP reset afterwards.
    if (sdma_runtime.closed and sdma_runtime.memory == &memory_runtime and sdma_runtime.gc_stop.confirmed)
        native_start.flow.cleanup_recheck = true;
    step = "firmware-quiesce"; if (!native_start.quiesce()) return false;
    step = "scanout-restore";
    if (native_start.self_address != 0) display_output.confirmRestore() catch return false;
    if (!display_output.retireReset()) return false;
    step = "native-close"; if (!native_start.close() or !display_output.closeMetadata()) return false;
    step = "memory-close";
    if (!memory_runtime.close(.{ .memory_epoch = memory_runtime.epoch, .boot_held = false, .engines_quiesced = false })) return false;
    // All worker handles, notifications, backend bindings, BOs and callbacks
    // have retired. A later initialization starts with fresh runtime owners.
    sdma_runtime = .{}; gc_runtime = .{}; vcn_runtime = .{}; queue_runtime = .{};
    display_present = .{}; display_pipeline = .{};
    complete = true;
    return true;
}
fn restartNative() !void {
    const ctx = r4os.r4dev.DriverContext.init(driver_api orelse return error.State);
    if (native_start.self_address != 0 or memory_runtime.self_address != 0 or queue_runtime.self_address != 0 or
        display_output.self_address != 0 or !boot_snapshot.valid) return error.Unconfirmed;
    const display = ctx.graphicsDisplay() orelse return error.Unsupported;
    var current: a.GfxNativeBootInfo = .{};
    if (display.bootInfo(&current) != a.gfx_output_ok or !@import("device_loss.zig").restartBoot(boot_snapshot.boot, current)) return error.Unconfirmed;
    const selected = boot_association orelse return error.State;
    if (!boot_snapshot.close()) return error.Retained;
    boot_snapshot.capture(&ctx, selected.adapter, current) catch |err| {
        _ = boot_snapshot.close(); // failed release keeps the snapshot resident
        return err;
    };
    boot_association.?.generation = current.generation;
    log("AMDGPU recovery: boot scanout confirmed; fresh start generation={d}; old application contexts remain lost", .{current.generation});
}
const Reader = struct {
    ctx: r4os.r4dev.DriverContext,
    pci: a.PciDeviceInfo,
    pub fn read(self: *Reader, offset: u16) u32 {
        return self.ctx.pciReadConfig32(self.pci, offset);
    }
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

// Private native-stage entrypoints retained in the driver artifact. They are
// not published as an application API or invoked by passive initialization.
pub export fn amdgpu_native_begin(epoch: u64) callconv(.c) i32 {
    if (native_worker.self_address != 0) return -1;
    beginNative(epoch) catch return -1;
    return 0;
}
pub export fn amdgpu_native_advance() callconv(.c) i32 {
    if (native_worker.self_address != 0) return -1;
    return @intFromBool(advanceNative() catch return -1);
}
/// Private staged display boundary. Native policy remains gated until the
/// connector/modeset owner supplies and confirms the physical clock point.
pub export fn amdgpu_display_prepare(limits: *const @import("display_core.zig").c.struct_r4dcn_limits, mode: *const @import("display_core.zig").c.struct_r4dcn_mode) callconv(.c) i32 {
    if (native_worker.self_address != 0) return -1;
    const ctx = r4os.r4dev.DriverContext.init(driver_api orelse return -1);
    if (gc_runtime.engine.phase != .ready or !sdma_runtime.active) return -1;
    const architecture = gc_runtime.architecture orelse return -1;
    if (limits.gb_addr_config != architecture.gb_addr_config) return -1;
    display_runtime.prepareBoot(&ctx, &memory_runtime, &native_start, &firmware.board, limits.*, mode.*) catch return -1;
    return 0;
}
pub export fn amdgpu_display_poll() callconv(.c) i32 {
    if (native_worker.self_address != 0) return -1;
    if (!display_runtime.poll()) return 1;
    return display_runtime.result;
}
pub export fn amdgpu_panel_bind() callconv(.c) i32 {
    if (native_worker.self_address != 0) return -1;
    display_runtime.bindPanel() catch return -1;
    return 0;
}
pub export fn amdgpu_panel_operation(operation: u32, value: u32) callconv(.c) i32 {
    if (native_worker.self_address != 0) return -1;
    if (operation < 1 or operation > 9) return -1;
    const tag: @import("panel_runtime.zig").Operation = @enumFromInt(operation);
    if (value > 65535) return -1;
    display_runtime.panelCommand(tag, @intCast(value)) catch return -1;
    return 0;
}

pub export fn amdgpu_panel_brightness(output_id: *const a.GfxOutputId) callconv(.c) i32 {
    if (native_worker.self_address != 0) return -1;
    if (@intFromPtr(output_id) == 0 or @intFromPtr(output_id) % @alignOf(a.GfxOutputId) != 0) return -1;
    display_runtime.brightnessCommand(output_id.*) catch return -1;
    return 0;
}

pub export fn amdgpu_hdmi_bind() callconv(.c) i32 {
    if (native_worker.self_address != 0) return -1;
    display_runtime.bindHdmi() catch return -1;
    return 0;
}
pub export fn amdgpu_hdmi_operation(operation: u32) callconv(.c) i32 {
    if (native_worker.self_address != 0) return -1;
    if (operation < 1 or operation > 7) return -1;
    display_runtime.hdmiCommand(@enumFromInt(operation)) catch return -1;
    return 0;
}
