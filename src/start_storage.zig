// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const l = @import("memory_layout.zig");
const mem = @import("memory_owner.zig");
const io = @import("memory_io.zig");
pub const Error = @import("start_common.zig").Error;
pub const tmr_bytes = 4 * 1024 * 1024;
pub const ring = 8 * 1024 * 1024;
pub const command = ring + 4096;
pub const fence = command + 4096;
pub const staging = fence + 4096;
pub const staging_bytes = @import("firmware.zig").max_blob_bytes;
pub const View = struct {
    words: []volatile u32, gpu: u64, physical: u64, tmr_offset: usize,
    pub fn create(words: []volatile u32, gpu: u64, physical: u64) Error!View {
        if (words.len < (staging + staging_bytes) / 4 or words.len > 16 * 1024 * 1024 / 4 or
            (gpu | physical) & 4095 != 0 or gpu >= l.address_limit or physical >= l.address_limit or
            words.len * 4 > l.address_limit - gpu or words.len * 4 > l.address_limit - physical) return error.Invalid;
        const tmr: usize = @intCast((try l.aligned(gpu, tmr_bytes)) - gpu);
        if ((physical + tmr) % tmr_bytes != 0 or tmr + tmr_bytes > ring) return error.Invalid;
        return .{ .words = words, .gpu = gpu, .physical = physical, .tmr_offset = tmr };
    }
    pub fn address(self: View, offset: usize) u64 { return self.gpu + offset; }
    pub fn write64(self: View, offset: usize, value: u64) void {
        self.words[offset / 4] = @truncate(value); self.words[offset / 4 + 1] = @truncate(value >> 32);
    }
    pub fn zero(self: View, offset: usize, bytes: usize) void { for (self.words[offset / 4..][0 .. bytes / 4]) |*word| word.* = 0; }
    pub fn copyFirmware(self: View, bytes: []const u8) Error!void {
        if (bytes.len == 0 or bytes.len & 3 != 0 or bytes.len > staging_bytes) return error.Firmware;
        self.zero(staging, staging_bytes);
        for (0..bytes.len / 4) |i| self.words[staging / 4 + i] = std.mem.readInt(u32, bytes[i * 4..][0..4], .little);
    }
};
pub const Owner = struct {
    self_address: usize = 0, memory: ?*mem.Owner = null, epoch: u64 = 0,
    window: io.Window = .{}, view: ?View = null,
    pub fn prepare(self: *Owner, memory: *mem.Owner) Error!void {
        if (self.self_address != 0 or memory.firmware_users != 0) return error.Busy;
        if (!memory.prepared or memory.self_address != @intFromPtr(memory)) return error.Unconfirmed;
        const map = memory.layout.?;
        if (!map.pool.owns(map.firmware) or map.firmware.span.bytes != 16 * 1024 * 1024) return error.Invalid;
        self.self_address = @intFromPtr(self); self.memory = memory; self.epoch = memory.epoch; memory.firmware_users += 1;
        try self.window.open(memory.memory.?, map.physical.offset, map.physical.bytes, map.firmware.span.offset, map.firmware.span.bytes, true);
        const ptr: [*]volatile u32 = @ptrFromInt(self.window.value.cpu_address);
        self.view = try View.create(ptr[0..@intCast(map.firmware.span.bytes / 4)], try map.mcAddress(map.firmware.span), try map.physicalAddress(map.firmware.span));
        // TMR belongs exclusively to PSP while configured. CPU writes occur
        // only before SETUP_TMR, never during execution or uncertain recovery.
        self.view.?.zero(0, @intCast(map.firmware.span.bytes));
    }
    pub fn close(self: *Owner, quiesced: bool) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or !quiesced) return false;
        const memory = self.memory orelse return false;
        if (memory.epoch != self.epoch or memory.firmware_users == 0) return false;
        if (!self.window.close()) return false;
        memory.firmware_users -= 1; self.* = .{}; return true;
    }
};
