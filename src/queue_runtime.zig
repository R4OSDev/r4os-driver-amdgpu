// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const q = @import("queue_timeline.zig");
const ih = @import("queue_ih.zig");
pub const Error = q.Error;
/// Engine/IP owners implement these worker-only hooks. No IRQ callback may
/// submit commands or assert engine quiescence. Native start wires them in /9+.
pub const Hooks = struct {
    context: usize,
    work: *const fn (*Owner, usize) void,
    before_poll: ?*const fn (*Owner, usize) void = null,
    irq_ready: ?*const fn (usize) Error!void = null,
    event: *const fn (usize, ih.Event) void,
    quiesce: *const fn (usize, q.Epoch, @import("queue_ring.zig").EngineMask) ?q.Quiescence,
};
pub const Owner = struct {
    self_address: usize = 0, ctx: ?r4os.r4dev.DriverContext = null,
    memory: ?*@import("memory_owner.zig").Owner = null,
    queue: ?r4os.driver_queue.Context = null, threads: ?r4os.r4dev.DriverThreadContext = null,
    semaphores: ?r4os.r4dev.DriverSemaphoreContext = null, clock: ?r4os.r4dev.DriverResourceContext = null,
    arena: @import("queue_storage.zig").Owner = .{}, irq: @import("queue_irq.zig").Owner = .{}, timeline: q.Timeline = .{},
    hooks: ?Hooks = null, semaphore: u64 = 0, thread: u64 = 0,
    stop: u32 = 0, wake_fault: u32 = 0, poll_ticks: u64 = 1, prepared: bool = false, started: bool = false,
    notify_state: u32 = 0x80000000, closed: bool = false,
    thread_stop_requested: bool = false, thread_joined: bool = false, worker_result: i32 = 0,
    pub fn prepare(self: *Owner, ctx: *const r4os.r4dev.DriverContext, memory: *@import("memory_owner.zig").Owner,
        snapshot: *const @import("identity.zig").Snapshot, binding: a.GfxBackendBinding, gate: @import("memory_hubs.zig").Gate) Error!void
    {
        if (self.self_address != 0) return error.Busy;
        const epoch = try q.Epoch.from(binding);
        if (memory.adapter != epoch.adapter or gate.memory_epoch != memory.epoch) return error.Invalid;
        self.self_address = @intFromPtr(self); self.ctx = ctx.*; self.memory = memory;
        self.queue = ctx.graphicsQueue() orelse return error.Unsupported;
        self.threads = ctx.threads() orelse return error.Unsupported;
        self.semaphores = ctx.semaphores() orelse return error.Unsupported;
        self.clock = ctx.resources() orelse return error.Unsupported;
        const hz = ctx.timerFrequency(); if (hz == 0) return error.Unsupported;
        self.poll_ticks = @max(@as(u64, 1), (@as(u64, hz) + 99) / 100); // at most 10ms, rounded to host tick
        if (!self.arena.ready) {
            try self.arena.prepare(memory, snapshot.bars[2], gate);
        } else if (self.arena.memory != memory or self.arena.epoch != memory.epoch or self.arena.self_address != @intFromPtr(&self.arena) or
            self.arena.doorbell.value.physical_address != snapshot.bars[2].base) return error.Stale;
        try self.timeline.init(binding, try self.arena.fences(), self.clock.?.nowNs());
        if (self.semaphores.?.create(0, 1, &self.semaphore) != 0 or self.semaphore == 0) return error.Capacity;
        self.prepared = true;
        @atomicStore(u32, &self.notify_state, 0, .release);
    }
    /// Native init calls this only with confirmed GMC/engine setup and held
    /// boot ownership. It does not advertise any application capability.
    pub fn start(self: *Owner, snapshot: *const @import("identity.zig").Snapshot, hooks: Hooks) Error!void {
        if (!self.prepared or self.started or self.self_address != @intFromPtr(self) or @atomicLoad(u32, &self.stop, .acquire) != 0) return error.Busy;
        self.hooks = hooks;
        try self.irq.open(&self.ctx.?, &self.arena, snapshot, self.timeline.epoch, .{ .context = self.self_address, .signal = signal });
        if (hooks.irq_ready) |ready| try ready(hooks.context);
        // Set before creation: the task may start on another CPU immediately.
        self.started = true;
        if (self.threads.?.start(worker, self.self_address, a.driver_thread_flag_parallel, &self.thread) != 0 or self.thread == 0) return error.Capacity;
    }
    pub fn signal(raw: usize) void {
        const self: *Owner = @ptrFromInt(raw);
        if (self.self_address != raw or self.semaphore == 0) return;
        const result = self.semaphores.?.release(self.semaphore);
        // One queued permit already covers additional IRQ/job notifications.
        if (result != 0 and result != a.driver_semaphore_error_overflow) @atomicStore(u32, &self.wake_fault, 1, .release);
    }
    pub fn notify(raw: usize) callconv(.c) void {
        const self: *Owner = @ptrFromInt(raw);
        // The canonical backend callback can race shutdown independently of
        // IH delivery. Atomically close admission and retain existing calls.
        for (0..4) |_| {
            const state = @atomicLoad(u32, &self.notify_state, .acquire);
            if (state & 0x80000000 != 0 or state == 0x7fffffff) return;
            if (@cmpxchgStrong(u32, &self.notify_state, state, state + 1, .acq_rel, .acquire) == null) {
                defer _ = @atomicRmw(u32, &self.notify_state, .Sub, 1, .release);
                signal(raw); return;
            }
        }
        // Lost coalesced hints are covered by the worker's periodic queue poll.
    }
    pub fn step(self: *Owner) void {
        const hooks = self.hooks orelse return;
        // Bounded work, no callback under IRQ gate. Poll also handles lost IRQs
        // and mailbox backpressure without claiming that either completed work.
        for (0..4) |_| {
            const captured = self.irq.poll();
            for (0..128) |_| {
                const event = self.irq.mailbox.pop() orelse break;
                if (!std.meta.eql(event.epoch, self.timeline.epoch)) continue;
                self.timeline.fault(event.faultMask()); hooks.event(hooks.context, event);
            }
            if (captured < 32) break;
        }
        if (self.irq.failed() or @atomicLoad(u32, &self.wake_fault, .acquire) != 0) self.timeline.fault(@import("queue_ring.zig").all_engines);
        if (hooks.before_poll) |before| before(self, hooks.context);
        self.timeline.poll(self.clock.?.nowNs());
        const failed = self.timeline.failed_engines;
        if (failed != 0) if (hooks.quiesce(hooks.context, self.timeline.epoch, failed)) |proof| {
            self.timeline.abort(proof, a.gfx_queue_result_device_lost) catch {};
        };
        _ = self.timeline.publish(self.queue.?);
        if (self.timeline.failed_engines == 0 and @atomicLoad(u32, &self.stop, .acquire) == 0) hooks.work(self, hooks.context);
    }
    fn worker(raw: usize) callconv(.c) i32 {
        const self: *Owner = @ptrFromInt(raw);
        if (self.self_address != raw or !self.prepared or !self.started) return -1;
        while (@atomicLoad(u32, &self.stop, .acquire) == 0) {
            self.step();
            if (@atomicLoad(u32, &self.stop, .acquire) != 0) break;
            const result = self.semaphores.?.acquire(self.semaphore, self.poll_ticks);
            if (result != 0 and result != a.driver_semaphore_error_timeout) {
                if (@atomicLoad(u32, &self.stop, .acquire) == 0) {
                    @atomicStore(u32, &self.wake_fault, 1, .release);
                    @atomicStore(u32, &self.stop, 1, .release);
                    // Attempt bounded recovery in this owning task before
                    // returning. Unproved DMA/failed release remains retained
                    // for the outer native-init/reset owner's close path.
                    self.timeline.stopping = true;
                    self.timeline.fault(@import("queue_ring.zig").all_engines); self.step();
                }
                return result;
            }
        }
        return 0;
    }
    /// Nonblocking shutdown. Stop/join/release retains the task and all arenas
    /// on busy/failure; no spinlock or IRQ admission gate spans those calls.
    pub fn stopWorker(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        if (self.closed) return true;
        _ = @atomicRmw(u32, &self.notify_state, .Or, 0x80000000, .acq_rel);
        if (@atomicLoad(u32, &self.notify_state, .acquire) & 0x7fffffff != 0) return false;
        @atomicStore(u32, &self.stop, 1, .release);
        if (self.thread != 0) {
            if (!self.thread_stop_requested) {
                if (self.threads.?.stop(self.thread) != 0) return false;
                self.thread_stop_requested = true;
            }
            if (!self.thread_joined) {
                if (self.threads.?.join(self.thread, 0, &self.worker_result) != 0) return false;
                self.thread_joined = true;
            }
            if (self.threads.?.release(self.thread) != 0) return false;
            self.thread = 0;
        }
        return true;
    }
    pub fn close(self: *Owner, proof: ?q.Quiescence) bool {
        if (!self.stopWorker()) return false;
        if (self.self_address == 0 or self.closed) return true;
        if (self.timeline.self_address != 0) {
            self.timeline.stopping = true;
            if (self.started or !self.timeline.empty()) {
                const stopped = proof orelse return false;
                if (stopped.engines != @import("queue_ring.zig").all_engines or !std.meta.eql(stopped.epoch, self.timeline.epoch)) return false;
                self.timeline.abort(stopped, a.gfx_queue_result_cancelled) catch return false;
            }
            if (!self.timeline.publish(self.queue.?) or !self.timeline.empty()) return false;
        }
        if (!self.irq.close()) return false;
        if (self.semaphore != 0) {
            if (self.semaphores.?.destroy(self.semaphore) != 0) return false;
            self.semaphore = 0;
        }
        if (!self.arena.close(true)) return false;
        // Keep the closed notification gate resident until the native owner
        // unregisters the canonical backend. Only then may it reset/reuse this
        // entire owner or allow module unload. There are no remaining handles.
        self.closed = true; return true;
    }
};
