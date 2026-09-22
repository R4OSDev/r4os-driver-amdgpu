// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Heap-resident ATOM, receiver and connection state in the DCN display task.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const atom = @import("atom_vm.zig");
const bios = @import("bios.zig");
pub const hdmi = @import("hdmi.zig");
pub const hotplug = @import("hdmi_hotplug.zig");
pub const c = hdmi.c;
pub const Operation = enum(u32) { probe = 1, configure = 2, enable = 3, show = 4, stop = 5, service = 6, clock = 7 };
pub const Runtime = struct {
    self_address: usize = 0,
    storage: ?*anyopaque = null,
    vm: atom.Vm = .{},
    scratch: [16384]u32 = @splat(0),
    route: ?hdmi.Route = null,
    receiver: hdmi.Receiver = .{},
    connection: hotplug.Connection = .{},
    initialized: bool = false,
    configured: bool = false,
    clock_bound: bool = false,
    dprefclk_khz: u32 = 0,
    activation_attempted: bool = false,
    last_atom_error: ?atom.Error = null,
    last_error: ?hdmi.Error = null,
    last_bind_error: ?anyerror = null,
    output: a.GfxOutputId = .{},
    outputs: ?r4os.driver_outputs.Context = null,
    retirement: ?hotplug.Io = null,
    reset_detached: bool = false,
    // Index0 is reserved for the internal eDP panel. /20 generalizes to the
    // complete board list; the Lenovo target has one physical HDMI output.
    const index = 1;
    pub fn bind(self: *Runtime, storage: *anyopaque, board: *const bios.Board, io: atom.Io) !void {
        if (self.self_address != 0) return error.State;
        const selected = try hdmi.route(board);
        const declared = if (board.reservation) |r| r.driver_scratch_bytes else 0;
        const bytes = if (declared == 0) 20 * 1024 else declared;
        if (bytes > self.scratch.len * 4 or bytes % 4 != 0) return error.Capacity;
        try self.vm.initialize(board, self.scratch[0..@intCast(bytes / 4)], io);
        const tx = try self.vm.revision(@offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, "dig1transmittercontrol") / 2);
        const enc = try self.vm.revision(@offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, "digxencodercontrol") / 2);
        if (!std.mem.eql(u8, &tx, &.{ 1, 6 }) or !std.mem.eql(u8, &enc, &.{ 1, 5 })) return error.Unsupported;
        self.storage = storage;
        self.self_address = @intFromPtr(self);
        const callback: c.struct_r4dcn_atom = .{ .context = self, .execute = execute };
        try checked(c.r4dcn_link_bind(storage, index, &selected.native, &callback));
        try checked(c.r4dcn_hdmi_bind(storage, index, selected.crystal_khz));
        self.route = selected;
    }
    pub fn run(self: *Runtime, operation: Operation, mode: c.struct_r4dcn_mode) hdmi.Error!void {
        if (!self.worker() or self.route == null) return error.State;
        self.last_error = null;
        self.work(operation, mode) catch |err| { self.last_error = err; return err; };
    }
    fn work(self: *Runtime, operation: Operation, mode: c.struct_r4dcn_mode) hdmi.Error!void {
        switch (operation) {
            .clock => {
                const reference_revision = self.vm.revision(@offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, "setdceclock") / 2) catch return error.Unsupported;
                if (!std.mem.eql(u8, &reference_revision, &.{ 2, 1 })) return error.Unsupported;
                if (!self.clock_bound) {
                    const revision = self.vm.revision(@offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, "setpixelclock") / 2) catch return error.Unsupported;
                    if (!std.mem.eql(u8, &revision, &.{ 1, 7 })) return error.Unsupported;
                    try checked(c.r4dcn_pixel_clock_bind(self.storage, index, self.route.?.crystal_khz));
                    self.clock_bound = true;
                }
                // Pixel-clock writes are native activation effects even when
                // a later link/stream operation fails before output publication.
                self.activation_attempted = true;
                // DPREFCLK was confirmed during the primary takeover. A live
                // HDMI addition must not reprogram the shared reference.
                try checked(c.r4dcn_reference_clock_get(self.storage, &self.dprefclk_khz));
                try checked(c.r4dcn_pixel_clock_program(self.storage, index, mode.pipe));
            },
            .probe, .service => {
                if (!self.initialized) { try checked(c.r4dcn_link_action(self.storage, index, c.R4DCN_LINK_INIT)); self.initialized = true; }
                const present = try hpd(self.self_address);
                self.connection.sample(present, now(self.self_address)) catch return error.State;
                if (!present and self.activation_attempted and self.output.adapter_id == 0) {
                    // Unplug during first activation still owns hardware even
                    // before common publication. /18 must restore that attempt.
                    self.connection.phase = .retained; return error.State;
                }
                if (self.connection.phase == .retiring) {
                    if (self.retirement == null or self.outputs == null) return error.State;
                    _ = self.connection.advance(.{ .context = self.self_address, .retire = retire }) catch return error.State;
                    return;
                }
                if (self.connection.phase == .retained) return error.State;
                if (!present or (self.connection.phase != .probing and self.connection.phase != .connected)) return;
                if (operation == .service and self.connection.phase == .connected) return;
                const token = self.connection.generation;
                self.receiver.read(.{ .context = self.self_address, .hpd = hpd, .block = block, .now = now, .delay = delay }, self.route.?.max_tmds_hz) catch |err| {
                    self.connection.invalidate(); return err;
                };
                if (self.connection.phase == .connected) self.connection.changed(token, self.receiver.fingerprint) catch return error.State;
            },
            .configure => {
                if ((self.connection.phase != .probing and self.connection.phase != .connected) or !self.receiver.valid or !try hpd(self.self_address)) return error.State;
                if (mode.flags & 1 == 0 or mode.h_front > std.math.maxInt(u32) - mode.width or
                    mode.h_sync > std.math.maxInt(u32) - mode.width - mode.h_front or mode.v_front > std.math.maxInt(u32) - mode.height or
                    mode.v_sync > std.math.maxInt(u32) - mode.height - mode.v_front) return error.Invalid;
                const timing: hdmi.edid.timing.Timing = .{ .width = mode.width, .height = mode.height, .h_total = mode.h_total, .v_total = mode.v_total,
                    .h_start = mode.width + mode.h_front, .h_end = mode.width + mode.h_front + mode.h_sync,
                    .v_start = mode.height + mode.v_front, .v_end = mode.height + mode.v_front + mode.v_sync,
                    .clock_hz = @as(u64, mode.pixel_khz) * 1000, .flags = mode.flags & 6 };
                var known: ?hdmi.edid.timing.Timing = null;
                for (self.receiver.report.modes[0..self.receiver.report.mode_count]) |candidate| if (candidate.sameMode(timing)) { known = candidate; break; };
                const avi = try self.receiver.avi(known orelse return error.Unsupported);
                self.configured = false;
                try checked(c.r4dcn_hdmi_configure(self.storage, index, mode.pipe, &avi));
                self.configured = true;
            },
            .enable, .show => {
                if (!self.configured or !self.receiver.valid or !try hpd(self.self_address) or
                    (self.connection.phase != .probing and self.connection.phase != .connected)) return error.State;
                if (operation == .enable) {
                    self.activation_attempted = true;
                    try checked(c.r4dcn_hdmi_enable(self.storage, index));
                } else try checked(c.r4dcn_hdmi_mute(self.storage, index, 0));
            },
            .stop => {
                if (self.configured) try checked(c.r4dcn_hdmi_mute(self.storage, index, 1));
                try checked(c.r4dcn_link_action(self.storage, index, c.R4DCN_LINK_DISABLE));
                var stopped: u32 = 0;
                try checked(c.r4dcn_hdmi_stopped(self.storage, index, &stopped));
                if (stopped == 1) { self.activation_attempted = false; self.configured = false; }
            },
        }
    }
    /// /18 calls only after real output publication. The common identity is
    /// retained separately from the local receiver token, never synthesized.
    pub fn published(self: *Runtime, token: u64, output: a.GfxOutputId, outputs: r4os.driver_outputs.Context, retirement: hotplug.Io) !void {
        if (!self.worker() or self.route == null or !self.receiver.valid or self.output.adapter_id != 0 or !outputs.supportsHotplug() or
            output.adapter_id == 0 or output.connector_id != self.route.?.native.connector or output.device_generation == 0 or output.connection_generation == 0) return error.State;
        if (!try hpd(self.self_address)) return error.Disconnected;
        try self.connection.publish(token, self.receiver.fingerprint);
        self.output = output; self.outputs = outputs; self.retirement = retirement;
    }
    /// Receiver-only HDMI has no scanout BOs or common mode jobs. During a
    /// whole-device reset, retain its common ID in the outer connector owner
    /// while stopping the real link and restoring its temporary pad state.
    pub fn detachInactive(self: *Runtime) !void {
        if (!self.worker() or self.activation_attempted or self.configured) return error.State;
        if (self.route == null) return;
        var stopped: u32 = 0;
        try checked(c.r4dcn_hdmi_stopped(self.storage, index, &stopped));
        if (stopped != 1) return error.State;
        try checked(c.r4dcn_link_restore_pads(self.storage, index));
        self.reset_detached = true; self.initialized = false;
    }
    fn retire(raw: usize, token: u64, step: hotplug.Step) hotplug.Receipt {
        const self = from(raw);
        var receipt: hotplug.Receipt = .{ .generation = token };
        if (token != self.connection.generation or self.outputs == null or self.retirement == null or !self.worker()) return receipt;
        switch (step) {
            .pause => { receipt.done = self.outputs.?.pauseOutput(&self.output, true) == a.gfx_output_ok; },
            .withdraw => {
                receipt = self.retirement.?.retire(self.retirement.?.context, token, .withdraw);
                if (receipt.generation == token and receipt.done and receipt.scanout_stopped and receipt.pending_jobs == 0 and receipt.live_leases == 0)
                    receipt.done = self.outputs.?.withdraw(&self.output) == a.gfx_output_ok;
            },
            else => {
                receipt = self.retirement.?.retire(self.retirement.?.context, token, step);
                if (step == .stop and receipt.done) {
                    var stopped: u32 = 0;
                    receipt.scanout_stopped = c.r4dcn_hdmi_stopped(self.storage, index, &stopped) == 0 and stopped == 1 and receipt.scanout_stopped;
                }
                if (step == .release and receipt.generation == token and receipt.done and receipt.scanout_stopped and receipt.pending_jobs == 0 and receipt.live_leases == 0) {
                    self.output = .{}; self.configured = false; self.receiver.valid = false; self.activation_attempted = false;
                }
            },
        }
        return receipt;
    }
    fn worker(self: *Runtime) bool { return self.self_address == @intFromPtr(self) and self.vm.io != null and self.vm.io.?.worker(self.vm.io.?.context); }
    fn checked(result: c_int) hdmi.Error!void { switch (result) { 0 => {}, c.R4DCN_TIMEOUT => return error.Timeout, c.R4DCN_UNSUPPORTED => return error.Unsupported, c.R4DCN_INVALID => return error.Invalid, c.R4DCN_STATE => return error.State, else => return error.Io } }
    fn from(raw: usize) *Runtime { return @ptrFromInt(raw); }
    fn execute(raw: ?*anyopaque, command: u32, words: [*c]u32, count: u32) callconv(.c) c_int {
        const self: *Runtime = @ptrCast(@alignCast(raw.?)); self.last_atom_error = null;
        if (!self.worker() or count > 256 or words == null or command > 255) return -1;
        self.vm.execute(@intCast(command), words[0..count]) catch |err| { self.last_atom_error = err; return -1; }; return 0;
    }
    fn hpd(raw: usize) hdmi.Error!bool { var value: u32 = 0; try checked(c.r4dcn_link_hpd(from(raw).storage, index, &value)); return value == 1; }
    fn block(raw: usize, number: u32, bytes: *[128]u8) hdmi.Error!void { try checked(c.r4dcn_hdmi_edid(from(raw).storage, index, number, bytes)); }
    fn now(raw: usize) u64 { const io = from(raw).vm.io.?; return io.now(io.context); }
    fn delay(raw: usize, us: u32) hdmi.Error!void { const io = from(raw).vm.io.?; io.delay(io.context, us) catch return error.Timeout; }
};
