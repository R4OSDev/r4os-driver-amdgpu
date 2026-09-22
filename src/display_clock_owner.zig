// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! UMA storage and mailbox lifetime for the SMU10 DPM clock table. Prepare
//! runs before the queue worker starts; close runs after that worker joins.
//! Display-clock changes are serialized by the same native display owner.
const std = @import("std");
const memory = @import("memory_owner.zig");
const layout = @import("memory_layout.zig");
const io = @import("memory_io.zig");
const native = @import("start_runtime.zig");
pub const clocks = @import("display_clocks.zig");
pub const Owner = struct {
    self_address: usize = 0, memory: ?*memory.Owner = null, epoch: u64 = 0,
    allocation: layout.Allocation = .{}, window: io.Window = .{},
    acquire: clocks.Acquisition = .{}, table: ?clocks.Table = null,
    cleanup: @import("start_smu.zig").Mailbox = .{},
    phase: enum { empty, allocating, acquiring, ready, retained, drain, clear_high, clear_low, release } = .empty,
    pub fn prepare(self: *Owner, mem: *memory.Owner, start: *const native.Owner) clocks.Error!void {
        if (self.self_address != 0) return error.Busy;
        if (mem.self_address != @intFromPtr(mem) or !mem.prepared or mem.engine_users == std.math.maxInt(u32) or
            start.memory != mem or !start.firmwareReady() or start.hold.held_generation == 0) return error.Unconfirmed;
        self.* = .{ .self_address = @intFromPtr(self), .memory = mem, .epoch = mem.epoch, .phase = .allocating };
        mem.engine_users += 1;
        errdefer self.phase = .retained;
        const map = mem.layout.?;
        self.allocation = try map.pool.allocate(4096, 4096, .firmware);
        try self.window.open(mem.memory.?, map.physical.offset, map.physical.bytes, self.allocation.span.offset, 4096, true);
        const ptr: [*]volatile u32 = @ptrFromInt(self.window.value.cpu_address);
        for (ptr[0..1024]) |*word| word.* = 0;
        self.phase = .acquiring;
        try self.acquire.begin(&mem.registers, try map.mcAddress(self.allocation.span), 4096);
    }
    pub fn poll(self: *Owner) clocks.Error!bool {
        if (self.self_address != @intFromPtr(self) or self.memory.?.epoch != self.epoch) return error.Stale;
        if (self.phase == .ready) return true;
        if (self.phase != .acquiring) return error.State;
        errdefer self.phase = .retained;
        if (!try self.acquire.step(&self.memory.?.registers)) return false;
        const ptr: [*]const volatile u32 = @ptrFromInt(self.window.value.cpu_address);
        var bytes: [@sizeOf(clocks.wire.DpmClocks_t)]u8 = undefined;
        for (0..bytes.len / 4) |i| std.mem.writeInt(u32, bytes[i * 4 ..][0..4], ptr[i], .little);
        self.table = try clocks.Table.parse(&bytes);
        self.phase = .ready;
        return true;
    }
    pub fn close(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.memory.?.epoch != self.epoch or self.memory.?.engine_users == 0) return false;
        const mem = self.memory.?;
        const regs = &mem.registers;
        switch (self.phase) {
            .clear_high => {
                if (!self.cleanup.active) {
                    self.cleanup.begin(regs, clocks.wire.PPSMC_MSG_SetDriverDramAddrHigh, 0) catch return false;
                    return false;
                }
                if (!(self.cleanup.poll(regs, true) catch return false)) return false;
                self.phase = .clear_low;
                return false;
            },
            .clear_low => {
                if (!self.cleanup.active) {
                    self.cleanup.begin(regs, clocks.wire.PPSMC_MSG_SetDriverDramAddrLow, 0) catch return false;
                    return false;
                }
                if (!(self.cleanup.poll(regs, true) catch return false)) return false;
                self.phase = .release;
            },
            .release => {},
            else => {
                self.phase = .drain;
                if (!(self.acquire.drain(regs) catch return false)) return false;
                // An untouched allocation never supplied a firmware address.
                if (self.acquire.stage == .empty) self.phase = .release else {
                    self.phase = .clear_high;
                    return false;
                }
            },
        }
        if (!self.window.close()) return false;
        if (self.allocation.serial != 0) {
            mem.layout.?.pool.release(self.allocation) catch return false;
            self.allocation = .{};
        }
        mem.engine_users -= 1;
        self.* = .{};
        return true;
    }
};
