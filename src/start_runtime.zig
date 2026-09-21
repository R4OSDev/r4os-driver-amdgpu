// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Resident owner of the native PSP/SMU phase. The later engine/display owner
//! drives advance() in its preemptible start worker and publishes readiness.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const mem = @import("memory_owner.zig");
const identity = @import("identity.zig");
const boot = @import("boot_snapshot.zig");
pub const Error = @import("start_common.zig").Error || boot.Error;
pub const Owner = struct {
    self_address: usize = 0, memory: ?*mem.Owner = null, ctx: ?r4os.r4dev.DriverContext = null,
    snapshot: identity.Snapshot = .{}, chip: ?identity.Chip = null, pci_changed: bool = false, old_command: u16 = 0,
    flow: @import("start_flow.zig").Flow = .{}, storage: @import("start_storage.zig").Owner = .{},
    hold: boot.Snapshot = .{}, guard: @import("start_guard.zig").Guard = .{},
    pub fn prepare(self: *Owner, ctx: *const r4os.r4dev.DriverContext, memory: *mem.Owner,
        snapshot: *const identity.Snapshot, chip: identity.Chip, store: *const @import("firmware_store.zig").Store,
        expected: a.GfxNativeBootInfo, boot_offset: u64) Error!void {
        if (self.self_address != 0) return error.Busy;
        const profile = @import("firmware.zig").select(snapshot, chip) catch return error.Unsupported;
        if (!memory.prepared or memory.start_users != 0 or memory.engine_users != 0 or memory.mapping_users != 0 or memory.controller.touched or
            !store.valid or store.profile == null or expected.format != a.gfx_buffer_format_xrgb8888) return error.Unconfirmed;
        if (!std.meta.eql(profile, store.profile.?) or memory.registers.window.value.physical_address != snapshot.bars[5].base) return error.Stale;
        const map = memory.layout.?;
        if (boot_offset >= map.mc.bytes or expected.byte_length > map.mc.bytes - boot_offset) return error.Invalid;
        self.self_address = @intFromPtr(self); self.ctx = ctx.*; self.memory = memory; self.snapshot = snapshot.*; self.chip = chip; memory.start_users += 1;
        // Caller routes every preparation error through close(); uncertain API
        // releases leave this entire resident owner and its callback intact.
        try self.storage.prepare(memory);
        try self.hold.captureHeld(ctx, memory.adapter, expected, @intFromPtr(&restore), @intFromPtr(self));
        try self.guard.capture(&memory.registers, map.mc.offset + boot_offset, expected.pitch);
        var reader: Reader = .{ .ctx = ctx.*, .pci = snapshot.pci };
        if (!identity.stable(snapshot, &reader)) return error.Stale;
        const command = ctx.pciReadConfig32(snapshot.pci, 4);
        if (command == 0xffffffff or @as(u16, @truncate(command)) != snapshot.command or
            ctx.pciReadConfig32(snapshot.pci, 0) != 0x15d81002) return error.Stale;
        self.old_command = @truncate(command);
        if (!self.hold.latchEffects()) return error.Hold;
        // Status bits are W1C: write only the low command word, with zero high
        // bits. Latch before the call and verify the actual PCI readback.
        self.pci_changed = true;
        if (ctx.pciWriteConfig32(snapshot.pci, 4, @as(u32, self.old_command) | 6) != 0 or
            @as(u16, @truncate(ctx.pciReadConfig32(snapshot.pci, 4))) != self.old_command | 6) return error.Unconfirmed;
        try self.flow.begin(&memory.registers, self.storage.view.?, store, memory.epoch, self.hold.effects and self.hold.held_generation != 0);
    }
    pub fn advance(self: *Owner) Error!void {
        if (self.self_address != @intFromPtr(self)) return error.State;
        try self.flow.advance(&self.memory.?.registers);
        if (self.flow.firmwareReady() and !(self.guard.matches(&self.memory.?.registers) catch false)) {
            self.flow.failure = error.Unconfirmed; self.flow.failed_phase = self.flow.phase;
            self.flow.abort(&self.memory.?.registers); return error.Unconfirmed;
        }
    }
    pub fn firmwareReady(self: *const Owner) bool {
        return self.self_address == @intFromPtr(self) and self.hold.effects and self.hold.held_generation != 0 and self.flow.firmwareReady();
    }
    /// Explicit retry observes late completions; it never assumes a GPU reset
    /// or discards an uncertain request. Each attempt has a fresh bounded drain.
    pub fn retryCleanup(self: *Owner) bool {
        if (self.self_address != @intFromPtr(self) or self.flow.phase != .retained) return false;
        self.flow.abort(&self.memory.?.registers); return true;
    }
    pub fn close(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        const memory = self.memory orelse return false;
        // Later owners must retire IH/engine mappings and restore GMC before
        // this stage can restore boot writers or remove PCI bus mastering.
        if (memory.engine_users != 0 or memory.mapping_users != 0 or memory.controller.touched) return false;
        if (!self.flow.safeToRelease()) {
            const Phase = @import("start_flow.zig").Phase;
            if (@intFromEnum(self.flow.phase) < @intFromEnum(Phase.cleanup_drain)) self.flow.abort(&memory.registers);
            self.flow.advance(&memory.registers) catch return false;
            if (!self.flow.safeToRelease()) return false;
        }
        if (self.pci_changed) {
            const ctx = self.ctx.?;
            if (ctx.pciReadConfig32(self.snapshot.pci, 0) != 0x15d81002 or
                ctx.pciWriteConfig32(self.snapshot.pci, 4, self.old_command) != 0 or
                @as(u16, @truncate(ctx.pciReadConfig32(self.snapshot.pci, 4))) != self.old_command) return false;
            self.pci_changed = false;
        }
        if (!self.storage.close(true) or !self.hold.close()) return false;
        memory.start_users -= 1; self.* = .{}; return true;
    }
    fn restore(raw: u64, generation: u64, original: *const a.GfxNativeBootInfo) callconv(.c) i32 {
        if (raw == 0) return 0;
        const self: *Owner = @ptrFromInt(raw);
        if (self.self_address != raw or generation != self.hold.held_generation or self.pci_changed or
            !self.flow.safeToRelease() or original.version != 1 or original.size < @sizeOf(a.GfxNativeBootInfo) or
            original.generation != generation or original.state != a.display_state_preparing) return 0;
        // bootDescription uses the pending hold generation and preparing state
        // during recovery. Compare the immutable geometry/mapping separately.
        var description = original.*;
        description.generation = self.hold.boot.generation; description.state = self.hold.boot.state;
        description.size = self.hold.boot.size;
        if (!std.meta.eql(description, self.hold.boot)) return 0;
        const memory = self.memory orelse return 0;
        if (memory.controller.touched or memory.engine_users != 0 or memory.mapping_users != 0) return 0;
        return @intFromBool(self.guard.matches(&memory.registers) catch false);
    }
};

const Reader = struct {
    ctx: r4os.r4dev.DriverContext, pci: a.PciDeviceInfo,
    pub fn read(self: *Reader, offset: u16) u32 { return self.ctx.pciReadConfig32(self.pci, offset); }
};
