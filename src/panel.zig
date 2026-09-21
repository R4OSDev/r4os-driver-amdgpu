// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Bounded SST eDP sequencing. Board facts, receiver facts and confirmed
//! hardware state stay separate. The display task owns every callback.
const std = @import("std");
const bios = @import("bios.zig");
pub const edid = @import("r4gfx_edid");
pub const c = @cImport({
    @cInclude("dcn_api.h");
});
pub const Error = error{ Invalid, Unsupported, Ambiguous, Io, Nack, Timeout, Training, State, Capacity };
pub const Action = enum { init, power_on, power_off, backlight_on, backlight_off, disable };
pub const Path = enum { unavailable, pwm, aux8, aux16 };
pub const Reason = enum { none, no_receiver_control, invalid_pwm, firmware_owner };
pub const Io = struct {
    context: usize,
    transfer: *const fn (usize, *c.struct_r4dcn_aux) Error!void,
    action: *const fn (usize, Action) Error!void,
    enable: *const fn (usize, u8, u8) Error!void,
    train: *const fn (usize, u8, *const [4]u8) Error!void,
    status: *const fn (usize) Error!c.struct_r4dcn_panel_state,
    pwm: *const fn (usize, u32) Error!void,
    hpd: *const fn (usize) Error!bool,
    video: *const fn (usize) Error!bool,
    now: *const fn (usize) u64,
    delay: *const fn (usize, u32) Error!void,
};
pub const Route = struct {
    native: c.struct_r4dcn_route,
    panel: bios.Panel,
    delays_ms: [7]u16,
    minimum: u16,
    maximum: u16,
};
pub fn route(board: *const bios.Board) Error!Route {
    var selected: ?bios.Path = null;
    for (board.paths[0..board.path_count]) |path| if (path.connector & 0xff == 0x14) {
        if (selected != null) return error.Ambiguous;
        selected = path;
    };
    const p = selected orelse return error.Unsupported;
    const panel = board.panel orelse return error.Unsupported;
    const integrated = board.integrated orelse return error.Unsupported;
    if (p.external_encoder != 0 or !p.i2c_hardware or p.i2c_slave != 0 or (p.encoder >> 8) & 15 < 1 or
        (p.encoder >> 8) & 15 > 2 or (panel.bpc != 6 and panel.bpc != 8)) return error.Unsupported;
    const phy: u32 = switch (p.encoder & 255) {
        0x1e => 0,
        0x20 => 2,
        else => return error.Unsupported,
    };
    const aux = p.aux_ddc_line orelse return error.Unsupported;
    const ddc = p.i2c_pin orelse return error.Unsupported;
    const hpd = p.hpd_pin orelse return error.Unsupported;
    // DCN1 HPD1..4 use 4-bit spaced fields. The native boundary also verifies
    // each register against the original DCN1 tables, including the DDC line.
    if (aux >= 4 or ddc.shift != 0 or ddc.mask_shift != 0 or hpd.shift % 4 != 0 or hpd.shift / 4 >= 4 or
        hpd.mask_shift != hpd.shift or p.hpd_active != 1) return error.Unsupported;
    if (integrated.external) |external| for (external.paths) |path| {
        if (path.connector != p.connector) continue;
        // External bridges, PHY permutations and inversion need their own
        // encoder programming. Identity wiring (0xe4) is the selected path.
        if (path.encoder != 0 or path.lane_mapping != 0xe4 or path.lane_invert != 0) return error.Unsupported;
        if (path.aux_ddc_index) |index| {
            const lut = p.aux_ddc_lut orelse return error.Unsupported;
            if (lut[index] != p.i2c_id.?) return error.Invalid;
        }
        if (path.hpd_index) |index| {
            const lut = p.hpd_lut orelse return error.Unsupported;
            if (lut[index] != p.hpd_id.?) return error.Invalid;
        }
    };
    var delays: [7]u16 = undefined;
    for (&delays, panel.delays_ms, integrated.panel_delays_ms) |*d, a, b| d.* = @max(a, b);
    const minimum: u16 = @as(u16, @max(panel.min_bl, integrated.min_backlight)) * 257;
    const maximum: u16 = if (panel.max_bl == 0) 65535 else @as(u16, panel.max_bl) * 257;
    if (minimum > maximum) return error.Invalid;
    return .{ .native = .{ .connector = p.connector, .encoder = p.encoder, .phy = phy + ((p.encoder >> 8) & 15) - 1, .aux = aux, .hpd = hpd.shift / 4, .caps = p.encoder_caps orelse 0, .ddc_a = ddc.register, .hpd_a = hpd.register, .hpd_shift = hpd.shift, .hpd_active = p.hpd_active }, .panel = panel, .delays_ms = delays, .minimum = minimum, .maximum = maximum };
}
pub const Link = struct { rate: u8 = 0, lanes: u8 = 0, enhanced: bool = false, table_index: ?u8 = null };
pub const Phase = enum { empty, bound, discovering, discovered, training, trained, visible, off, retained };
pub const Panel = struct {
    io: Io,
    route: Route,
    phase: Phase = .bound,
    effects: bool = false,
    receiver: [16]u8 = @splat(0),
    edp_caps: [5]u8 = @splat(0),
    rate_table: [16]u8 = @splat(0),
    edid_bytes: [edid.max_blocks * 128]u8 = undefined,
    edid_length: usize = 0,
    report: edid.Report = .{},
    mode: edid.timing.Timing = .{},
    bpc: u8 = 0,
    link: Link = .{},
    lane_settings: [4]u8 = @splat(0),
    brightness_path: Path = .unavailable,
    brightness_reason: Reason = .no_receiver_control,
    brightness: u16 = 0,
    brightness_known: bool = false,
    aux_maximum: u16 = 0,
    powered: bool = false,
    lit: bool = false,
    off_at: ?u64 = null,
    fn wait(self: *Panel, us: u32) Error!void {
        try self.io.delay(self.io.context, us);
    }
    fn act(self: *Panel, action: Action) Error!void {
        self.effects = true;
        try self.io.action(self.io.context, action);
    }
    fn elapsed(self: *const Panel, begin: u64, limit: u64) Error!void {
        const now = self.io.now(self.io.context);
        if (now < begin or now - begin >= limit) return error.Timeout;
    }
    fn transfer(self: *Panel, address: u32, flags: u32, bytes: []u8) Error!void {
        if (bytes.len > 16) return error.Invalid;
        var packet: c.struct_r4dcn_aux = std.mem.zeroes(c.struct_r4dcn_aux);
        packet.address = address;
        packet.length = @intCast(bytes.len);
        packet.flags = flags;
        @memcpy(packet.data[0..bytes.len], bytes);
        const begin = self.io.now(self.io.context);
        var attempts: u32 = 0;
        var timeouts: u32 = 0;
        while (attempts < 32) : (attempts += 1) {
            try self.elapsed(begin, 60_000_000);
            self.effects = true; // Native AUX writes its FIFO/arbitration even for reads.
            self.io.transfer(self.io.context, &packet) catch |err| {
                if (err != error.Timeout or timeouts == 2) return err;
                timeouts += 1;
                try self.wait(400);
                continue;
            };
            switch (packet.reply) {
                0 => {
                    if (packet.flags & 8 != 0) {
                        if (packet.transferred == 0) return;
                    } else if (flags & 1 != 0) {
                        if (packet.transferred != bytes.len) return error.Io;
                        @memcpy(bytes, packet.data[0..bytes.len]);
                        return;
                    } else if (packet.transferred == 0) return else if (flags & 2 != 0) {
                        packet.flags = (flags | 1 | 8);
                        packet.length = 0;
                    } else return error.Io;
                },
                2 => {}, // native AUX defer
                8 => {
                    if (flags & 2 == 0) return error.Io;
                    if (flags & 1 == 0) {
                        packet.flags = flags | 1 | 8;
                        packet.length = 0;
                    }
                },
                1, 4 => return error.Nack,
                else => return error.Io,
            }
            try self.wait(400);
        }
        return error.Timeout;
    }
    pub fn read(self: *Panel, address: u32, out: []u8) Error!void {
        if (address > 0xfffff or out.len > 0x100000 - address) return error.Invalid;
        var offset: usize = 0;
        while (offset < out.len) {
            const n = @min(16, out.len - offset);
            try self.transfer(address + @as(u32, @intCast(offset)), 1, out[offset..][0..n]);
            offset += n;
        }
    }
    pub fn write(self: *Panel, address: u32, data: []const u8) Error!void {
        if (address > 0xfffff or data.len > 0x100000 - address) return error.Invalid;
        var offset: usize = 0;
        while (offset < data.len) {
            const n = @min(16, data.len - offset);
            var bytes: [16]u8 = undefined;
            @memcpy(bytes[0..n], data[offset..][0..n]);
            try self.transfer(address + @as(u32, @intCast(offset)), 0, bytes[0..n]);
            offset += n;
        }
    }
    fn readByte(self: *Panel, address: u32) Error!u8 {
        var b: [1]u8 = undefined;
        try self.read(address, &b);
        return b[0];
    }
    fn receiverPower(self: *Panel, on: bool) Error!void {
        if (self.receiver[0] < 0x11) return;
        const old = try self.readByte(0x600);
        try self.write(0x600, &.{(old & ~@as(u8, 7)) | @as(u8, if (on) 1 else 2)});
        if (on) try self.wait(1000);
    }
    fn readEdid(self: *Panel) Error!void {
        var blocks: usize = 1;
        for (0..edid.max_blocks) |block| {
            if (block >= blocks) break;
            // Every block is a bounded E-DDC transaction; STOP is attempted
            // on errors too, and a failed STOP is not reported as success.
            var segment = [_]u8{@intCast(block / 2)};
            if (block >= 2) try self.transfer(0x30, 2 | 4, &segment);
            errdefer self.transfer(0x50, 2, &.{}) catch {};
            var start = [_]u8{@intCast((block % 2) * 128)};
            try self.transfer(0x50, 2 | 4, &start);
            for (0..8) |chunk| try self.transfer(0x50, 1 | 2 | (if (chunk == 7) @as(u32, 0) else 4), self.edid_bytes[block * 128 + chunk * 16 ..][0..16]);
            if (block == 0) {
                blocks = @as(usize, self.edid_bytes[126]) + 1;
                if (blocks > edid.max_blocks) return error.Capacity;
            }
        }
        self.edid_length = blocks * 128;
        edid.parse(self.edid_bytes[0..self.edid_length], &self.report) catch return error.Invalid;
        if (!self.report.complete() or !self.report.digital) return error.Invalid;
        var selected: ?edid.timing.Timing = null;
        for (self.report.modes[0..self.report.mode_count]) |mode| {
            if (mode.flags & (edid.timing.interlaced | edid.timing.incomplete | edid.timing.y420_only) != 0 or
                mode.width != self.route.panel.width or mode.height != self.route.panel.height) continue;
            if (selected == null or mode.flags & edid.timing.preferred != 0) selected = mode;
            if (mode.flags & edid.timing.preferred != 0) break;
        }
        self.mode = selected orelse return error.Unsupported;
        self.bpc = self.route.panel.bpc;
        if (self.report.bits_per_color != 0 and self.report.bits_per_color < self.bpc) self.bpc = self.report.bits_per_color;
        if (self.bpc != 6 and self.bpc != 8) return error.Unsupported;
    }
    pub fn discover(self: *Panel) Error!void {
        if (self.phase != .bound and self.phase != .off) return error.State;
        self.phase = .discovering;
        errdefer self.phase = .retained;
        const initial = try self.io.status(self.io.context);
        self.powered = initial.powered != 0;
        self.lit = initial.lit != 0;
        if (self.lit) {
            try self.act(.backlight_off);
            self.lit = false;
            try self.wait(@as(u32, self.route.delays_ms[6]) * 1000);
        }
        try self.act(.init);
        if (!self.powered) {
            const minimum = @as(u64, @max(500, self.route.delays_ms[4])) * 1_000_000;
            const now = self.io.now(self.io.context);
            const elapsed_ns = if (self.off_at) |off| if (now >= off) now - off else return error.Timeout else 0;
            if (elapsed_ns < minimum) try self.wait(@intCast((minimum - elapsed_ns + 999) / 1000));
            try self.act(.power_on);
            self.powered = true;
            try self.wait(@as(u32, self.route.delays_ms[0]) * 1000);
        }
        const begin = self.io.now(self.io.context);
        var present = false;
        for (0..1000) |_| {
            try self.elapsed(begin, 1_000_000_000);
            if (try self.io.hpd(self.io.context)) {
                present = true;
                break;
            }
            try self.wait(1000);
        }
        if (!present) return error.Timeout;
        try self.read(0, &self.receiver);
        if (self.receiver[14] & 0x80 != 0) try self.read(0x2200, &self.receiver);
        if (self.receiver[0] < 0x11 or self.receiver[0] > 0x14 or self.receiver[14] & 0x7f > 4 or
            (self.receiver[2] & 31 != 1 and self.receiver[2] & 31 != 2 and self.receiver[2] & 31 != 4)) return error.Unsupported;
        try self.receiverPower(true);
        // Explicit standard scrambling on both endpoints, no implicit PSR or
        // ASSR policy. Optimized eDP power states follow their later owner.
        if (self.receiver[13] & 1 != 0) {
            const old = try self.readByte(0x10a);
            try self.write(0x10a, &.{old & ~@as(u8, 1)});
        }
        if (self.receiver[1] == 0) try self.read(0x10, &self.rate_table);
        try self.readEdid();
        const current = try self.io.status(self.io.context);
        if (current.powered == 0) return error.Io;
        try self.selectBrightness(current);
        self.phase = .discovered;
    }
    fn selectBrightness(self: *Panel, initial: c.struct_r4dcn_panel_state) Error!void {
        self.brightness_path = .unavailable;
        self.brightness_reason = .no_receiver_control;
        if (self.receiver[13] & 8 != 0) {
            try self.read(0x700, &self.edp_caps);
            if (self.edp_caps[0] <= 5 and self.edp_caps[1] & 1 != 0 and self.edp_caps[2] & 2 != 0) {
                self.brightness_path = if (self.edp_caps[2] & 4 != 0) .aux16 else .aux8;
                const bits = if (self.brightness_path == .aux16) (try self.readByte(0x724)) & 31 else 8;
                const width: u5 = if (self.brightness_path == .aux8) 8 else if (bits > 0 and bits <= 16) @intCast(bits) else return error.Unsupported;
                self.aux_maximum = @intCast((@as(u32, 1) << width) - 1);
                var level: [2]u8 = @splat(0);
                try self.read(0x722, level[0..if (self.brightness_path == .aux16) @as(usize, 2) else 1]);
                const raw: u32 = if (self.brightness_path == .aux16) (@as(u32, level[0]) << 8) | level[1] else level[0];
                if (raw > self.aux_maximum) return error.Invalid;
                self.brightness = @intCast(raw * 65535 / self.aux_maximum);
                self.brightness_reason = .none;
                self.brightness_known = true;
                return;
            }
        }
        if (initial.firmware_busy != 0) {
            self.brightness_reason = .firmware_owner;
            return;
        }
        if (initial.pwm_valid == 0) {
            self.brightness_reason = .invalid_pwm;
            return;
        }
        self.brightness_path = .pwm;
        self.brightness_reason = .none;
        self.brightness = @intCast((@as(u64, initial.pwm) * 65535 + 32768) / 65536);
        self.brightness_known = true;
    }
    fn eligible(self: *const Panel, rate: u8, lanes: u8) ?Link {
        if (lanes > self.receiver[2] & 31 or (rate >= 20 and self.route.native.caps & 2 == 0) or
            (rate == 30 and (self.route.native.caps & 8 == 0 or self.receiver[3] & 0x80 == 0))) return null;
        // 8b/10b payload; reserve 0.5% for transport overhead.
        const payload = @as(u64, rate) * 27_000_000 * lanes * 8;
        if (self.mode.clock_hz * self.bpc * 3 * 1000 > payload * 995) return null;
        var link: Link = .{ .rate = rate, .lanes = lanes, .enhanced = self.receiver[2] & 0x80 != 0 };
        if (self.receiver[1] == 0) {
            for (0..8) |i| {
                const khz = @as(u32, std.mem.readInt(u16, self.rate_table[i * 2 ..][0..2], .little)) * 200;
                if (khz == @as(u32, rate) * 27000) {
                    link.table_index = @intCast(i);
                    return link;
                }
            }
            return null;
        }
        return if (rate <= self.receiver[1]) link else null;
    }
    fn pattern(self: *Panel, value: u8) Error!void {
        self.effects = true;
        try self.io.train(self.io.context, value, &self.lane_settings);
        var bytes: [5]u8 = undefined;
        bytes[0] = if (value == 4) 7 else value | (if (value == 0) @as(u8, 0) else 0x20);
        @memcpy(bytes[1..], &self.lane_settings);
        try self.write(0x102, bytes[0 .. 1 + self.link.lanes]);
    }
    fn linkStatus(self: *Panel, eq: bool) Error![6]u8 {
        const interval = self.receiver[14] & 0x7f;
        try self.wait(if (interval != 0 and (eq or self.receiver[0] < 0x14)) @as(u32, interval) * 4000 else if (eq) 400 else 100);
        var status: [6]u8 = undefined;
        try self.read(0x202, &status);
        return status;
    }
    fn lanesOk(self: *const Panel, status: [6]u8, bits: u8) bool {
        for (0..self.link.lanes) |i| if ((status[i / 2] >> @as(u3, @intCast((i % 2) * 4))) & bits != bits) return false;
        return true;
    }
    fn adjust(self: *Panel, status: [6]u8) void {
        // DCN1 sets a common drive level across active lanes. Saturation and
        // max flags describe the actual source limits (VS+PE <= 3).
        var swing: u8 = 0;
        var pre: u8 = 0;
        for (0..self.link.lanes) |i| {
            const n = status[4 + i / 2] >> @as(u3, @intCast((i % 2) * 4));
            swing = @max(swing, n & 3);
            pre = @max(pre, (n >> 2) & 3);
        }
        pre = @min(pre, 3 - swing);
        const level = swing | (pre << 3) | (if (swing == 3) @as(u8, 4) else 0) | (if (pre == 3 - swing) @as(u8, 32) else 0);
        self.lane_settings = @splat(level);
    }
    fn attempt(self: *Panel, link: Link) Error!void {
        self.link = link;
        self.lane_settings = @splat(0);
        self.effects = true;
        try self.io.enable(self.io.context, link.rate, link.lanes);
        try self.write(0x100, &.{ if (link.table_index == null) link.rate else 0, link.lanes | (if (link.enhanced) @as(u8, 0x80) else 0) });
        if (link.table_index) |index| try self.write(0x115, &.{index});
        try self.write(0x107, &.{ 0, 1 }); // no downspread; ANSI 8b/10b coding
        try self.pattern(1);
        var recovered = false;
        var repeated: u32 = 0;
        for (0..20) |_| {
            const status = try self.linkStatus(false);
            if (self.lanesOk(status, 1)) {
                recovered = true;
                break;
            }
            if (self.lane_settings[0] & 4 != 0) return error.Training;
            const previous = self.lane_settings[0] & 3;
            self.adjust(status);
            repeated = if (previous == self.lane_settings[0] & 3) repeated + 1 else 0;
            if (repeated >= 5) return error.Training;
            try self.pattern(1);
        }
        if (!recovered) return error.Training;
        const training: u8 = if (link.rate == 30) 4 else if (link.rate == 20 and self.receiver[2] & 0x40 != 0) 3 else 2;
        try self.pattern(training);
        for (0..6) |_| {
            const status = try self.linkStatus(true);
            if (!self.lanesOk(status, 1)) return error.Training;
            if (self.lanesOk(status, 7) and status[2] & 1 != 0) {
                try self.pattern(0);
                return;
            }
            self.adjust(status);
            try self.pattern(training);
        }
        return error.Training;
    }
    pub fn train(self: *Panel) Error!void {
        if (self.phase != .discovered) return error.State;
        self.phase = .training;
        errdefer self.phase = .retained;
        const begin = self.io.now(self.io.context);
        for ([_]u8{ 4, 2, 1 }) |lanes| for ([_]u8{ 30, 20, 10, 6 }) |rate| {
            const link = self.eligible(rate, lanes) orelse continue;
            try self.elapsed(begin, 5_000_000_000);
            self.attempt(link) catch |err| {
                // Disable the receiver's training pattern before PHY teardown.
                try self.write(0x102, &.{0});
                try self.act(.disable);
                if (err != error.Training) return err;
                continue;
            };
            self.phase = .trained;
            return;
        };
        return error.Training;
    }
    pub fn setBrightness(self: *Panel, value: u16) Error!void {
        if (self.phase != .visible and self.phase != .trained) return error.State;
        if (self.brightness_path == .unavailable) return error.Unsupported;
        if (value < self.route.minimum or value > self.route.maximum) return error.Invalid;
        errdefer self.phase = .retained;
        self.effects = true;
        self.brightness_known = false;
        var confirmed: u16 = undefined;
        switch (self.brightness_path) {
            .pwm => {
                try self.io.pwm(self.io.context, (@as(u32, value) * 65536 + 32767) / 65535);
                const current = try self.io.status(self.io.context);
                if (current.pwm_valid == 0 or current.firmware_busy != 0 or current.pwm > 65536) return error.Io;
                confirmed = @intCast((@as(u64, current.pwm) * 65535 + 32768) / 65536);
            },
            .aux8, .aux16 => {
                const old = try self.readByte(0x721);
                // Preserve frequency/other controls, select DPCD brightness.
                try self.write(0x721, &.{(old & ~@as(u8, 3)) | 2});
                const raw = (@as(u32, value) * self.aux_maximum + 32767) / 65535;
                if (self.brightness_path == .aux16) try self.write(0x722, &.{ @intCast(raw >> 8), @truncate(raw) }) else try self.write(0x722, &.{@intCast(raw)});
                var readback: [2]u8 = .{ 0, 0 };
                try self.read(0x722, readback[0..if (self.brightness_path == .aux16) @as(usize, 2) else 1]);
                const actual: u32 = if (self.brightness_path == .aux16) (@as(u32, readback[0]) << 8) | readback[1] else readback[0];
                if (actual != raw or (try self.readByte(0x721)) & 3 != 2) return error.Io;
                confirmed = @intCast((actual * 65535 + self.aux_maximum / 2) / self.aux_maximum);
            },
            .unavailable => unreachable,
        }
        self.brightness = confirmed;
        self.brightness_known = true;
    }
    pub fn show(self: *Panel, value: u16) Error!void {
        if (self.phase != .trained or !try self.io.video(self.io.context)) return error.State;
        errdefer self.phase = .retained;
        try self.wait(@as(u32, self.route.delays_ms[1]) * 1000);
        if (self.brightness_path != .unavailable) try self.setBrightness(value);
        try self.wait(@as(u32, self.route.delays_ms[5]) * 1000);
        try self.act(.backlight_on);
        if ((self.brightness_path == .aux8 or self.brightness_path == .aux16) and self.edp_caps[1] & 4 != 0) {
            const old = try self.readByte(0x720);
            try self.write(0x720, &.{old | 1});
        }
        self.lit = true;
        self.phase = .visible;
    }
    pub fn hide(self: *Panel) Error!void {
        if (self.phase == .off or self.phase == .bound) return;
        errdefer self.phase = .retained;
        if ((self.brightness_path == .aux8 or self.brightness_path == .aux16) and self.edp_caps[1] & 4 != 0) {
            const old = try self.readByte(0x720);
            try self.write(0x720, &.{old & ~@as(u8, 1)});
        }
        try self.act(.backlight_off);
        self.lit = false;
        try self.wait(@as(u32, self.route.delays_ms[6]) * 1000);
        try self.wait(@as(u32, self.route.delays_ms[2]) * 1000);
        // The modeset owner must have disabled video before cutting link power.
        if (try self.io.video(self.io.context)) return error.State;
        try self.receiverPower(false);
        try self.act(.disable);
        try self.wait(@as(u32, self.route.delays_ms[3]) * 1000);
        try self.act(.power_off);
        if ((try self.io.status(self.io.context)).powered != 0) return error.Io;
        self.powered = false;
        self.off_at = self.io.now(self.io.context);
        self.phase = .off;
    }
};
