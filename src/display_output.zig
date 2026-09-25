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
const bios = @import("bios.zig");
const Outputs = @TypeOf(@as(r4os.r4dev.DriverContext, undefined).graphicsOutputs().?);
pub const Phase = enum { empty, allocate, copy, publish_buffer, prepare_core, wait_core, bind_panel, wait_panel, bind_hdmi, wait_hdmi, commit_core, wait_commit,
    shadow, publication, prepare_common, bind_scanout, wait_bind, enable, wait_enable, stream, wait_stream, sample, wait_sample,
    acknowledge, wait_ack, light, wait_light, handoff, active, failed, closing };
pub const RequestStep = enum { empty, gate, display_api, outputs_api, capabilities, boot_mode, hdmi_route, shape, clock, reference_clock, ready };
pub const Owner = struct {
    self_address: usize = 0,
    // Resident admission diagnostics; no borrowed pointers or extra MMIO.
    request_step: RequestStep = .empty,
    request_caps: u16 = 0,
    request_display_bytes: u32 = 0,
    request_output_bytes: u32 = 0,
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
    recovery_fault: u32 = 0, // 1: startup failure; 2: previously active output
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
    power: @import("display_power.zig").Owner = .{},
    color: @import("display_color.zig").Owner = .{},
    signal: ?@import("display_color.zig").color.Signal = null,
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
        self.request_step = .gate;
        if (self.self_address != 0 or !native.firmwareReady() or engine.memory != native.memory or engine.client != null or engine.active) return error.State;
        self.request_step = .display_api;
        const display = ctx.graphicsDisplay() orelse return error.Unsupported;
        self.request_display_bytes = display.table.size;
        self.request_step = .outputs_api;
        const outputs = ctx.graphicsOutputs() orelse return error.Unsupported;
        self.request_output_bytes = outputs.table.size;
        self.request_step = .capabilities;
        self.request_caps = 0;
        inline for (.{ display.table.prepare_held != 0, display.table.transition != 0, outputs.table.publish != 0, outputs.table.withdraw != 0,
            display.supportsReset(), display.supportsPresentationStats(), display.supportsPresentationInfo(),
            outputs.supportsHotplug(), outputs.supportsModes() }, 0..) |supported, index| {
            if (supported) self.request_caps |= @as(u16, 1) << index;
        }
        if (self.request_caps != 0x1ff) return error.Unsupported;
        self.request_step = .boot_mode;
        const mode = try pipeline.bootMode(board, native);
        self.request_step = .hdmi_route;
        const have_hdmi = blk: {
            _ = @import("hdmi.zig").route(board) catch |err| {
                if (err == error.Unsupported) break :blk false;
                return err;
            };
            break :blk true;
        };
        self.request_step = .shape;
        const shape = try buffers.Shape.make(mode.width, mode.height, false);
        self.request_step = .clock;
        const now = ctx.resources().?.nowNs();
        if (now == 0 or now > std.math.maxInt(u64) - 120 * std.time.ns_per_s) return error.Clock;
        self.request_step = .reference_clock;
        const ref_khz = try board.displayReferenceClock();
        self.* = .{ .self_address = @intFromPtr(self), .ctx = ctx.*, .native = native, .engine = engine, .core = core, .pipeline = pipe,
            .request_step = .ready, .request_caps = self.request_caps,
            .request_display_bytes = self.request_display_bytes, .request_output_bytes = self.request_output_bytes,
            .present = presentation, .frames = frames, .board = board, .clocks = table, .mode = mode, .shape = shape,
            .display = display, .outputs = outputs, .phase = .allocate, .last_time = now, .deadline = now + 120 * std.time.ns_per_s,
            .original_boot = native.hold.boot, .hdmi_present = have_hdmi,
            // ASIC limits bound DML admission; actual programmed clocks still
            // require the SMU/ATOM acknowledgements in the pipeline owner.
            .limits = .{ .channels = board.integrated.?.uma_channels, .dcf_khz = table.dcf_khz, .fabric_khz = table.fabric_khz,
                .soc_khz = table.soc_khz, .disp_khz = 1108000, .dpp_khz = 720000, .ref_khz = ref_khz,
                .gb_addr_config = gb_addr_config, .reserved = 0, .pipe_count = native.memory.?.layout.?.profile.displayPipes() } };
        engine.client = .{ .context = self.self_address, .work = work, .available = available, .accept = accept, .drain = drain, .lost = lost, .idle = powerIdle, .sleep_poll = sleepPoll };
    }
    fn from(raw: usize) *Owner { return @ptrFromInt(raw); }
    fn lost(raw: usize) void {
        const self = from(raw);
        if (self.phase != .failed and self.phase != .closing) self.fail(error.DeviceLost);
    }
    fn powerIdle(raw: usize) bool {
        const self = from(raw);
        if (self.phase != .active or self.failure != null or self.primary_failure != null or self.power.transition() or
            @atomicLoad(u32, &self.restore_requested, .acquire) != 0 or
            !self.modes.permitsQueue() or self.mode_inbox != null or self.cursor.phase != .idle or
            self.present.?.input != null or self.connector.quarantined or
            (self.connector.phase != .idle and self.connector.phase != .wait_service)) return false;
        for (&self.incoming) |*entry| if (entry.* != null) return false;
        // HPD's task may update retirement requests. Read that owner only
        // after join; the task itself touches DCN, never the sleeping GC/VM.
        if (self.core.?.thread != 0) return self.health_pending or self.brightness_pending or self.connector.phase == .wait_service;
        const head = &self.additional;
        if (head.draining or head.mode_inbox != null or head.presentation.input != null) return false;
        return head.phase == .empty or head.phase == .retired or
            (head.phase == .active and head.failure == null and head.modes.permitsQueue());
    }
    /// Only DCN service and common mailboxes run while GC sleeps. Discovering
    /// a mode/cursor/connector change wakes GC before the normal BO/VM path.
    fn sleepPoll(raw: usize) void {
        const self = from(raw);
        if (!powerIdle(raw)) return;
        self.sleepStep() catch |err| self.fail(err);
    }
    fn sleepStep(self: *Owner) !void {
        const core = self.core.?;
        const now = self.ctx.?.resources().?.nowNs();
        if (now < self.last_time or now == std.math.maxInt(u64)) return error.Clock;
        self.last_time = now;
        if (self.health_pending) {
            if (!core.poll()) return;
            self.health_pending = false;
            if (core.result != 0 and core.result != dc.c.R4DCN_BUSY) return error.Visibility;
            if (core.result == dc.c.R4DCN_BUSY) {
                if (now >= self.health_retry_deadline) return error.Deadline;
                self.next_health = now;
            } else { self.next_health = now + 250 * std.time.ns_per_ms; self.health_retry_deadline = 0; }
        }
        if (self.brightness_pending) {
            if (!core.poll()) return;
            self.brightness_pending = false;
            if (core.phase == .retained) return error.Visibility;
        }
        try self.connector.poll(self);
        if (self.connector.waiting() or !powerIdle(@intFromPtr(self))) return;
        try self.power.poll(self, false);
        if (self.power.transition()) return;
        if (!self.power.held()) try self.modeWork();
        if (self.power.permits(true)) try self.cursor.pollDemand(self);
        if (!powerIdle(@intFromPtr(self))) return;
        try self.connector.step(self);
        if (core.thread != 0) return;
        if (self.power.permits(true) and now >= self.next_health) {
            if (self.health_retry_deadline == 0) self.health_retry_deadline = now + 2 * std.time.ns_per_s;
            try core.healthCommand(); self.health_pending = true;
        } else if (self.power.permits(true) and self.outputs.?.supportsBrightness() and now >= self.next_brightness) {
            try core.brightnessCommand(self.output); self.brightness_pending = true;
            self.next_brightness = now + std.time.ns_per_s;
        }
        _ = self.display.?.schedule(&self.engine.?.binding);
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
            if (!self.power.permits(primary)) {
                if (self.engine.?.queue.?.complete(&input.fence, a.gfx_queue_result_cancelled, 1) == 1) entry.* = null;
                continue;
            }
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
                if (self.power.transition()) {
                    try self.power.poll(self, true);
                    if (self.power.transition()) return;
                }
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
                try self.power.poll(self, true);
                if (self.power.held()) {
                    try self.screenService();
                    return;
                }
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
    fn screenService(self: *Owner) !void {
        const core = self.core.?;
        if (self.power.transition()) return;
        if (self.cursor.phase != .idle and self.power.permits(true)) {
            self.cursor.step(self) catch |err| { try self.losePrimary(err); return; };
            if (self.cursor.phase != .idle or core.thread != 0) return;
        }
        if (self.additional.draining) self.additional.step(self);
        if (core.thread != 0) return;
        // Geometry changes require all peers awake. Consume and reject only
        // new, unarmed apply jobs; a pending confirm prevented off admission.
        try self.modeWork();
        for ([_]*?a.GfxDriverModeJob{ &self.mode_inbox, &self.additional.mode_inbox }) |inbox| if (inbox.*) |job| {
            if (job.operation != a.gfx_mode_operation_apply) return error.State;
            const result = self.outputs.?.completeMode(&.{ .ticket = job.ticket, .sequence = job.sequence, .operation = job.operation,
                .outcome = a.gfx_output_outcome_old_preserved, .quiesced = 2, .error_code = a.gfx_output_error_busy });
            if (result == a.gfx_output_error_busy) return;
            if (result != a.gfx_output_ok) return error.Publication;
            inbox.* = null;
        };
        if (self.additional.draining) self.additional.step(self);
        if (core.thread != 0) return;
        if (self.power.permits(true)) {
            self.cursor.step(self) catch |err| { try self.losePrimary(err); return; };
            if (core.thread != 0) return;
        }
        try self.connector.step(self);
        if (core.thread != 0) return;
        if (self.power.permits(true) and self.cursor.phase == .idle and self.present.?.available()) {
            if (self.last_time >= self.next_health) {
                if (self.health_retry_deadline == 0) self.health_retry_deadline = self.last_time + 2 * std.time.ns_per_s;
                try core.healthCommand(); self.health_pending = true;
            } else if (self.outputs.?.supportsBrightness() and self.last_time >= self.next_brightness) {
                try core.brightnessCommand(self.output); self.brightness_pending = true;
                self.next_brightness = self.last_time + std.time.ns_per_s;
            }
        }
        _ = self.display.?.schedule(&self.engine.?.binding);
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
        if (self.failure == null) {
            self.failure = err; self.failed_phase = self.phase;
            @atomicStore(u32, &self.recovery_fault, if (self.phase == .active) 2 else 1, .release);
        }
        if (self.engine) |engine| _ = engine.closeAdmission();
        self.phase = .failed; @atomicStore(u32, &self.restore_requested, 1, .release);
        self.statistics.publish(self);
        if (self.output.connection_generation != 0) _ = self.outputs.?.pauseOutput(&self.output, true);
        var buffer: [220]u8 = undefined;
        const message = std.fmt.bufPrintZ(&buffer, "AMDGPU output: phase={s} failure={s} status={d} resources=retained", .{ @tagName(self.failed_phase), @errorName(err), self.last_status }) catch return;
        self.ctx.?.logError(message);
        self.diagnoseTask();
    }
    fn diagnostic(self: *const Owner, comptime format: []const u8, args: anytype) void {
        var buffer: [384]u8 = undefined;
        const message = std.fmt.bufPrintZ(&buffer, format, args) catch return;
        self.ctx.?.logError(message);
    }
    fn diagnoseTask(self: *const Owner) void {
        const core = self.core orelse return;
        // Task-owned snapshots are not read while that task can still run.
        if (core.thread != 0 or !core.joined) return;
        if (core.action == .health_work) {
            self.diagnostic("AMDGPU health: step={s} error={s} native={d} expected={x} epoch={d} frame={d} progress-ns={d}",
                .{ @tagName(core.health_step), if (core.health_error) |err| @errorName(err) else "none", core.result,
                core.health_expected_address, core.health_epoch, core.health_frame, core.health_progress });
            if (core.health_sample) |sample| {
                self.diagnostic("AMDGPU health sample: running={d} blank={d} locked={d} pending={d} underflow={d} hubp={d} optc={d} frame={d} position={d}/{d}",
                    .{ sample.running, sample.blank, sample.locked, sample.pending, sample.underflow, sample.hubp_underflow, sample.optc_underflow, sample.frame, sample.hpos, sample.vpos });
                self.diagnostic("AMDGPU health addresses: requested={x} inuse={x} time={d}/{d}",
                    .{ sample.requested_address, sample.inuse_address, sample.begin_ns, sample.end_ns });
                self.diagnostic("AMDGPU health blank sources: hubp-control={x} otg-blank-control={x} vblank-only={d}",
                    .{ sample.hubp_control, sample.otg_blank_control, sample.vblank_only });
            }
            if (self.initial_receipt) |receipt| self.diagnostic("AMDGPU initial receipt: sequence={d} address={x} frame={d} time={d}/{d}",
                .{ receipt.sequence, receipt.image.address, receipt.frame, receipt.submitted_ns, receipt.observed_ns });
        }
        if (core.action == .scanout_work) {
            const life = core.scanoutFor(core.scanout_request.epoch);
            self.diagnostic("AMDGPU scanout task: operation={s} phase={s} error={s} last-native={d}",
                .{ @tagName(core.scanout_request.operation), @tagName(life.phase), if (core.scanout_error) |err| @errorName(err) else "none", life.last_native_result });
            self.diagnostic("AMDGPU scanout request: sequence={d} current={d} deadline={d} last-sample={d} worker-now={d}",
                .{core.scanout_request.sequence, life.sequence, core.scanout_request.deadline_ns, life.last_ns, self.last_time});
            if (core.scanout_request.image) |image| self.diagnostic("AMDGPU scanout image: id={d} generation={d} reserved={d} address={x} bytes={d}",
                .{image.reference.id, image.reference.generation, image.reference.reserved0, image.address, image.bytes});
            if (life.last_sample) |sample| {
                self.diagnostic("AMDGPU scanout last sample: running={d} blank={d} locked={d} pending={d} underflow={d} hubp={d} optc={d} frame={d} position={d}/{d}",
                    .{ sample.running, sample.blank, sample.locked, sample.pending, sample.underflow, sample.hubp_underflow, sample.optc_underflow, sample.frame, sample.hpos, sample.vpos });
                self.diagnostic("AMDGPU scanout sample addresses: requested={x} inuse={x} time={d}/{d}",
                    .{ sample.requested_address, sample.inuse_address, sample.begin_ns, sample.end_ns });
                self.diagnostic("AMDGPU scanout blank sources: hubp-control={x} otg-blank-control={x} vblank-only={d}",
                    .{ sample.hubp_control, sample.otg_blank_control, sample.vblank_only });
            }
            if (life.self_address != 0) self.diagnostic("AMDGPU scanout mode: size={d}x{d} total={d}/{d} pixel-khz={d}",
                .{ life.mode.width, life.mode.height, life.mode.h_total, life.mode.v_total, life.mode.pixel_khz });
        }
        const program = &core.program_diagnostic;
        const waited = &program.wait;
        self.diagnostic("AMDGPU DC program: step={d} pipe={d} fault={d}", .{program.step, program.pipe, program.fault});
        const function_end = std.mem.indexOfScalar(u8, &waited.function, 0) orelse waited.function.len;
        self.diagnostic("AMDGPU DC wait: valid={d} function={s} line={d} register={x} shift={d} mask={x} expected={x} observed={x}",
            .{waited.valid, waited.function[0..function_end], waited.line, waited.address, waited.shift, waited.mask, waited.expected, waited.observed});
        self.diagnostic("AMDGPU DC wait bounds: polls={d} delay-us={d} tries={d} elapsed-ns={d}",
            .{waited.polls, waited.delay_us, waited.tries, waited.elapsed_ns});
        if (self.pipeline) |pipe| {
            self.diagnostic("AMDGPU mode prepare: step={s} failure={s} native={d} touched={d} command={d} revision={d}/{d} boot-video={d}",
                .{ @tagName(pipe.prepare_step), if (pipe.failure) |failure| @errorName(failure) else "none", pipe.prepare_native_result,
                @intFromBool(pipe.touched), pipe.prepare_command, pipe.prepare_revision[0], pipe.prepare_revision[1], pipe.prepare_boot_video });
            const state = pipe.prepare_panel_state;
            const inherited = &pipe.prepare_inherited;
            self.diagnostic("AMDGPU inherited: checked={x} power-sampled={x} rejected={d}",
                .{ inherited.checked_mask, inherited.power_mask, inherited.rejected_pipe });
            for (0..4) |i| if (inherited.checked_mask & (@as(u32, 1) << @intCast(i)) != 0) {
                self.diagnostic("AMDGPU inherited pipe{d}: otg={x} hubp={x} power={x}",
                    .{ i, inherited.control[i], inherited.hubp[i], inherited.power[i] });
            };
            self.diagnostic("AMDGPU mode panel: power={d} lit={d} pwm-valid={d} firmware-busy={d} pwm={d} period={d}",
                .{ state.powered, state.lit, state.pwm_valid, state.firmware_busy, state.pwm, state.period });
        }
        if (core.panel_allocation.cpu_address != 0) {
            const runtime: *const @import("panel_runtime.zig").Runtime = @ptrFromInt(core.panel_allocation.cpu_address);
            self.diagnostic("AMDGPU mode runtime: panel-error={s} atom-error={s} atom-effects={d} panel-phase={s}",
                .{ if (runtime.last_panel_error) |failure| @errorName(failure) else "none",
                if (runtime.last_atom_error) |failure| @errorName(failure) else "none", @intFromBool(runtime.vm.effects),
                if (runtime.protocol) |*p| @tagName(p.phase) else "none" });
            if (runtime.protocol) |*p| {
                if (core.action == .health_work) {
                    const health = &p.link_health;
                    self.diagnostic("AMDGPU link health: step={s} phase={s} powered={d} lanes={d} hpd={d} video={d}",
                        .{ @tagName(health.step), @tagName(p.phase), @intFromBool(p.powered), p.link.lanes,
                        if (health.hpd) |value| @as(i32, @intFromBool(value)) else @as(i32, -1),
                        if (health.video) |value| @as(i32, @intFromBool(value)) else @as(i32, -1) });
                    if (health.status) |status| self.diagnostic("AMDGPU link status: bytes={x}", .{status});
                    if (health.video != null or health.step == .video) {
                        const video = &runtime.last_video;
                        self.diagnostic("AMDGPU link video: native={d} pipe={d} phy={d} otg={x} stream={x} source-valid={d} source={d}",
                            .{ runtime.video_native_result, video.pipe, video.phy, video.control, video.stream, video.source_valid, video.source });
                    }
                }
                self.diagnostic("AMDGPU panel discovery: step={s} hpd-polls={d} present={d} receiver={x} edid={d}",
                    .{ @tagName(p.discover_step), p.hpd_polls, @intFromBool(p.hpd_present), p.receiver, p.edid_length });
                if (p.initial_state) |state| self.diagnostic("AMDGPU panel initial: powered={d} lit={d}", .{state.powered, state.lit});
                if (p.initialized_state) |state| self.diagnostic("AMDGPU panel after INIT: powered={d} lit={d}", .{state.powered, state.lit});
            }
            const aux = &runtime.last_aux;
            self.diagnostic("AMDGPU panel HPD sample: source=controller-sense-delayed native={d} valid={d} index={d} status={x}",
                .{ runtime.hpd_native_result, runtime.last_hpd.valid, runtime.last_hpd.index, runtime.last_hpd.status });
            self.diagnostic("AMDGPU panel AUX: calls={d} native={d} address={x} flags={x} length={d} reply={x} status={d} transferred={d}",
                .{ runtime.aux_calls, runtime.aux_native_result, aux.address, aux.flags, aux.length, aux.reply, aux.status, aux.transferred });
            const clock = &runtime.clock_diagnostic;
            self.diagnostic("AMDGPU pixel clock: step={s} native={d} crystal={d} reference={d} bound={d} calls={d}/{d} unit={s}",
                .{ @tagName(clock.step), clock.native_result, runtime.crystal_khz, runtime.dprefclk_khz,
                @intFromBool(runtime.clock_bound), clock.reference_calls, clock.pixel_calls, if (clock.reference_hz) "Hz" else "10kHz" });
            self.diagnostic("AMDGPU clock ATOM: reference={x}/{x}/{x}/{x} pixel={x}/{x}/{x}/{x}",
                .{ clock.reference_words[0], clock.reference_words[1], clock.reference_words[2], clock.reference_words[3],
                clock.pixel_words[0], clock.pixel_words[1], clock.pixel_words[2], clock.pixel_words[3] });
            const trace = &runtime.clock_trace;
            self.diagnostic("AMDGPU clock trace: instructions={d} retained={d}", .{trace.count, @min(trace.count, trace.entries.len)});
            const first = trace.count - @min(trace.count, trace.entries.len);
            for (first..trace.count) |n| {
                const entry = &trace.entries[n % trace.entries.len];
                self.diagnostic("AMDGPU clock op{d}: pc={x} depth={d} ps={d} words={x}/{x}/{x} qr={x}/{x}",
                    .{n, entry.pc, entry.depth, entry.ps, entry.words[0], entry.words[1], entry.words[2], entry.quotient, entry.remainder});
            }
            var remaining: usize = 4096;
            // These immutable BIOS tables also explain the clock contract if
            // panel discovery failed before the clock command was executed.
            const selected = [_]usize{
                @offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, "setdceclock") / 2,
                @offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, "getsmuclockinfo") / 2,
                @offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, "setpixelclock") / 2,
            };
            var dumped: [256]bool = @splat(false);
            for (0..selected.len + trace.commands.len) |slot| {
                const command = if (slot < selected.len) selected[slot] else slot - selected.len;
                if (dumped[command] or (slot >= selected.len and !trace.commands[command]) or
                    runtime.vm.commands.len < 4 or command >= (runtime.vm.commands.len - 4) / 2) continue;
                dumped[command] = true;
                const offset = bios.number(u16, runtime.vm.commands, 4 + command * 2) catch continue;
                if (offset < 0x4a) continue;
                const length = bios.number(u16, runtime.vm.image, offset) catch continue;
                const bytes = bios.part(runtime.vm.image, offset, length) catch continue;
                const count = @min(bytes.len, remaining);
                self.diagnostic("AMDGPU clock table: command={d} offset={x} length={d} captured={d}", .{command, offset, length, count});
                var at: usize = 0;
                while (at < count) : (at += 64) {
                    self.diagnostic("AMDGPU clock bytes: offset={x} data={x}", .{offset + at, bytes[at..@min(at + 64, count)]});
                }
                remaining -= count;
            }
        }
        const bind = core.panel_bind_diagnostic;
        self.diagnostic("AMDGPU display task: action={s} phase={s} result={d} worker={d} panel-error={s}",
            .{ @tagName(core.action), @tagName(core.phase), core.result, core.worker_result,
            if (core.panel_bind_error) |failure| @errorName(failure) else "none" });
        self.diagnostic("AMDGPU panel bind: step={s} native={d} scratch={d} tx-rev={d}/{d} commands={d} data={d}",
            .{ @tagName(bind.step), bind.native_result, bind.scratch_bytes, bind.revision[0], bind.revision[1], core.panel_bind_commands, core.panel_bind_data });
        const route = bind.route;
        self.diagnostic("AMDGPU panel route: valid={d} connector={x} encoder={x} phy={d} aux={d} hpd={d} ddc={x} hpd-a={x}",
            .{ @intFromBool(bind.route_valid), route.connector, route.encoder, route.phy, route.aux, route.hpd, route.ddc_a, route.hpd_a });
        const board = core.board orelse return;
        if (board.panel) |p| self.diagnostic("AMDGPU panel decoded: bpc={d} size={d}x{d} clock={d} misc={x}", .{p.bpc, p.width, p.height, p.pixel_clock_khz, p.misc});
        for (board.paths[0..board.path_count], 0..) |path, index| {
            if (path.connector & 0xff != 0x14) continue;
            self.diagnostic("AMDGPU panel path{d}: connector={x} encoder={x} external={x} hardware={d} slave={x} aux={d} hpd-active={d} caps={x}",
                .{ index, path.connector, path.encoder, path.external_encoder, @intFromBool(path.i2c_hardware), path.i2c_slave,
                path.aux_ddc_line orelse 255, path.hpd_active, path.encoder_caps orelse 0 });
            if (path.i2c_pin) |p| self.diagnostic("AMDGPU panel DDC: register={x} shift={d} mask-shift={d}", .{p.register, p.shift, p.mask_shift});
            if (path.hpd_pin) |p| self.diagnostic("AMDGPU panel HPD: register={x} shift={d} mask-shift={d}", .{p.register, p.shift, p.mask_shift});
        }
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
            self.native == null or !self.native.?.hold.native_adopted) return 0;
        const held = self.native.?.hold.native_generation;
        if (generation < held or (generation != held and boot.state != a.display_state_recovering)) return 0;
        // CpuWrite.finish may initiate recovery without a driver transition
        // caller to receive its advanced generation. Signal the outer owner,
        // but never adopt a callback token or claim physical stop here.
        @atomicStore(u32, &self.restore_requested, 1, .release);
        return @intFromBool(generation == held and @atomicLoad(u32, &self.restore_ready, .acquire) == 1);
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
        var result = self.display.?.deviceReset(&self.engine.?.binding, self.reset_original, false, &state);
        if (result == a.gfx_output_error_stale) {
            // Only a failed common restore may advance the display identity
            // behind this driver. Read that identity, then let deviceReset
            // validate the exact owner/backend again. Busy or unrelated state
            // never updates the retained snapshot or proves quiescence.
            var boot: a.GfxNativeBootInfo = .{};
            if (self.display.?.bootInfo(&boot) != a.gfx_output_ok or !self.geometry(&boot) or
                boot.state != a.display_state_unavailable or boot.generation <= self.reset_original) return false;
            self.reset_original = boot.generation;
            state = .{};
            result = self.display.?.deviceReset(&self.engine.?.binding, self.reset_original, false, &state);
        }
        if (result != a.gfx_output_ok) return false;
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
