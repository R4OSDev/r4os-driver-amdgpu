// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
pub const Error = @import("memory_hubs.zig").Error || error{ Firmware, Response, Interface, State, Retained };
pub const wire = @cImport({ @cInclude("start_wire.h"); });
/// Nonblocking deadlines. One step performs bounded register accesses and
/// returns to the preemptible caller; no owner lock spans a sleep or callback.
pub const Deadline = struct {
    last: u64 = 0, end: u64 = 0, earliest: u64 = 0, polls: u32 = 0,
    pub fn start(self: *Deadline, now: u64, duration: u64, delay: u64) Error!void {
        if (duration == 0 or delay >= duration) return error.Invalid;
        self.* = .{ .last = now, .end = std.math.add(u64, now, duration) catch return error.Deadline,
            .earliest = std.math.add(u64, now, delay) catch return error.Deadline };
    }
    pub fn check(self: *Deadline, now: u64) Error!bool {
        if (self.end == 0 or now < self.last or now >= self.end or self.polls == 1000000) return error.Deadline;
        self.last = now; self.polls += 1; return now >= self.earliest;
    }
};
pub fn read(io: anytype, address: u32) Error!u32 {
    const value = try io.read(address); if (value == 0xffffffff) return error.Disconnected; return value;
}
pub fn set(io: anytype, address: u32, mask: u32, value: u32) Error!void {
    try io.write(address, (try read(io, address) & ~mask) | (value & mask));
}
pub fn hdpFlush(io: anytype) Error!void {
    const r = @import("memory_registers.zig");
    try io.barrier(); try io.write(r.nb.HDP_MEM_COHERENCY_FLUSH_CNTL, 0);
    _ = try read(io, r.nb.HDP_MEM_COHERENCY_FLUSH_CNTL); try io.barrier();
}
pub fn hdpInvalidate(io: anytype) Error!void {
    const r = @import("start_registers.zig");
    try io.write(r.hdp.HDP_READ_CACHE_INVALIDATE, 1);
    _ = try read(io, r.hdp.HDP_READ_CACHE_INVALIDATE); try io.barrier();
}
comptime {
    if (@import("start_registers.zig").required_prefix > @import("memory_registers.zig").required_prefix) @compileError("startup prefix exceeds admitted BAR5");
}
