// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! VCN1 owns one pre-budgeted UMA arena. Only the start pump, then the common
//! worker, may mutate it. IRQs provide hints; GPU writeback proves completion.
const std = @import("std");
const c = @import("start_common.zig");
const q = @import("queue_timeline.zig");
const qr = @import("queue_ring.zig");
const ve = @import("vcn_engine.zig");
const packets = @import("vcn_packets.zig");
const mem = @import("memory_owner.zig");
pub const Owner = struct {
    self_address: usize = 0, memory: ?*mem.Owner = null,
    runtime: ?*@import("queue_runtime.zig").Owner = null,
    engine: ve.Owner = .{}, window: @import("memory_io.zig").Window = .{},
    epoch: u64 = 0, gpu: u64 = 0, started_test: bool = false, verified: bool = false, closed: bool = false,
    test_deadline: c.Deadline = .{},
    idle_since: u64 = 0, gated: bool = false, wake_requested: bool = false,
    power_phase: enum { active, stopping, sleeping, starting } = .active,
    saved_setup: ?ve.Setup = null,

    pub fn words32(self: *const Owner, offset: usize, bytes: usize) c.Error![]volatile u32 {
        if (self.self_address != @intFromPtr(self) or self.closed or !@import("memory_io.zig").handle(self.window.value.handle) or
            offset & 3 != 0 or bytes == 0 or bytes & 3 != 0 or offset >= self.window.value.byte_length or bytes > self.window.value.byte_length - offset) return error.Invalid;
        const ptr: [*]volatile u32 = @ptrFromInt(self.window.value.cpu_address + offset); return ptr[0..bytes / 4];
    }
    pub fn prepare(self: *Owner, memory: *mem.Owner, runtime: *@import("queue_runtime.zig").Owner,
        native: *const @import("start_runtime.zig").Owner, graphics: *@import("gc_runtime.zig").Owner) c.Error!void {
        if (self.self_address != 0 or !native.firmwareReady() or native.memory != memory or !memory.controller.enabled or
            runtime.started or !runtime.arena.ready or runtime.arena.memory != memory or graphics.engine.phase != .ready) return error.Unconfirmed;
        const map = memory.layout.?;
        if (map.media.span.bytes != 1024 * 1024 or !map.pool.owns(map.media)) return error.Invalid;
        const entry = native.flow.plan.entries[12];
        if (entry.role != .vcn or !entry.confirmed or entry.address == 0 or entry.version != @import("firmware.zig").specification(.vcn).ucode_version) return error.Firmware;
        // Linux's firmware cache includes the original header + one dword,
        // rounded to a GPU page. PSP returns the authenticated code location.
        const container = native.flow.store.?.container(.vcn) orelse return error.Firmware;
        const fw_bytes: u32 = @intCast(try @import("memory_layout.zig").aligned(container.len + 4, 4096));
        const view = native.flow.view.?;
        if (entry.address + fw_bytes > view.address(view.tmr_offset) + @import("start_storage.zig").tmr_bytes) return error.Firmware;
        self.self_address = @intFromPtr(self); self.memory = memory; self.runtime = runtime; self.epoch = memory.epoch;
        memory.engine_users += 1;
        self.gpu = try map.mcAddress(map.media.span);
        try self.window.open(memory.memory.?, map.physical.offset, map.physical.bytes, map.media.span.offset, map.media.span.bytes, true);
        const words = try self.words32(0, 1024 * 1024); for (words) |*word| word.* = 0;
        try c.hdpFlush(&memory.registers);
        var rings: [3]u64 = undefined;
        for (&rings, 0..) |*address, i| address.* = self.gpu + ve.ringOffset(@enumFromInt(i + 3));
        try self.engine.begin(&memory.registers, self, .{ .epoch = self.epoch, .firmware = entry.address,
            .firmware_bytes = fw_bytes, .workspace = self.gpu, .ring = rings, .gb_addr_config = graphics.engine.gb_addr_config, .boot_held = true });
    }
    pub fn advance(self: *Owner) c.Error!bool {
        if (self.self_address != @intFromPtr(self) or self.closed or self.runtime.?.started or self.memory.?.epoch != self.epoch) return error.State;
        if (self.verified) return true;
        const io = &self.memory.?.registers;
        if (!try self.engine.advance(io)) return false;
        if (!self.started_test) {
            const words = try self.words32(ve.test_offset, 24); for (words) |*word| word.* = 0xffffffff;
            try self.test_deadline.start(io.nowNs(), 2_000_000_000, 0);
            self.started_test = true;
            for (0..3) |i| {
                const engine: qr.Engine = @enumFromInt(i + 3);
                var commands: [packets.max_words]u32 = undefined;
                const count = try packets.frame(engine, null, self.gpu + ve.test_offset + i * 8, @as(u32, 0x56434e01) + @as(u32, @intCast(i)), self.gpu + ve.ringOffset(engine), &commands);
                const ticket = try self.engine.stage(engine, commands[0..count]);
                try self.engine.kick(io, engine, ticket);
            }
            return false;
        }
        _ = try self.test_deadline.check(io.nowNs()); try c.hdpInvalidate(io); try self.engine.observe(io);
        const words = try self.words32(ve.test_offset, 24);
        for (0..3) |i| {
            const token = @as(u32, 0x56434e01) + @as(u32, @intCast(i));
            const first = words[i * 2]; try io.barrier(); const second = words[i * 2];
            if (first != token or second != token or self.engine.rings[i].read != self.engine.rings[i].write) return false;
        }
        self.verified = true; return true;
    }
    pub fn poll(self: *Owner) void {
        if (!self.verified or self.closed or self.engine.faulted) return;
        self.powerStep() catch { self.engine.faulted = true; self.runtime.?.timeline.fault(qr.media_engines); };
    }
    fn occupied(self: *const Owner) bool {
        for (&self.runtime.?.timeline.entries) |*entry| if (entry.phase != .free and qr.isMedia(entry.engine)) return true;
        for (&self.engine.rings) |*ring| if (ring.read != ring.write) return true;
        return false;
    }
    fn powerStep(self: *Owner) c.Error!void {
        const io = &self.memory.?.registers;
        const now = io.nowNs();
        switch (self.power_phase) {
            .active => {
                if (self.engine.stopping) return;
                if (!self.gated) try self.engine.observe(io);
                if (self.wake_requested or self.occupied()) {
                    self.idle_since = now; self.wake_requested = false;
                    if (self.gated) { try @import("vcn_clocks.zig").enable(io); self.gated = false; }
                    return;
                }
                if (self.idle_since == 0) self.idle_since = now;
                if (now < self.idle_since) return error.Deadline;
                if (!self.gated and now - self.idle_since >= 100 * std.time.ns_per_ms) {
                    try @import("vcn_clocks.zig").gate(io); self.gated = true;
                }
                if (now - self.idle_since >= 2 * std.time.ns_per_s) {
                    if (self.gated) { try @import("vcn_clocks.zig").enable(io); self.gated = false; }
                    self.saved_setup = self.engine.setup;
                    self.power_phase = .stopping;
                }
            },
            .stopping => if (try self.engine.stop(io)) { self.power_phase = .sleeping; },
            .sleeping => if (self.wake_requested) {
                // Firmware context/DPB backing stays retained in the same UMA
                // workspace. Only ring state is rebuilt, as in VCN1 stop/start.
                // Do not reset a mailbox whose PowerUp response is uncertain.
                if (@atomicLoad(usize, &io.smu_owner, .acquire) != 0) return;
                self.engine = .{};
                self.power_phase = .starting;
                try self.engine.begin(io, self, self.saved_setup orelse return error.State);
            },
            .starting => if (try self.engine.advance(io)) {
                try self.engine.interrupts(io);
                self.power_phase = .active; self.wake_requested = false; self.idle_since = now;
            },
        }
    }
    pub fn canSubmit(self: *Owner, engine: qr.Engine) c.Error!bool {
        if (!self.verified or self.closed or self.engine.faulted or
            self.memory.?.epoch != self.epoch or !qr.isMedia(engine)) return error.Unsupported;
        self.wake_requested = true;
        if (self.power_phase != .active) return false;
        if (self.engine.stopping) return error.Unsupported;
        if (self.gated) {
            try @import("vcn_clocks.zig").enable(&self.memory.?.registers); self.gated = false;
        }
        const timeline = &self.runtime.?.timeline;
        if (timeline.stopping or timeline.failed_engines != 0) return error.Unconfirmed;
        // Linux vcn1_jpeg1_workaround: JPEG and both video engines must never
        // overlap. RPTR alone is insufficient; retain the exclusion until the
        // exact fence and resource retirement have completed.
        for (&timeline.entries) |*entry| if (entry.phase != .free and qr.isMedia(entry.engine) and
            (engine == .jpeg) != (entry.engine == .jpeg)) return false;
        return true;
    }
    pub fn submit(self: *Owner, engine: qr.Engine, fence: @import("r4os").abi.GfxFence, ib: packets.Ib,
        jpeg_commands: []const u32, deadline: u64, resources: q.Resources) c.Error!void {
        if (!try self.canSubmit(engine)) return error.Busy;
        if ((engine == .jpeg and (jpeg_commands.len != ib.dwords or jpeg_commands.len == 0 or jpeg_commands.len > 2048)) or
            (engine != .jpeg and jpeg_commands.len != 0)) return error.Invalid;
        const rt = self.runtime.?;
        const ticket = try rt.timeline.reserve(fence, engine, deadline, resources);
        var armed = false;
        errdefer { if (!armed) rt.timeline.cancelUnsubmitted(ticket) catch {} else rt.timeline.fault(qr.media_engines); }
        var indirect = ib;
        if (engine == .jpeg) {
            // JPEG1 fetches its IB with VMID0; picture/stream BARs use VMID1.
            // A timeline-owned slot retains this copied IB through uncertainty.
            const dst = try rt.arena.ib(ticket.slot);
            for (jpeg_commands, dst[0..jpeg_commands.len]) |word, *target| target.* = word;
            indirect.address = try rt.arena.address(@import("queue_storage.zig").ib_offset +
                @as(usize, ticket.slot) * @import("queue_storage.zig").ib_bytes, jpeg_commands.len * 4);
            try c.hdpFlush(&self.memory.?.registers);
        }
        var commands: [packets.max_words]u32 = undefined;
        const count = try packets.frame(engine, indirect, try rt.arena.address(@import("queue_storage.zig").fence_offset + @as(usize, ticket.slot) * 8, 8), @intCast(ticket.token), self.gpu + ve.ringOffset(engine), &commands);
        const staged = try self.engine.stage(engine, commands[0..count]);
        rt.timeline.arm(ticket) catch |err| { self.engine.rings[@intFromEnum(engine) - 3].cancel(staged) catch {}; return err; };
        armed = true;
        try self.engine.kick(&self.memory.?.registers, engine, staged);
    }
    /// Hardware-only stop; no callbacks/PTE releases while GC may be asleep.
    pub fn quiet(self: *Owner) bool {
        if (self.self_address == 0 or self.closed) return true;
        if (self.gated) {
            @import("vcn_clocks.zig").enable(&self.memory.?.registers) catch return false;
            self.gated = false;
        }
        return self.engine.stop(&self.memory.?.registers) catch false;
    }
    /// Invoke before GC renderer teardown: media fence callbacks retain its
    /// canonical bindings until the VCN idle/LMI/reset/power proof is complete.
    pub fn close(self: *Owner) bool {
        if (self.self_address == 0 or self.closed) return true;
        if (self.self_address != @intFromPtr(self) or self.memory.?.epoch != self.epoch) return false;
        if (!self.quiet()) return false;
        const rt = self.runtime.?;
        if (rt.timeline.self_address != 0) {
            rt.timeline.abort(.{ .epoch = rt.timeline.epoch, .engines = qr.media_engines }, @import("r4os").abi.gfx_queue_result_device_lost) catch return false;
            if (!rt.timeline.publish(rt.queue.?)) return false;
        }
        if (!self.window.close()) return false;
        self.memory.?.engine_users -= 1; self.closed = true; self.verified = false; return true;
    }
};
