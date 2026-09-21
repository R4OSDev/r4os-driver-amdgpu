// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Heap-resident panel/ATOM state under the existing SIMD display-task owner.
const std = @import("std");
const bios = @import("bios.zig");
const atom = @import("atom_vm.zig");
pub const panel = @import("panel.zig");
pub const c = panel.c;
pub const Operation = enum(u32) { discover = 1, train = 2, show = 3, brightness = 4, hide = 5 };
pub const Runtime = struct {
    self_address: usize = 0,
    storage: ?*anyopaque = null,
    pipe: u32 = 0,
    vm: atom.Vm = .{},
    scratch: [16384]u32 = @splat(0),
    protocol: ?panel.Panel = null,
    last_atom_error: ?atom.Error = null,
    last_panel_error: ?panel.Error = null,
    brightness: @import("panel_brightness.zig").Bridge = .{},
    pub fn bind(self: *Runtime, storage: *anyopaque, board: *const bios.Board, io: atom.Io, pipe: u32) !void {
        if (self.self_address != 0 or pipe >= 4) return error.State;
        const route = try panel.route(board);
        const declared = if (board.reservation) |r| r.driver_scratch_bytes else 0;
        const scratch_bytes = if (declared == 0) 20 * 1024 else declared;
        if (scratch_bytes > self.scratch.len * 4 or scratch_bytes % 4 != 0) return error.Capacity;
        try self.vm.initialize(board, self.scratch[0..@intCast(scratch_bytes / 4)], io);
        const command = @offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, "dig1transmittercontrol") / 2;
        const revision = try self.vm.revision(command);
        if (!std.mem.eql(u8, &revision, &.{ 1, 6 })) return error.Unsupported;
        self.storage = storage;
        self.pipe = pipe;
        self.self_address = @intFromPtr(self);
        self.protocol = .{ .route = route, .io = .{ .context = self.self_address, .transfer = transfer, .action = action, .enable = enable, .train = train, .status = status, .pwm = pwm, .hpd = hpd, .video = video, .now = now, .delay = delay } };
        const callback: c.struct_r4dcn_atom = .{ .context = self, .execute = execute };
        try checked(c.r4dcn_link_bind(storage, 0, &route.native, &callback));
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
        };
        result catch |err| {
            self.last_panel_error = err;
            return err;
        };
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
        self.vm.execute(@intCast(command), words[0..count]) catch |err| {
            self.last_atom_error = err;
            return -1;
        };
        return 0;
    }
    fn transfer(raw: usize, p: *c.struct_r4dcn_aux) panel.Error!void {
        try checked(c.r4dcn_link_aux(from(raw).storage, 0, p));
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
        var value: u32 = 0;
        try checked(c.r4dcn_link_hpd(from(raw).storage, 0, &value));
        return value == 1;
    }
    fn video(raw: usize) panel.Error!bool {
        const self = from(raw);
        var value: u32 = 0;
        try checked(c.r4dcn_link_video(self.storage, 0, self.pipe, &value));
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
