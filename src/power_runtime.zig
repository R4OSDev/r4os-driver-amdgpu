// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! One queue-worker owner coordinates GC power and finite telemetry demand.
//! DCN stays independent; every VM/BO/queue operation first needs awake GC.
const std = @import("std");
const c = @import("start_common.zig");
const sr = @import("start_registers.zig");
const jobs = @import("sdma_jobs.zig");
pub const Owner = struct {
    gfx: @import("power_gfx.zig").Owner = .{},
    telemetry: @import("power_telemetry.zig").Owner = .{},
    started: bool = false, ready: bool = false, restored: bool = false,
    sdma_saved: [2]u32 = .{ 0, 0 }, sdma_touched: bool = false,
    activity: u64 = 0, idle_since: u64 = 0, last_time: u64 = 0,
    pub fn prepare(self: *Owner, owner: *jobs.Owner, native: *const @import("start_runtime.zig").Owner) c.Error!bool {
        if (self.ready) return true;
        const memory = owner.memory.?; const io = &memory.registers;
        if (!self.started) {
            if (owner.active or owner.graphics == null or owner.graphics.?.engine.phase != .ready or
                owner.media == null or !owner.media.?.verified or !native.firmwareReady()) return error.Unconfirmed;
            self.started = true;
            self.telemetry.configure(memory.adapter, memory.epoch, native.flow.smu_version_raw);
            self.sdma_saved = .{ try c.read(io, sr.sdma.SDMA0_CLK_CTRL), try c.read(io, sr.sdma.SDMA0_POWER_CNTL) };
            self.sdma_touched = true;
            // SDMA4.1 medium-grain clocks and memory light sleep. The active
            // display retains SDMA; whole-engine power-down belongs to close.
            try c.set(io, sr.sdma.SDMA0_CLK_CTRL, 0xff000000, 0);
            try c.set(io, sr.sdma.SDMA0_POWER_CNTL, sr.sdma.SDMA0_POWER_CNTL__MEM_POWER_OVERRIDE_MASK, sr.sdma.SDMA0_POWER_CNTL__MEM_POWER_OVERRIDE_MASK);
            try self.gfx.begin(io, !@import("power_gfx.zig").quirk(native.snapshot));
        }
        try self.gfx.step(io, true, false, false);
        if (!self.gfx.awake()) return false;
        try self.telemetry.step(io);
        if (self.telemetry.phase != .ready) return false;
        self.last_time = io.nowNs(); self.idle_since = self.last_time;
        var text: [192]u8 = undefined;
        const message = std.fmt.bufPrintZ(&text, "AMDGPU power: SMU=0x{x} factory-GFX={d}..{d}MHz limits={s} GFXOFF={s} APU-budget=firmware-owned", .{
            native.flow.smu_version_raw, self.telemetry.min_mhz, self.telemetry.max_mhz,
            if (self.telemetry.min_mhz != 0 and self.telemetry.max_mhz != 0) "known" else "unknown",
            if (self.gfx.gfxoff_supported) "idle-controlled" else "board-quirk-disabled" }) catch return error.Capacity;
        native.ctx.?.logInfo(message);
        self.ready = true; return true;
    }
    pub fn awake(self: *const Owner) bool {
        // Fixtures without a power owner preserve their original execution.
        return !self.started or self.restored or (self.ready and self.gfx.awake());
    }
    fn retained(owner: *jobs.Owner) bool {
        if (!owner.runtime.?.timeline.empty()) return true;
        for (&owner.jobs) |*job| if (job.owner != null) return true;
        if (owner.graphics) |gc| {
            for (&gc.contexts.jobs) |*job| if (job.owner != null) return true;
            for (&gc.renderer.jobs) |*job| if (job.owner != null) return true;
            if (gc.renderer.allocations.pending != null or gc.renderer.virtual.pending != null) return true;
            for (&gc.engine.rings) |*ring| if (ring.read != ring.write) return true;
        }
        if (owner.engine.ring.read != owner.engine.ring.write) return true;
        if (owner.media) |media| for (&media.engine.rings) |*ring| { if (ring.read != ring.write) return true; };
        return false;
    }
    pub fn step(self: *Owner, owner: *jobs.Owner) c.Error!void {
        if (!self.ready or self.restored) return;
        const io = &owner.memory.?.registers;
        const now = io.nowNs();
        if (now < self.last_time or now == std.math.maxInt(u64)) return error.Deadline;
        self.last_time = now;
        if (!self.awake()) if (owner.client) |client| if (client.sleep_poll) |poll| poll(client.context);
        const sequence = @atomicLoad(u64, &owner.runtime.?.activity_sequence, .acquire);
        const client_idle = if (owner.client) |client| if (client.idle) |idle| idle(client.context) else false else true;
        const busy = sequence != self.activity or retained(owner) or !client_idle;
        if (busy) self.idle_since = now;
        // Retain each notification until GC is awake and a normal worker pass
        // can consume it. IRQ hints never masquerade as new canonical work.
        if (self.awake()) self.activity = sequence;
        const idle = !busy and now - self.idle_since >= 2 * std.time.ns_per_s;
        try self.gfx.step(io, busy, idle, false);
        // Power messages have priority over optional read-only samples. A
        // sensor failure invalidates telemetry; it does not invent a GPU loss.
        self.telemetry.step(io) catch {};
        const policy: u32 = if (self.gfx.allowed) 0 else if (!self.gfx.awake()) 1 else if (retained(owner)) 4 else if (owner.client != null) 2 else 0;
        self.telemetry.exchange(owner.memory.?.memory.?, io, policy) catch { self.telemetry.failed = true; };
    }
    pub fn close(self: *Owner, owner: *jobs.Owner) bool {
        if (!self.started or self.restored) return true;
        const io = &owner.memory.?.registers;
        if (!self.telemetry.drain(io)) return false;
        self.telemetry.exchange(owner.memory.?.memory.?, io, 9) catch {};
        self.gfx.step(io, true, false, true) catch {};
        // Both channels can already own a reply; advance both without cyclic
        // waits, and retire media resources only after GC is confirmed awake.
        if (owner.media) |media| if (!media.quiet()) return false;
        if (self.gfx.touched and self.gfx.phase != .closed) return false;
        if (self.sdma_touched) {
            io.write(sr.sdma.SDMA0_CLK_CTRL, self.sdma_saved[0]) catch return false;
            io.write(sr.sdma.SDMA0_POWER_CNTL, self.sdma_saved[1]) catch return false;
            self.sdma_touched = false;
        }
        self.restored = true; return true;
    }
};
