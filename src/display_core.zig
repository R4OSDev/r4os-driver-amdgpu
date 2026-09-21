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
    hdmi_storage_valid: bool = false,
    hdmi_operation: hdmi.Operation = .probe,
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
    action: enum { prepare, commit, abort, panel_bind, panel_work, brightness_work, hdmi_bind, hdmi_work } = .prepare,
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
    pub fn prepareBoot(self: *Owner, ctx: *const r4os.r4dev.DriverContext, memory: *mem.Owner, native: *start.Owner, board: *const @import("bios.zig").Board, limits: c.struct_r4dcn_limits, mode: c.struct_r4dcn_mode) Error!void {
        if (self.self_address != 0) return error.Busy;
        const integrated = board.integrated orelse return error.Unsupported;
        const held = &native.hold;
        if (!native.firmwareReady() or native.memory != memory or !memory.prepared or memory.engine_users == 0 or
            memory.engine_users == std.math.maxInt(u32) or !native.guard.valid or held.held_generation == 0 or !held.effects or
            limits.channels != integrated.uma_channels or memory.self_address != @intFromPtr(memory)) return error.Stale;
        if (mode.mc_address != native.guard.boot_mc or mode.buffer_bytes != held.boot.byte_length or
            mode.width != held.boot.width or mode.height != held.boot.height or mode.pitch_bytes != held.boot.pitch or
            held.boot.format != a.gfx_buffer_format_xrgb8888 or mode.pipe >= 4) return error.Invalid;
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
    pub fn bindPanel(self: *Owner) Error!void {
        if (self.self_address != @intFromPtr(self) or self.closing or self.thread != 0 or
            self.phase != .planned or self.panel_allocation.handle != 0) return error.State;
        try self.launch(.panel_bind);
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
    pub fn hdmiInWorker(self: *Owner, operation: hdmi.Operation) Error!void {
        if (workerCheck(self) != 1 or self.hooks == null or self.hdmi_allocation.handle == 0 or
            (self.action != .commit and self.action != .hdmi_work and self.action != .abort)) return error.State;
        const runtime: *hdmi.Runtime = @ptrFromInt(self.hdmi_allocation.cpu_address);
        if (runtime.self_address != @intFromPtr(runtime)) return error.State;
        self.effects = true; self.frontend_attempted = true; self.quiet = false;
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
            (self.action != .commit and self.action != .panel_work)) return error.State;
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
        if (self.effects) {
            self.launch(.abort) catch return false;
            return false;
        }
        if (self.hdmi_allocation.handle != 0) {
            if (self.hdmi_storage_valid) {
                const runtime: *hdmi.Runtime = @ptrFromInt(self.hdmi_allocation.cpu_address);
                if (runtime.self_address == @intFromPtr(runtime) and runtime.output.adapter_id != 0) return false;
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
    fn storage(self: *Owner) ?*anyopaque {
        return if (self.allocation.cpu_address == 0) null else @ptrFromInt(self.allocation.cpu_address);
    }
    fn worker(raw: usize) callconv(.c) i32 {
        const self: *Owner = @ptrFromInt(raw);
        if (self.self_address != raw or workerCheck(self) != 1) return c.R4DCN_STATE;
        switch (self.action) {
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
                runtime.bind(self.storage().?, self.board.?, .{ .context = raw, .read = atomRead, .write = atomWrite, .now = atomNow, .delay = atomDelay, .worker = atomWorker }) catch {
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
                self.result = if (self.quiet or !self.frontend_attempted) 0 else c.r4dcn_quiesce(self.storage());
                if (self.result == 0) {
                    self.quiet = true;
                    const hooks = self.hooks.?;
                    self.result = if (hooks.restore(hooks.context) and
                        (self.native.?.guard.matches(&self.memory.?.registers) catch false)) 0 else c.R4DCN_IO;
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
        if (workerCheck(raw) != 1 or !self.effects or (self.action != .commit and self.action != .panel_work and self.action != .brightness_work and self.action != .hdmi_work and self.action != .abort)) return -1;
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
