// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Driver-worker-owned logical contexts and bounded CP submissions. Provider
//! code retains every BO/PTE/DMA/scratch dependency before enqueue transfers
//! that resource owner here. No user callback is invoked from an IRQ or lock.
const std = @import("std");
const a = @import("r4os").abi;
const c = @import("start_common.zig");
const l = @import("gc_layout.zig");
const p = l.p;
const q = @import("queue_timeline.zig");
const runtime = @import("queue_runtime.zig");
const storage = @import("queue_storage.zig");
pub const Priority = enum(u2) { high, normal, low };
pub const Handle = struct { slot: u8, generation: u64, epoch: q.Epoch };
const Context = struct { live: bool = false, generation: u64 = 0, engine: p.Engine = .gfx,
    priority: Priority = .normal, resources: p.Resources = .{}, jobs: u32 = 0 };
const Job = struct {
    owner: ?*Owner = null, context: Handle = undefined, resources: ?q.Resources = null, fence: a.GfxFence = .{},
    ticket: ?q.Ticket = null, retired: bool = false, failed: bool = false, serial: u64 = 0,
    age: u64 = 0, deadline: u64 = 0, count: usize = 0, words: [p.max_ib_words]u32 = undefined,
    fn retire(raw: usize, fence: a.GfxFence) bool {
        const self: *Job = @ptrFromInt(raw); const owner = self.owner orelse return false;
        if (!std.meta.eql(self.fence, fence)) return false;
        if (self.retired) return true;
        const ctx = owner.context(self.context) catch return false;
        if (ctx.jobs == 0 or !self.resources.?.retire(self.resources.?.context, fence)) return false;
        ctx.jobs -= 1; self.retired = true; return true;
    }
    fn reset(self: *Job) void { self.owner = null; self.resources = null; self.ticket = null; self.retired = false; self.failed = false; }
};
pub const Owner = struct {
    self_address: usize = 0, epoch: q.Epoch = .{ .adapter = 0, .device = 0, .reset = 0 },
    contexts: [8]Context = @splat(.{}), jobs: [8]Job = @splat(.{}), gds: u16 = 0,
    generation: u64 = 0, serial: u64 = 0, dispatches: u64 = 0, stopping: bool = false,
    pub fn init(self: *Owner, epoch: q.Epoch) c.Error!void {
        if (self.self_address != 0 or epoch.adapter == 0 or epoch.device == 0 or epoch.reset == 0) return error.Invalid;
        self.self_address = @intFromPtr(self); self.epoch = epoch;
    }
    pub fn create(self: *Owner, engine: p.Engine, priority: Priority, resources: p.Resources) c.Error!Handle {
        if (self.self_address != @intFromPtr(self) or self.stopping) return error.State;
        resources.validate() catch return error.Invalid;
        const mask = gdsMask(resources);
        if (self.gds & mask != 0) return error.Busy;
        for (&self.contexts) |*ctx| if (ctx.live and ctx.resources.scratch_bytes != 0 and resources.scratch_bytes != 0 and
            !p.disjoint(ctx.resources.scratch, ctx.resources.scratch_bytes, resources.scratch, resources.scratch_bytes)) return error.Busy;
        if (self.generation == std.math.maxInt(u64)) return error.Overflow;
        for (&self.contexts, 0..) |*ctx, index| if (!ctx.live) {
            self.generation += 1;
            ctx.* = .{ .live = true, .generation = self.generation, .engine = engine, .priority = priority, .resources = resources };
            self.gds |= mask;
            return .{ .slot = @intCast(index), .generation = self.generation, .epoch = self.epoch };
        };
        return error.Capacity;
    }
    pub fn context(self: *Owner, handle: Handle) c.Error!*Context {
        if (self.self_address != @intFromPtr(self) or !std.meta.eql(handle.epoch, self.epoch) or handle.slot >= self.contexts.len) return error.Stale;
        const ctx = &self.contexts[handle.slot];
        if (!ctx.live or ctx.generation != handle.generation or handle.generation == 0) return error.Stale;
        return ctx;
    }
    pub fn destroy(self: *Owner, handle: Handle) c.Error!void {
        const ctx = try self.context(handle); if (ctx.jobs != 0) return error.Busy;
        self.gds &= ~gdsMask(ctx.resources); ctx.live = false;
    }
    pub fn contains(self: *const Owner, fence: a.GfxFence) bool {
        for (&self.jobs) |*job| if (job.owner != null and std.meta.eql(job.fence, fence)) return true;
        return false;
    }
    fn gdsMask(resources: p.Resources) u16 {
        if (resources.gds_bytes == 0) return 0;
        return @intCast(((@as(u32, 1) << @as(u5, @intCast(resources.gds_bytes / 256))) - 1) << @as(u5, @intCast(resources.gds_offset / 256)));
    }
    /// Success transfers the caller's already pinned resource owner and exact
    /// canonical fence. Errors leave both with the caller. No command executes
    /// until step() attaches that owner to the real shared GPU timeline.
    pub fn enqueue(self: *Owner, handle: Handle, fence: a.GfxFence, now: u64, deadline: u64,
        commands: []const u32, resources: q.Resources) c.Error!void {
        const ctx = try self.context(handle);
        if (self.stopping or !self.epoch.matches(fence) or resources.context == 0 or commands.len == 0 or commands.len > p.max_ib_words - 32 or
            deadline <= now or deadline - now > 2_000_000_000 or self.serial == std.math.maxInt(u64) or self.dispatches == std.math.maxInt(u64)) return error.Invalid;
        p.packetBoundaries(commands) catch return error.Invalid;
        for (&self.jobs) |*job| if (job.owner != null and std.meta.eql(job.fence, fence)) return error.Busy;
        for (&self.jobs) |*job| if (job.owner == null) {
            var prefix: [32]u32 = undefined; const count = try preamble(&prefix, ctx.engine, ctx.resources);
            @memcpy(job.words[0..count], prefix[0..count]); @memcpy(job.words[count..][0..commands.len], commands);
            const total = count + commands.len; const aligned = (total + 7) & ~@as(usize, 7);
            @memset(job.words[total..aligned], p.nop);
            self.serial += 1; ctx.jobs += 1;
            job.owner = self; job.context = handle; job.fence = fence; job.resources = resources;
            job.ticket = null; job.retired = false; job.failed = false; job.serial = self.serial;
            job.age = self.dispatches; job.deadline = deadline; job.count = aligned;
            return;
        };
        return error.Capacity;
    }
    pub fn preamble(output: []u32, engine: p.Engine, resources: p.Resources) c.Error!usize {
        const size = resources.ringSize() catch return error.Invalid;
        if (output.len < 12) return error.Capacity;
        var b: p.Builder = .{ .words = output };
        if (engine == .gfx) {
            b.add(&.{ p.packet(0x69, 1), l.r.SPI_TMPRING_SIZE / 4 - 0xa000, size });
        } else {
            // GFX9 uses a swizzled scratch descriptor in user SGPR0/1. The
            // compiler ABI must agree; GFX11 scratch-base registers are absent.
            b.add(&.{ p.packet(0x76, 2) | 2, l.r.COMPUTE_USER_DATA_0 / 4 - 0x2c00, @truncate(resources.scratch),
                @as(u32, @truncate(resources.scratch >> 32)) | (if (resources.scratch_bytes != 0) @as(u32, 1 << 31) else 0),
                p.packet(0x76, 1) | 2, l.r.COMPUTE_TMPRING_SIZE / 4 - 0x2c00, size });
            if (resources.gds_bytes != 0) b.add(&.{ p.packet(0x68, 1), l.r.GDS_COMPUTE_MAX_WAVE_ID / 4 - 0x2000, 0x15f });
        }
        return b.used;
    }
    fn next(self: *Owner, engine: p.Engine) ?*Job {
        var best: ?*Job = null;
        for (&self.jobs) |*job| {
            if (job.owner == null or job.ticket != null or job.failed or job.retired) continue;
            const ctx = self.context(job.context) catch continue;
            if (ctx.engine != engine) continue;
            if (best) |old| {
                const old_ctx = self.context(old.context) catch continue;
                const aged = self.dispatches - job.age >= 8; const old_aged = self.dispatches - old.age >= 8;
                if (aged != old_aged) { if (aged) best = job; }
                else if ((aged and job.serial < old.serial) or (!aged and (@intFromEnum(ctx.priority) < @intFromEnum(old_ctx.priority) or
                    (ctx.priority == old_ctx.priority and job.serial < old.serial)))) best = job;
            } else best = job;
        }
        return best;
    }
    pub fn collect(self: *Owner, rt: *runtime.Owner) bool {
        var complete = true;
        for (&self.jobs) |*job| {
            if (job.owner == null) continue;
            if (job.ticket) |ticket| {
                _ = rt.timeline.entry(ticket) catch {
                    if (job.retired) job.reset() else complete = false;
                    continue;
                };
                complete = false;
            } else if (job.failed or self.stopping) {
                if (Job.retire(@intFromPtr(job), job.fence) and rt.queue.?.complete(&job.fence, a.gfx_queue_result_failed, 1) == 1) job.reset() else complete = false;
            } else complete = false;
        }
        return complete;
    }
    pub fn step(self: *Owner, rt: *runtime.Owner, engine: *@import("gc_engine.zig").Owner) void {
        if (self.self_address != @intFromPtr(self)) return;
        _ = self.collect(rt);
        if (self.stopping or rt.timeline.failed_engines != 0 or engine.faulted or engine.phase != .ready) return;
        // At most one complete IB per engine/worker pass; age bounds priority
        // starvation. Separate rings allow SDMA, graphics and compute progress
        // without waiting for another engine in a global CPU critical section.
        for ([_]p.Engine{ .gfx, .compute }) |kind| {
            const job = self.next(kind) orelse continue;
            const ring = &engine.rings[@intFromEnum(kind)];
            if (ring.available() < 48) continue;
            self.dispatches +|= 1;
            self.submit(rt, engine, job, kind) catch {
                job.failed = true;
                if (job.ticket) |ticket| rt.timeline.cancelUnsubmitted(ticket) catch {
                    engine.faulted = true; rt.timeline.fault(6);
                };
            };
        }
    }
    fn submit(self: *Owner, rt: *runtime.Owner, engine: *@import("gc_engine.zig").Owner, job: *Job, kind: p.Engine) c.Error!void {
        _ = self;
        const io = &rt.memory.?.registers;
        if (io.nowNs() >= job.deadline) return error.Deadline;
        const ticket = try rt.timeline.reserve(job.fence, if (kind == .gfx) .gfx else .compute, job.deadline, .{ .context = @intFromPtr(job), .retire = Job.retire });
        job.ticket = ticket;
        const ib = try rt.arena.ib(ticket.slot); for (job.words[0..job.count], ib[0..job.count]) |word, *dest| dest.* = word;
        var frame: [48]u32 = undefined;
        const count = p.encodeFrame(&frame, .{ .engine = kind, .ib = @import("sdma_jobs.zig").arena_va + storage.ib_offset + @as(u64, ticket.slot) * storage.ib_bytes,
            .words = @intCast(job.count), .fence = try rt.arena.address(storage.fence_offset + @as(usize, ticket.slot) * 8, 8), .sequence = ticket.token,
            .eop_scratch = if (kind == .gfx) try rt.arena.address(l.scratch_offset, 256) else 0, .interrupt = true }) catch return error.Invalid;
        const ring = &engine.rings[@intFromEnum(kind)];
        const staged = try ring.stage(frame[0..count]);
        rt.timeline.arm(ticket) catch |err| { try ring.cancel(staged); return err; };
        // Once armed, even an uncertain doorbell requires a proven idle/reset.
        try engine.kick(io, &rt.arena, if (kind == .gfx) .gfx else .compute, staged);
    }
};
