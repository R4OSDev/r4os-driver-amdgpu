// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const a = @import("r4os").abi;
const mem = @import("memory_owner.zig");
const io = @import("memory_io.zig");
const layout = @import("memory_layout.zig");
const reg = @import("queue_registers.zig");
pub const Error = @import("memory_hubs.zig").Error;
pub const ih_bytes = 64 * 1024;
pub const wb_offset = 0x10000;
pub const fence_offset = wb_offset + 0x100;
pub const ring_bytes = 64 * 1024;
pub const ib_offset = 0x80000;
pub const ib_bytes = 8192;
pub const bytes = 1024 * 1024;
pub const Engine = @import("queue_ring.zig").Engine;
pub fn ringOffset(engine: Engine) usize { return 0x20000 + @as(usize, @intFromEnum(engine)) * ring_bytes; }
pub const Owner = struct {
    self_address: usize = 0, memory: ?*mem.Owner = null, epoch: u64 = 0,
    arena: io.Window = .{}, doorbell: io.Window = .{}, gpu: u64 = 0, ready: bool = false,
    dummy: @import("memory_mapping.zig").Mapping = .{}, dummy_pages: [1]u64 = .{0},
    pub fn prepare(self: *Owner, memory: *mem.Owner, bar2: @import("identity.zig").Bar, gate: @import("memory_hubs.zig").Gate) Error!void {
        if (self.self_address != 0 or memory.engine_users != 0) return error.Busy;
        if (!memory.prepared or memory.self_address != @intFromPtr(memory) or !gate.boot_held or !gate.engines_quiesced or
            gate.memory_epoch != memory.epoch or (bar2.kind != .memory32 and bar2.kind != .memory64) or bar2.base == 0 or
            (bar2.bytes != 0 and bar2.bytes < 4096)) return error.Unconfirmed;
        const map = memory.layout.?;
        if (map.rings.span.bytes != bytes or !map.pool.owns(map.rings)) return error.Invalid;
        self.self_address = @intFromPtr(self); self.memory = memory; self.epoch = memory.epoch; memory.engine_users += 1;
        self.gpu = try map.mcAddress(map.rings.span);
        try self.arena.open(memory.memory.?, map.physical.offset, map.physical.bytes, map.rings.span.offset, bytes, true);
        try self.doorbell.open(memory.memory.?, bar2.base, 4096, 0, 4096, false);
        // NBIO's dummy read is a direct PCI DMA address, not a VRAM MC alias.
        // Retain one canonical, zeroed system BO and its actual pinned segment.
        // It needs no GPU VA/PTE and is never published to a GPU page table.
        try self.dummy.prepareDma(memory, null, 4096, &self.dummy_pages);
        if (self.dummy_pages[0] >= (@as(u64, 1) << 40)) return error.Unsupported;
        const words = try self.arena.words(); for (words) |*word| word.* = 0;
        asm volatile ("mfence" ::: .{ .memory = true }); self.ready = true;
    }
    pub fn words32(self: *const Owner, offset: usize, length: usize) Error![]volatile u32 {
        if (!self.ready or self.self_address != @intFromPtr(self) or offset & 3 != 0 or length == 0 or length & 3 != 0 or offset >= bytes or length > bytes - offset) return error.Invalid;
        const ptr: [*]volatile u32 = @ptrFromInt(self.arena.value.cpu_address + offset); return ptr[0 .. length / 4];
    }
    pub fn fences(self: *const Owner) Error![]volatile u64 {
        _ = try self.words32(fence_offset, @import("queue_timeline.zig").capacity * 8);
        const ptr: [*]volatile u64 = @ptrFromInt(self.arena.value.cpu_address + fence_offset); return ptr[0..@import("queue_timeline.zig").capacity];
    }
    pub fn ib(self: *const Owner, slot: usize) Error![]volatile u32 {
        if (slot >= @import("queue_timeline.zig").capacity) return error.Invalid;
        return self.words32(ib_offset + slot * ib_bytes, ib_bytes);
    }
    pub fn address(self: *const Owner, offset: usize, length: usize) Error!u64 {
        _ = try self.words32(offset, length); return self.gpu + offset;
    }
    pub fn doorbell32(self: *const Owner, index: u32, value: u32) Error!void {
        if (!self.ready or self.self_address != @intFromPtr(self) or !io.handle(self.doorbell.value.handle) or index >= 1024) return error.Invalid;
        asm volatile ("mfence" ::: .{ .memory = true });
        const ptr: [*]volatile u32 = @ptrFromInt(self.doorbell.value.cpu_address); ptr[index] = value;
    }
    pub fn doorbell64(self: *const Owner, engine: Engine, value: u64) Error!void {
        const index: u32 = switch (engine) { .sdma => reg.sdma_doorbell, .gfx => reg.gfx_doorbell, .compute => reg.compute_doorbell };
        try self.doorbellIndex64(index, value);
    }
    pub fn doorbellIndex64(self: *const Owner, index: u32, value: u64) Error!void {
        if (!self.ready or self.self_address != @intFromPtr(self) or !io.handle(self.doorbell.value.handle) or index & 1 != 0 or
            (index != reg.sdma_doorbell and index != reg.gfx_doorbell and index != reg.compute_doorbell and index != reg.kiq_doorbell)) return error.Invalid;
        // One aligned 64-bit MMIO store; two 32-bit stores are not a doorbell64.
        asm volatile ("mfence" ::: .{ .memory = true });
        const word: *volatile u64 = @ptrFromInt(self.doorbell.value.cpu_address + index * 4); word.* = value;
    }
    /// IRQ registration, IH DMA, engine queues and the worker must already be
    /// retired. A timeout deliberately leaves both mappings and the UMA hold.
    pub fn close(self: *Owner, quiesced: bool) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or !quiesced) return false;
        const memory = self.memory orelse return false;
        if (memory.self_address != @intFromPtr(memory) or memory.epoch != self.epoch or memory.engine_users == 0) return false;
        self.ready = false;
        if (self.dummy.translated or !self.dummy.close(&memory.virtual, &memory.registers)) return false;
        if (!self.doorbell.close() or !self.arena.close()) return false;
        memory.engine_users -= 1; self.* = .{}; return true;
    }
};
comptime {
    if (ib_offset + @import("queue_timeline.zig").capacity * ib_bytes != bytes or
        fence_offset + @import("queue_timeline.zig").capacity * 8 > 0x11000 or reg.required_prefix > @import("memory_registers.zig").required_prefix) @compileError("AMD queue arena/prefix mismatch");
}
