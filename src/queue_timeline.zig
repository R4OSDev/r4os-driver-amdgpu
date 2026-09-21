// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
pub const Engine = @import("queue_ring.zig").Engine;
pub const Error = @import("memory_hubs.zig").Error;
pub const capacity = 64;
pub const Epoch = struct {
    adapter: u32, device: u64, reset: u64,
    pub fn from(binding: a.GfxBackendBinding) Error!Epoch {
        if (binding.version != 1 or binding.size < @sizeOf(a.GfxBackendBinding) or binding.adapter_id == 0 or
            binding.device_generation == 0 or binding.reset_generation == 0) return error.Invalid;
        return .{ .adapter = binding.adapter_id, .device = binding.device_generation, .reset = binding.reset_generation };
    }
    pub fn matches(self: Epoch, fence: a.GfxFence) bool {
        return fence.adapter_id == self.adapter and fence.device_generation == self.device and fence.reset_generation == self.reset and
            fence.timeline != 0 and fence.point != 0 and fence.slot < a.gfx_queue_fence_capacity;
    }
};
/// Supplied only by the engine stop/reset owner after real idle/reset evidence.
/// Metadata/IRQ arrival/timeout alone must never construct this proof.
pub const Quiescence = struct {
    epoch: Epoch, engines: u3,
    pub fn covers(self: Quiescence, epoch: Epoch, engine: Engine) bool {
        return std.meta.eql(self.epoch, epoch) and self.engines & (@as(u3, 1) << @intFromEnum(engine)) != 0;
    }
};
pub const Ticket = struct { slot: u8, token: u64, epoch: Epoch };
pub const Resources = struct {
    context: usize,
    // Exact fence release and PTE/TLB/DMA/BO cleanup, outside the IRQ gate.
    // False retains this job and IB slot; partial cleanup must be retryable.
    retire: *const fn (usize, a.GfxFence) bool,
};
pub const Phase = enum { free, reserved, submitted, retiring };
pub const Entry = struct {
    phase: Phase = .free, fence: a.GfxFence = .{}, engine: Engine = .sdma,
    token: u64 = 0, deadline: u64 = 0, result: u32 = a.gfx_queue_result_pending,
    resources: ?Resources = null, resources_retired: bool = false,
};
/// Only the dedicated worker mutates this pool. IRQs never call it, complete
/// canonical jobs, unmap BOs or wake a set of application waiters.
pub const Timeline = struct {
    self_address: usize = 0, epoch: Epoch = .{ .adapter = 0, .device = 0, .reset = 0 },
    writeback: []volatile u64 = &.{}, entries: [capacity]Entry = @splat(.{}),
    token: u64 = 0, last_time: u64 = 0, stopping: bool = false, failed_engines: u3 = 0,
    completed: u64 = 0, stale_writebacks: u64 = 0,
    pub fn init(self: *Timeline, binding: a.GfxBackendBinding, words: []volatile u64, now: u64) Error!void {
        if (self.self_address != 0 or words.len != capacity or @intFromPtr(words.ptr) & 7 != 0 or now == std.math.maxInt(u64)) return error.Invalid;
        self.epoch = try Epoch.from(binding); self.self_address = @intFromPtr(self);
        self.writeback = words; self.last_time = now;
        for (words) |*word| word.* = std.math.maxInt(u64);
        asm volatile ("mfence" ::: .{ .memory = true });
    }
    pub fn reserve(self: *Timeline, fence: a.GfxFence, engine: Engine, deadline: u64, resources: Resources) Error!Ticket {
        if (self.self_address != @intFromPtr(self) or self.stopping or self.failed_engines != 0) return error.Busy;
        if (!self.epoch.matches(fence) or deadline <= self.last_time or deadline == std.math.maxInt(u64)) return error.Invalid;
        if (self.token >= std.math.maxInt(u64) - 1) return error.Overflow;
        for (&self.entries) |*job| if (job.phase != .free and std.meta.eql(job.fence, fence)) return error.Busy;
        for (&self.entries, 0..) |*job, i| if (job.phase == .free) {
            self.token += 1;
            self.writeback[i] = std.math.maxInt(u64);
            asm volatile ("mfence" ::: .{ .memory = true });
            job.* = .{ .phase = .reserved, .fence = fence, .engine = engine, .token = self.token, .deadline = deadline, .resources = resources };
            return .{ .slot = @intCast(i), .token = self.token, .epoch = self.epoch };
        };
        return error.Capacity;
    }
    pub fn entry(self: *Timeline, ticket: Ticket) Error!*Entry {
        if (self.self_address != @intFromPtr(self) or !std.meta.eql(self.epoch, ticket.epoch) or ticket.slot >= capacity or
            ticket.token == 0 or self.entries[ticket.slot].phase == .free or self.entries[ticket.slot].token != ticket.token) return error.Stale;
        return &self.entries[ticket.slot];
    }
    /// Arm before making ring packets visible; any later failure is uncertain
    /// GPU reachability and requires quiescence, never a local cancellation.
    pub fn arm(self: *Timeline, ticket: Ticket) Error!void {
        const job = try self.entry(ticket);
        if (job.phase != .reserved or self.stopping or self.failed_engines != 0) return error.Busy;
        if (self.writeback[ticket.slot] != std.math.maxInt(u64)) return error.Stale;
        job.phase = .submitted;
    }
    pub fn cancelUnsubmitted(self: *Timeline, ticket: Ticket) Error!void {
        const job = try self.entry(ticket);
        if (job.phase != .reserved) return error.Busy;
        job.result = a.gfx_queue_result_cancelled; job.phase = .retiring;
    }
    pub fn fault(self: *Timeline, mask: u3) void { self.failed_engines |= mask; }
    /// Poll real GPU-written fence locations even without an interrupt. A
    /// matching token is accepted only in its submitted generation/IB slot.
    pub fn poll(self: *Timeline, now: u64) void {
        if (self.self_address != @intFromPtr(self)) return;
        if (now < self.last_time or now == std.math.maxInt(u64)) { self.fault(7); return; }
        self.last_time = now;
        asm volatile ("mfence" ::: .{ .memory = true });
        for (&self.entries, 0..) |*job, i| {
            if (job.phase != .submitted) continue;
            const mask = @as(u3, 1) << @intFromEnum(job.engine);
            if (self.failed_engines & mask != 0) continue;
            const first = self.writeback[i];
            asm volatile ("lfence" ::: .{ .memory = true });
            const second = self.writeback[i];
            if (first == job.token and second == job.token) {
                job.result = a.gfx_queue_result_complete; job.phase = .retiring;
            } else if (now >= job.deadline) {
                job.result = a.gfx_queue_result_timeout; self.fault(mask);
            } else if (first == second and first != std.math.maxInt(u64)) {
                self.stale_writebacks +|= 1;
            }
        }
    }
    pub fn abort(self: *Timeline, proof: Quiescence, reason: u32) Error!void {
        if (self.self_address != @intFromPtr(self) or !std.meta.eql(proof.epoch, self.epoch) or proof.engines == 0 or
            (reason != a.gfx_queue_result_cancelled and reason != a.gfx_queue_result_device_lost and reason != a.gfx_queue_result_failed)) return error.Unconfirmed;
        for (&self.entries) |*job| {
            if ((job.phase != .reserved and job.phase != .submitted) or !proof.covers(self.epoch, job.engine)) continue;
            if (job.result == a.gfx_queue_result_pending) job.result = reason;
            job.phase = .retiring;
        }
    }
    pub fn publish(self: *Timeline, queue: r4os.driver_queue.Context) bool {
        if (self.self_address != @intFromPtr(self)) return false;
        var all = true;
        for (&self.entries, 0..) |*job, i| {
            if (job.phase != .retiring) continue;
            if (!job.resources_retired) {
                const resources = job.resources.?;
                if (!resources.retire(resources.context, job.fence)) { all = false; continue; }
                job.resources_retired = true;
            }
            if (queue.complete(&job.fence, job.result, 1) != 1) { all = false; continue; }
            self.writeback[i] = std.math.maxInt(u64); job.* = .{}; self.completed +|= 1;
        }
        return all;
    }
    pub fn empty(self: *const Timeline) bool {
        for (&self.entries) |*job| if (job.phase != .free) return false;
        return true;
    }
};
