// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
// Retain a CPU-readable immutable boot-frame snapshot. No display registers,
// clocks, panel power, training state or firmware command is modified here.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
pub const Error = error{ Busy, Unsupported, BootChanged, Buffer, Hold, Map, Release };
pub const Snapshot = struct {
    memory: ?r4os.driver_memory.Context = null, display: ?r4os.driver_display.Context = null,
    reference: a.GfxBufferReference = .{}, read: a.GfxBufferMap = .{}, held_generation: u64 = 0,
    boot: a.GfxNativeBootInfo = .{}, sha256: [32]u8 = @splat(0), valid: bool = false, effects: bool = false,

    pub fn capture(self: *Snapshot, ctx: *const r4os.r4dev.DriverContext, adapter: u32, expected: a.GfxNativeBootInfo) Error!void {
        try self.captureHeld(ctx, adapter, expected, @intFromPtr(&refuseRecovery), 0);
        if (!self.releaseHold()) return error.Release;
    }
    pub fn captureHeld(self: *Snapshot, ctx: *const r4os.r4dev.DriverContext, adapter: u32, expected: a.GfxNativeBootInfo, callback: u64, cookie: u64) Error!void {
        if (self.reference.reference.id != 0 or self.read.lease.id != 0 or self.held_generation != 0) return error.Busy;
        const memory = ctx.memory() orelse return error.Unsupported;
        const display = ctx.graphicsDisplay() orelse return error.Unsupported;
        if (display.table.size < @offsetOf(a.GfxDriverDisplayApi, "boot_finish") + 8 or display.table.boot_hold == 0 or display.table.boot_finish == 0) return error.Unsupported;
        self.memory = memory; self.display = display;
        var current: a.GfxNativeBootInfo = .{};
        if (display.bootInfo(&current) != a.gfx_output_ok or !std.meta.eql(expected, current)) return error.BootChanged;
        @import("boot.zig").validate(current) catch return error.BootChanged;
        const bytes = @as(u64, current.pitch) * current.height;
        if (bytes == 0 or bytes > 256 * 1024 * 1024) return error.Buffer;
        if (memory.bufferCreate(&.{ .byte_length = bytes, .alignment = 4096,
            .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write }, &self.reference) != a.gfx_buffer_result_ok) return error.Buffer;
        if (self.reference.reference.id == 0 or self.reference.reference.generation == 0) return error.Buffer;
        var state: a.GfxNativeState = .{};
        const status = display.bootHold(&.{ .adapter_id = adapter, .generation = current.generation,
            .reference = self.reference.reference, .restore_callback = callback, .context = cookie }, &state);
        // Even a failed capture can retain a real kernel hold. Keep its token
        // until bootFinish confirms that all boot writers have been restored.
        if (state.retained != 0) self.held_generation = state.generation;
        if (status != a.gfx_output_ok or !validState(state) or state.retained != 1 or state.generation <= current.generation or
            state.state != a.display_state_preparing or
            state.outcome != a.gfx_output_outcome_validated) return error.Hold;
        if (memory.bufferMap(&self.reference.reference, a.gfx_buffer_map_read, 0, bytes, &self.read) != a.gfx_buffer_result_ok) return error.Map;
        if (self.read.lease.id == 0 or self.read.lease.generation == 0 or self.read.cpu_address == 0 or
            self.read.cpu_address > std.math.maxInt(u64) - bytes or self.read.byte_length < bytes) return error.Map;
        var held: a.GfxNativeBootInfo = .{};
        if (display.bootInfo(&held) != a.gfx_output_ok or held.state != a.display_state_preparing) return error.BootChanged;
        held.state = current.state;
        // State changes to preparing while the hold excludes boot writers.
        if (!std.meta.eql(current, held)) return error.BootChanged;
        const pointer: [*]const u8 = @ptrFromInt(self.read.cpu_address);
        std.crypto.hash.sha2.Sha256.hash(pointer[0..bytes], &self.sha256, .{});
        self.boot = current;
        // Caller owns the hold until either abandon, native handover or a
        // proven recovery; the immutable snapshot remains valid throughout.
        self.valid = true;
    }
    pub fn latchEffects(self: *Snapshot) bool {
        if (!self.valid or self.held_generation == 0 or self.effects) return false;
        self.effects = true; // must latch locally before a possibly partial call
        var state: a.GfxNativeState = .{};
        return self.display.?.bootFinish(self.held_generation, 1, &state) == a.gfx_output_ok and validState(state) and
            state.retained == 1 and state.generation == self.held_generation and state.outcome == a.gfx_output_outcome_validated;
    }
    fn releaseHold(self: *Snapshot) bool {
        if (self.held_generation == 0) return true;
        const display = self.display orelse return false;
        var state: a.GfxNativeState = .{};
        if (display.bootFinish(self.held_generation, if (self.effects) 2 else 0, &state) != a.gfx_output_ok or !validState(state) or
            state.retained != 0 or state.outcome != a.gfx_output_outcome_old_preserved or state.state != a.display_state_bootfb) return false;
        self.held_generation = 0; return true;
    }
    pub fn close(self: *Snapshot) bool {
        if (self.read.lease.id != 0) {
            const memory = self.memory orelse return false;
            if (memory.bufferUnmap(&self.read.lease) != a.gfx_buffer_result_ok) return false;
            self.read = .{};
        }
        if (!self.releaseHold()) return false;
        if (self.reference.reference.id != 0) {
            const memory = self.memory orelse return false;
            if (memory.bufferRelease(&self.reference.reference) != a.gfx_buffer_result_ok) return false;
            self.reference = .{};
        }
        self.* = .{}; return true;
    }
};
fn validState(state: a.GfxNativeState) bool { return state.version == 1 and state.size >= @sizeOf(a.GfxNativeState) and state.reserved0 == 0; }
fn refuseRecovery(_: u64, _: u64, _: *const a.GfxNativeBootInfo) callconv(.c) i32 {
    // No native effects are admitted. Unexpected recovery cannot claim that
    // DCN register restoration exists before the later display stages.
    return 0;
}
