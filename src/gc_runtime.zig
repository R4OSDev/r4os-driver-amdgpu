// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! The GC owner shares SDMA's resident arena and canonical timeline. All its
//! mutable methods run in the start pump or, after activation, the one driver
//! worker. IRQ callbacks never enter this owner.
const c = @import("start_common.zig");
const mem = @import("memory_owner.zig");
const q = @import("queue_timeline.zig");
pub const Owner = struct {
    self_address: usize = 0, memory: ?*mem.Owner = null, runtime: ?*@import("queue_runtime.zig").Owner = null,
    engine: @import("gc_engine.zig").Owner = .{}, closed: bool = false,
    contexts: @import("gc_contexts.zig").Owner = .{},
    pub fn prepare(self: *Owner, memory: *mem.Owner, runtime: *@import("queue_runtime.zig").Owner,
        native: *const @import("start_runtime.zig").Owner, sdma: *@import("sdma_jobs.zig").Owner) c.Error!void {
        if (self.self_address != 0 or !native.firmwareReady() or native.memory != memory or !memory.controller.enabled or
            !sdma.verified or sdma.active or sdma.memory != memory or sdma.runtime != runtime or sdma.graphics != null or
            runtime.started or !runtime.arena.ready or runtime.arena.memory != memory or runtime.arena.epoch != memory.epoch) return error.Unconfirmed;
        self.self_address = @intFromPtr(self); self.memory = memory; self.runtime = runtime; sdma.graphics = self;
        try self.engine.begin(&memory.registers, &runtime.arena, .{ .firmware_ready = true, .boot_held = true, .gmc_enabled = true });
    }
    pub fn advance(self: *Owner) c.Error!bool {
        if (self.self_address != @intFromPtr(self) or self.closed or self.runtime.?.started) return error.State;
        return self.engine.advance(&self.memory.?.registers, &self.runtime.?.arena);
    }
    pub fn irqReady(self: *Owner) c.Error!void {
        try self.contexts.init(self.runtime.?.timeline.epoch);
        try self.engine.interrupts(&self.memory.?.registers);
    }
    pub fn poll(self: *Owner) void {
        if (self.self_address != @intFromPtr(self) or self.closed) return;
        if (self.engine.phase != .ready or self.engine.faulted or self.engine.stop_started) return;
        self.engine.observe(&self.memory.?.registers, &self.runtime.?.arena) catch { self.engine.faulted = true; self.runtime.?.timeline.fault(6); };
    }
    pub fn work(self: *Owner) void { if (!self.closed) self.contexts.step(self.runtime.?, &self.engine); }
    pub fn quiesce(self: *Owner, epoch: q.Epoch) ?q.Quiescence {
        if (!@import("std").meta.eql(epoch, self.runtime.?.timeline.epoch) or !self.close()) return null;
        return .{ .epoch = epoch, .engines = 6 };
    }
    /// Caller has joined the worker, or is that worker's error path. SDMA
    /// remains independently owned; only its enclosing owner releases arena.
    pub fn close(self: *Owner) bool {
        if (self.self_address == 0 or self.closed) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        self.contexts.stopping = true;
        if (!(self.engine.stop(&self.memory.?.registers, &self.runtime.?.arena) catch false)) return false;
        const rt = self.runtime.?;
        if (rt.timeline.self_address != 0) {
            rt.timeline.abort(.{ .epoch = rt.timeline.epoch, .engines = 6 }, @import("r4os").abi.gfx_queue_result_device_lost) catch return false;
            _ = rt.timeline.publish(rt.queue.?);
        }
        if (!self.contexts.collect(rt)) return false;
        self.closed = true; return true;
    }
};
