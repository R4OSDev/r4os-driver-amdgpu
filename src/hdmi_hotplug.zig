// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Serialized worker lifecycle. Receipts refer to one exact connection token.
const std = @import("std");
pub const Error = error{ State, Stale, Capacity, Clock, Timeout };
pub const Phase = enum { disconnected, debounce, probing, connected, retiring, retained };
pub const Step = enum { pause, drain, stop, settle, withdraw, release };
pub const Receipt = struct {
    generation: u64,
    done: bool = false,
    pending_jobs: u32 = 0,
    live_leases: u32 = 0,
    scanout_stopped: bool = false,
};
pub const Io = struct {
    context: usize,
    // Pause rejects new work. Drain waits for users of the old resources;
    // stop confirms physical retirement; settle delivers every completion;
    // withdraw invalidates the common output; release finally frees backing.
    retire: *const fn (usize, u64, Step) Receipt,
};
pub const Connection = struct {
    phase: Phase = .disconnected,
    generation: u64 = 0,
    fingerprint: [32]u8 = @splat(0),
    candidate: bool = false,
    since: u64 = 0,
    last: u64 = 0,
    sampled: bool = false,
    step: Step = .pause,
    published: bool = false,
    retiring_since: u64 = 0,
    pub fn sample(self: *Connection, present: bool, now: u64) Error!void {
        if (self.sampled and now < self.last) { self.phase = .retained; return error.Clock; }
        self.last = now;
        if (!self.sampled or present != self.candidate) { self.candidate = present; self.since = now; }
        self.sampled = true;
        // Even a short observed disconnect invalidates in-flight acquisition.
        // Resources retire conservatively; new admission waits for stable HPD.
        if (!present and (self.phase == .connected or self.phase == .probing)) self.invalidate();
        if (self.phase == .retiring or self.phase == .retained) return;
        if (!present) { self.phase = .disconnected; return; }
        if (self.phase == .connected or self.phase == .probing) return;
        self.phase = .debounce;
        if (now - self.since >= 100_000_000) {
            if (self.generation == std.math.maxInt(u64)) { self.phase = .retained; return error.Capacity; }
            self.generation += 1;
            self.phase = .probing;
        }
    }
    pub fn publish(self: *Connection, token: u64, fingerprint: [32]u8) Error!void {
        if (token == 0 or token != self.generation) return error.Stale;
        if (self.phase != .probing or !self.candidate or self.published) return error.State;
        self.fingerprint = fingerprint;
        self.published = true;
        self.phase = .connected;
    }
    pub fn changed(self: *Connection, token: u64, fingerprint: [32]u8) Error!void {
        if (token == 0 or token != self.generation) return error.Stale;
        if (self.phase != .connected) return error.State;
        if (!std.mem.eql(u8, &fingerprint, &self.fingerprint)) self.invalidate();
    }
    pub fn invalidate(self: *Connection) void {
        if (self.phase == .retiring or self.phase == .retained) return;
        if (self.published) { self.step = .pause; self.phase = .retiring; self.retiring_since = self.last; }
        else { self.phase = .disconnected; self.since = self.last; }
    }
    pub fn advance(self: *Connection, io: Io) Error!bool {
        if (self.phase != .retiring) return self.phase != .retained;
        if (self.last < self.retiring_since or self.last - self.retiring_since >= 5_000_000_000) { self.phase = .retained; return error.Timeout; }
        const receipt = io.retire(io.context, self.generation, self.step);
        if (receipt.generation != self.generation) { self.phase = .retained; return error.Stale; }
        if (!receipt.done) return false;
        if ((self.step == .drain or self.step == .settle or self.step == .withdraw or self.step == .release) and
            (receipt.pending_jobs != 0 or receipt.live_leases != 0)) { self.phase = .retained; return error.State; }
        if (@intFromEnum(self.step) >= @intFromEnum(Step.stop) and !receipt.scanout_stopped) { self.phase = .retained; return error.State; }
        if (self.step != .release) { self.step = @enumFromInt(@intFromEnum(self.step) + 1); return false; }
        self.published = false;
        self.fingerprint = @splat(0);
        self.phase = .disconnected;
        self.since = self.last;
        return true;
    }
};
