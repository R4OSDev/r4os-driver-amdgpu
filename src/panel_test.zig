// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
// Synthetic MMIO/receiver fixtures. No laptop, panel or electrical evidence.
const std = @import("std");
const t = std.testing;
const p = @import("panel.zig");
const c = p.c;
const b = @import("bios.zig");
const fixture = @import("bios_fixture.zig");
const hw = @cImport({
    @cInclude("display_test_wire.h");
});
fn reg(comptime name: []const u8) u32 {
    return hw.DCE_BASE__INST0_SEG2 + @field(hw, "mm" ++ name);
}
const Native = struct {
    var bytes: [5 * 1024 * 1024]u8 align(16) = undefined;
    var words: [@import("memory_registers.zig").required_prefix / 4]u32 = undefined;
    var ticks: u64 = 0;
    var writes: usize = 0;
    var count: usize = 0;
    var commands: [32][8]u32 = undefined;
    var fifo: [32]u8 = undefined;
    var fifo_count: usize = 0;
    var sent: [32]u8 = undefined;
    var sent_count: usize = 0;
    var reply: [17]u8 = undefined;
    var reply_count: u32 = 0;
    var reply_at: usize = 0;
    var timeout = false;
    var fail_write: usize = 0;
    fn read(_: ?*anyopaque, offset: u32, out: [*c]u32) callconv(.c) c_int {
        if (offset % 4 != 0 or offset / 4 >= words.len) return -1;
        const index = offset / 4;
        out.* = words[index];
        if (index == reg("DP_AUX0_AUX_SW_DATA") and words[index] & hw.DP_AUX0_AUX_SW_DATA__AUX_SW_DATA_RW_MASK != 0) {
            const value: u32 = if (reply_at < reply_count) reply[reply_at] else 0;
            reply_at += 1;
            out.* = (out.* & ~@as(u32, hw.DP_AUX0_AUX_SW_DATA__AUX_SW_DATA_MASK)) | (value << hw.DP_AUX0_AUX_SW_DATA__AUX_SW_DATA__SHIFT);
        }
        return 0;
    }
    fn write(_: ?*anyopaque, offset: u32, value: u32) callconv(.c) c_int {
        if (offset % 4 != 0 or offset / 4 >= words.len) return -1;
        writes += 1;
        if (fail_write != 0 and writes == fail_write) return -1;
        const index = offset / 4;
        words[index] = value;
        if (index == reg("DP_AUX0_AUX_ARB_CONTROL")) {
            words[index] &= ~@as(u32, hw.DP_AUX0_AUX_ARB_CONTROL__AUX_REG_RW_CNTL_STATUS_MASK);
            if (value & hw.DP_AUX0_AUX_ARB_CONTROL__AUX_SW_USE_AUX_REG_REQ_MASK != 0) words[index] |= 1 << hw.DP_AUX0_AUX_ARB_CONTROL__AUX_REG_RW_CNTL_STATUS__SHIFT;
        }
        if (index == reg("DP_AUX0_AUX_INTERRUPT_CONTROL") and value & hw.DP_AUX0_AUX_INTERRUPT_CONTROL__AUX_SW_DONE_ACK_MASK != 0) words[reg("DP_AUX0_AUX_SW_STATUS")] = 0;
        if (index == reg("DP_AUX0_AUX_SW_DATA")) {
            if (value & hw.DP_AUX0_AUX_SW_DATA__AUX_SW_DATA_RW_MASK != 0) reply_at = 0 else {
                if (value & hw.DP_AUX0_AUX_SW_DATA__AUX_SW_AUTOINCREMENT_DISABLE_MASK != 0) fifo_count = 0;
                if (fifo_count < fifo.len) {
                    fifo[fifo_count] = @truncate(value >> hw.DP_AUX0_AUX_SW_DATA__AUX_SW_DATA__SHIFT);
                    fifo_count += 1;
                }
            }
        }
        if (index == reg("DP_AUX0_AUX_SW_CONTROL") and value & hw.DP_AUX0_AUX_SW_CONTROL__AUX_SW_GO_MASK != 0) {
            @memcpy(&sent, &fifo); sent_count = fifo_count;
            words[index] &= ~@as(u32, hw.DP_AUX0_AUX_SW_CONTROL__AUX_SW_GO_MASK);
            if (!timeout) words[reg("DP_AUX0_AUX_SW_STATUS")] = @as(u32, hw.DP_AUX0_AUX_SW_STATUS__AUX_SW_DONE_MASK) | (reply_count << hw.DP_AUX0_AUX_SW_STATUS__AUX_SW_REPLY_BYTE_COUNT__SHIFT);
        }
        return 0;
    }
    fn now(_: ?*anyopaque) callconv(.c) u64 {
        ticks += 1000;
        return ticks;
    }
    fn delay(_: ?*anyopaque, us: u32) callconv(.c) c_int {
        ticks += @as(u64, us) * 1000;
        return 0;
    }
    fn worker(_: ?*anyopaque) callconv(.c) c_int {
        return 1;
    }
    fn log(_: ?*anyopaque, _: [*c]const u8) callconv(.c) void {}
    fn fatal(_: ?*anyopaque, e: [*c]const u8, f: [*c]const u8, l: c_uint) callconv(.c) void {
        std.debug.panic("{s}:{d}: {s}", .{ std.mem.span(f), l, std.mem.span(e) });
    }
    fn atom(_: ?*anyopaque, command: u32, parameters: [*c]u32, n: u32) callconv(.c) c_int {
        std.debug.assert(command == @offsetOf(b.c.struct_atom_master_list_of_command_functions_v2_1, "dig1transmittercontrol") / 2 and n == 8 and count < commands.len);
        @memcpy(&commands[count], parameters[0..8]);
        count += 1;
        return 0;
    }
    const io: c.struct_r4dcn_io = .{ .context = null, .read = read, .write = write, .now_ns = now, .delay_us = delay, .worker = worker, .log = log, .fatal = fatal };
    const atom_io: c.struct_r4dcn_atom = .{ .context = null, .execute = atom };
    fn init() !void {
        @memset(&words, 0);
        ticks = 0;
        writes = 0;
        count = 0;
        fifo_count = 0;
        timeout = false;
        fail_write = 0;
        @memset(&reply, 0);
        reply_count = 1;
        reply_at = 0;
        const limits: c.struct_r4dcn_limits = .{ .channels = 2, .dcf_khz = 600000, .disp_khz = 960000, .dpp_khz = 626000, .fabric_khz = 1066666, .soc_khz = 626000, .ref_khz = 48000, .gb_addr_config = 0x24000042, .reserved = 0, .pipe_count = 4 };
        try t.expectEqual(@as(c_int, 0), c.r4dcn_init(&bytes, c.r4dcn_size(), &io, &limits));
    }
    const route: c.struct_r4dcn_route = .{ .connector = 0x3114, .encoder = 0x211e, .phy = 0, .aux = 0, .hpd = 0, .caps = 0xa, .ddc_a = reg("DC_GPIO_DDC1_A"), .hpd_a = reg("DC_GPIO_HPD_A"), .hpd_shift = 0, .hpd_active = 1 };
};
test "DCN1 native link AUX and PWM use original registers and release an ordinary bus timeout" {
    const n = Native;
    try n.init();
    var invalid = n.route;
    invalid.ddc_a += 1;
    try t.expectEqual(@as(c_int, c.R4DCN_INVALID), c.r4dcn_link_bind(&n.bytes, 0, &invalid, &n.atom_io));
    try t.expectEqual(@as(usize, 0), n.writes);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_link_bind(&n.bytes, 0, &n.route, &n.atom_io));
    n.words[reg("DC_GPIO_DDC1_MASK")] = 0x101;
    n.words[reg("DC_GPIO_HPD_MASK")] = 1;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_link_action(&n.bytes, 0, c.R4DCN_LINK_INIT));
    try t.expectEqual(@as(u32, 0x04000700), n.commands[0][0]);
    try t.expectEqual(@as(u32, 0x00140001), n.commands[0][2]);
    try t.expectEqual(@as(u32, 0x10000), n.words[reg("DC_GPIO_DDC1_MASK")]);
    try t.expectEqual(@as(u32, 0), n.words[reg("DC_GPIO_HPD_MASK")]);
    n.reply_count = 4;
    n.reply[1..4].* = .{ 0x14, 0x14, 0xc4 };
    var packet: c.struct_r4dcn_aux = std.mem.zeroes(c.struct_r4dcn_aux);
    packet.address = 0xabc;
    packet.length = 3;
    packet.flags = 1;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_link_aux(&n.bytes, 0, &packet));
    try t.expectEqualSlices(u8, &.{ 0x90, 0x0a, 0xbc, 2 }, n.sent[0..n.sent_count]);
    try t.expectEqualSlices(u8, &.{ 0x14, 0x14, 0xc4 }, packet.data[0..3]);
    try t.expect(packet.reply == 0 and packet.transferred == 3);
    n.timeout = true;
    try t.expectEqual(@as(c_int, c.R4DCN_TIMEOUT), c.r4dcn_link_aux(&n.bytes, 0, &packet));
    try t.expectEqual(@as(c_int, 0), c.r4dcn_fault(&n.bytes));
    try t.expectEqual(@as(u32, 0), n.words[reg("DP_AUX0_AUX_ARB_CONTROL")] & hw.DP_AUX0_AUX_ARB_CONTROL__AUX_SW_USE_AUX_REG_REQ_MASK);
    n.timeout = false;
    n.reply_count = 1;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_link_enable(&n.bytes, 0, 20, 4, 0));
    try t.expectEqual(@as(u32, 54000), n.commands[1][1]);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_link_train(&n.bytes, 0, 1, &[_]u8{ 0, 0, 0, 0 }));
    try t.expectEqual(@as(usize, 6), n.count);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_link_train(&n.bytes, 0, 0, &[_]u8{ 0, 0, 0, 0 }));
    n.words[reg("BL_PWM_PERIOD_CNTL")] = (12 << hw.BL_PWM_PERIOD_CNTL__BL_PWM_PERIOD_BITCNT__SHIFT) | 4000;
    n.words[reg("BL_PWM_CNTL")] = hw.BL_PWM_CNTL__BL_PWM_EN_MASK | 64000;
    var state: c.struct_r4dcn_panel_state = undefined;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_panel_read(&n.bytes, &state));
    try t.expect(state.pwm_valid == 1 and state.firmware_busy == 1 and state.pwm == 65536);
    var before = n.writes;
    try t.expectEqual(@as(c_int, c.R4DCN_UNSUPPORTED), c.r4dcn_panel_pwm(&n.bytes, 32768));
    try t.expectEqual(before, n.writes);
    n.words[reg("DMCU_STATUS")] = 1;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_panel_pwm(&n.bytes, 32768));
    try t.expectEqual(@as(u32, 32000), n.words[reg("BL_PWM_CNTL")] & hw.BL_PWM_CNTL__BL_ACTIVE_INT_FRAC_CNT_MASK);
    n.words[reg("BL_PWM_PERIOD_CNTL")] = 17 << hw.BL_PWM_PERIOD_CNTL__BL_PWM_PERIOD_BITCNT__SHIFT;
    before = n.writes;
    try t.expectEqual(@as(c_int, c.R4DCN_UNSUPPORTED), c.r4dcn_panel_pwm(&n.bytes, 32768));
    try t.expectEqual(before, n.writes);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_link_action(&n.bytes, 0, c.R4DCN_LINK_DISABLE));
    try t.expectEqual(@as(c_int, 0), c.r4dcn_link_restore_pads(&n.bytes, 0));
    try t.expectEqual(@as(u32, 0x101), n.words[reg("DC_GPIO_DDC1_MASK")]);
    try t.expectEqual(@as(u32, 1), n.words[reg("DC_GPIO_HPD_MASK")]);
    try AtomNative.check();
    std.debug.print("[amd-panel-native] original AUX/link/PWM; exact FIFO, ATOM parameters, timeout arbitration, invalid PWM and firmware-owner rejection\n", .{});
}
const Receiver = struct {
    var rom: [4096]u8 = undefined;
    var board: b.Board = undefined;
    var panel: p.Panel = undefined;
    var data: [0x800]u8 = undefined;
    var edid: [128]u8 = undefined;
    var ticks: u64 = 0;
    var pointer: usize = 0;
    var rate: u8 = 0;
    var pattern: u8 = 0;
    var powered = false;
    var lit = false;
    var video = false;
    var fail_rate20 = false;
    var defer_all = false;
    var fail_brightness = false;
    var ignore_brightness = false;
    var writes: usize = 0;
    var attempts: usize = 0;
    var light_on_at: u64 = 0;
    var power_on_at: u64 = 0;
    var stop_count: usize = 0;
    var pwm_value: u32 = 0;
    var firmware_busy: u32 = 0;
    var pwm_valid: u32 = 1;
    fn now(_: usize) u64 {
        return ticks;
    }
    fn delay(_: usize, us: u32) p.Error!void {
        ticks += @as(u64, us) * 1000;
    }
    fn action(_: usize, a: p.Action) p.Error!void {
        switch (a) {
            .init => {},
            .power_on => {
                powered = true;
                power_on_at = ticks;
            },
            .power_off => powered = false,
            .backlight_on => {
                if (!video or !powered) return error.State;
                lit = true;
                light_on_at = ticks;
            },
            .backlight_off => lit = false,
            .disable => {
                rate = 0;
                pattern = 0;
            },
        }
    }
    fn enable(_: usize, r: u8, l: u8) p.Error!void {
        if (!powered or l != 4) return error.State;
        rate = r;
    }
    fn train(_: usize, value: u8, levels: *const [4]u8) p.Error!void {
        pattern = value;
        for (levels) |level| if ((level & 3) + ((level >> 3) & 3) > 3) return error.Invalid;
    }
    fn status(_: usize) p.Error!c.struct_r4dcn_panel_state {
        return .{ .powered = @intFromBool(powered), .lit = @intFromBool(lit), .pwm_valid = pwm_valid, .firmware_busy = firmware_busy, .pwm = pwm_value, .period = 4000 };
    }
    fn pwm(_: usize, value: u32) p.Error!void {
        if (firmware_busy != 0 or pwm_valid == 0) return error.Unsupported;
        pwm_value = value;
    }
    fn hpd(_: usize) p.Error!bool {
        return powered;
    }
    fn playing(_: usize) p.Error!bool {
        return video;
    }
    fn transfer(_: usize, packet: *c.struct_r4dcn_aux) p.Error!void {
        attempts += 1;
        packet.transferred = 0;
        packet.reply = 0;
        if (defer_all) {
            packet.reply = 2;
            return;
        }
        if (packet.flags & 2 != 0) {
            if (packet.address != 0x50) return error.Nack;
            if (packet.flags & 1 != 0) {
                if (pointer + packet.length > edid.len) return error.Io;
                @memcpy(packet.data[0..packet.length], edid[pointer..][0..packet.length]);
                pointer += packet.length;
                packet.transferred = packet.length;
            } else if (packet.length == 1) pointer = packet.data[0];
            if (packet.flags & 4 == 0) stop_count += 1;
            return;
        }
        if (packet.address + packet.length > data.len) return error.Invalid;
        if (packet.flags & 1 != 0) {
            if (packet.address == 0x202) {
                const good = !(fail_rate20 and rate == 20);
                packet.data[0..6].* = if (!good) .{ 0, 0, 0, 0, 0, 0 } else if (pattern == 1) .{ 0x11, 0x11, 0, 0, 0, 0 } else .{ 0x77, 0x77, 1, 0, 0, 0 };
            } else @memcpy(packet.data[0..packet.length], data[packet.address..][0..packet.length]);
            packet.transferred = packet.length;
        } else {
            writes += 1;
            if (fail_brightness and packet.address == 0x722) return error.Io;
            if (ignore_brightness and packet.address == 0x722) return;
            @memcpy(data[packet.address..][0..packet.length], packet.data[0..packet.length]);
        }
    }
    fn reset(aux: bool) !void {
        fixture.rom(&rom);
        try b.parse(&rom, fixture.device, &board);
        board.paths[0].encoder_caps = 0xa;
        board.paths[0].i2c_pin.?.shift = 0;
        board.paths[0].hpd_pin.?.shift = 8; board.paths[0].hpd_pin.?.mask_shift = 8;
        ticks = 0;
        pointer = 0;
        rate = 0;
        pattern = 0;
        powered = false;
        lit = false;
        video = false;
        fail_rate20 = false;
        defer_all = false;
        fail_brightness = false;
        ignore_brightness = false;
        writes = 0;
        attempts = 0;
        light_on_at = 0;
        power_on_at = 0;
        stop_count = 0;
        pwm_value = 32768;
        firmware_busy = 0;
        pwm_valid = 1;
        @memset(&data, 0);
        data[0..16].* = .{ 0x14, 20, 0xc4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, if (aux) 8 else 0, 0, 0 };
        data[0x700..0x705].* = .{ 3, 5, 6, 0, 0 };
        data[0x724] = 16;
        data[0x722] = 0x80;
        @memset(&edid, 0);
        edid[0..8].* = .{ 0, 255, 255, 255, 255, 255, 255, 0 };
        edid[8] = 4;
        edid[9] = 0x43;
        edid[18] = 1;
        edid[19] = 4;
        edid[20] = 0xa5;
        edid[24] = 2;
        @memset(edid[38..54], 1);
        edid[54..72].* = .{ 2, 0x3a, 0x80, 0x18, 0x71, 0x38, 0x2d, 0x40, 0x58, 0x2c, 0x45, 0, 0, 0, 0, 0, 0, 0x1e };
        fixture.checksum(&edid, 127);
        const route = try p.route(&board);
        panel = .{ .route = route, .io = .{ .context = 0, .transfer = transfer, .action = action, .enable = enable, .train = train, .status = status, .pwm = pwm, .hpd = hpd, .video = playing, .now = now, .delay = delay } };
    }
};
test "eDP discovery training fallback and brightness preserve ordered effects across failures" {
    const r = Receiver;
    try r.reset(true);
    // DCN1 DDC pairs may be described by CLK bit0 or DATA bit8. Every
    // other field or mismatched MASK/A description remains unsupported.
    try t.expectEqual(@as(u32, 0), hw.DC_GPIO_DDC1_A__DC_GPIO_DDC1CLK_A__SHIFT);
    try t.expectEqual(@as(u32, 8), hw.DC_GPIO_DDC1_A__DC_GPIO_DDC1DATA_A__SHIFT);
    const original_route = try p.route(&r.board);
    for (0..32) |shift| for (0..32) |mask| {
        r.board.paths[0].i2c_pin.?.shift = @intCast(shift);
        r.board.paths[0].i2c_pin.?.mask_shift = @intCast(mask);
        if (shift == mask and (shift == 0 or shift == 8)) {
            try t.expect(std.meta.eql(original_route.native, (try p.route(&r.board)).native));
        } else try t.expectError(error.Unsupported, p.route(&r.board));
    };
    try r.reset(true);
    r.fail_rate20 = true;
    try r.panel.discover();
    try t.expectEqual(@as(u64, 500_000_000), r.power_on_at);
    try t.expect(r.panel.edid_length == 128 and r.stop_count == 1 and r.panel.mode.clock_hz == 148500000 and r.panel.brightness_path == .aux16);
    try r.panel.train();
    try t.expectEqual(@as(u8, 10), r.panel.link.rate);
    try t.expectError(error.State, r.panel.show(32768));
    try t.expect(!r.lit);
    r.video = true;
    const before = r.ticks;
    try r.panel.show(32768);
    try t.expect(r.lit and r.light_on_at >= before + 20_000_000 and r.data[0x721] & 3 == 2 and r.data[0x720] & 1 != 0);
    try t.expectEqual(@as(u8, 0x80), r.data[0x722]);
    const previous = r.panel.brightness;
    r.fail_brightness = true;
    try t.expectError(error.Io, r.panel.setBrightness(45000));
    try t.expect(r.panel.phase == .retained and r.panel.effects and r.panel.brightness == previous);
    r.fail_brightness = false;
    r.video = false;
    try r.panel.hide();
    try t.expect(!r.powered and !r.lit and r.panel.phase == .off);
    const off = r.ticks;
    try r.panel.discover();
    try t.expect(r.power_on_at >= off + 500_000_000);
    try r.reset(false);
    r.firmware_busy = 1;
    try r.panel.discover();
    try t.expect(r.panel.brightness_path == .unavailable and r.panel.brightness_reason == .firmware_owner);
    try r.reset(false);
    try r.panel.discover();
    try r.panel.train();
    r.video = true;
    try r.panel.show(65535);
    try t.expectEqual(@as(u32, 65536), r.pwm_value);
    try r.reset(true); try r.panel.discover(); try r.panel.train();
    r.ignore_brightness = true;
    try t.expectError(error.Io, r.panel.setBrightness(40000));
    try t.expect(!r.panel.brightness_known and r.panel.phase == .retained);
    try r.reset(true);
    r.defer_all = true;
    try t.expectError(error.Timeout, r.panel.discover());
    try t.expect(r.attempts <= 32 and r.panel.effects and r.panel.phase == .retained and !r.lit);
    try r.reset(true);
    r.edid[10] ^= 1;
    try t.expectError(error.Invalid, r.panel.discover());
    try t.expect(!r.lit and r.panel.phase == .retained);
    try r.reset(true);
    r.board.paths[0].external_encoder = 0x2101;
    try t.expectError(error.Unsupported, p.route(&r.board));
    r.board.paths[0].external_encoder = 0;
    r.board.paths[0].hpd_active = 0;
    try t.expectEqual(@as(u32, 0), (try p.route(&r.board)).native.hpd_active);
    r.board.paths[0].hpd_active = 2;
    try t.expectError(error.Unsupported, p.route(&r.board));
    try brightnessContractCheck();
    std.debug.print("[amd-panel] bounded AUX/EDID, HBR2-to-HBR fallback, native mode, AUX/PWM brightness, power timing and retained partial failure; no physical device\n", .{});
}

const BrightnessCatalog = struct {
    const a = @import("r4os").abi;
    request: a.GfxBrightnessRequest,
    value: ?a.GfxOutputBrightness = null,
    fail_sequence: u64 = 0,
    pub fn publishBrightness(self: *BrightnessCatalog, value: *const a.GfxOutputBrightness) i32 {
        if (value.sequence == self.fail_sequence) return -1;
        self.value = value.*; return 1;
    }
    pub fn readBrightness(self: *BrightnessCatalog, _: *const a.GfxOutputId, out: *a.GfxBrightnessRequest) i32 {
        out.* = self.request; return 1;
    }
};
fn brightnessContractCheck() !void {
    const r = Receiver;
    try r.reset(true); try r.panel.discover(); try r.panel.train();
    const id: BrightnessCatalog.a.GfxOutputId = .{ .adapter_id = 1, .connector_id = 2, .device_generation = 3, .connection_generation = 4 };
    var catalog: BrightnessCatalog = .{ .request = .{ .identity = id, .level = 45000, .sequence = 1 }, .fail_sequence = 2 };
    var bridge: @import("panel_brightness.zig").Bridge = .{};
    try t.expectError(error.Catalog, bridge.service(&r.panel, &catalog, id, r.ticks));
    try t.expect(bridge.acknowledged == 1 and r.panel.brightness_known and r.panel.brightness == 45000);
    const writes = r.writes;
    catalog.fail_sequence = 0;
    try bridge.service(&r.panel, &catalog, id, r.ticks);
    try t.expect(r.writes == writes and catalog.value.?.request_sequence == 1 and catalog.value.?.current == 45000);
    r.fail_brightness = true; catalog.request.sequence = 2; catalog.request.level = 40000;
    try bridge.service(&r.panel, &catalog, id, r.ticks);
    try t.expect(catalog.value.?.phase == BrightnessCatalog.a.gfx_brightness_phase_failed and catalog.value.?.flags == 0 and r.panel.phase == .retained);
    const failed_writes = r.writes;
    try bridge.service(&r.panel, &catalog, id, r.ticks);
    try t.expect(r.writes == failed_writes);
}

const AtomNative = struct {
    const atom = @import("atom_vm.zig");
    var rom: [4096]u8 = undefined;
    var board: b.Board = undefined;
    var runtime: @import("panel_runtime.zig").Runtime = .{};
    fn read(_: usize, space: atom.Space, index: u32) atom.Error!u32 {
        if (space != .mmio or index >= Native.words.len) return error.Bounds;
        return Native.words[index];
    }
    fn write(_: usize, space: atom.Space, index: u32, value: u32) atom.Error!void {
        if (space != .mmio or index >= Native.words.len) return error.Bounds;
        Native.words[index] = value; Native.writes += 1;
    }
    fn now(_: usize) u64 { return Native.ticks + 1; }
    fn delay(_: usize, us: u32) atom.Error!void { Native.ticks += @as(u64, us) * 1000; }
    fn worker(_: usize) bool { return true; }
    fn check() !void {
        try Native.init();
        fixture.rom(&rom);
        fixture.set(b.c.struct_atom_rom_header_v2_2, "masterhwfunction_offset", rom[0x100..], 0xb00);
        fixture.header(rom[0xb00..], @intCast(4 + @sizeOf(b.c.struct_atom_master_list_of_command_functions_v2_1)), 2, 1);
        const command = @offsetOf(b.c.struct_atom_master_list_of_command_functions_v2_1, "dig1transmittercontrol") / 2;
        fixture.put(u16, &rom, 0xb04 + command * 2, 0xd00);
        fixture.header(rom[0xd00..], 12, 1, 6); rom[0xd04] = 0; rom[0xd05] = 32;
        // Real MOV_REG from PS0 followed by EOT. Records the complete ATOM
        // action word passed through native C into the actual bounded VM.
        rom[0xd06..0xd0c].* = .{ 1, 1, 10, 0, 0, 91 };
        try b.parse(&rom, fixture.device, &board);
        board.paths[0].encoder = 0x211e; board.paths[0].aux_ddc_line = 0;
        board.paths[0].i2c_pin.?.register = reg("DC_GPIO_DDC1_A");
        board.paths[0].i2c_pin.?.shift = 0; board.paths[0].i2c_pin.?.mask_shift = 0;
        board.paths[0].hpd_pin.?.register = reg("DC_GPIO_HPD_A");
        board.paths[0].hpd_pin.?.shift = 0; board.paths[0].hpd_pin.?.mask_shift = 0;
        runtime = .{};
        try runtime.bind(&Native.bytes, &board, .{ .context = 0, .read = read, .write = write, .now = now, .delay = delay, .worker = worker }, 0);
        try t.expect(Native.writes == 0);
        try t.expectEqual(@as(c_int, 0), c.r4dcn_link_action(&Native.bytes, 0, c.R4DCN_PANEL_ON));
        try t.expect(Native.words[10] & 0xff00 == 12 << 8 and runtime.vm.effects and Native.writes == 1);
        c.r4dcn_destroy(&Native.bytes);
    }
};
