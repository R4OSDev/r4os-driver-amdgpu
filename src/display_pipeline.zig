// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! One internal eDP pipeline. Runs only inside the abortable DCN task; queue
//! BO ownership and common output publication remain in the outer worker.
//! Recovery reconstructs a boot-compatible image at the original reserved
//! address. It does not replay MMIO journals, W1C status or indexed LUT RAM.
const std = @import("std");
const a = @import("r4os").abi;
const dc = @import("display_core.zig");
const c = dc.c;
const bios = @import("bios.zig");
const clocks = @import("display_clocks.zig");
const panel = @import("panel.zig");
const edid = @import("r4gfx_edid");
pub fn bootMode(board: *const bios.Board, start: *const @import("start_runtime.zig").Owner) !c.struct_r4dcn_mode {
    const timing = board.panel orelse return error.Unsupported;
    const boot = start.hold.boot;
    if (timing.width != boot.width or timing.height != boot.height or boot.format != a.gfx_buffer_format_xrgb8888 or
        timing.misc & ~@as(u16, bios.c.ATOM_HSYNC_POLARITY | bios.c.ATOM_VSYNC_POLARITY) != 0 or
        (timing.bpc != 6 and timing.bpc != 8)) return error.Unsupported;
    return .{ .width = boot.width, .height = boot.height, .h_total = boot.width + timing.h_blank, .v_total = boot.height + timing.v_blank,
        .h_front = timing.h_sync_offset, .h_sync = timing.h_sync_width, .v_front = timing.v_sync_offset, .v_sync = timing.v_sync_width,
        .pixel_khz = timing.pixel_clock_khz, .pitch_bytes = boot.pitch, .pipe = try start.guard.singlePipe(),
        .flags = ((~@as(u32, timing.misc)) & 6) | @as(u32, if (timing.bpc == 6) 8 else 0),
        .mc_address = start.guard.boot_mc, .buffer_bytes = boot.byte_length };
}
pub const Owner = struct {
    self_address: usize = 0,
    core: ?*dc.Owner = null,
    table: clocks.Table = undefined,
    boot_mode: c.struct_r4dcn_mode = undefined,
    point: clocks.Point = .{},
    touched: bool = false,
    boot_lit: bool = false,
    boot_brightness: ?u16 = null,
    fingerprint: ?[32]u8 = null,
    failure: ?anyerror = null,
    restore_frame: u32 = 0,
    restore_observed_ns: u64 = 0,
    restored: bool = false,
    pub fn bind(self: *Owner, core: *dc.Owner, table: clocks.Table) !dc.Hooks {
        if (self.self_address != 0 or core.self_address != @intFromPtr(core) or core.phase != .planned or core.thread != 0 or
            core.panel_allocation.cpu_address == 0 or core.native == null or core.board == null or core.hooks != null) return error.State;
        const boot = try bootMode(core.board.?, core.native.?);
        if (boot.pipe != core.mode.pipe or boot.width != core.mode.width or boot.height != core.mode.height or core.mode.flags & 1 != 0 or
            table.dcf_khz != core.limits.dcf_khz or table.fabric_khz != core.limits.fabric_khz or table.soc_khz != core.limits.soc_khz) return error.Unconfirmed;
        self.* = .{ .self_address = @intFromPtr(self), .core = core, .table = table, .boot_mode = boot };
        return .{ .context = self.self_address, .prepare = prepare, .stop = stop, .restore = restore, .modeset = modeset };
    }
    fn from(raw: usize) *Owner { return @ptrFromInt(raw); }
    fn checked(result: c_int) !void {
        return switch (result) { 0 => {}, c.R4DCN_BUSY => error.Busy, c.R4DCN_TIMEOUT => error.Timeout,
            c.R4DCN_UNSUPPORTED => error.Unsupported, c.R4DCN_INVALID => error.Invalid, else => error.State };
    }
    fn enter(self: *Owner) !*dc.Owner {
        if (self.self_address != @intFromPtr(self)) return error.State;
        const core = self.core orelse return error.State;
        _ = try core.workerStorage();
        if (!core.native.?.firmwareReady()) return error.Unconfirmed;
        return core;
    }
    fn prepare(raw: usize, _: *const c.struct_r4dcn_plan, _: *const c.struct_r4dcn_limits) bool {
        const self = from(raw);
        self.prepareHardware() catch |err| { self.failure = err; return false; };
        return true;
    }
    fn stop(raw: usize) bool {
        const self = from(raw);
        if (!self.touched) return true;
        // The original DP blank routine retries transient MMIO failures and
        // proves stop before the other connector's pad-state checks.
        self.stopHardware() catch |err| { self.failure = err; return false; };
        if (self.core.?.hdmi_storage_valid) {
            const runtime: *@import("hdmi_runtime.zig").Runtime = @ptrFromInt(self.core.?.hdmi_allocation.cpu_address);
            if (runtime.self_address == @intFromPtr(runtime)) runtime.detachInactive() catch |err| { self.failure = err; return false; };
        }
        return true;
    }
    fn restore(raw: usize) bool {
        const self = from(raw);
        if (!self.touched) return self.core.?.native.?.bootMatches();
        self.restoreHardware() catch |err| { self.failure = err; return false; };
        return true;
    }
    fn modeset(raw: usize, request: dc.ModeRequest) bool {
        const self = from(raw);
        self.switchHardware(request) catch |err| { self.failure = err; return false; };
        return true;
    }
    fn switchHardware(self: *Owner, request: dc.ModeRequest) !void {
        const core = try self.enter(); const storage = try core.workerStorage(); const runtime = try core.workerPanel();
        if (!self.touched or self.restored or core.scanout_owner.phase != .active or core.scanout_owner.cursor_current.image != null) return error.State;
        var selected = request.mode;
        try self.selectMode(&runtime.protocol.?, &selected);
        if (!std.meta.eql(selected, request.mode)) return error.Unsupported;
        const brightness = if (runtime.protocol.?.brightness_known) runtime.protocol.?.brightness else self.boot_brightness orelse 65535;
        try self.stopHardware();
        try core.scanout_owner.stop(core.scanout_owner.epoch);
        try checked(c.r4dcn_quiesce(storage));
        try runtime.run(.hide, 0);
        try runtime.run(.discover, 0); try self.selectMode(&runtime.protocol.?, &selected);
        core.mode = selected;
        try checked(c.r4dcn_prepare(storage, &core.mode, 1, &core.plan));
        try self.applyClocks(core.plan);
        try runtime.run(.clock, 0); try runtime.run(.stream_configure, 0); try runtime.run(.train, 0);
        try checked(c.r4dcn_program(storage));
        core.scanout_owner = .{};
        try core.scanout_owner.bind(storage, request.epoch, core.mode, request.image);
        const now = core.clock.?.nowNs();
        const deadline = @min(request.deadline_ns, now + std.time.ns_per_s);
        try core.scanout_owner.enable(request.epoch, request.sequence, deadline);
        try runtime.run(.stream_on, 0);
        core.mode_receipt = null;
        for (0..1500) |_| {
            if (try core.scanout_owner.poll(request.epoch, core.clock.?.nowNs())) |receipt| {
                var video: u32 = 0; try checked(c.r4dcn_link_video(storage, 0, core.mode.pipe, &video));
                if (video != 1) return error.Unconfirmed;
                core.mode_receipt = receipt;
                try core.scanout_owner.acknowledge(request.epoch, request.sequence);
                try runtime.run(.show, brightness);
                return;
            }
            try core.workerDelay(1000);
        }
        return error.Timeout;
    }
    fn validateCommands(runtime: *@import("panel_runtime.zig").Runtime) !void {
        inline for (.{ .{ "setpixelclock", 1, 7 }, .{ "setdceclock", 2, 1 }, .{ "dig1transmittercontrol", 1, 6 } }) |entry| {
            const revision = try runtime.vm.revision(@offsetOf(bios.c.struct_atom_master_list_of_command_functions_v2_1, entry[0]) / 2);
            if (revision[0] != entry[1] or revision[1] != entry[2]) return error.Unsupported;
        }
    }
    fn selectMode(self: *Owner, p: *panel.Panel, mode: *c.struct_r4dcn_mode) !void {
        const wanted: edid.timing.Timing = .{ .width = mode.width, .height = mode.height, .h_total = mode.h_total, .v_total = mode.v_total,
            .h_start = mode.width + mode.h_front, .h_end = mode.width + mode.h_front + mode.h_sync,
            .v_start = mode.height + mode.v_front, .v_end = mode.height + mode.v_front + mode.v_sync,
            .clock_hz = @as(u64, mode.pixel_khz) * 1000, .flags = mode.flags & 6 };
        for (p.report.modes[0..p.report.mode_count]) |candidate| if (candidate.sameMode(wanted)) {
            if (candidate.flags & (edid.timing.interlaced | edid.timing.incomplete | edid.timing.y420_only) != 0) return error.Unsupported;
            p.mode = candidate;
            mode.flags = (mode.flags & ~@as(u32, 8)) | @as(u32, if (p.bpc == 6) 8 else 0);
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(p.edid_bytes[0..p.edid_length], &hash, .{});
            if (self.fingerprint) |old| { if (!std.mem.eql(u8, &old, &hash)) return error.Stale; } else self.fingerprint = hash;
            return;
        };
        return error.Unsupported;
    }
    fn prepareHardware(self: *Owner) !void {
        const core = try self.enter();
        const storage = try core.workerStorage();
        const runtime = try core.workerPanel();
        try validateCommands(runtime);
        if (!core.native.?.bootMatches()) return error.Unconfirmed;
        var active: u32 = 0;
        try checked(c.r4dcn_link_video(storage, 0, self.boot_mode.pipe, &active));
        if (active != 1) return error.Unsupported; // Boot must actually use this eDP route.
        var initial: c.struct_r4dcn_panel_state = undefined;
        try checked(c.r4dcn_panel_read(storage, &initial));
        if (initial.powered != 1) return error.Unconfirmed;
        self.boot_lit = initial.lit != 0;
        // Validate both original backing and candidate before the first write.
        var original_plan: c.struct_r4dcn_plan = undefined;
        try checked(c.r4dcn_prepare(storage, &self.boot_mode, 1, &original_plan));
        try checked(c.r4dcn_prepare(storage, &core.mode, 1, &core.plan));
        try checked(c.r4dcn_inherited_admit(storage));
        self.touched = true; self.restored = false;
        try self.stopHardware();
        try runtime.run(.discover, 0);
        const p = &runtime.protocol.?;
        if (p.brightness_known) self.boot_brightness = p.brightness;
        try self.selectMode(p, &self.boot_mode);
        try self.selectMode(p, &core.mode);
        try checked(c.r4dcn_prepare(storage, &core.mode, 1, &core.plan));
        try self.applyClocks(core.plan);
        try runtime.run(.clock, 0);
        try runtime.run(.stream_configure, 0);
        try runtime.run(.train, 0);
        // Core programs HUBBUB/MPC/frontend after this hook. The outer worker
        // enables TG, enables DP video and waits for the actual scanout receipt.
    }
    fn stopHardware(self: *Owner) !void {
        const core = try self.enter();
        const storage = try core.workerStorage();
        // Stream stop also retries sticky MMIO faults. No TG is disabled while
        // DP is waiting for its next VBlank to stop transmitting video.
        try checked(c.r4dcn_dp_stream_stop(storage, 0));
        try checked(c.r4dcn_link_action(storage, 0, c.R4DCN_BACKLIGHT_OFF));
        try checked(c.r4dcn_inherited_stop(storage));
        try checked(c.r4dcn_link_action(storage, 0, c.R4DCN_LINK_DISABLE));
    }
    fn applyClocks(self: *Owner, plan: c.struct_r4dcn_plan) !void {
        const core = try self.enter();
        const registers = &core.memory.?.registers;
        // Retry cleanup never reuses a response for an unknown submission.
        if (self.point.driver.active and !try self.point.driver.poll(registers, true)) return error.Busy;
        if (self.point.vbios.active and !try self.point.vbios.poll(registers, true)) return error.Busy;
        self.point = .{};
        try self.point.begin(registers, self.table, plan.disp_khz, true);
        for (0..3000) |_| {
            if (try self.point.step(registers)) {
                const actual = self.point.actual_disp_khz;
                const dpp = if (plan.dpp_khz <= plan.disp_khz / 2) actual / 2 else actual;
                if (actual < plan.disp_khz or actual > core.limits.disp_khz or dpp < plan.dpp_khz or dpp > core.limits.dpp_khz) return error.Unconfirmed;
                return;
            }
            try core.workerDelay(1000);
        }
        return error.Timeout;
    }
    fn restoreHardware(self: *Owner) !void {
        const core = try self.enter();
        const storage = try core.workerStorage();
        const runtime = try core.workerPanel();
        self.restored = false;
        try checked(c.r4dcn_quiesce(storage));
        try runtime.run(.hide, 0);
        try runtime.run(.discover, 0);
        try self.selectMode(&runtime.protocol.?, &self.boot_mode);
        var plan: c.struct_r4dcn_plan = undefined;
        try checked(c.r4dcn_prepare(storage, &self.boot_mode, 1, &plan));
        try self.applyClocks(plan);
        try runtime.run(.clock, 0);
        try runtime.run(.stream_configure, 0);
        try runtime.run(.train, 0);
        try checked(c.r4dcn_program(storage));
        try checked(c.r4dcn_scanout_enable(storage, self.boot_mode.pipe));
        try runtime.run(.stream_on, 0);
        try self.confirmBootImage();
        if (self.boot_lit) try runtime.run(.show, self.boot_brightness orelse runtime.protocol.?.brightness);
        // The original startup guard is not overwritten. Cleanup later checks
        // this independently captured, physically observed compatible layout.
        var captured: @import("start_guard.zig").Guard = .{};
        try captured.capture(&core.memory.?.registers, self.boot_mode.mc_address, self.boot_mode.pitch_bytes);
        try core.native.?.adoptDisplayRestore(core.native.?.hold.held_generation, captured);
        self.restored = true;
    }
    fn confirmBootImage(self: *Owner) !void {
        const core = try self.enter();
        const storage = try core.workerStorage();
        const begin = core.clock.?.nowNs();
        var first: ?u32 = null;
        var previous: u64 = begin;
        for (0..2000) |_| {
            var sample: c.struct_r4dcn_scanout_sample = undefined;
            const result = c.r4dcn_scanout_sample(storage, self.boot_mode.pipe, &sample);
            if (result != c.R4DCN_BUSY) {
                try checked(result);
                if (sample.begin_ns < previous or sample.end_ns < sample.begin_ns or sample.underflow != 0) return error.Unconfirmed;
                if (sample.end_ns - begin >= 2 * std.time.ns_per_s) return error.Timeout;
                previous = sample.end_ns;
                var video: u32 = 0;
                try checked(c.r4dcn_link_video(storage, 0, self.boot_mode.pipe, &video));
                if (sample.running == 1 and sample.blank == 0 and sample.locked == 0 and sample.pending == 0 and video == 1 and
                    sample.requested_address == self.boot_mode.mc_address and sample.inuse_address == self.boot_mode.mc_address) {
                    if (first) |frame| {
                        const delta = (sample.frame -% frame) & 0xffffff;
                        if (delta >= 0x800000) return error.Stale;
                        if (delta != 0) { self.restore_frame = sample.frame; self.restore_observed_ns = sample.end_ns; return; }
                    } else first = sample.frame;
                }
            }
            try core.workerDelay(1000);
        }
        return error.Timeout;
    }
};
