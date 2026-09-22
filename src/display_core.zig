// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Private DCN1 owner. The first transition retains the original boot plane;
//! connector owners supply clock/link preparation and complete restoration.
//! Those hooks are installed by the later modeset milestone, never by probes.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const mem = @import("memory_owner.zig");
const start = @import("start_runtime.zig");
const panel = @import("panel_runtime.zig");
const atom = @import("atom_vm.zig");
const hdmi = @import("hdmi_runtime.zig");
pub const scanout = @import("scanout_lifetime.zig");
pub const c = panel.c;
pub const Error = error{ Busy, Invalid, Unsupported, Stale, Capacity, State };
pub const Phase = enum { empty, preparing, planned, programming, programmed, retained, aborted };
pub const Hooks = struct {
    context: usize,
    // Runs in the display task. Must confirm the planned DISPCLK and its DPP
    // divider, the fixed DCF/SOC/fabric point, all four pipes blank/disabled,
    // and preparation of the selected board links.
    prepare: *const fn (usize, *const c.struct_r4dcn_plan, *const c.struct_r4dcn_limits) bool,
    // Restores all changed frontend/link/clock state, including HUBBUB. The
    // boot guard is an additional check, not a substitute for this proof.
    restore: *const fn (usize) bool,
    // Stop encoder video before TG shutdown. Optional only for read-only or
    // synthetic callers which never acquired a physical output stream.
    stop: ?*const fn (usize) bool = null,
    modeset: ?*const fn (usize, ModeRequest) bool = null,
    remove: ?*const fn (usize) bool = null,
    pause_primary: ?*const fn (usize) bool = null,
    power: ?*const fn (usize, PowerRequest) bool = null,
};
pub const PowerRequest = struct { epoch: scanout.Epoch, off: bool };
pub const ModeRequest = struct { mode: c.struct_r4dcn_mode, epoch: scanout.Epoch, image: scanout.Image, sequence: u64, deadline_ns: u64, signal: ?@import("display_color.zig").color.Signal = null };
pub const ScanoutOperation = enum { bind, enable, flip, sample, acknowledge, stop, cursor, cursor_sample, cursor_acknowledge, rekey };
pub const ScanoutRequest = struct {
    operation: ScanoutOperation,
    epoch: scanout.Epoch,
    image: ?scanout.Image = null,
    cursor: ?scanout.Cursor = null,
    sequence: u64 = 0,
    deadline_ns: u64 = 0,
};
var active_owner: usize = 0;
pub const Owner = struct {
    self_address: usize = 0,
    memory: ?*mem.Owner = null,
    native: ?*start.Owner = null,
    ctx: ?r4os.r4dev.DriverContext = null,
    heap: ?r4os.r4dev.DriverHeapContext = null,
    threads: ?r4os.r4dev.DriverThreadContext = null,
    clock: ?r4os.r4dev.DriverResourceContext = null,
    allocation: a.DriverHeapAllocation = .{},
    panel_allocation: a.DriverHeapAllocation = .{},
    hdmi_allocation: a.DriverHeapAllocation = .{},
    candidate_allocation: a.DriverHeapAllocation = .{},
    candidate_mode: c.struct_r4dcn_mode = undefined,
    candidate_plan: c.struct_r4dcn_plan = undefined,
    candidate_valid: bool = false,
    mode_request: ModeRequest = undefined,
    power_request: PowerRequest = undefined,
    extra_mode: ?c.struct_r4dcn_mode = null,
    extra_scanout: scanout.Owner = .{},
    fixed_disp_khz: u32 = 0,
    stop_extra: bool = false,
    mode_receipt: ?scanout.Receipt = null,
    health_epoch: u64 = 0,
    health_frame: u32 = 0,
    health_progress: u64 = 0,
    hdmi_storage_valid: bool = false,
    audio_peer: ?@import("display_audio.zig").Peer = null,
    hdmi_operation: hdmi.Operation = .probe,
    hdmi_publish_token: u64 = 0,
    hdmi_output: a.GfxOutputId = .{},
    hdmi_retirement: ?hdmi.hotplug.Io = null,
    board: ?*const @import("bios.zig").Board = null,
    panel_operation: panel.Operation = .discover,
    panel_value: u16 = 0,
    panel_identity: a.GfxOutputId = .{},
    initialized: bool = false,
    thread: u64 = 0,
    joined: bool = false,
    worker_result: i32 = 0,
    result: i32 = 0,
    phase: Phase = .empty,
    action: enum { prepare, commit, abort, panel_bind, panel_work, brightness_work, hdmi_bind, hdmi_work, hdmi_publish, scanout_work, mode_plan, mode_apply, head_remove, primary_pause, health_work, power_work } = .prepare,
    limits: c.struct_r4dcn_limits = std.mem.zeroes(c.struct_r4dcn_limits),
    mode: c.struct_r4dcn_mode = std.mem.zeroes(c.struct_r4dcn_mode),
    plan: c.struct_r4dcn_plan = std.mem.zeroes(c.struct_r4dcn_plan),
    hooks: ?Hooks = null,
    effects: bool = false,
    frontend_attempted: bool = false,
    quiet: bool = false,
    closing: bool = false,
    frequency: u64 = 0,
    diagnostic_count: u32 = 0,
    scanout_owner: scanout.Owner = .{},
    scanout_request: ScanoutRequest = undefined,
    pub fn prepareBoot(self: *Owner, ctx: *const r4os.r4dev.DriverContext, memory: *mem.Owner, native: *start.Owner, board: *const @import("bios.zig").Board, limits: c.struct_r4dcn_limits, mode: c.struct_r4dcn_mode) Error!void {
        const held = &native.hold;
        if (mode.mc_address != native.guard.boot_mc or mode.buffer_bytes != held.boot.byte_length or
            mode.width != held.boot.width or mode.height != held.boot.height or mode.pitch_bytes != held.boot.pitch or
            held.boot.format != a.gfx_buffer_format_xrgb8888 or mode.pipe >= 4) return error.Invalid;
        try self.prepareImpl(ctx, memory, native, board, limits, mode);
    }
    pub fn prepareOwned(self: *Owner, ctx: *const r4os.r4dev.DriverContext, memory: *mem.Owner, native: *start.Owner,
        board: *const @import("bios.zig").Board, limits: c.struct_r4dcn_limits, mode: c.struct_r4dcn_mode, reference: a.GfxBufferReference) Error!void
    {
        if (!memory.prepared or memory.self_address != @intFromPtr(memory) or reference.reference.id == 0) return error.Stale;
        var descriptor: a.GfxBufferDescriptor = .{};
        if (memory.memory.?.bufferDescribe(&reference.reference, &descriptor) != a.gfx_buffer_result_ok or
            descriptor.version != 1 or descriptor.size < @sizeOf(a.GfxBufferDescriptor) or descriptor.adapter_id != memory.adapter or
            descriptor.device_generation != memory.epoch or descriptor.location != a.gfx_buffer_location_device_local or
            descriptor.format != a.gfx_buffer_format_xrgb8888 or descriptor.modifier != 0 or descriptor.plane_count != 1 or
            descriptor.width != mode.width or descriptor.height != mode.height or descriptor.plane_offsets[0] != 0 or
            descriptor.plane_pitches[0] != mode.pitch_bytes or descriptor.byte_length != mode.buffer_bytes or
            descriptor.usage & a.gfx_buffer_usage_scanout == 0) return error.Invalid;
        const backing = memory.backing(reference.buffer) catch return error.Stale;
        const map = memory.layout.?;
        if (backing.offset < map.physical.offset or mode.mc_address != map.mc.offset + backing.offset - map.physical.offset or
            backing.bytes != mode.buffer_bytes) return error.Invalid;
        try self.prepareImpl(ctx, memory, native, board, limits, mode);
    }
    fn prepareImpl(self: *Owner, ctx: *const r4os.r4dev.DriverContext, memory: *mem.Owner, native: *start.Owner, board: *const @import("bios.zig").Board, limits: c.struct_r4dcn_limits, mode: c.struct_r4dcn_mode) Error!void {
        if (self.self_address != 0) return error.Busy;
        const integrated = board.integrated orelse return error.Unsupported;
        const held = &native.hold;
        if (!native.firmwareReady() or native.memory != memory or !memory.prepared or memory.engine_users == 0 or
            memory.engine_users == std.math.maxInt(u32) or !native.guard.valid or held.held_generation == 0 or !held.effects or
            limits.channels != integrated.uma_channels or memory.self_address != @intFromPtr(memory)) return error.Stale;
        const threads = ctx.threads() orelse return error.Unsupported;
        if (!threads.canAbort() or !threads.hasCurrentRequest()) return error.Unsupported;
        const heap = ctx.heap() orelse return error.Unsupported;
        const clock = ctx.resources() orelse return error.Unsupported;
        const frequency = ctx.timerFrequency();
        if (frequency == 0) return error.Unsupported;
        if (@cmpxchgStrong(usize, &active_owner, 0, @intFromPtr(self), .acq_rel, .acquire) != null) return error.Busy;
        self.self_address = @intFromPtr(self);
        self.memory = memory;
        self.native = native;
        self.board = board;
        self.ctx = ctx.*;
        self.threads = threads;
        self.heap = heap;
        self.clock = clock;
        self.frequency = frequency;
        self.limits = limits;
        self.mode = mode;
        memory.engine_users += 1;
        try self.launch(.prepare);
    }
    pub fn commit(self: *Owner, hooks: Hooks) Error!void {
        if (self.self_address != @intFromPtr(self) or self.closing or self.thread != 0 or self.phase != .planned) return error.State;
        self.hooks = hooks;
        try self.launch(.commit);
    }
    /// Independent DML state validates a candidate without changing the live
    /// frontend or the live C object's internal streams/plane pointers.
    pub fn planMode(self: *Owner, mode: c.struct_r4dcn_mode) Error!void {
        if (self.self_address != @intFromPtr(self) or self.closing or self.thread != 0 or self.phase != .programmed or
            (self.scanout_owner.phase != .active and self.scanout_owner.phase != .stopped) or mode.pipe >= 4 or
            (mode.pipe == self.mode.pipe and self.scanout_owner.cursor_current.image != null)) return error.State;
        self.candidate_mode = mode; self.candidate_valid = false;
        try self.launch(.mode_plan);
    }
    pub fn applyMode(self: *Owner, request: ModeRequest) Error!void {
        const life = if (request.mode.pipe == self.mode.pipe) &self.scanout_owner else &self.extra_scanout;
        if (self.self_address != @intFromPtr(self) or self.closing or self.thread != 0 or self.phase != .programmed or
            !self.candidate_valid or !std.meta.eql(request.mode, self.candidate_mode) or self.hooks == null or self.hooks.?.modeset == null or
            request.epoch.memory != self.memory.?.epoch or request.epoch.backend.adapter_id != self.memory.?.adapter or
            !std.meta.eql(request.epoch.backend, self.scanout_owner.epoch.backend) or request.deadline_ns <= self.clock.?.nowNs() or
            request.sequence == 0 or request.sequence == std.math.maxInt(u64) or request.epoch.mode == 0 or
            request.image.address != request.mode.mc_address or request.image.bytes != request.mode.buffer_bytes) return error.State;
        if (life.self_address != 0 and (!std.meta.eql(request.epoch.output, life.epoch.output) or request.epoch.display != life.epoch.display or
            request.epoch.mode <= life.epoch.mode or request.sequence <= life.sequence)) return error.Stale;
        // Confirm the exact caller-retained private BO again after preparation.
        var descriptor: a.GfxBufferDescriptor = .{};
        if (self.memory.?.memory.?.bufferDescribe(&request.image.reference, &descriptor) != 1 or descriptor.driver_owner == 0 or
            descriptor.adapter_id != self.memory.?.adapter or descriptor.device_generation != self.memory.?.epoch or
            descriptor.location != a.gfx_buffer_location_device_local or descriptor.format != (if (request.mode.flags & 16 != 0) a.gfx_buffer_format_xrgb2101010 else a.gfx_buffer_format_xrgb8888) or
            descriptor.modifier != 0 or descriptor.plane_count != 1 or descriptor.width != request.mode.width or descriptor.height != request.mode.height or
            descriptor.plane_offsets[0] != 0 or descriptor.plane_pitches[0] != request.mode.pitch_bytes or descriptor.byte_length != request.mode.buffer_bytes or
            descriptor.usage & a.gfx_buffer_usage_scanout == 0) return error.Invalid;
        self.mode_request = request; self.candidate_valid = false; try self.launch(.mode_apply);
    }
    /// Native presentation submits one operation at a time; only join/release
    /// makes its result and receipt observable outside the owning DCN task.
    pub fn scanoutCommand(self: *Owner, request: ScanoutRequest) Error!void {
        if (self.self_address != @intFromPtr(self) or self.closing or self.thread != 0 or self.hooks == null or
            (self.phase != .programmed and !(request.operation == .stop and self.phase == .retained))) return error.State;
        if (request.epoch.backend.adapter_id != self.memory.?.adapter or request.epoch.memory != self.memory.?.epoch)
            return error.Stale;
        if (request.operation != .bind and request.operation != .rekey and (self.scanoutFor(request.epoch).self_address == 0 or !std.meta.eql(request.epoch, self.scanoutFor(request.epoch).epoch))) return error.Stale;
        if ((request.operation == .bind or request.operation == .flip) and request.image == null) return error.Invalid;
        if (request.operation == .cursor and request.cursor == null) return error.Invalid;
        self.scanout_request = request;
        try self.launch(.scanout_work);
    }
    pub fn taskFor(self: *const Owner, pipe: u32, connector: u32) bool {
        return switch (self.action) {
            .scanout_work => self.scanout_request.epoch.output.connector_id == connector,
            .mode_apply => self.mode_request.epoch.output.connector_id == connector,
            .power_work => self.power_request.epoch.output.connector_id == connector,
            .mode_plan => self.candidate_mode.pipe == pipe,
            .health_work, .brightness_work, .primary_pause => pipe == self.mode.pipe,
            else => false,
        };
    }
    pub fn scanoutFor(self: *Owner, epoch: scanout.Epoch) *scanout.Owner {
        return if (self.scanout_owner.self_address != 0 and epoch.output.connector_id != self.scanout_owner.epoch.output.connector_id)
            &self.extra_scanout else &self.scanout_owner;
    }
    pub fn removeExtra(self: *Owner) Error!void {
        if (self.self_address != @intFromPtr(self) or self.closing or self.thread != 0 or self.phase != .programmed or
            self.hooks == null or self.hooks.?.remove == null) return error.State;
        try self.launch(.head_remove);
    }
    pub fn powerCommand(self: *Owner, request: PowerRequest) Error!void {
        if (self.self_address != @intFromPtr(self) or self.closing or self.thread != 0 or self.phase != .programmed or
            self.hooks == null or self.hooks.?.power == null or !std.meta.eql(self.scanoutFor(request.epoch).epoch, request.epoch)) return error.State;
        self.power_request = request; try self.launch(.power_work);
    }
    pub fn pausePrimary(self: *Owner) Error!void {
        if (self.self_address != @intFromPtr(self) or self.closing or self.thread != 0 or self.phase != .programmed or
            self.hooks == null or self.hooks.?.pause_primary == null) return error.State;
        try self.launch(.primary_pause);
    }
    pub fn candidateStorage(self: *Owner) Error!*anyopaque {
        if (workerCheck(self) != 1 or self.candidate_allocation.cpu_address == 0) return error.State;
        return @ptrFromInt(self.candidate_allocation.cpu_address);
    }
    pub fn bindPanel(self: *Owner) Error!void {
        if (self.self_address != @intFromPtr(self) or self.closing or self.thread != 0 or
            self.phase != .planned or self.panel_allocation.handle != 0) return error.State;
        try self.launch(.panel_bind);
    }
    pub fn healthCommand(self: *Owner) Error!void {
        if (self.self_address != @intFromPtr(self) or self.closing or self.thread != 0 or self.phase != .programmed or
            self.scanout_owner.phase != .active or self.panel_allocation.cpu_address == 0) return error.State;
        try self.launch(.health_work);
    }
    pub fn bindHdmi(self: *Owner) Error!void {
        if (self.self_address != @intFromPtr(self) or self.closing or self.thread != 0 or
            self.phase != .planned or self.hdmi_allocation.handle != 0) return error.State;
        try self.launch(.hdmi_bind);
    }
    pub fn hdmiCommand(self: *Owner, operation: hdmi.Operation) Error!void {
        if (self.self_address != @intFromPtr(self) or self.closing or self.thread != 0 or self.hooks == null or
            (self.phase != .planned and self.phase != .programmed) or self.hdmi_allocation.handle == 0) return error.State;
        self.hdmi_operation = operation;
        try self.launch(.hdmi_work);
    }
    pub fn hdmiPublish(self: *Owner, token: u64, identity: a.GfxOutputId, retirement: hdmi.hotplug.Io) Error!void {
        if (self.self_address != @intFromPtr(self) or self.closing or self.thread != 0 or self.phase != .programmed or
            self.hdmi_allocation.handle == 0 or token == 0 or identity.connection_generation == 0) return error.State;
        self.hdmi_publish_token = token; self.hdmi_output = identity; self.hdmi_retirement = retirement;
        try self.launch(.hdmi_publish);
    }
    pub fn hdmiInWorker(self: *Owner, operation: hdmi.Operation) Error!void {
        if (workerCheck(self) != 1 or self.hooks == null or self.hdmi_allocation.handle == 0 or
            (self.action != .commit and self.action != .hdmi_work and self.action != .abort)) return error.State;
        const runtime: *hdmi.Runtime = @ptrFromInt(self.hdmi_allocation.cpu_address);
        if (runtime.self_address != @intFromPtr(runtime)) return error.State;
        self.effects = true; self.frontend_attempted = true; self.quiet = false;
        if (self.stop_extra) runtime.connection.invalidate();
        runtime.run(operation, self.mode) catch return error.State;
    }
    pub fn panelCommand(self: *Owner, operation: panel.Operation, value: u16) Error!void {
        if (self.self_address != @intFromPtr(self) or self.closing or self.thread != 0 or self.hooks == null or
            (self.phase != .planned and self.phase != .programmed) or self.panel_allocation.handle == 0) return error.State;
        self.panel_operation = operation;
        self.panel_value = value;
        try self.launch(.panel_work);
    }
    /// Called by the native output worker after publication/activation. The
    /// private operation does not grant native output ownership on its own.
    pub fn brightnessCommand(self: *Owner, identity: a.GfxOutputId) Error!void {
        if (self.self_address != @intFromPtr(self) or self.closing or self.thread != 0 or self.hooks == null or
            (self.phase != .programmed and self.phase != .retained) or self.panel_allocation.handle == 0) return error.State;
        self.panel_identity = identity;
        try self.launch(.brightness_work);
    }
    /// Modeset hooks may use the panel only inside this admitted worker, after
    /// installing complete boot restoration. No nested task or C entry occurs.
    pub fn panelInWorker(self: *Owner, operation: panel.Operation, value: u16) Error!void {
        if (workerCheck(self) != 1 or self.hooks == null or self.panel_allocation.handle == 0 or
            (self.action != .commit and self.action != .panel_work and self.action != .abort)) return error.State;
        const runtime: *panel.Runtime = @ptrFromInt(self.panel_allocation.cpu_address);
        if (runtime.self_address != @intFromPtr(runtime)) return error.State;
        self.effects = true;
        self.frontend_attempted = true;
        self.quiet = false;
        runtime.run(operation, value) catch return error.State;
    }
    fn launch(self: *Owner, action: @FieldType(Owner, "action")) Error!void {
        if (self.thread != 0 or self.self_address != @intFromPtr(self)) return error.Busy;
        self.action = action;
        self.joined = false;
        self.worker_result = 0;
        self.result = c.R4DCN_STATE;
        if (self.threads.?.start(worker, self.self_address, a.driver_thread_flag_parallel | a.driver_thread_flag_abortable, &self.thread) != 0 or self.thread == 0) return error.Capacity;
    }
    /// A completed operation becomes observable only after Task join/release.
    /// A late join or failed release retains the callback context unchanged.
    pub fn poll(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        if (self.thread == 0) return true;
        if (!self.joined) {
            if (self.threads.?.join(self.thread, 0, &self.worker_result) != 0) return false;
            self.joined = true;
            if (self.worker_result != 0) {
                self.result = self.worker_result;
                self.phase = .retained;
            }
        }
        if (self.threads.?.release(self.thread) != 0) return false;
        self.thread = 0;
        return true;
    }
    pub fn close(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        self.closing = true;
        if (!self.poll()) return false;
        if (self.hdmi_storage_valid and self.hdmi_allocation.handle != 0) {
            const runtime: *hdmi.Runtime = @ptrFromInt(self.hdmi_allocation.cpu_address);
            if (!runtime.audio.closeMetadata()) return false;
        }
        if (self.effects) {
            self.launch(.abort) catch return false;
            return false;
        }
        if (self.candidate_allocation.handle != 0) {
            if (self.heap.?.release(self.candidate_allocation.handle) != 0) return false;
            self.candidate_allocation = .{};
        }
        if (self.hdmi_allocation.handle != 0) {
            if (self.hdmi_storage_valid) {
                const runtime: *hdmi.Runtime = @ptrFromInt(self.hdmi_allocation.cpu_address);
                if (runtime.self_address == @intFromPtr(runtime) and runtime.output.adapter_id != 0 and !runtime.reset_detached) return false;
            }
            if (self.heap.?.release(self.hdmi_allocation.handle) != 0) return false;
            self.hdmi_allocation = .{};
            self.hdmi_storage_valid = false;
        }
        if (self.panel_allocation.handle != 0) {
            if (self.heap.?.release(self.panel_allocation.handle) != 0) return false;
            self.panel_allocation = .{};
        }
        if (self.allocation.handle != 0) {
            if (self.heap.?.release(self.allocation.handle) != 0) return false;
            self.allocation = .{};
        }
        const memory = self.memory orelse return false;
        if (memory.self_address != @intFromPtr(memory) or memory.engine_users == 0) return false;
        memory.engine_users -= 1;
        if (@cmpxchgStrong(usize, &active_owner, self.self_address, 0, .acq_rel, .acquire) != null) return false;
        self.* = .{};
        return true;
    }
    pub fn workerStorage(self: *Owner) Error!*anyopaque {
        if (workerCheck(self) != 1 or !self.initialized) return error.State;
        return self.storage() orelse error.State;
    }
    pub fn workerPanel(self: *Owner) Error!*panel.Runtime {
        if (workerCheck(self) != 1 or self.panel_allocation.cpu_address == 0) return error.State;
        const runtime: *panel.Runtime = @ptrFromInt(self.panel_allocation.cpu_address);
        if (runtime.self_address != @intFromPtr(runtime)) return error.State;
        return runtime;
    }
    pub fn workerDelay(self: *Owner, us: u32) Error!void {
        if (delay(self, us) != 0) return error.State;
    }
    fn storage(self: *Owner) ?*anyopaque {
        return if (self.allocation.cpu_address == 0) null else @ptrFromInt(self.allocation.cpu_address);
    }
    fn worker(raw: usize) callconv(.c) i32 {
        const self: *Owner = @ptrFromInt(raw);
        if (self.self_address != raw or workerCheck(self) != 1) return c.R4DCN_STATE;
        switch (self.action) {
            .health_work => {
                self.result = self.healthInWorker();
                if (c.r4dcn_fault(self.storage()) != 0) self.phase = .retained;
            },
            .primary_pause => {
                self.result = if (self.hooks.?.pause_primary.?(self.hooks.?.context)) 0 else c.R4DCN_IO;
                if (c.r4dcn_fault(self.storage()) != 0) self.phase = .retained;
            },
            .mode_plan => {
                if (!self.initialized or self.phase != .programmed) return c.R4DCN_STATE;
                const bytes = c.r4dcn_size();
                if (self.candidate_allocation.handle == 0 and self.heap.?.allocate(bytes, 16, &self.candidate_allocation) != 0) return c.R4DCN_IO;
                const allocation = self.candidate_allocation;
                if (bytes == 0 or bytes > 8 * 1024 * 1024 or allocation.version != 1 or allocation.size < @sizeOf(a.DriverHeapAllocation) or
                    allocation.handle == 0 or allocation.cpu_address == 0 or allocation.cpu_address % 16 != 0 or allocation.byte_length != bytes or
                    allocation.cpu_address > std.math.maxInt(u64) - bytes or allocation.alignment < 16 or allocation.reserved != 0) return c.R4DCN_INVALID;
                const io: c.struct_r4dcn_io = .{ .context = self, .read = read, .write = write, .now_ns = now, .delay_us = delay, .worker = workerCheck, .log = log, .fatal = fatal };
                const storage_ptr: *anyopaque = @ptrFromInt(allocation.cpu_address);
                self.result = c.r4dcn_init(storage_ptr, bytes, &io, &self.limits);
                if (self.result == 0) {
                    var modes: [2]c.struct_r4dcn_mode = undefined;
                    modes[0] = if (self.candidate_mode.pipe == self.mode.pipe) self.candidate_mode else self.mode;
                    var count: u32 = 1;
                    if (self.candidate_mode.pipe != self.mode.pipe) { modes[1] = self.candidate_mode; count = 2; }
                    else if (self.extra_mode) |extra| { modes[1] = extra; count = 2; }
                    self.result = c.r4dcn_prepare(storage_ptr, &modes, count, &self.candidate_plan);
                    if (self.result == 0 and self.fixed_disp_khz != 0 and
                        (self.candidate_plan.disp_khz > self.fixed_disp_khz or self.candidate_plan.dpp_khz > self.fixed_disp_khz)) self.result = c.R4DCN_BANDWIDTH;
                }
                self.candidate_valid = self.result == 0;
            },
            .power_work => {
                self.result = if (self.hooks.?.power.?(self.hooks.?.context, self.power_request)) 0 else c.R4DCN_IO;
                // A link error leaves this head unavailable. A sticky MMIO
                // failure still transfers the entire device to recovery.
                if (c.r4dcn_fault(self.storage()) != 0) self.phase = .retained;
            },
            .head_remove => {
                self.result = if (self.hooks.?.remove.?(self.hooks.?.context)) 0 else c.R4DCN_IO;
                if (c.r4dcn_fault(self.storage()) != 0) self.phase = .retained;
            },
            .mode_apply => {
                if (!self.initialized or self.phase != .programmed or self.hooks == null or self.hooks.?.modeset == null) return c.R4DCN_STATE;
                self.result = if (self.hooks.?.modeset.?(self.hooks.?.context, self.mode_request)) 0 else c.R4DCN_IO;
                if (self.result != 0 and (self.extra_mode == null or c.r4dcn_fault(self.storage()) != 0)) self.phase = .retained;
            },
            .scanout_work => {
                self.result = 0;
                self.scanoutInWorker() catch |err| {
                    self.result = switch (err) {
                        error.Busy => c.R4DCN_BUSY, error.Timeout => c.R4DCN_TIMEOUT,
                        error.Invalid => c.R4DCN_INVALID, error.State, error.Stale => c.R4DCN_STATE,
                        else => c.R4DCN_IO,
                    };
                };
                if (c.r4dcn_fault(self.storage()) != 0) self.phase = .retained;
            },
            .panel_bind => {
                if (!self.initialized or self.phase != .planned or self.board == null or self.panel_allocation.handle != 0) return c.R4DCN_STATE;
                const bytes = @sizeOf(panel.Runtime);
                if (self.heap.?.allocate(bytes, 16, &self.panel_allocation) != 0) return c.R4DCN_IO;
                const allocation = self.panel_allocation;
                if (allocation.version != 1 or allocation.size < @sizeOf(a.DriverHeapAllocation) or allocation.handle == 0 or
                    allocation.cpu_address == 0 or allocation.cpu_address % 16 != 0 or allocation.byte_length != bytes or
                    allocation.cpu_address > std.math.maxInt(u64) - bytes or allocation.alignment < 16 or allocation.reserved != 0) return c.R4DCN_INVALID;
                const runtime: *panel.Runtime = @ptrFromInt(allocation.cpu_address);
                runtime.* = .{};
                runtime.bind(self.storage().?, self.board.?, .{ .context = raw, .read = atomRead, .write = atomWrite, .now = atomNow, .delay = atomDelay, .worker = atomWorker }, self.mode.pipe) catch {
                    self.result = c.R4DCN_UNSUPPORTED;
                    return 0;
                };
                self.result = 0;
            },
            .hdmi_bind => {
                if (!self.initialized or self.phase != .planned or self.board == null or self.hdmi_allocation.handle != 0) return c.R4DCN_STATE;
                const bytes = @sizeOf(hdmi.Runtime);
                if (self.heap.?.allocate(bytes, 16, &self.hdmi_allocation) != 0) return c.R4DCN_IO;
                const allocation = self.hdmi_allocation;
                if (allocation.version != 1 or allocation.size < @sizeOf(a.DriverHeapAllocation) or allocation.handle == 0 or
                    allocation.cpu_address == 0 or allocation.cpu_address % 16 != 0 or allocation.byte_length != bytes or
                    allocation.cpu_address > std.math.maxInt(u64) - bytes or allocation.alignment < 16 or allocation.reserved != 0) return c.R4DCN_INVALID;
                const runtime: *hdmi.Runtime = @ptrFromInt(allocation.cpu_address);
                runtime.* = .{};
                self.hdmi_storage_valid = true;
                runtime.audio.peer = self.audio_peer;
                runtime.bind(self.storage().?, self.board.?, .{ .context = raw, .read = atomRead, .write = atomWrite, .now = atomNow, .delay = atomDelay, .worker = atomWorker }) catch |err| {
                    runtime.last_bind_error = err;
                    self.result = c.R4DCN_UNSUPPORTED;
                    return 0;
                };
                self.result = 0;
            },
            .hdmi_work => {
                self.result = 0;
                self.hdmiInWorker(self.hdmi_operation) catch { self.result = c.R4DCN_IO; };
                // NACK, missing receiver and unplug are ordinary link events.
                // A sticky native MMIO fault still retains the entire owner.
                if (c.r4dcn_fault(self.storage()) != 0) self.phase = .retained;
            },
            .hdmi_publish => {
                const runtime: *hdmi.Runtime = @ptrFromInt(self.hdmi_allocation.cpu_address);
                self.result = 0;
                runtime.published(self.hdmi_publish_token, self.hdmi_output, self.ctx.?.graphicsOutputs() orelse return c.R4DCN_UNSUPPORTED,
                    self.hdmi_retirement.?) catch { self.result = c.R4DCN_IO; };
                if (c.r4dcn_fault(self.storage()) != 0) self.phase = .retained;
            },
            .panel_work => {
                self.result = 0;
                self.panelInWorker(self.panel_operation, self.panel_value) catch {
                    self.result = c.R4DCN_IO;
                    self.phase = .retained;
                };
            },
            .brightness_work => {
                self.result = 0;
                const runtime: *panel.Runtime = @ptrFromInt(self.panel_allocation.cpu_address);
                if (runtime.self_address != @intFromPtr(runtime) or runtime.protocol == null) return c.R4DCN_STATE;
                const outputs = self.ctx.?.graphicsOutputs() orelse return c.R4DCN_UNSUPPORTED;
                if (!outputs.supportsBrightness()) return c.R4DCN_UNSUPPORTED;
                self.effects = true; self.frontend_attempted = true; self.quiet = false;
                runtime.brightness.service(&runtime.protocol.?, &outputs, self.panel_identity, atomNow(@intFromPtr(self))) catch {
                    self.result = c.R4DCN_IO;
                };
                if (runtime.protocol.?.phase == .retained) self.phase = .retained;
            },
            .prepare => {
                self.phase = .preparing;
                const bytes = c.r4dcn_size();
                if (bytes == 0 or bytes > 8 * 1024 * 1024) return c.R4DCN_INVALID;
                if (self.heap.?.allocate(bytes, 16, &self.allocation) != 0) return c.R4DCN_IO;
                const allocation = self.allocation;
                if (allocation.version != 1 or allocation.size < @sizeOf(a.DriverHeapAllocation) or allocation.handle == 0 or
                    allocation.cpu_address == 0 or allocation.cpu_address % 16 != 0 or allocation.byte_length != bytes or
                    allocation.cpu_address > std.math.maxInt(u64) - bytes or allocation.alignment < 16 or allocation.reserved != 0) return c.R4DCN_INVALID;
                const io: c.struct_r4dcn_io = .{ .context = self, .read = read, .write = write, .now_ns = now, .delay_us = delay, .worker = workerCheck, .log = log, .fatal = fatal };
                self.result = c.r4dcn_init(self.storage(), bytes, &io, &self.limits);
                if (self.result == 0) {
                    self.initialized = true;
                    self.result = c.r4dcn_prepare(self.storage(), &self.mode, 1, &self.plan);
                }
                self.phase = if (self.result == 0) .planned else .retained;
            },
            .commit => {
                if (!self.initialized or self.phase != .planned or self.hooks == null or !self.native.?.firmwareReady()) return c.R4DCN_STATE;
                self.phase = .programming;
                // Hook effects include clock/link writes, so retain before the
                // first callback, even when it returns failure partway through.
                self.effects = true;
                self.quiet = false;
                const hooks = self.hooks.?;
                self.result = c.R4DCN_IO;
                if (hooks.prepare(hooks.context, &self.plan, &self.limits)) {
                    self.frontend_attempted = true;
                    self.result = c.r4dcn_program(self.storage());
                }
                self.phase = if (self.result == 0) .programmed else .retained;
            },
            .abort => {
                if (!self.effects or self.hooks == null or !self.initialized) return c.R4DCN_STATE;
                if (self.hooks.?.stop) |stop| if (!stop(self.hooks.?.context)) {
                    self.result = c.R4DCN_IO; self.phase = .retained; return 0;
                };
                if (self.scanout_owner.self_address != 0) self.scanout_owner.stop(self.scanout_owner.epoch) catch {
                    self.result = c.R4DCN_IO; self.phase = .retained; return 0;
                };
                self.result = if (self.quiet or !self.frontend_attempted) 0 else c.r4dcn_quiesce(self.storage());
                if (self.result == 0) {
                    self.quiet = true;
                    const hooks = self.hooks.?;
                    self.result = if (hooks.restore(hooks.context) and self.native.?.bootMatches()) 0 else c.R4DCN_IO;
                    if (self.result == 0) {
                        self.effects = false;
                        self.phase = .aborted;
                    }
                }
                if (self.result != 0) self.phase = .retained;
            },
        }
        return 0;
    }
    fn scanoutInWorker(self: *Owner) scanout.Error!void {
        if (workerCheck(self) != 1 or self.action != .scanout_work) return error.State;
        const request = self.scanout_request;
        const life = self.scanoutFor(request.epoch);
        const mode = if (life == &self.scanout_owner) self.mode else self.extra_mode orelse return error.State;
        switch (request.operation) {
            .bind => try life.bind(self.storage().?, request.epoch, mode, request.image.?),
            .rekey => try life.rekey(request.epoch),
            .enable => try life.enable(request.epoch, request.sequence, request.deadline_ns),
            .flip => try life.flip(request.epoch, request.sequence, request.image.?, request.deadline_ns),
            .sample => if (try life.poll(request.epoch, self.clock.?.nowNs()) == null) { self.result = c.R4DCN_BUSY; },
            .acknowledge => try life.acknowledge(request.epoch, request.sequence),
            .stop => try life.stop(request.epoch),
            .cursor => try life.cursor(request.epoch, request.sequence, request.cursor.?, request.deadline_ns),
            .cursor_sample => if (try life.pollCursor(request.epoch, self.clock.?.nowNs()) == null) { self.result = c.R4DCN_BUSY; },
            .cursor_acknowledge => try life.acknowledgeCursor(request.epoch, request.sequence),
        }
    }
    fn healthInWorker(self: *Owner) c_int {
        if (workerCheck(self) != 1 or self.action != .health_work or self.scanout_owner.current == null) return c.R4DCN_STATE;
        const runtime = self.workerPanel() catch return c.R4DCN_STATE;
        runtime.protocol.?.verifyLink() catch return c.R4DCN_IO;
        var sample: c.struct_r4dcn_scanout_sample = undefined;
        const result = c.r4dcn_scanout_sample(self.storage(), self.mode.pipe, &sample);
        if (result != 0) return result;
        if (sample.underflow != 0 or sample.running != 1 or sample.blank != 0 or sample.requested_address != self.scanout_owner.current.?.address or
            sample.inuse_address != self.scanout_owner.current.?.address) return c.R4DCN_IO;
        if (sample.pending != 0 or sample.locked != 0) return c.R4DCN_BUSY;
        if (self.health_epoch != self.scanout_owner.epoch.mode) {
            self.health_epoch = self.scanout_owner.epoch.mode; self.health_frame = sample.frame; self.health_progress = sample.end_ns;
        } else {
            if (sample.end_ns < self.health_progress) return c.R4DCN_IO;
            const delta = (sample.frame -% self.health_frame) & 0xffffff;
            if (delta >= 0x800000) return c.R4DCN_IO;
            if (delta != 0) { self.health_frame = sample.frame; self.health_progress = sample.end_ns; }
            if (sample.end_ns - self.health_progress >= 2 * std.time.ns_per_s) return c.R4DCN_TIMEOUT;
        }
        return 0;
    }
    fn from(raw: ?*anyopaque) *Owner {
        return @ptrCast(@alignCast(raw.?));
    }
    fn workerCheck(raw: ?*anyopaque) callconv(.c) c_int {
        const self = from(raw);
        if (self.self_address != @intFromPtr(self) or @atomicLoad(usize, &active_owner, .acquire) != self.self_address) return 0;
        var request: a.DriverThreadRequest = .{};
        return @intFromBool(self.threads.?.current() != 0 and self.threads.?.currentRequest(&request) == 0 and
            request.version == 1 and request.size >= @sizeOf(a.DriverThreadRequest) and request.handler == @intFromPtr(&worker) and
            request.context == self.self_address and request.flags == a.driver_thread_flag_parallel | a.driver_thread_flag_abortable);
    }
    fn read(raw: ?*anyopaque, offset: u32, value: [*c]u32) callconv(.c) c_int {
        const self = from(raw);
        if (workerCheck(raw) != 1) return -1;
        value.* = self.memory.?.registers.read(offset) catch return -1;
        return 0;
    }
    fn write(raw: ?*anyopaque, offset: u32, value: u32) callconv(.c) c_int {
        const self = from(raw);
        if (workerCheck(raw) != 1 or !self.effects or (self.action != .commit and self.action != .panel_work and self.action != .brightness_work and self.action != .hdmi_work and self.action != .scanout_work and self.action != .mode_apply and self.action != .head_remove and self.action != .primary_pause and self.action != .health_work and self.action != .abort)) return -1;
        self.memory.?.registers.write(offset, value) catch return -1;
        self.memory.?.registers.barrier() catch return -1;
        return 0;
    }
    fn now(raw: ?*anyopaque) callconv(.c) u64 {
        return from(raw).clock.?.nowNs();
    }
    fn atomRead(raw: usize, space: atom.Space, index: u32) atom.Error!u32 {
        if (space != .mmio or index > std.math.maxInt(u32) / 4) return error.Unsupported;
        var value: u32 = 0;
        if (read(@ptrFromInt(raw), index * 4, &value) != 0) return error.Io;
        return value;
    }
    fn atomWrite(raw: usize, space: atom.Space, index: u32, value: u32) atom.Error!void {
        if (space != .mmio or index > std.math.maxInt(u32) / 4) return error.Unsupported;
        if (write(@ptrFromInt(raw), index * 4, value) != 0) return error.Io;
    }
    fn atomWorker(raw: usize) bool {
        return workerCheck(@ptrFromInt(raw)) == 1;
    }
    fn atomNow(raw: usize) u64 {
        return now(@ptrFromInt(raw));
    }
    fn atomDelay(raw: usize, us: u32) atom.Error!void {
        if (delay(@ptrFromInt(raw), us) != 0) return error.Deadline;
    }
    fn delay(raw: ?*anyopaque, us: u32) callconv(.c) c_int {
        const self = from(raw);
        if (workerCheck(raw) != 1 or us > 3_000_000) return -1;
        if (us >= 1000) return if (self.threads.?.sleepTicks(@max(1, (@as(u64, us) * self.frequency + 999_999) / 1_000_000)) == 0) 0 else -1;
        const begin = self.clock.?.nowNs();
        for (0..1_000_000) |_| {
            const current = self.clock.?.nowNs();
            if (current < begin) return -1;
            if (current - begin >= @as(u64, us) * 1000) return 0;
            std.atomic.spinLoopHint();
        }
        return -1;
    }
    fn log(raw: ?*anyopaque, message: [*c]const u8) callconv(.c) void {
        const self = from(raw);
        _ = message;
        // Templates contain C varargs; plan/fault reporting uses typed fields.
        self.diagnostic_count +|= 1;
    }
    fn fatal(raw: ?*anyopaque, expression: [*c]const u8, file: [*c]const u8, line: c_uint) callconv(.c) void {
        const self = from(raw);
        self.phase = .retained;
        self.result = c.R4DCN_STATE;
        var buffer: [384]u8 = undefined;
        if (std.fmt.bufPrintZ(&buffer, "AMDGPU DC fatal: {s}:{d}: {s}", .{ std.mem.span(file), line, std.mem.span(expression) })) |message| self.ctx.?.logError(message) else |_| {}
        _ = self.threads.?.abortCurrent(c.R4DCN_STATE);
        @trap();
    }
};
