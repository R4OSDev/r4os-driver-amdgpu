// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Common presentation metadata from confirmed OTG/HUBP receipts. Timing is
//! the host observation of the frame; no fabricated IRQ or GPU timestamp.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
pub const Owner = struct {
    last: ?a.DisplayPresentationStats = null,
    info: ?a.DisplayPresentationInfo = null,
    disabled: bool = false,
    info_disabled: bool = false,
    pub fn publish(self: *Owner, output: anytype) void {
        if (!output.callback_confirmed or output.initial_receipt == null) return;
        output.color.publish(output);
        const p = output.present.?;
        const receipt = p.receipt orelse output.initial_receipt.?;
        const failed = output.failure != null or p.failed_output;
        var value: a.DisplayPresentationStats = .{
            .backend = output.engine.?.binding, .head_id = output.mode.pipe, .display_generation = output.epoch.display,
            .sequence = if (self.last) |last| last.sequence else 0,
            .flags = a.display_presentation_flag_available | a.display_presentation_flag_polled |
                @as(u32, if (failed) a.display_presentation_flag_lost else 0),
            .buffer_count = 2, .acquired_count = p.acquired, .rendered_count = p.rendered, .submitted_count = p.submitted,
            .visible_count = p.visible, .released_count = p.released, .rejected_count = p.rejected,
            .pending = switch (p.phase) { .copying => a.display_presentation_pending_copy,
                .flip_retry => a.display_presentation_pending_ready,
                .flip_wait, .sample_retry, .sample_wait, .ack_retry, .ack_wait => a.display_presentation_pending_flip, else => 0 },
        };
        var receipt_ready = true;
        if (p.visible != 0) {
            // Boot/mode receipts observe scanout but are not submitted images.
            // The present owner attaches a source fence only after the exact
            // address and a later hardware frame have both been observed.
            value.visible_sequence = p.visible;
            if (p.source_fence.timeline != 0 and p.source_fence.point != 0 and p.receipt != null) {
                value.source_timeline = p.source_fence.timeline; value.source_point = p.source_fence.point;
                value.submitted_ns = p.receipt.?.submitted_ns; value.visible_ns = p.receipt.?.observed_ns;
                value.released_ns = if (p.receipt.?.previous != null) p.receipt.?.observed_ns else 0;
            } else if (self.last) |last| {
                // A mode-only rebind clears the present source. Preserve the
                // last published image receipt, never pair its old fence with
                // the new mode observation. A new submitted image replaces it.
                receipt_ready = last.visible_count == p.visible and last.display_generation == value.display_generation and
                    std.meta.eql(last.backend, value.backend) and last.head_id == value.head_id;
                value.source_timeline = last.source_timeline; value.source_point = last.source_point;
                value.submitted_ns = last.submitted_ns; value.visible_ns = last.visible_ns; value.released_ns = last.released_ns;
            } else receipt_ready = false;
        }
        if (receipt_ready and !self.disabled and (self.last == null or !std.meta.eql(value, self.last.?))) {
            if (value.sequence == std.math.maxInt(u64)) self.disabled = true else {
                value.sequence += 1;
                const status = output.display.?.presentationStats(&value);
                if (status == a.gfx_output_ok) self.last = value else if (status != a.gfx_output_error_busy) self.disabled = true;
            }
        }
        var info: a.DisplayPresentationInfo = .{
            .backend = output.engine.?.binding, .head_id = output.mode.pipe, .display_generation = output.epoch.display,
            .sequence = if (self.info) |last| last.sequence else 0,
            .flags = a.display_presentation_info_native | a.display_presentation_info_synchronized | a.display_presentation_info_visibility | a.display_presentation_info_system_source |
                @as(u32, if (failed) a.display_presentation_info_lost else a.display_presentation_info_active),
            .width = output.mode.width, .height = output.mode.height, .format = output.shape.format,
            .policies = 3, .buffer_count = 2, .plane_count = 1, .path = 1,
            .interval_ns = @as(u64, output.mode.h_total) * output.mode.v_total * 1_000_000 / output.mode.pixel_khz,
            .observed_sequence = receipt.frame, .observed_ns = receipt.observed_ns,
        };
        if (!self.info_disabled and (self.info == null or !std.meta.eql(info, self.info.?))) {
            if (info.sequence == std.math.maxInt(u64)) self.info_disabled = true else {
                info.sequence += 1;
                const status = output.display.?.presentationInfo(&info);
                if (status == a.gfx_output_ok) self.info = info else if (status != a.gfx_output_error_busy and status != a.gfx_output_error_stale) self.info_disabled = true;
            }
        }
    }
};
