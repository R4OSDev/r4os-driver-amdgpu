// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Encoded pixels, DCN depth and wire packets form one mode transaction.
//! Source masks describe this implementation, never receiver advertisements.
const std = @import("std");
const a = @import("r4os").abi;
const edid = @import("r4gfx_edid");
pub const color = edid.color;
pub const sdr: color.Signal = .{ .format = .xr24, .transfer = .srgb, .primaries = .bt709,
    .range = .full, .bpc = 8, .reference_white = 1_000_000, .peak = 1_000_000 };
pub fn source(hdmi: bool) color.Source {
    return if (hdmi) .{ .formats = 3, .bpc = 3, .primaries = 3, .ranges = 3, .eotf = 13, .static_metadata = true }
        else .{ .formats = 1, .bpc = 1, .primaries = 1, .ranges = 1, .eotf = 1 };
}
pub fn format(signal: color.Signal) u32 {
    return if (signal.format == .xr30) a.gfx_buffer_format_xrgb2101010 else a.gfx_buffer_format_xrgb8888;
}
pub fn defaultSignal(report: *const edid.Report, mode: edid.timing.Timing) color.Signal {
    var signal = sdr;
    if (report.hdmi and mode.vic > 1 and !report.rgb_quantization_selectable) signal.range = .limited;
    return signal;
}
pub fn timing(report: *const edid.Report, mode: anytype) !edid.timing.Timing {
    const wanted: edid.timing.Timing = .{ .width = mode.width, .height = mode.height, .h_total = mode.h_total, .v_total = mode.v_total,
        .h_start = mode.width + mode.h_front, .h_end = mode.width + mode.h_front + mode.h_sync,
        .v_start = mode.height + mode.v_front, .v_end = mode.height + mode.v_front + mode.v_sync,
        .clock_hz = @as(u64, mode.pixel_khz) * 1000, .flags = mode.flags & 6 };
    for (report.modes[0..report.mode_count]) |candidate| if (candidate.sameMode(wanted) and
        candidate.flags & (edid.timing.incomplete | edid.timing.interlaced | edid.timing.y420_only) == 0) return candidate;
    return error.Unsupported;
}
pub fn hdmiPlan(report: *const edid.Report, mode: edid.timing.Timing, signal: color.Signal, limit: u64) !color.Plan {
    return color.admit(report, signal, source(true), .{ .linear_composition = true, .output_transform = true, .opaque_output = true },
        .{ .hdmi = .{ .max_tmds_hz = @min(limit, 340_000_000), .scdc = false } }, mode.clock_hz, mode.vic);
}
pub fn avi(report: *const edid.Report, mode: edid.timing.Timing, signal: color.Signal, limit: u64) ![17]u8 {
    _ = try hdmiPlan(report, mode, signal, limit);
    var packet: [17]u8 = @splat(0);
    packet[0..3].* = .{ 0x82, 2, 13 };
    if (signal.primaries == .bt2020) { packet[5] = 3 << 6; packet[6] = 6 << 4; }
    if (report.rgb_quantization_selectable) packet[6] |= @as(u8, if (signal.range == .full) 2 else 1) << 2;
    packet[7] = @intCast(mode.vic);
    var sum: u8 = 0; for (packet) |byte| sum +%= byte;
    packet[3] = 0 -% sum;
    return packet;
}
pub const limitedPixel = color.limitedRgb8;
pub const Owner = struct {
    reported: ?a.GfxOutputColorState = null,
    refresh: ?a.GfxOutputRefresh = null,
    pub fn publish(self: *Owner, output: anytype) void {
        if (!output.callback_confirmed or output.initial_receipt == null or output.failure != null or !output.modes.permitsQueue()) return;
        const outputs = output.outputs orelse return;
        // The common color contract names 8/10-bit wire encodings. A 6-bit
        // panel retains ordinary SDR output, without inventing an 8-bit link.
        if (outputs.supportsColor() and output.mode.flags & 8 == 0) {
            const signal = output.signal orelse sdr;
            if (output.shape.format != format(signal)) return;
            var caps = source(output.mode.flags & 1 != 0 and outputs.supportsModeColor());
            if (!outputs.supportsModeColor() and signal.range == .limited) caps.ranges = 2;
            var state: a.GfxOutputColorState = .{ .identity = output.output, .flags = 7,
                .format = format(signal), .bpc = signal.bpc, .primaries = if (signal.primaries == .bt2020) 3 else 1,
                .transfer = switch (signal.transfer) { .srgb => 1, .pq => 3, .hlg => 4 }, .range = if (signal.range == .full) 1 else 2,
                .reference_white = signal.reference_white, .peak = signal.peak, .black = signal.black,
                .formats = caps.formats, .depths = caps.bpc, .color_spaces = caps.primaries, .transfers = caps.eotf, .ranges = caps.ranges,
                .h_active = output.mode.width, .h_total = output.mode.h_total, .v_active = output.mode.height,
                .pixel_clock_numerator = @as(u64, output.mode.pixel_khz) * 1000, .pixel_clock_denominator = 1 };
            if (output.mode.flags & 1 != 0) {
                if (caps.static_metadata) state.flags |= a.gfx_output_color_hdmi_metadata;
                state.link_kind = a.gfx_output_link_tmds; state.max_tmds_clock_hz = 340_000_000;
            } else {
                const p = &@as(*@import("panel_runtime.zig").Runtime, @ptrFromInt(output.core.?.panel_allocation.cpu_address)).protocol.?;
                const config = p.link;
                if (config.rate == 0 or config.lanes == 0) return;
                state.link_kind = a.gfx_output_link_dp_sst; state.link_lanes = config.lanes; state.link_rate_mbps = @as(u32, config.rate) * 270;
                state.dp_payload_bits_per_second = @as(u64, state.link_rate_mbps) * state.link_lanes * 800_000;
                state.link_payload_bits_per_second = state.dp_payload_bits_per_second;
            }
            if ((self.reported == null or !std.meta.eql(self.reported.?, state)) and outputs.publishColor(&state) == a.gfx_output_ok) self.reported = state;
        }
        // DCN1 DRR registers alone prove neither a qualified eDP panel nor
        // HDMI Forum EMP/vendor FreeSync transport. Report fixed/unavailable.
        if (outputs.supportsRefresh()) {
            const period = @as(u64, output.mode.h_total) * output.mode.v_total * 1_000_000 / output.mode.pixel_khz;
            var value: a.GfxOutputRefresh = .{ .target = output.target,
                .capabilities = .{ .flags = a.gfx_refresh_cap_known | a.gfx_refresh_cap_independent_heads,
                    .nominal_millihz = @intCast(1_000_000_000_000 / period) },
                .status = .{ .sequence = if (self.refresh) |last| last.status.sequence else 0,
                    .phase = a.gfx_refresh_phase_fixed, .reason = a.gfx_refresh_reason_unavailable } };
            var request: a.GfxRefreshRequest = .{};
            if (outputs.readRefresh(&output.target, &request) == a.gfx_output_ok) {
                value.status.request_sequence = request.sequence; value.status.policy = request.policy; value.status.scene = request.scene;
            }
            if (self.refresh != null and std.meta.eql(self.refresh.?, value)) return;
            if (value.status.sequence == std.math.maxInt(u64)) return;
            value.status.sequence += 1;
            if (outputs.publishRefresh(&value) == a.gfx_output_ok) self.refresh = value;
        }
    }
};
