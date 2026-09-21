// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
pub const Error = @import("memory_hubs.zig").Error;
pub const Engine = enum(u2) { sdma, gfx, compute };
pub const Ticket = struct { start: u64, end: u64, serial: u64 };
/// Worker-owned ring cursor. Engine-specific packets and write-pointer units
/// belong to SDMA/GFX. This owner never fabricates a hardware read pointer.
pub const Ring = struct {
    words: []volatile u32 = &.{}, read: u64 = 0, write: u64 = 0,
    alignment: u32 = 0, nop: u32 = 0, serial: u64 = 0, staged: ?Ticket = null,
    pub fn init(words: []volatile u32, alignment: u32, nop: u32) Error!Ring {
        if (words.len < 32 or words.len > 65536 or !std.math.isPowerOfTwo(words.len) or alignment == 0 or
            !std.math.isPowerOfTwo(alignment) or alignment >= words.len) return error.Invalid;
        return .{ .words = words, .alignment = alignment, .nop = nop };
    }
    pub fn available(self: *const Ring) usize { return self.words.len - 1 - @as(usize, @intCast(self.write - self.read)); }
    /// Decode/mask SDMA byte or CP dword units before calling this function.
    pub fn observe(self: *Ring, rptr_dw: u32) Error!void {
        if (self.words.len == 0 or rptr_dw >= self.words.len) return error.Invalid;
        const old = self.read & (self.words.len - 1);
        const delta = (rptr_dw + self.words.len - old) & (self.words.len - 1);
        if (delta > self.write - self.read) return error.Stale;
        self.read += delta;
    }
    pub fn stage(self: *Ring, commands: []const u32) Error!Ticket {
        if (self.staged != null) return error.Busy;
        if (self.words.len == 0 or commands.len == 0 or commands.len >= self.words.len) return error.Invalid;
        const count = (commands.len + self.alignment - 1) & ~@as(usize, self.alignment - 1);
        if (count > self.available()) return error.Capacity;
        const end = std.math.add(u64, self.write, count) catch return error.Overflow;
        if (self.serial == std.math.maxInt(u64)) return error.Overflow;
        for (0..count) |i| self.words[(self.write + i) & (self.words.len - 1)] = if (i < commands.len) commands[i] else self.nop;
        self.serial += 1;
        const ticket: Ticket = .{ .start = self.write, .end = end, .serial = self.serial };
        self.staged = ticket;
        return ticket;
    }
    /// Commit before the engine doorbell: a failed/uncertain doorbell cannot
    /// roll back storage which the GPU may already have consumed.
    pub fn commit(self: *Ring, ticket: Ticket) Error!u64 {
        if (self.staged == null or !std.meta.eql(self.staged.?, ticket) or ticket.start != self.write) return error.Stale;
        asm volatile ("mfence" ::: .{ .memory = true });
        self.write = ticket.end; self.staged = null;
        return self.write;
    }
    pub fn cancel(self: *Ring, ticket: Ticket) Error!void {
        if (self.staged == null or !std.meta.eql(self.staged.?, ticket)) return error.Stale;
        self.staged = null;
    }
};
