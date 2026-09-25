// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
// Synthetic MMIO/receiver fixtures. No laptop, panel or electrical evidence.
const std = @import("std");
const t = std.testing;
const p = @import("hdmi.zig");
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
    var i2c_deny = false;
    var i2c_nack = false;
    var i2c_timeout = false;
    var i2c_reply: [128]u8 = undefined;
    var i2c_at: usize = 0;
    var i2c_go: usize = 0;
    var i2c_auto_sink = false;
    var i2c_sent: [8]u8 = undefined;
    var i2c_sent_count: usize = 0;
    var fail_write: usize = 0;
    fn read(_: ?*anyopaque, offset: u32, out: [*c]u32) callconv(.c) c_int {
        if (offset % 4 != 0 or offset / 4 >= words.len) return -1;
        const index = offset / 4;
        out.* = words[index];
        // External hotplug stimulus drives both raw and controller views in
        // this integration fixture; panel_test independently varies them.
        inline for (.{ "HPD0_DC_HPD_INT_STATUS", "HPD1_DC_HPD_INT_STATUS", "HPD2_DC_HPD_INT_STATUS", "HPD3_DC_HPD_INT_STATUS" }, 0..) |name, source| {
            if (index == reg(name)) out.* = if (words[reg("DC_GPIO_HPD_Y")] & (@as(u32, 1) << (source * 8)) != 0)
                hw.HPD0_DC_HPD_INT_STATUS__DC_HPD_SENSE_DELAYED_MASK else 0;
        }
        if (index == reg("DP_AUX0_AUX_SW_DATA") and words[index] & hw.DP_AUX0_AUX_SW_DATA__AUX_SW_DATA_RW_MASK != 0) {
            const value: u32 = if (reply_at < reply_count) reply[reply_at] else 0;
            reply_at += 1;
            out.* = (out.* & ~@as(u32, hw.DP_AUX0_AUX_SW_DATA__AUX_SW_DATA_MASK)) | (value << hw.DP_AUX0_AUX_SW_DATA__AUX_SW_DATA__SHIFT);
        }
        if (index == reg("DC_I2C_DATA") and words[index] & hw.DC_I2C_DATA__DC_I2C_DATA_RW_MASK != 0) {
            const value: u32 = if (i2c_at < 128) i2c_reply[i2c_at] else 0;
            i2c_at += 1;
            out.* = (out.* & ~@as(u32, hw.DC_I2C_DATA__DC_I2C_DATA_MASK)) | (value << hw.DC_I2C_DATA__DC_I2C_DATA__SHIFT);
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
        if (index == reg("DC_I2C_ARBITRATION")) {
            words[index] &= ~@as(u32, hw.DC_I2C_ARBITRATION__DC_I2C_REG_RW_CNTL_STATUS_MASK);
            if (value & hw.DC_I2C_ARBITRATION__DC_I2C_SW_DONE_USING_I2C_REG_MASK != 0) {
                words[index] &= ~@as(u32, hw.DC_I2C_ARBITRATION__DC_I2C_SW_USE_I2C_REG_REQ_MASK | hw.DC_I2C_ARBITRATION__DC_I2C_SW_DONE_USING_I2C_REG_MASK);
            } else if (!i2c_deny and value & hw.DC_I2C_ARBITRATION__DC_I2C_SW_USE_I2C_REG_REQ_MASK != 0) words[index] |= 1 << hw.DC_I2C_ARBITRATION__DC_I2C_REG_RW_CNTL_STATUS__SHIFT;
        }
        if (index == reg("DC_I2C_DATA")) {
            if (value & hw.DC_I2C_DATA__DC_I2C_DATA_RW_MASK != 0) i2c_at = 0 else {
                if (value & hw.DC_I2C_DATA__DC_I2C_INDEX_WRITE_MASK != 0) i2c_sent_count = 0;
                if (i2c_sent_count < i2c_sent.len) { i2c_sent[i2c_sent_count] = @truncate(value >> hw.DC_I2C_DATA__DC_I2C_DATA__SHIFT); i2c_sent_count += 1; }
            }
        }
        if (index == reg("DC_I2C_CONTROL")) {
            if (value & hw.DC_I2C_CONTROL__DC_I2C_SW_STATUS_RESET_MASK != 0) words[reg("DC_I2C_SW_STATUS")] = 0;
            if (value & hw.DC_I2C_CONTROL__DC_I2C_GO_MASK != 0) {
                i2c_go += 1;
                if (i2c_auto_sink and i2c_sent_count == 3) @memcpy(&i2c_reply, Sink.bytes[i2c_sent[1]..][0..128]);
                words[index] &= ~@as(u32, hw.DC_I2C_CONTROL__DC_I2C_GO_MASK);
                words[reg("DC_I2C_SW_STATUS")] = if (i2c_timeout) 1 else if (i2c_nack) hw.DC_I2C_SW_STATUS__DC_I2C_SW_STOPPED_ON_NACK_MASK else hw.DC_I2C_SW_STATUS__DC_I2C_SW_DONE_MASK;
            }
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
        std.debug.assert(count < commands.len);
        if (command == @offsetOf(b.c.struct_atom_master_list_of_command_functions_v2_1, "setdceclock") / 2 and n == 4) {
            std.debug.assert(parameters[0] == 0 and parameters[1] == 0x0801 and parameters[2] == 0 and parameters[3] == 0);
            parameters[0] = 60000; return 0;
        }
        const tx = @offsetOf(b.c.struct_atom_master_list_of_command_functions_v2_1, "dig1transmittercontrol") / 2;
        const enc = @offsetOf(b.c.struct_atom_master_list_of_command_functions_v2_1, "digxencodercontrol") / 2;
        const pixel = @offsetOf(b.c.struct_atom_master_list_of_command_functions_v2_1, "setpixelclock") / 2;
        std.debug.assert((command == tx and n == 8) or (command == enc and n == 3) or (command == pixel and n == 4));
        commands[count] = @splat(0);
        @memcpy(commands[count][0..n], parameters[0..n]);
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
        i2c_deny = false; i2c_nack = false; i2c_timeout = false; i2c_go = 0; i2c_auto_sink = false; i2c_at = 0; i2c_sent_count = 0;
        for (&i2c_reply, 0..) |*v, i| v.* = @intCast(i);
        @memset(&reply, 0);
        reply_count = 1;
        reply_at = 0;
        const limits: c.struct_r4dcn_limits = .{ .channels = 2, .dcf_khz = 600000, .disp_khz = 960000, .dpp_khz = 626000, .fabric_khz = 1066666, .soc_khz = 626000, .ref_khz = 48000, .gb_addr_config = 0x24000042, .reserved = 0, .pipe_count = 4 };
        try t.expectEqual(@as(c_int, 0), c.r4dcn_init(&bytes, c.r4dcn_size(), &io, &limits));
    }
    const route: c.struct_r4dcn_route = .{ .connector = 0x310c, .encoder = 0x211e, .phy = 0, .aux = 0, .hpd = 0, .caps = 0xa, .ddc_a = reg("DC_GPIO_DDC1_A"), .hpd_a = reg("DC_GPIO_HPD_A"), .hpd_shift = 0, .hpd_active = 1 };
};
const mode: c.struct_r4dcn_mode = .{ .width = 1920, .height = 1080, .h_total = 2200, .v_total = 1125, .h_front = 88, .h_sync = 44, .v_front = 4, .v_sync = 5, .pixel_khz = 148500, .pitch_bytes = 7680, .pipe = 0, .flags = 7, .mc_address = 0x200000000, .buffer_bytes = 7680 * 1080 };
/// Share the real I2C register/FIFO model with the composite driver test.
pub const SharedI2c = struct {
    pub fn reset() void {
        @memset(&Native.words, 0); Sink.init();
        Native.i2c_at = 0; Native.i2c_go = 0; Native.i2c_sent_count = 0;
        Native.i2c_deny = false; Native.i2c_nack = false; Native.i2c_timeout = false;
        Native.i2c_auto_sink = true; Native.fail_write = 0; Native.writes = 0;
    }
    pub fn handles(offset: u32) bool { return offset >= reg("DC_I2C_CONTROL") * 4 and offset <= reg("DC_I2C_READ_REQUEST_INTERRUPT") * 4; }
    pub fn read(raw: ?*anyopaque, offset: u32, out: [*c]u32) c_int { return Native.read(raw, offset, out); }
    pub fn write(raw: ?*anyopaque, offset: u32, value: u32) c_int { return Native.write(raw, offset, value); }
    pub fn colorCapabilities(limited: bool) void {
        // Explicit synthetic HDMI deep-color, BT2020-RGB and PQ/HLG metadata.
        Sink.bytes[141] = 0x10;
        if (limited) Sink.bytes[145] = 0;
        Sink.bytes[130] = 26;
        Sink.bytes[146..154].* = .{ 0xe3, 5, 0x80, 0, 0xe3, 6, 13, 1 };
        Sink.checksum();
    }
    pub fn audioCapabilities() void { Sink.bytes[131] |= 0x40; Sink.checksum(); }
    pub fn changed() void { Sink.bytes[12] +%= 1; Sink.checksum(); }
    pub fn requests() usize { return Native.i2c_go; }
};
test "HDMI original I2C arbitration FIFO E-DDC release and stream infoframes" {
    const n = Native;
    try n.init();
    try t.expectEqual(@as(c_int, 0), c.r4dcn_link_bind(&n.bytes, 1, &n.route, &n.atom_io));
    try t.expectEqual(@as(c_int, 0), c.r4dcn_hdmi_bind(&n.bytes, 1, 48000));
    try t.expectEqual(@as(usize, 0), n.writes);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_link_action(&n.bytes, 1, c.R4DCN_LINK_INIT));
    n.words[reg("DC_GPIO_DDC1_MASK")] = 0x10101;
    var bytes: [128]u8 = @splat(0xa5);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_hdmi_edid(&n.bytes, 1, 0, &bytes));
    try t.expectEqualSlices(u8, &n.i2c_reply, &bytes);
    try t.expectEqualSlices(u8, &.{0xa0, 0, 0xa1}, n.i2c_sent[0..n.i2c_sent_count]);
    try t.expectEqual(@as(usize, 1), n.i2c_go);
    try t.expectEqual(@as(u32, 0x10101), n.words[reg("DC_GPIO_DDC1_MASK")]);
    try t.expectEqual(@as(u32, 0), n.words[reg("DC_I2C_ARBITRATION")] & hw.DC_I2C_ARBITRATION__DC_I2C_REG_RW_CNTL_STATUS_MASK);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_hdmi_edid(&n.bytes, 1, 3, &bytes));
    try t.expectEqualSlices(u8, &.{0x60, 1, 0xa0, 128, 0xa1}, n.i2c_sent[0..n.i2c_sent_count]);
    const before = n.i2c_go;
    n.i2c_deny = true;
    try t.expectEqual(@as(c_int, c.R4DCN_IO), c.r4dcn_hdmi_edid(&n.bytes, 1, 0, &bytes));
    try t.expectEqual(before, n.i2c_go);
    try t.expectEqual(@as(u32, 0x10101), n.words[reg("DC_GPIO_DDC1_MASK")]);
    n.i2c_deny = false; n.i2c_nack = true; bytes = @splat(0xa5);
    try t.expectEqual(@as(c_int, c.R4DCN_IO), c.r4dcn_hdmi_edid(&n.bytes, 1, 0, &bytes));
    try t.expectEqualSlices(u8, &(@as([128]u8, @splat(0xa5))), &bytes);
    n.i2c_nack = false; n.i2c_timeout = true;
    try t.expectEqual(@as(c_int, c.R4DCN_IO), c.r4dcn_hdmi_edid(&n.bytes, 1, 0, &bytes));
    try t.expectEqual(@as(u32, 0x10101), n.words[reg("DC_GPIO_DDC1_MASK")]);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_fault(&n.bytes));
    n.i2c_timeout = false;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_hdmi_edid(&n.bytes, 1, 0, &bytes));
    var plan: c.struct_r4dcn_plan = undefined;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_prepare(&n.bytes, &mode, 1, &plan));
    const pixel_calls = n.count;
    const pixel_writes = n.writes;
    try t.expectEqual(@as(c_int, c.R4DCN_INVALID), c.r4dcn_pixel_clock_bind(&n.bytes, 1, 0));
    try t.expectEqual(@as(c_int, 0), c.r4dcn_pixel_clock_bind(&n.bytes, 1, 48000));
    try t.expectEqual(pixel_writes, n.writes);
    n.words[reg("OTG0_OTG_CONTROL")] = hw.OTG0_OTG_CONTROL__OTG_CURRENT_MASTER_EN_STATE_MASK;
    try t.expectEqual(@as(c_int, c.R4DCN_STATE), c.r4dcn_pixel_clock_program(&n.bytes, 1, 0));
    try t.expectEqual(pixel_calls, n.count);
    n.words[reg("OTG0_OTG_CONTROL")] = 0;
    var reference_khz: u32 = 0;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_reference_clock_program(&n.bytes, 1, &reference_khz));
    try t.expectEqual(@as(u32, 600000), reference_khz);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_pixel_clock_program(&n.bytes, 1, 0));
    try t.expectEqual(pixel_calls + 1, n.count);
    try t.expectEqual(@as(u32, 1485000), n.commands[pixel_calls][0]);
    try t.expectEqual(@as(u32, 0x00031e14), n.commands[pixel_calls][1]); // HDMI3 / UNIPHY0x1e / PLL20
    try t.expectEqual(@as(u32, 0), n.commands[pixel_calls][2]); // CRTC0 / RGB8
    try t.expectEqual(@as(u32, 0), n.commands[pixel_calls][3]);
    var avi: [17]u8 = @splat(0); avi[0..4].* = .{0x82, 2, 13, 0x6f};
    const calls = n.count;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_hdmi_configure(&n.bytes, 1, 0, &avi));
    try t.expectEqual(calls + 1, n.count);
    try t.expectEqual(@as(u32, 0x04030f00), n.commands[calls][0]);
    try t.expectEqual(@as(u32, 14850), n.commands[calls][1]);
    try t.expectEqual(@as(u32, 2), n.commands[calls][2]);
    try t.expect(n.words[reg("DIG0_HDMI_GC")] & hw.DIG0_HDMI_GC__HDMI_GC_AVMUTE_MASK != 0);
    try t.expect(n.words[reg("DIG0_HDMI_INFOFRAME_CONTROL0")] & hw.DIG0_HDMI_INFOFRAME_CONTROL0__HDMI_AUDIO_INFO_SEND_MASK == 0);
    try t.expect(n.words[reg("DIG0_HDMI_GENERIC_PACKET_CONTROL0")] & hw.DIG0_HDMI_GENERIC_PACKET_CONTROL0__HDMI_GENERIC0_SEND_MASK != 0);
    try t.expectEqual(@as(c_int, c.R4DCN_STATE), c.r4dcn_hdmi_enable(&n.bytes, 1)); // No frontend commit yet.
    var deep = mode; deep.flags |= 16;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_prepare(&n.bytes, &deep, 1, &plan));
    const deep_calls = n.count;
    try t.expectEqual(@as(c_int, 0), c.r4dcn_pixel_clock_program(&n.bytes, 1, 0));
    try t.expectEqual(@as(u32, 1856250), n.commands[deep_calls][0]); // 148.5MHz * 5/4, in 100Hz.
    try t.expectEqual(@as(u32, 0), n.commands[deep_calls][2]); // DCN1 programs 5:4 directly after ATOM.
    try t.expectEqual(@as(u32, 1), (n.words[hw.DCE_BASE__INST0_SEG1 + hw.mmPHYPLLA_PIXCLK_RESYNC_CNTL] >> 4) & 3);
    try t.expectEqual(@as(c_int, 0), c.r4dcn_hdmi_configure(&n.bytes, 1, 0, &avi));
    try t.expectEqual(@as(u32, 3), n.commands[deep_calls + 1][2]); // PANEL_10BIT_PER_COLOR.
    try t.expectEqual(@as(u32, 18562), n.commands[deep_calls + 1][1]); // Physical TMDS clock in 10kHz.
    try t.expect(n.words[reg("DIG0_HDMI_CONTROL")] & hw.DIG0_HDMI_CONTROL__HDMI_DEEP_COLOR_ENABLE_MASK != 0);
    avi[3] = 0;
    const writes = n.writes;
    try t.expectEqual(@as(c_int, c.R4DCN_INVALID), c.r4dcn_hdmi_configure(&n.bytes, 1, 0, &avi));
    try t.expectEqual(writes, n.writes);
}
const Sink = struct {
    var bytes: [256]u8 = undefined;
    var ticks: u64 = 1;
    var present = true;
    var fail = false;
    var slow = false;
    var mutate = false;
    var reads: usize = 0;
    fn hpd(_: usize) p.Error!bool { return present; }
    fn block(_: usize, number: u32, out: *[128]u8) p.Error!void {
        reads += 1;
        if (fail) return error.Io;
        if (number > 1) return error.Invalid;
        @memcpy(out, bytes[number * 128 ..][0..128]);
        if (slow) ticks += 2_000_000_000;
        if (mutate and reads == 3) out[12] ^= 1;
    }
    fn now(_: usize) u64 { return ticks; }
    fn delay(_: usize, us: u32) p.Error!void { ticks += @as(u64, us) * 1000; }
    const io: p.Io = .{ .context = 0, .hpd = hpd, .block = block, .now = now, .delay = delay };
    fn init() void {
        ticks = 1; present = true; fail = false; slow = false; mutate = false; reads = 0;
        bytes = @splat(0);
        bytes[0..8].* = .{ 0, 255, 255, 255, 255, 255, 255, 0 };
        bytes[8] = 4; bytes[9] = 0x43; bytes[18] = 1; bytes[19] = 4; bytes[20] = 0xa2; bytes[24] = 2;
        @memset(bytes[38..54], 1);
        bytes[54..72].* = .{ 2, 0x3a, 0x80, 0x18, 0x71, 0x38, 0x2d, 0x40, 0x58, 0x2c, 0x45, 0, 0, 0, 0, 0, 0, 0x1e };
        bytes[126] = 1;
        // CTA: 1080p60 + 4K30; HDMI VSDB, 600MHz receiver, RGB selectable.
        bytes[128..146].* = .{ 2, 3, 18, 0, 0x42, 16, 95, 0x67, 3, 12, 0, 0x10, 0, 0, 120, 0xe2, 0, 0x40 };
        checksum();
    }
    fn checksum() void { fixture.checksum(bytes[0..128], 127); fixture.checksum(bytes[128..256], 127); }
};
test "HDMI admits only complete receiver timings and the direct HDMI1.4 board route" {
    const s = Sink;
    var receiver: p.Receiver = .{};
    s.init();
    try receiver.read(s.io, 340_000_000);
    try t.expect(receiver.valid and receiver.length == 256 and receiver.max_tmds_hz == 340_000_000);
    const chosen = try receiver.preferred();
    var record: @import("r4os").abi.GfxReceiverInfo = .{};
    try receiver.describe(0x310c, &record);
    try t.expect(record.connector_kind == @import("r4os").abi.gfx_output_kind_hdmi and record.edid_bytes == 256 and record.mode_count >= 1 and record.preferred_mode_id == 1);
    try t.expectEqualSlices(u8, &s.bytes, record.edid[0..256]);
    const preserved = record;
    receiver.valid = false;
    try t.expectError(error.State, receiver.describe(0x310c, &record));
    try t.expect(std.meta.eql(record, preserved));
    receiver.valid = true;
    try t.expectEqual(@as(u32, 1920), chosen.width);
    try t.expectEqual(@as(u16, 16), chosen.vic); // Base DTD merged with its CTA VIC.
    const avi = try receiver.avi(chosen);
    var sum: u8 = 0; for (avi) |byte| sum +%= byte;
    try t.expect(sum == 0 and avi[6] == 8 and avi[7] == chosen.vic);
    const colors = @import("display_color.zig");
    SharedI2c.colorCapabilities(false);
    try receiver.read(s.io, 340_000_000);
    const hdr: colors.color.Signal = .{ .format = .xr30, .bpc = 10, .transfer = .pq, .primaries = .bt2020,
        .range = .limited, .reference_white = 2_030_000, .peak = 10_000_000, .metadata = .{ .max_cll = 1000, .max_fall = 400 } };
    const plan = try colors.hdmiPlan(&receiver.report, chosen, hdr, 340_000_000);
    try t.expect(plan.tmds_hz == 185625000 and plan.metadata_bytes == 30 and plan.metadata[4] == 2);
    const hdr_avi = try colors.avi(&receiver.report, chosen, hdr, 340_000_000);
    try t.expect(hdr_avi[5] == 0xc0 and hdr_avi[6] == 0x64);
    var excessive = chosen; excessive.clock_hz = 297_000_000;
    try t.expectError(error.Bandwidth, colors.hdmiPlan(&receiver.report, excessive, hdr, 340_000_000));
    receiver.report.hdr_static = 0;
    try t.expectError(error.Unsupported, colors.hdmiPlan(&receiver.report, chosen, hdr, 340_000_000));
    SharedI2c.colorCapabilities(true); try receiver.read(s.io, 340_000_000);
    var cta = chosen; cta.vic = 16;
    const limited = colors.defaultSignal(&receiver.report, cta);
    try t.expect(limited.range == .limited);
    const limited_avi = try colors.avi(&receiver.report, cta, limited, 340_000_000);
    try t.expect(limited_avi[6] == 0 and limited_avi[7] == 16);
    try t.expectError(error.Unsupported, colors.hdmiPlan(&receiver.report, cta, colors.sdr, 340_000_000));
    try t.expectEqual(@as(u32, 0xff101010), colors.limitedPixel(0));
    try t.expectEqual(@as(u32, 0xffebebeb), colors.limitedPixel(0x00ffffff));
    try t.expectEqual(@as(u32, 0xff7e7e7e), colors.limitedPixel(0x00808080));
    s.init(); try receiver.read(s.io, 340_000_000);
    var forged = chosen; forged.clock_hz += 1000;
    try t.expect(!receiver.admits(forged));
    forged = chosen; forged.vic = 99;
    try t.expect(!receiver.admits(forged));
    forged = chosen; forged.flags |= p.edid.timing.y420_only;
    try t.expect(!receiver.admits(forged));
    s.bytes[142] = 20; s.checksum(); // 100MHz sink maximum.
    try receiver.read(s.io, 340_000_000);
    try t.expectError(error.Unsupported, receiver.preferred());
    s.init(); s.bytes[255] ^= 1;
    try t.expectError(error.Unsupported, receiver.read(s.io, 340_000_000));
    try t.expect(!receiver.valid);
    s.init(); s.mutate = true;
    try t.expectError(error.Changed, receiver.read(s.io, 340_000_000));
    s.init(); s.present = false;
    try t.expectError(error.Disconnected, receiver.read(s.io, 340_000_000));
    try t.expectEqual(@as(usize, 0), s.reads);
    s.init(); s.fail = true;
    try t.expectError(error.Io, receiver.read(s.io, 340_000_000));
    try t.expectEqual(@as(usize, 3), s.reads);
    s.init(); s.slow = true;
    try t.expectError(error.Timeout, receiver.read(s.io, 340_000_000));
    s.init(); s.bytes[126] = 32; s.checksum();
    try t.expectError(error.Capacity, receiver.read(s.io, 340_000_000));
    var rom: [fixture.image_bytes]u8 = undefined; fixture.rom(&rom);
    var board: b.Board = undefined; try b.parse(&rom, fixture.device, &board);
    board.paths[0].connector = 0x310c; board.paths[0].i2c_pin.?.shift = 0;
    board.paths[0].hpd_pin.?.shift = 8; board.paths[0].hpd_pin.?.mask_shift = 8;
    var info: [@sizeOf(b.c.struct_atom_display_controller_info_v4_1)]u8 = @splat(0);
    fixture.header(&info, info.len, 4, 1); fixture.set(b.c.struct_atom_display_controller_info_v4_1, "dce_refclk_10khz", &info, 4800);
    board.tables[@offsetOf(b.c.struct_atom_master_list_of_data_tables_v2_1, "dce_info") / 2] = .{ .offset = 0xb00, .bytes = &info };
    try t.expectEqual(@as(u32, 48000), (try p.route(&board)).crystal_khz);
    try t.expectEqual(@as(u32, 1), (try p.route(&board)).native.hpd);
    const original_route = try p.route(&board);
    for (0..32) |shift| for (0..32) |mask| {
        board.paths[0].i2c_pin.?.shift = @intCast(shift);
        board.paths[0].i2c_pin.?.mask_shift = @intCast(mask);
        if (shift == mask and (shift == 0 or shift == 8)) {
            try t.expect(std.meta.eql(original_route.native, (try p.route(&board)).native));
        } else try t.expectError(error.Unsupported, p.route(&board));
    };
    board.paths[0].i2c_pin.?.shift = 0; board.paths[0].i2c_pin.?.mask_shift = 0;
    board.paths[0].hpd_active = 0;
    try t.expectEqual(@as(u32, 0), (try p.route(&board)).native.hpd_active);
    board.paths[0].hpd_active = 2;
    try t.expectError(error.Unsupported, p.route(&board)); board.paths[0].hpd_active = 1;
    board.paths[0].hpd_pin.?.shift = 4; board.paths[0].hpd_pin.?.mask_shift = 4;
    try t.expectError(error.Unsupported, p.route(&board));
    board.paths[0].hpd_pin.?.shift = 8; board.paths[0].hpd_pin.?.mask_shift = 8;
    board.paths[1] = board.paths[0]; board.path_count = 2;
    try t.expectError(error.Ambiguous, p.route(&board)); board.path_count = 1;
    board.paths[0].connector = 0x3113; // A DP/USB-C path is never inferred as HDMI.
    try t.expectError(error.Unsupported, p.route(&board)); board.paths[0].connector = 0x310c;
    board.paths[0].external_encoder = 1;
    try t.expectError(error.Unsupported, p.route(&board)); board.paths[0].external_encoder = 0;
    fixture.set(b.c.struct_atom_display_controller_info_v4_1, "dce_refclk_10khz", &info, 0);
    try t.expectError(error.Invalid, p.route(&board));
}
const hp = @import("hdmi_hotplug.zig");
const Retirement = struct {
    var steps: [16]hp.Step = undefined;
    var count: usize = 0;
    var busy: ?hp.Step = null;
    var stale = false;
    var unsafe_stop = false;
    var jobs: u32 = 0;
    fn retire(_: usize, generation: u64, step: hp.Step) hp.Receipt {
        steps[count] = step; count += 1;
        return .{ .generation = generation + @as(u64, @intFromBool(stale)), .done = busy != step,
            .pending_jobs = jobs, .scanout_stopped = !unsafe_stop };
    }
    const io: hp.Io = .{ .context = 0, .retire = retire };
    fn reset() void { count = 0; busy = null; stale = false; unsafe_stop = false; jobs = 0; }
};
test "HDMI hotplug debounces new connections and retains old jobs until confirmed retirement" {
    const r = Retirement;
    r.reset();
    var connection: hp.Connection = .{};
    try connection.sample(true, 1);
    try connection.sample(false, 50_000_000);
    try connection.sample(true, 60_000_000);
    try connection.sample(true, 159_999_999);
    try t.expect(connection.phase == .debounce and connection.generation == 0);
    try connection.sample(true, 160_000_000);
    try connection.publish(1, @splat(7));
    try connection.changed(1, @splat(7));
    try t.expect(connection.phase == .connected);
    try connection.sample(false, 170_000_000);
    try t.expect(connection.published and connection.phase == .retiring);
    try connection.sample(true, 180_000_000);
    try t.expectError(error.Stale, connection.publish(2, @splat(8)));
    r.busy = .drain;
    try t.expect(!try connection.advance(r.io));
    try t.expect(!try connection.advance(r.io));
    try t.expectEqual(hp.Step.drain, connection.step);
    r.busy = null;
    for (0..4) |_| try t.expect(!try connection.advance(r.io));
    try t.expect(try connection.advance(r.io));
    try t.expectEqualSlices(hp.Step, &.{ .pause, .drain, .drain, .stop, .settle, .withdraw, .release }, r.steps[0..r.count]);
    try t.expect(!connection.published);
    try connection.sample(true, 280_000_000);
    try t.expectEqual(@as(u64, 2), connection.generation);
    try connection.publish(2, @splat(8));
    try connection.changed(2, @splat(9)); // Replacement without observed HPD edge.
    try t.expectEqual(hp.Phase.retiring, connection.phase);
    r.reset(); r.stale = true;
    try t.expectError(error.Stale, connection.advance(r.io));
    try t.expect(connection.phase == .retained and connection.published);
    r.reset(); connection.phase = .retiring; connection.step = .stop; r.unsafe_stop = true;
    try t.expectError(error.State, connection.advance(r.io));
    try t.expect(connection.published);
    r.reset(); connection.phase = .retiring; connection.step = .settle; r.jobs = 1;
    try t.expectError(error.State, connection.advance(r.io));
    try t.expect(connection.published);
    try t.expectError(error.Clock, connection.sample(true, 1));
    connection = .{ .generation = std.math.maxInt(u64) };
    try connection.sample(true, 1);
    try t.expectError(error.Capacity, connection.sample(true, 100_000_001));
    r.reset(); connection = .{ .phase = .retiring, .published = true, .generation = 5, .retiring_since = 1, .last = 5_000_000_001 };
    try t.expectError(error.Timeout, connection.advance(r.io));
    try t.expect(connection.published and r.count == 0);
    try AtomNative.check();
}

const AtomNative = struct {
    const atom = @import("atom_vm.zig");
    var rom: [4096]u8 = undefined;
    var board: b.Board = undefined;
    var runtime: @import("hdmi_runtime.zig").Runtime = .{};
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
    const a = @import("r4os").abi;
    var pauses: usize = 0;
    var withdrawals: usize = 0;
    const identity: a.GfxOutputId = .{ .adapter_id = 17, .connector_id = 0x310c, .device_generation = 3, .connection_generation = 9 };
    fn pause(id: *const a.GfxOutputId, value: u32) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(id.*, identity) and value == 1);
        pauses += 1;
        return if (pauses == 1) a.gfx_output_error_busy else a.gfx_output_ok;
    }
    fn withdraw(id: *const a.GfxOutputId) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(id.*, identity)); withdrawals += 1; return a.gfx_output_ok;
    }
    fn restore(_: *const a.GfxAtomicState, _: *a.GfxModeStatus) callconv(.c) i32 { unreachable; }
    fn modeStatus(_: u64, _: *a.GfxModeStatus) callconv(.c) i32 { unreachable; }
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
        const enc = @offsetOf(b.c.struct_atom_master_list_of_command_functions_v2_1, "digxencodercontrol") / 2;
        fixture.put(u16, &rom, 0xb04 + enc * 2, 0xd20);
        fixture.header(rom[0xd20..], 12, 1, 5); rom[0xd24] = 0; rom[0xd25] = 12;
        rom[0xd26..0xd2c].* = .{ 1, 1, 11, 0, 0, 91 };
        fixture.entry(&rom, "dce_info", 0xe00);
        fixture.header(rom[0xe00..], @sizeOf(b.c.struct_atom_display_controller_info_v4_1), 4, 1);
        fixture.set(b.c.struct_atom_display_controller_info_v4_1, "dce_refclk_10khz", rom[0xe00..], 4800);
        try b.parse(&rom, fixture.device, &board);
        board.paths[0].connector = 0x310c;
        board.paths[0].encoder = 0x211e; board.paths[0].aux_ddc_line = 0;
        board.paths[0].i2c_pin.?.register = reg("DC_GPIO_DDC1_A");
        board.paths[0].i2c_pin.?.shift = 0; board.paths[0].i2c_pin.?.mask_shift = 0;
        board.paths[0].hpd_pin.?.register = reg("DC_GPIO_HPD_A");
        board.paths[0].hpd_pin.?.shift = 0; board.paths[0].hpd_pin.?.mask_shift = 0;
        runtime = .{};
        try runtime.bind(&Native.bytes, &board, .{ .context = 0, .read = read, .write = write, .now = now, .delay = delay, .worker = worker });
        try t.expect(Native.writes == 0);
        Sink.init(); Native.i2c_auto_sink = true;
        Native.words[reg("DC_GPIO_HPD_Y")] = 1;
        try runtime.run(.probe, mode);
        try t.expectEqual(@import("hdmi_hotplug.zig").Phase.debounce, runtime.connection.phase);
        Native.ticks += 100_000_000;
        try runtime.run(.probe, mode);
        try t.expect(runtime.receiver.valid and runtime.connection.generation == 1);
        var plan: c.struct_r4dcn_plan = undefined;
        try t.expectEqual(@as(c_int, 0), c.r4dcn_prepare(&Native.bytes, &mode, 1, &plan));
        try runtime.run(.configure, mode);
        try t.expect(runtime.configured and runtime.vm.effects and Native.words[11] == 0x04030f00);
        const outputs: @import("r4os").driver_outputs.Context = .{ .table = .{ .output_pause = @intFromPtr(&pause), .withdraw = @intFromPtr(&withdraw), .mode_restore = @intFromPtr(&restore), .mode_status = @intFromPtr(&modeStatus) } };
        pauses = 0; withdrawals = 0; Retirement.reset();
        try runtime.published(1, identity, outputs, Retirement.io);
        Native.words[reg("DC_GPIO_HPD_Y")] = 0;
        try runtime.run(.service, mode);
        try t.expect(runtime.output.adapter_id == 17 and runtime.connection.step == .pause and pauses == 1);
        for (0..6) |_| try runtime.run(.service, mode);
        try t.expect(runtime.output.adapter_id == 0 and runtime.connection.phase == .disconnected and pauses == 2 and withdrawals == 1);
        Native.words[reg("DC_GPIO_HPD_Y")] = 1;
        try runtime.run(.probe, mode); Native.ticks += 100_000_000;
        try runtime.run(.probe, mode);
        try t.expect(runtime.receiver.valid and runtime.connection.generation == 2);
        try runtime.run(.configure, mode);
        try t.expectError(error.State, runtime.run(.enable, mode));
        Native.words[reg("DC_GPIO_HPD_Y")] = 0;
        try t.expectError(error.State, runtime.run(.service, mode));
        try t.expectEqual(@import("hdmi_hotplug.zig").Phase.retained, runtime.connection.phase);
        try t.expectError(error.State, runtime.run(.show, mode));
        c.r4dcn_destroy(&Native.bytes);
    }
};
