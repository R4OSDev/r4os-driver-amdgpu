// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Heap-resident panel/ATOM state under the existing SIMD display-task owner.
const std = @import("std");
const bios = @import("bios.zig");
const atom = @import("atom_vm.zig");
pub const panel = @import("panel.zig");
pub const c = panel.c;
pub const Operation = enum(u32) { discover = 1, train = 2, show = 3, brightness = 4, hide = 5, clock = 6, stream_configure = 7, stream_on = 8, stream_off = 9 };
pub const BindDiagnostic = struct {
    step: enum { empty, gate, route, scratch, vm, command, revision, link, stream, ready } = .empty,
    scratch_bytes: u64 = 0,
    revision: [2]u8 = .{ 0, 0 },
    native_result: c_int = 0,
    route_valid: bool = false,
    route: c.struct_r4dcn_route = std.mem.zeroes(c.struct_r4dcn_route),
};
pub const ClockDiagnostic = struct {
    step: enum { empty, reference_revision, pixel_revision, bind, reference, pixel, ready } = .empty,
    native_result: c_int = 0,
    reference_words: [4]u32 = @splat(0),
    pixel_words: [4]u32 = @splat(0),
    reference_calls: u32 = 0,
    pixel_calls: u32 = 0,
    reference_hz: bool = false,
};
pub const Runtime = struct {
    self_address: usize = 0,
    storage: ?*anyopaque = null,
    pipe: u32 = 0,
    crystal_khz: u32 = 0,
    clock_bound: bool = false,
    dprefclk_khz: u32 = 0,
    vm: atom.Vm = .{},
    scratch: [16384]u32 = @splat(0),
    protocol: ?panel.Panel = null,
    last_atom_error: ?atom.Error = null,
    last_panel_error: ?panel.Error = null,
    brightness: @import("panel_brightness.zig").Bridge = .{},
    bind_diagnostic: BindDiagnostic = .{},
    clock_diagnostic: ClockDiagnostic = .{},
    clock_trace: atom.Trace = .{},
    aux_calls: u32 = 0,
    aux_native_result: c_int = 0,
    last_aux: c.struct_r4dcn_aux = std.mem.zeroes(c.struct_r4dcn_aux),
    video_native_result: c_int = 0,
    last_video: c.struct_r4dcn_video_observation = std.mem.zeroes(c.struct_r4dcn_video_observation),
    hpd_native_result: c_int = 0,
    last_hpd: c.struct_r4dcn_hpd_observation = std.mem.zeroes(c.struct_r4dcn_hpd_observation),
    pub fn bind(self: *Runtime, storage: *anyopaque, board: *const bios.Board, io: atom.Io, pipe: u32) !void {
        self.bind_diagnostic.step = .gate;
        if (self.self_address != 0 or pipe >= 4) return error.State;
        self.bind_diagnostic.step = .route;
        const route = try panel.route(board);
        self.bind_diagnostic.route = route.native;
        self.bind_diagnostic.route_valid = true;
        self.bind_diagnostic.step = .scratch;
        const declared = if (board.reservation) |r| r.driver_scratch_bytes else 0;
        const scratch_bytes = if (declared == 0) 20 * 1024 else declared;
        self.bind_diagnostic.scratch_bytes = scratch_bytes;
        if (scratch_bytes > self.scratch.len * 4 or scratch_bytes % 4 != 0) return error.Capacity;
        self.bind_diagnostic.step = .vm;
        try self.vm.initialize(board, self.scratch[0..@intCast(scratch_bytes / 4)], io);
        self.bind_diagnostic.step = .command;
        const command = @offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, "dig1transmittercontrol") / 2;
        const revision = try self.vm.revision(command);
        self.bind_diagnostic.revision = revision;
        self.bind_diagnostic.step = .revision;
        if (!std.mem.eql(u8, &revision, &.{ 1, 6 })) return error.Unsupported;
        self.storage = storage;
        self.pipe = pipe;
        self.crystal_khz = board.displayReferenceClock() catch 0;
        self.self_address = @intFromPtr(self);
        self.protocol = .{ .route = route, .io = .{ .context = self.self_address, .transfer = transfer, .action = action, .enable = enable, .train = train, .status = status, .pwm = pwm, .hpd = hpd, .video = video, .now = now, .delay = delay } };
        const callback: c.struct_r4dcn_atom = .{ .context = self, .execute = execute };
        self.bind_diagnostic.step = .link;
        self.bind_diagnostic.native_result = c.r4dcn_link_bind(storage, 0, &route.native, &callback);
        try checked(self.bind_diagnostic.native_result);
        self.bind_diagnostic.step = .stream;
        self.bind_diagnostic.native_result = c.r4dcn_dp_stream_bind(storage, 0);
        try checked(self.bind_diagnostic.native_result);
        self.bind_diagnostic.step = .ready;
    }
    pub fn run(self: *Runtime, operation: Operation, value: u16) panel.Error!void {
        if (self.self_address != @intFromPtr(self) or self.protocol == null or !self.vm.io.?.worker(self.vm.io.?.context)) return error.State;
        self.last_panel_error = null;
        const p = &self.protocol.?;
        const result = switch (operation) {
            .discover => p.discover(),
            .train => p.train(),
            .show => p.show(value),
            .brightness => p.setBrightness(value),
            .hide => p.hide(),
            .clock => self.pixelClock(),
            .stream_configure => self.configureStream(),
            .stream_on => if (p.phase == .trained) checked(c.r4dcn_dp_stream_start(self.storage, 0)) else error.State,
            .stream_off => checked(c.r4dcn_dp_stream_stop(self.storage, 0)),
        };
        result catch |err| {
            self.last_panel_error = err;
            return err;
        };
    }
    fn configureStream(self: *Runtime) panel.Error!void {
        if (self.protocol.?.phase != .discovered) return error.State;
        try checked(c.r4dcn_dp_stream_configure(self.storage, 0, self.pipe, self.protocol.?.bpc));
    }
    fn pixelClock(self: *Runtime) panel.Error!void {
        const diagnostic = &self.clock_diagnostic;
        diagnostic.step = .reference_revision;
        const reference_revision = self.vm.revision(@offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, "setdceclock") / 2) catch return error.Unsupported;
        if (!std.mem.eql(u8, &reference_revision, &.{ 2, 1 })) return error.Unsupported;
        // Observed Lenovo Raven2 command: SMU reply in MHz * 1000000,
        // minus the firmware spread-spectrum correction, returned in Hertz.
        // Bind this exception to both complete command implementations.
        // The ATOM 2.1 header alone does not distinguish their output units.
        diagnostic.reference_hz = self.commandMatches(
            @offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, "setdceclock") / 2,
            "f6fc1b5a4a677c3f35184595de755d121d016e94391224661ad72e10ace235cf") and
            self.commandMatches(19, "07d01c593fa585633f60cf71a7e22cf1f0d373bd4431a284f4f5083cd1d3713d");
        if (!self.clock_bound) {
            diagnostic.step = .pixel_revision;
            const revision = self.vm.revision(@offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, "setpixelclock") / 2) catch return error.Unsupported;
            if (!std.mem.eql(u8, &revision, &.{ 1, 7 }) or self.crystal_khz == 0) return error.Unsupported;
            diagnostic.step = .bind;
            diagnostic.native_result = c.r4dcn_pixel_clock_bind(self.storage, 0, self.crystal_khz);
            try checked(diagnostic.native_result);
            self.clock_bound = true;
        }
        if (self.dprefclk_khz == 0) {
            diagnostic.step = .reference;
            diagnostic.native_result = if (diagnostic.reference_hz)
                c.r4dcn_reference_clock_program_hz(self.storage, 0, &self.dprefclk_khz)
            else c.r4dcn_reference_clock_program(self.storage, 0, &self.dprefclk_khz);
            try checked(diagnostic.native_result);
        }
        diagnostic.step = .pixel;
        diagnostic.native_result = c.r4dcn_pixel_clock_program(self.storage, 0, self.pipe);
        try checked(diagnostic.native_result);
        diagnostic.step = .ready;
    }
    fn commandMatches(self: *const Runtime, index: u32, expected: []const u8) bool {
        if (self.vm.commands.len < 4 or index >= (self.vm.commands.len - 4) / 2) return false;
        const offset = bios.number(u16, self.vm.commands, 4 + @as(usize, index) * 2) catch return false;
        if (offset < 0x4a) return false;
        const length = bios.number(u16, self.vm.image, offset) catch return false;
        if (length < 6) return false;
        const bytes = bios.part(self.vm.image, offset, length) catch return false;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        return std.mem.eql(u8, &hex, expected);
    }
    fn checked(result: c_int) panel.Error!void {
        switch (result) {
            0 => {},
            c.R4DCN_TIMEOUT => return error.Timeout,
            c.R4DCN_UNSUPPORTED => return error.Unsupported,
            c.R4DCN_INVALID => return error.Invalid,
            c.R4DCN_STATE => return error.State,
            else => return error.Io,
        }
    }
    fn from(raw: usize) *Runtime {
        return @ptrFromInt(raw);
    }
    fn execute(raw: ?*anyopaque, command: u32, words: [*c]u32, count: u32) callconv(.c) c_int {
        const self: *Runtime = @ptrCast(@alignCast(raw.?));
        self.last_atom_error = null;
        if (self.self_address != @intFromPtr(self) or count > 256 or words == null or command > 255) return -1;
        if (command == @offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, "setdceclock") / 2) {
            self.clock_trace = .{};
            self.vm.trace = &self.clock_trace;
        }
        defer self.vm.trace = null;
        // Copy only already-returned ATOM parameters; no additional hardware
        // access. The display owner reads this snapshot after the worker joins.
        defer if (count == 4) {
            if (command == @offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, "setdceclock") / 2) {
                self.clock_diagnostic.reference_words = words[0..4].*;
                self.clock_diagnostic.reference_calls +|= 1;
            } else if (command == @offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, "setpixelclock") / 2) {
                self.clock_diagnostic.pixel_words = words[0..4].*;
                self.clock_diagnostic.pixel_calls +|= 1;
            }
        };
        self.vm.execute(@intCast(command), words[0..count]) catch |err| {
            self.last_atom_error = err;
            return -1;
        };
        return 0;
    }
    fn transfer(raw: usize, p: *c.struct_r4dcn_aux) panel.Error!void {
        const self = from(raw);
        self.aux_calls +|= 1;
        self.aux_native_result = c.r4dcn_link_aux(self.storage, 0, p);
        self.last_aux = p.*;
        try checked(self.aux_native_result);
    }
    fn action(raw: usize, value: panel.Action) panel.Error!void {
        try checked(c.r4dcn_link_action(from(raw).storage, 0, @intFromEnum(value)));
    }
    fn enable(raw: usize, rate: u8, lanes: u8) panel.Error!void {
        try checked(c.r4dcn_link_enable(from(raw).storage, 0, rate, lanes, 0));
    }
    fn train(raw: usize, pattern: u8, levels: *const [4]u8) panel.Error!void {
        try checked(c.r4dcn_link_train(from(raw).storage, 0, pattern, levels));
    }
    fn status(raw: usize) panel.Error!c.struct_r4dcn_panel_state {
        var s: c.struct_r4dcn_panel_state = undefined;
        try checked(c.r4dcn_panel_read(from(raw).storage, &s));
        return s;
    }
    fn pwm(raw: usize, value: u32) panel.Error!void {
        try checked(c.r4dcn_panel_pwm(from(raw).storage, value));
    }
    fn hpd(raw: usize) panel.Error!bool {
        const self = from(raw);
        var value: u32 = 0;
        self.hpd_native_result = c.r4dcn_link_hpd_observe(self.storage, 0, &value, &self.last_hpd);
        try checked(self.hpd_native_result);
        return value == 1;
    }
    fn video(raw: usize) panel.Error!bool {
        const self = from(raw);
        var value: u32 = 0;
        self.video_native_result = c.r4dcn_link_video_observe(self.storage, 0, self.pipe, &value, &self.last_video);
        try checked(self.video_native_result);
        return value == 1;
    }
    fn now(raw: usize) u64 {
        const io = from(raw).vm.io.?;
        return io.now(io.context);
    }
    fn delay(raw: usize, us: u32) panel.Error!void {
        const io = from(raw).vm.io.?;
        io.delay(io.context, us) catch return error.Timeout;
    }
};
