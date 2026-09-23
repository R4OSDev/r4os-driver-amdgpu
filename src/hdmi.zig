// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Direct HDMI1.4 receiver owner; every usable timing must come from EDID.
const std = @import("std");
const bios = @import("bios.zig");
pub const edid = @import("r4gfx_edid");
pub const c = @import("panel.zig").c;
pub const Error = error{ Invalid, Unsupported, Ambiguous, Io, Timeout, State, Capacity, Disconnected, Changed };
pub const Route = struct { native: c.struct_r4dcn_route, crystal_khz: u32, max_tmds_hz: u64 = 340_000_000 };
pub fn route(board: *const bios.Board) Error!Route {
    var selected: ?bios.Path = null;
    for (board.paths[0..board.path_count]) |path| if (path.connector & 255 == 0x0c) {
        if (selected != null) return error.Ambiguous;
        selected = path;
    };
    const p = selected orelse return error.Unsupported;
    // Only a direct ATOM HDMI-A connector is selected. DP/USB-C/bridges and
    // receiver HDMI2/FRL advertisements never widen this board/source limit.
    if (p.external_encoder != 0 or !p.i2c_hardware or p.i2c_slave != 0 or
        (p.encoder >> 8) & 15 < 1 or (p.encoder >> 8) & 15 > 2) return error.Unsupported;
    const phy: u32 = switch (p.encoder & 255) { 0x1e => 0, 0x20 => 2, else => return error.Unsupported };
    const line = p.aux_ddc_line orelse return error.Unsupported;
    const ddc = p.i2c_pin orelse return error.Unsupported;
    const hpd = p.hpd_pin orelse return error.Unsupported;
    // Match the pinned DCN1 GPIO masks: one byte per physical HPD pin.
    if (line >= 4 or !@import("panel.zig").ddcPinPair(ddc) or hpd.shift % 8 != 0 or hpd.shift / 8 >= 4 or
        hpd.mask_shift != hpd.shift or p.hpd_active > 1) return error.Unsupported;
    const integrated = board.integrated orelse return error.Unsupported;
    if (integrated.external) |external| for (external.paths) |path| {
        if (path.connector != p.connector) continue;
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
    const crystal = board.displayReferenceClock() catch |err| switch (err) {
        error.Missing, error.Revision, error.Short => return error.Unsupported,
        else => return error.Invalid,
    };
    return .{ .native = .{ .connector = p.connector, .encoder = p.encoder, .phy = phy + ((p.encoder >> 8) & 15) - 1,
        .aux = line, .hpd = hpd.shift / 8, .caps = p.encoder_caps orelse 0, .ddc_a = ddc.register,
        .hpd_a = hpd.register, .hpd_shift = hpd.shift, .hpd_active = p.hpd_active }, .crystal_khz = crystal };
}
pub const Io = struct {
    context: usize,
    hpd: *const fn (usize) Error!bool,
    block: *const fn (usize, u32, *[128]u8) Error!void,
    now: *const fn (usize) u64,
    delay: *const fn (usize, u32) Error!void,
};
pub const Receiver = struct {
    bytes: [edid.max_blocks * 128]u8 = undefined,
    length: usize = 0,
    report: edid.Report = .{},
    fingerprint: [32]u8 = @splat(0),
    max_tmds_hz: u64 = 0,
    valid: bool = false,
    pub fn read(self: *Receiver, io: Io, source_limit: u64) Error!void {
        self.valid = false;
        self.length = 0;
        if (source_limit == 0 or source_limit > 340_000_000) return error.Invalid;
        const begin = io.now(io.context);
        try block(io, begin, 0, self.bytes[0..128]);
        const blocks = @as(usize, self.bytes[126]) + 1;
        if (blocks > edid.max_blocks) return error.Capacity;
        for (1..blocks) |index| try block(io, begin, @intCast(index), self.bytes[index * 128 ..][0..128]);
        var verify: [128]u8 = undefined;
        try block(io, begin, 0, &verify);
        if (!std.mem.eql(u8, &verify, self.bytes[0..128])) return error.Changed;
        edid.parse(self.bytes[0 .. blocks * 128], &self.report) catch return error.Invalid;
        if (!self.report.complete() or !self.report.digital or !self.report.hdmi or self.report.colors & 1 == 0) return error.Unsupported;
        // Absent VSDB maximum never implies 340/600MHz receiver support.
        self.max_tmds_hz = @min(source_limit, if (self.report.max_tmds_hz != 0) self.report.max_tmds_hz else 165_000_000);
        self.length = blocks * 128;
        std.crypto.hash.sha2.Sha256.hash(self.bytes[0..self.length], &self.fingerprint, .{});
        self.valid = true;
    }
    fn block(io: Io, begin: u64, index: u32, out: *[128]u8) Error!void {
        for (0..3) |_| {
            const now = io.now(io.context);
            if (now < begin or now - begin >= 2_000_000_000) return error.Timeout;
            if (!try io.hpd(io.context)) return error.Disconnected;
            io.block(io.context, index, out) catch |err| {
                if (err != error.Io and err != error.Timeout) return err;
                try io.delay(io.context, 2000);
                continue;
            };
            if (!try io.hpd(io.context)) return error.Disconnected;
            const end = io.now(io.context);
            if (end < begin or end - begin >= 2_000_000_000) return error.Timeout;
            return;
        }
        return error.Io;
    }
    pub fn admits(self: *const Receiver, mode: edid.timing.Timing) bool {
        if (!self.valid or !mode.valid() or mode.flags & (edid.timing.interlaced | edid.timing.incomplete | edid.timing.y420_only) != 0 or
            mode.clock_hz % 1000 != 0 or mode.clock_hz < 10_000_000 or mode.clock_hz > self.max_tmds_hz or
            mode.width > 4096 or mode.height > 4096 or mode.h_total > 8192 or mode.v_total > 8192 or mode.vic > 127 or
            mode.h_start == mode.width or mode.v_start == mode.height) return false;
        // Range is selected jointly with pixel conversion and AVI in /21.
        for (self.report.modes[0..self.report.mode_count]) |known| {
            if (known.vic == mode.vic and known.sameMode(mode) and known.flags & (edid.timing.y420_only | edid.timing.incomplete | edid.timing.interlaced) == 0) return true;
        }
        return false;
    }
    pub fn preferred(self: *const Receiver) Error!edid.timing.Timing {
        var candidate: ?edid.timing.Timing = null;
        for (self.report.modes[0..self.report.mode_count]) |mode| if (self.admits(mode)) {
            if (mode.flags & edid.timing.preferred != 0) return mode;
            if (candidate == null) candidate = mode;
        };
        return candidate orelse error.Unsupported;
    }
    pub fn avi(self: *const Receiver, mode: edid.timing.Timing) Error![17]u8 {
        if (!self.admits(mode)) return error.Unsupported;
        const colors = @import("display_color.zig");
        return colors.avi(&self.report, mode, colors.defaultSignal(&self.report, mode), self.max_tmds_hz) catch return error.Unsupported;
    }

    /// Copied common metadata for DISPLAYD and the /18 output owner. IDs are
    /// stable within this capture; only admitted complete timings enter it.
    pub fn describe(self: *const Receiver, connector: u32, out: *@import("r4os").abi.GfxReceiverInfo) Error!void {
        const a = @import("r4os").abi;
        if (!self.valid or connector & 255 != 0x0c or connector & 0x7000 != 0x3000) return error.State;
        var record: a.GfxReceiverInfo = .{ .connector_id = connector, .connector_kind = a.gfx_output_kind_hdmi,
            .flags = a.gfx_output_flag_connected, .edid_bytes = @intCast(self.length) };
        @memcpy(record.edid[0..self.length], self.bytes[0..self.length]);
        for (self.report.modes[0..self.report.mode_count]) |mode| {
            if (!self.admits(mode)) continue;
            if (record.mode_count == record.modes.len) { record.flags |= a.gfx_output_flag_receiver_incomplete; break; }
            const id = record.mode_count + 1;
            record.modes[record.mode_count] = .{ .mode_id = id, .flags = mode.flags & 15, .width = mode.width, .height = mode.height,
                .pixel_clock_hz = mode.clock_hz, .h_total = mode.h_total, .h_sync_start = mode.h_start, .h_sync_end = mode.h_end,
                .v_total = mode.v_total, .v_sync_start = mode.v_start, .v_sync_end = mode.v_end, .refresh_millihz = mode.millihz() };
            record.mode_count += 1;
            if (record.preferred_mode_id == 0 and mode.flags & edid.timing.preferred != 0) record.preferred_mode_id = id;
        }
        out.* = record;
    }
};
