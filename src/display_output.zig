// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Initial internal-panel takeover in the existing serialized queue worker.
//! Hardware tasks join before publication; common callbacks never wait for
//! that same worker. The outer native owner performs whole-device recovery.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const dc = @import("display_core.zig");
const buffers = @import("display_buffers.zig");
const pipeline = @import("display_pipeline.zig");
const present = @import("display_present.zig");
const sdma = @import("sdma_jobs.zig");
const start = @import("start_runtime.zig");
const clocks = @import("display_clocks.zig");
const Outputs = @TypeOf(@as(r4os.r4dev.DriverContext, undefined).graphicsOutputs().?);
pub const Phase = enum { empty, allocate, copy, publish_buffer, prepare_core, wait_core, bind_panel, wait_panel, bind_hdmi, wait_hdmi, commit_core, wait_commit,
    shadow, publication, prepare_common, bind_scanout, wait_bind, enable, wait_enable, stream, wait_stream, sample, wait_sample,
    acknowledge, wait_ack, light, wait_light, handoff, active, failed, closing };
pub const Owner = struct {
    self_address: usize = 0,
    ctx: ?r4os.r4dev.DriverContext = null,
    native: ?*start.Owner = null,
    engine: ?*sdma.Owner = null,
    core: ?*dc.Owner = null,
    pipeline: ?*pipeline.Owner = null,
    present: ?*present.Owner = null,
    frames: [2]*buffers.Image = undefined,
    board: ?*const @import("bios.zig").Board = null,
    clocks: clocks.Table = undefined,
    limits: dc.c.struct_r4dcn_limits = undefined,
    mode: dc.c.struct_r4dcn_mode = undefined,
    shape: buffers.Shape = undefined,
    shadow: buffers.Shadow = .{},
    display: ?r4os.driver_display.Context = null,
    outputs: ?Outputs = null,
    publication: a.GfxOutputPublication = .{},
    output: a.GfxOutputId = .{},
    prepared: a.GfxNativeState = .{},
    committed: a.GfxNativeState = .{},
    epoch: dc.scanout.Epoch = undefined,
    target: a.GfxOutputTarget = .{},
    original_boot: a.GfxNativeBootInfo = .{},
    initial_receipt: ?dc.scanout.Receipt = null,
    phase: Phase = .empty,
    buffer_index: u1 = 0,
    failure: ?anyerror = null,
    failed_phase: Phase = .empty,
    last_status: i32 = 0,
    deadline: u64 = 0,
    last_time: u64 = 0,
    restore_requested: u32 = 0,
    restore_ready: u32 = 0,
    reset_original: u64 = 0,
    reset_state: a.GfxNativeState = .{},
    reset_retired: bool = false,
    callback_confirmed: bool = false,
    brightness_pending: bool = false,
    next_brightness: u64 = 0,
    health_pending: bool = false,
    next_health: u64 = 0,
    health_retry_deadline: u64 = 0,
    statistics: @import("display_stats.zig").Owner = .{},
    cursor: @import("display_cursor.zig").Owner = .{},
    modes: @import("display_modes.zig").Owner = .{},
    connector: @import("display_connector.zig").Owner = .{},
    additional: @import("display_head.zig").Owner = .{},
    mode_inbox: ?a.GfxDriverModeJob = null,
    slot_base: u8 = 0,
    incoming: [64]?a.GfxDriverJob = @splat(null),
    hdmi_present: bool = false,
    primary_failure: ?anyerror = null,
    primary_stop_pending: bool = false,
    primary_stop_attempted: bool = false,
    primary_stopped: bool = false,
    pub fn request(self: *Owner, ctx: *const r4os.r4dev.DriverContext, native: *start.Owner, engine: *sdma.Owner,
        core: *dc.Owner, pipe: *pipeline.Owner, presentation: *present.Owner, frames: [2]*buffers.Image,
        board: *const @import("bios.zig").Board, table: clocks.Table, gb_addr_config: u32) !void
    {
        if (self.self_address != 0 or !native.firmwareReady() or engine.memory != native.memory or engine.client != null or engine.active) return error.State;
        const display = ctx.graphicsDisplay() orelse return error.Unsupported;
        const outputs = ctx.graphicsOutputs() orelse return error.Unsupported;
        if (display.table.prepare_held == 0 or display.table.transition == 0 or outputs.table.publish == 0 or outputs.table.withdraw == 0 or
            !display.supportsReset() or !display.supportsPresentationStats() or !display.supportsPresentationInfo() or
            !outputs.supportsHotplug() or !outputs.supportsModes()) return error.Unsupported;
        const mode = try pipeline.bootMode(board, native);
        const have_hdmi = blk: {
            _ = @import("hdmi.zig").route(board) catch |err| {
                if (err == error.Unsupported) break :blk false;
                return err;
            };
            break :blk true;
        };
        const shape = try buffers.Shape.make(mode.width, mode.height, false);
        const now = ctx.resources().?.nowNs();
        if (now == 0 or now > std.math.maxInt(u64) - 120 * std.time.ns_per_s) return error.Clock;
        self.* = .{ .self_address = @intFromPtr(self), .ctx = ctx.*, .native = native, .engine = engine, .core = core, .pipeline = pipe,
            .present = presentation, .frames = frames, .board = board, .clocks = table, .mode = mode, .shape = shape,
            .display = display, .outputs = outputs, .phase = .allocate, .last_time = now, .deadline = now + 120 * std.time.ns_per_s,
            .original_boot = native.hold.boot, .hdmi_present = have_hdmi,
            // ASIC limits bound DML admission; actual programmed clocks still
            // require the SMU/ATOM acknowledgements in the pipeline owner.
            .limits = .{ .channels = board.integrated.?.uma_channels, .dcf_khz = table.dcf_khz, .fabric_khz = table.fabric_khz,
                .soc_khz = table.soc_khz, .disp_khz = 1108000, .dpp_khz = 720000, .ref_khz = try board.displayReferenceClock(),
                .gb_addr_config = gb_addr_config, .reserved = 0 } };
        engine.client = .{ .context = self.self_address, .work = work, .available = available, .accept = accept, .drain = drain, .lost = lost };
    }
    fn from(raw: usize) *Owner { return @ptrFromInt(raw); }
    fn lost(raw: usize) void {
        const self = from(raw);
        if (self.phase != .failed and self.phase != .closing) self.fail(error.DeviceLost);
    }
    fn available(raw: usize) bool {
        const self = from(raw);
        if (self.phase != .active or !self.modes.ready or self.core.?.thread != 0 or
            @atomicLoad(u32, &self.restore_requested, .acquire) != 0) return false;
        for (&self.incoming) |*entry| if (entry.* == null) return true;
        return false;
    }
    fn accept(raw: usize, input: a.GfxDriverJob) bool {
        if (!present.supports(input.operation)) return false;
        const self = from(raw);
        for (&self.incoming) |*entry| if (entry.* == null) {
            entry.* = input; self.dispatch(); return true;
        };
        return false;
    }
    fn dispatch(self: *Owner) void {
        for (&self.incoming) |*entry| if (entry.*) |input| {
            const primary = input.display_target.connector_id == 0 or input.display_target.connector_id == self.output.connector_id;
            const head = &self.additional;
            const known = (primary and self.primary_failure == null) or (!primary and head.phase == .active and !head.draining and std.meta.eql(input.display_target, head.target));
            if (!known) {
                if (self.engine.?.queue.?.complete(&input.fence, a.gfx_queue_result_cancelled, 1) == 1) entry.* = null;
                continue;
            }
            const owner = if (primary) self.present.? else &head.presentation;
            if (!(if (primary) self.modes.permitsQueue() and self.cursor.permitsQueue() else head.modes.permitsQueue()) or !owner.available()) continue;
            entry.* = null; owner.accept(input); return;
        };
    }
    fn modeWork(self: *Owner) !void {
        if (self.mode_inbox != null or self.additional.mode_inbox != null) return;
        var job: a.GfxDriverModeJob = .{};
        const result = self.outputs.?.takeMode(&self.engine.?.binding, &job);
        if (result == 0 or result == a.gfx_output_error_busy) return;
        if (result != a.gfx_output_ok) return error.Publication;
        if (self.additional.self_address != 0 and job.assignment.output.connector_id == self.additional.output.connector_id)
            self.additional.mode_inbox = job else self.mode_inbox = job;
    }
    fn drain(raw: usize) bool {
        const self = from(raw);
        self.present.?.cancel_display = true; self.additional.presentation.cancel_display = true;
        self.present.?.work(); self.additional.presentation.work();
        for (&self.incoming) |*entry| if (entry.*) |job| {
            if (self.engine.?.queue.?.complete(&job.fence, a.gfx_queue_result_cancelled, 1) != 1) return false;
            entry.* = null;
        };
        return (self.present.?.input == null or self.present.?.ticket != null) and
            (self.additional.presentation.input == null or self.additional.presentation.ticket != null);
    }
    fn work(raw: usize) void {
        const self = from(raw);
        if (self.self_address != raw) return;
        self.present.?.work(); self.additional.presentation.work();
        if (self.phase == .failed or self.phase == .closing or @atomicLoad(u32, &self.restore_requested, .acquire) != 0) return;
        const now = self.ctx.?.resources().?.nowNs();
        if (now < self.last_time or now == std.math.maxInt(u64)) { self.fail(error.Clock); return; }
        self.last_time = now;
        if ((self.phase != .active or !self.modes.ready) and now >= self.deadline) { self.fail(error.Deadline); return; }
        self.advance() catch |err| { self.fail(err); };
        if (self.phase == .active) self.dispatch();
    }
    fn taskDone(self: *Owner) !bool {
        if (!self.core.?.poll()) return false;
        if (self.core.?.result != 0) return error.Unconfirmed;
        return true;
    }
    fn advance(self: *Owner) !void {
        const core = self.core.?; const memory = self.native.?.memory.?;
        switch (self.phase) {
            .allocate => { try self.frames[self.buffer_index].allocate(memory, self.shape, self.buffer_index); self.phase = .copy; },
            .copy => { if (try self.frames[self.buffer_index].copyBoot(&self.native.?.hold)) self.phase = .publish_buffer; },
            .publish_buffer => {
                try self.frames[self.buffer_index].publish();
                if (self.buffer_index == 0) { self.buffer_index = 1; self.phase = .allocate; } else self.phase = .prepare_core;
            },
            .prepare_core => {
                self.mode.mc_address = self.frames[0].mc_address; self.mode.pitch_bytes = self.shape.pitch; self.mode.buffer_bytes = self.shape.bytes;
                try core.prepareOwned(&self.ctx.?, memory, self.native.?, self.board.?, self.limits, self.mode, self.frames[0].reference);
                self.phase = .wait_core;
            },
            .wait_core => { if (try self.taskDone()) self.phase = .bind_panel; },
            .bind_panel => { try core.bindPanel(); self.phase = .wait_panel; },
            .wait_panel => { if (try self.taskDone()) self.phase = if (self.hdmi_present) .bind_hdmi else .commit_core; },
            .bind_hdmi => { try core.bindHdmi(); self.phase = .wait_hdmi; },
            .wait_hdmi => { if (try self.taskDone()) self.phase = .commit_core; },
            .commit_core => {
                const hooks = try self.pipeline.?.bind(core, self.clocks);
                _ = try self.frames[0].scanout(); // Retain before frontend address writes, even if commit fails.
                try core.commit(hooks); self.phase = .wait_commit;
            },
            .wait_commit => { if (try self.taskDone()) self.phase = .shadow; },
            .shadow => { try self.shadow.create(memory.memory.?, self.mode.width, self.mode.height); self.phase = .publication; },
            .publication => {
                try self.buildPublication();
                self.last_status = self.outputs.?.publish(&self.publication, &self.output);
                if (self.last_status == a.gfx_output_error_busy) return;
                if (self.last_status != a.gfx_output_ok or self.output.adapter_id != self.engine.?.binding.adapter_id or
                    self.output.device_generation != self.engine.?.binding.device_generation or self.output.connection_generation == 0 or
                    self.output.connector_id != self.publication.info.identity.connector_id) return error.Publication;
                const ops = (@as(u64, 1) << a.gfx_queue_operation_copy) | (@as(u64, 1) << a.gfx_queue_operation_copy_rows) |
                    @import("render_jobs.zig").operations | (@as(u64, 1) << a.gfx_queue_operation_upload) | (@as(u64, 1) << a.gfx_queue_operation_present);
                if (self.engine.?.queue.?.updateOperations(&self.engine.?.binding, ops) != 1) return error.Unsupported;
                self.phase = .prepare_common;
            },
            .prepare_common => {
                var registration: a.GfxNativeRegistration = .{ .backend = self.engine.?.binding, .output = self.output,
                    .reference = self.shadow.reference.reference, .context = self.self_address, .commit_callback = @intFromPtr(&commit), .restore_callback = @intFromPtr(&restore) };
                @memcpy(registration.name[0..10], "AMDGPU-eDP");
                self.prepared = .{};
                self.last_status = self.display.?.prepareHeld(&registration, self.native.?.hold.held_generation, &self.prepared);
                if (self.last_status != a.gfx_output_ok and self.prepared.retained == 1 and self.prepared.outcome == a.gfx_output_outcome_lost) {
                    try self.native.?.hold.adoptRetainedNative(self.prepared);
                    return error.Prepare;
                }
                if (self.last_status == a.gfx_output_error_busy) return;
                if (self.last_status != a.gfx_output_ok) return error.Prepare;
                try self.native.?.hold.adoptNative(self.prepared);
                self.epoch = .{ .backend = self.engine.?.binding, .output = self.output, .memory = memory.epoch, .display = self.prepared.generation, .mode = 1 };
                self.target = .{ .adapter_id = self.output.adapter_id, .connector_id = self.output.connector_id,
                    .device_generation = self.output.device_generation, .connection_generation = self.output.connection_generation,
                    .display_generation = self.prepared.generation, .head_id = self.mode.pipe };
                self.phase = .bind_scanout;
            },
            .bind_scanout => { try core.scanoutCommand(.{ .operation = .bind, .epoch = self.epoch, .image = try self.frames[0].scanout() }); self.phase = .wait_bind; },
            .wait_bind => { if (try self.taskDone()) self.phase = .enable; },
            .enable => { try core.scanoutCommand(.{ .operation = .enable, .epoch = self.epoch, .sequence = 1, .deadline_ns = self.last_time + std.time.ns_per_s }); self.phase = .wait_enable; },
            .wait_enable => { if (try self.taskDone()) self.phase = .stream; },
            .stream => { try core.panelCommand(.stream_on, 0); self.phase = .wait_stream; },
            .wait_stream => { if (try self.taskDone()) self.phase = .sample; },
            .sample => { try core.scanoutCommand(.{ .operation = .sample, .epoch = self.epoch }); self.phase = .wait_sample; },
            .wait_sample => {
                if (!core.poll()) return;
                if (core.result == dc.c.R4DCN_BUSY) { self.phase = .sample; return; }
                if (core.result != 0) return error.Visibility;
                const receipt = core.scanout_owner.receipt orelse return error.Visibility;
                if (receipt.sequence != 1 or receipt.image.address != self.frames[0].mc_address or !std.meta.eql(receipt.epoch, self.epoch)) return error.Stale;
                self.initial_receipt = receipt; self.phase = .acknowledge;
            },
            .acknowledge => { try core.scanoutCommand(.{ .operation = .acknowledge, .epoch = self.epoch, .sequence = 1 }); self.phase = .wait_ack; },
            .wait_ack => { if (try self.taskDone()) self.phase = .light; },
            .light => {
                const runtime: *@import("panel_runtime.zig").Runtime = @ptrFromInt(core.panel_allocation.cpu_address);
                try core.panelCommand(.show, self.pipeline.?.boot_brightness orelse runtime.protocol.?.brightness); self.phase = .wait_light;
            },
            .wait_light => { if (try self.taskDone()) self.phase = .handoff; },
            .handoff => {
                self.last_status = self.display.?.transition(self.prepared.generation, 0, &self.committed);
                if (self.last_status == a.gfx_output_error_busy) return;
                if (self.last_status != a.gfx_output_ok or !self.callback_confirmed or self.committed.generation != self.prepared.generation or
                    self.committed.state != a.display_state_software_native or self.committed.outcome != a.gfx_output_outcome_applied or self.committed.retained != 1) return error.Commit;
                try self.present.?.bind(self.engine.?, core, self.frames, self.epoch, self.target);
                self.phase = .active;
            },
            .active => {
                self.statistics.publish(self);
                if (core.phase == .retained) return error.DeviceLost;
                if (self.primary_failure == null) {
                    if (self.present.?.failed_output) try self.losePrimary(self.present.?.failure orelse error.Visibility);
                    if (self.present.?.input) |job| if (self.last_time >= job.deadline_ns) { try self.losePrimary(error.Deadline); };
                }
                if (self.primary_failure != null) {
                    try self.modeWork();
                    // Finish the exact owner's task before considering a new
                    // primary stop. Connector/mode work can already be in flight
                    // when the panel's presentation reports loss.
                    try self.connector.poll(self);
                    if (self.connector.waiting()) return;
                    if (self.additional.waiting()) {
                        self.additional.step(self);
                        if (self.additional.waiting() or core.thread != 0) return;
                    }
                    try self.primaryRetirement();
                    if (core.thread != 0) return;
                    self.additional.step(self);
                    if (core.thread != 0) return;
                    if (!self.connector.waiting()) try self.connector.step(self);
                    return;
                }
                if (self.health_pending) {
                    if (!core.poll()) return;
                    self.health_pending = false;
                    if (core.result != 0 and core.result != dc.c.R4DCN_BUSY) { try self.losePrimary(error.Visibility); return; }
                    if (core.result == dc.c.R4DCN_BUSY) {
                        if (self.last_time >= self.health_retry_deadline) { try self.losePrimary(error.Deadline); return; }
                        self.next_health = self.last_time;
                    } else { self.next_health = self.last_time + 250 * std.time.ns_per_ms; self.health_retry_deadline = 0; }
                }
                if (self.brightness_pending) {
                    if (!core.poll()) return;
                    // The brightness bridge reports ordinary unsupported/I/O
                    // results itself. A native MMIO fault still loses output.
                    if (core.phase == .retained) return error.Unconfirmed;
                    self.brightness_pending = false;
                }
                try self.connector.poll(self);
                if (self.connector.waiting()) return;
                try self.modeWork();
                if (self.cursor.phase != .idle) {
                    self.cursor.step(self) catch |err| { try self.losePrimary(err); return; };
                    if (self.cursor.phase != .idle or core.thread != 0) return;
                }
                if (self.additional.waiting()) {
                    self.additional.step(self);
                    if (self.additional.waiting() or core.thread != 0) return;
                }
                if (self.modes.waiting() or core.thread == 0) self.modes.step(self) catch |err| { try self.losePrimary(err); return; };
                if (core.thread != 0) return;
                if (self.modes.permitsQueue()) self.cursor.step(self) catch |err| { try self.losePrimary(err); return; };
                if (core.thread != 0) return;
                self.additional.step(self);
                if (core.thread != 0) return;
                try self.connector.step(self);
                if (self.connector.waiting()) return;
                if (self.modes.permitsQueue() and self.cursor.phase == .idle and self.present.?.available() and self.last_time >= self.next_health) {
                    if (self.health_retry_deadline == 0) self.health_retry_deadline = self.last_time + 2 * std.time.ns_per_s;
                    try core.healthCommand(); self.health_pending = true;
                } else if (self.modes.permitsQueue() and self.cursor.phase == .idle and self.present.?.available() and self.outputs.?.supportsBrightness() and self.last_time >= self.next_brightness) {
                    try core.brightnessCommand(self.output); self.brightness_pending = true;
                    self.next_brightness = self.last_time + std.time.ns_per_s;
                }
                _ = self.display.?.schedule(&self.engine.?.binding);
            },
            else => return error.State,
        }
    }
    fn losePrimary(self: *Owner, err: anyerror) !void {
        if (!self.additional.callback_confirmed or self.additional.draining or self.core.?.phase != .programmed) return err;
        self.primary_failure = err; self.present.?.cancel_display = true;
        self.present.?.failed_output = true; self.present.?.failure = err;
        _ = self.outputs.?.pauseOutput(&self.output, true);
    }
    fn primaryRetirement(self: *Owner) !void {
        const core = self.core.?;
        if (core.thread != 0) {
            if (!core.taskFor(self.mode.pipe, self.epoch.output.connector_id) or !core.poll()) return;
            if (core.phase == .retained) return error.DeviceLost;
        }
        self.health_pending = false; self.brightness_pending = false;
        if (self.primary_stop_pending) {
            self.primary_stop_pending = false;
            self.primary_stopped = core.result == 0 and core.scanout_owner.phase == .stopped;
        }
        _ = self.cursor.abandon(self);
        _ = self.modes.abandon(self);
        if (self.present.?.input != null or self.primary_stop_attempted) return;
        try core.pausePrimary(); self.primary_stop_pending = true; self.primary_stop_attempted = true;
        // An unconfirmed stop retains this head's images. Repeated stop tasks
        // must not starve a healthy peer; whole-device recovery may retry later.
    }
    fn buildPublication(self: *Owner) !void {
        const runtime: *@import("panel_runtime.zig").Runtime = @ptrFromInt(self.core.?.panel_allocation.cpu_address);
        const p = &runtime.protocol.?;
        if (p.phase != .trained or p.edid_length == 0 or p.edid_length > a.gfx_output_max_edid_bytes) return error.State;
        const timing = p.mode;
        const mask = @as(u32, 1) << @intCast(self.mode.pipe);
        self.publication = .{ .backend = self.engine.?.binding, .info = .{
            .identity = .{ .adapter_id = self.engine.?.binding.adapter_id, .connector_id = p.route.native.connector, .device_generation = self.engine.?.binding.device_generation },
            // Active/fixed_geometry are common-owner results, never flags a
            // driver may submit through GfxDriverOutputApi.publish.
            .connector_kind = a.gfx_output_kind_edp, .flags = a.gfx_output_flag_connected,
            .mode_count = 1, .preferred_mode_id = 1, .edid_bytes = @intCast(p.edid_length), .possible_heads = mask, .possible_planes = mask, .possible_plls = mask,
            .limits = .{ .head_mask = mask, .plane_mask = mask, .pll_mask = mask, .max_width = self.mode.width, .max_height = self.mode.height,
                .pitch_alignment = 256, .bpc_mask = @as(u32, 1) << @intCast(p.bpc), .max_pixel_clock_hz = timing.clock_hz, .total_pixel_clock_hz = timing.clock_hz } } };
        self.publication.modes[0] = .{ .mode_id = 1, .flags = timing.flags | a.gfx_output_mode_preferred, .width = timing.width, .height = timing.height,
            .pixel_clock_hz = timing.clock_hz, .h_total = timing.h_total, .h_sync_start = timing.h_start, .h_sync_end = timing.h_end,
            .v_total = timing.v_total, .v_sync_start = timing.v_start, .v_sync_end = timing.v_end, .refresh_millihz = timing.millihz() };
        @memcpy(self.publication.edid[0..p.edid_length], p.edid_bytes[0..p.edid_length]);
    }
    pub fn fail(self: *Owner, err: anyerror) void {
        if (self.failure == null) { self.failure = err; self.failed_phase = self.phase; }
        self.phase = .failed; @atomicStore(u32, &self.restore_requested, 1, .release);
        self.statistics.publish(self);
        if (self.output.connection_generation != 0) _ = self.outputs.?.pauseOutput(&self.output, true);
        var buffer: [220]u8 = undefined;
        const message = std.fmt.bufPrintZ(&buffer, "AMDGPU output: phase={s} failure={s} status={d} resources=retained", .{ @tagName(self.failed_phase), @errorName(err), self.last_status }) catch return;
        self.ctx.?.logError(message);
    }
    fn geometry(self: *const Owner, boot: *const a.GfxNativeBootInfo) bool {
        const original = self.original_boot;
        return boot.version == 1 and boot.size >= @sizeOf(a.GfxNativeBootInfo) and boot.width == original.width and boot.height == original.height and
            boot.pitch == original.pitch and boot.physical_address == original.physical_address and boot.byte_length == original.byte_length and boot.format == original.format;
    }
    fn commit(raw: u64, generation: u64, boot: *const a.GfxNativeBootInfo) callconv(.c) i32 {
        if (raw == 0) return 0;
        const self = from(raw);
        if (self.self_address != raw or self.phase != .handoff or self.callback_confirmed or generation != self.prepared.generation or
            boot.generation != generation or !self.geometry(boot) or @atomicLoad(u32, &self.restore_requested, .acquire) != 0 or
            self.initial_receipt == null or self.core.?.thread != 0 or self.core.?.phase != .programmed or self.core.?.scanout_owner.phase != .active) return 0;
        self.callback_confirmed = true; return 1;
    }
    fn restore(raw: u64, generation: u64, boot: *const a.GfxNativeBootInfo) callconv(.c) i32 {
        if (raw == 0) return 0;
        const self = from(raw);
        if (self.self_address != raw or !self.geometry(boot) or generation != boot.generation or
            self.native == null or !self.native.?.hold.native_adopted or generation != self.native.?.hold.native_generation) return 0;
        @atomicStore(u32, &self.restore_requested, 1, .release);
        return @intFromBool(@atomicLoad(u32, &self.restore_ready, .acquire) == 1);
    }
    /// Called only after the queue worker joins, display restores boot, every
    /// copy/GC mapping retires, GMC restores and native.quiesce finishes.
    pub fn confirmRestore(self: *Owner) !void {
        if (self.self_address == 0) return;
        const native = self.native.?; const memory = native.memory.?;
        if (self.self_address != @intFromPtr(self) or self.engine.?.runtime.?.thread != 0 or !self.engine.?.closed or
            self.core.?.self_address != 0 or memory.engine_users != 0 or memory.mapping_users != 0 or memory.controller.touched or memory.controller.enabled or
            !native.flow.safeToRelease() or native.pci_changed or native.storage.self_address != 0 or !native.bootMatches()) return error.Unconfirmed;
        @atomicStore(u32, &self.restore_ready, 1, .release);
    }
    /// Parent worker only, after the queue worker has joined. Starting reset
    /// excludes common consumers but makes no quiescence claim.
    pub fn beginReset(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.engine.?.runtime.?.thread != 0) return false;
        if (!self.native.?.hold.native_adopted or self.reset_state.generation != 0) return true;
        if (self.reset_original == 0) self.reset_original = self.native.?.hold.native_generation;
        var state: a.GfxNativeState = .{};
        if (self.display.?.deviceReset(&self.engine.?.binding, self.reset_original, false, &state) != a.gfx_output_ok) return false;
        self.native.?.hold.adoptReset(state) catch return false;
        self.reset_state = state;
        return true;
    }
    pub fn retireReset(self: *Owner) bool {
        if (self.self_address == 0 or self.reset_state.generation == 0 or self.reset_retired) return true;
        if (self.self_address != @intFromPtr(self) or @atomicLoad(u32, &self.restore_ready, .acquire) != 1) return false;
        var state: a.GfxNativeState = .{};
        if (self.display.?.deviceReset(&self.engine.?.binding, self.reset_state.generation, true, &state) != a.gfx_output_ok or
            !std.meta.eql(state, self.reset_state)) return false;
        self.reset_retired = true; return true;
    }
    pub fn closeMetadata(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.native.?.self_address != 0) return false;
        if (!self.connector.closeMetadata(&self.outputs.?)) return false;
        if (self.output.connection_generation != 0) {
            const result = self.outputs.?.withdraw(&self.output);
            if (result != a.gfx_output_ok and result != a.gfx_output_error_stale) return false;
            self.output = .{};
        }
        if (!self.shadow.close()) return false;
        self.engine.?.client = null; self.* = .{}; return true;
    }
};
