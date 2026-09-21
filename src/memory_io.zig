// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const r4os = @import("r4os");
const a = r4os.abi;
const regs = @import("memory_registers.zig");
const Error = @import("memory_hubs.zig").Error;
pub const Window = struct {
    memory: ?r4os.driver_memory.Context = null,
    value: a.GfxMmioWindow = .{}, pending: bool = false,
    pub fn open(self: *Window, memory: r4os.driver_memory.Context, base: u64, total: u64, offset: u64, bytes: u64, wc: bool) Error!void {
        if (self.pending or self.value.handle.id != 0) return error.Busy;
        _ = try @import("memory_layout.zig").pages(base, total, @as(u64, 1) << 48);
        _ = try @import("memory_layout.zig").pages(offset, bytes, total);
        self.memory = memory; self.pending = true;
        const cache: u32 = if (wc) a.gfx_buffer_cache_write_combining else a.gfx_buffer_cache_uncached;
        if (memory.mmioMap(&.{ .resource_base = base, .resource_bytes = total, .byte_offset = offset, .byte_length = bytes,
            .cache_policy = cache, .resource_flags = @intFromBool(wc) }, &self.value) != 1) return error.Unsupported;
        const v = self.value;
        if (v.version != 1 or v.size < @sizeOf(a.GfxMmioWindow) or !handle(v.handle) or v.cpu_address == 0 or
            v.cpu_address & 4095 != 0 or v.cpu_address > (~@as(u64, 0)) - bytes or v.byte_length != bytes or
            v.physical_address != base + offset or v.cache_policy != cache or v.flags & ~@as(u32, 1) != 0) return error.Invalid;
    }
    /// Used only after all CPU accesses and device reachability have ended.
    pub fn close(self: *Window) bool {
        if (!self.pending and self.value.handle.id == 0) return true;
        const memory = self.memory orelse return false;
        if (self.value.handle.id != 0) {
            if (memory.mmioUnmap(&self.value.handle, 1) != 1) return false;
            self.value = .{};
        }
        if (memory.collect() != 1) return false;
        self.* = .{}; return true;
    }
    pub fn words(self: *const Window) Error![]volatile u64 {
        const v = self.value;
        if (!handle(v.handle) or v.cpu_address == 0 or v.cache_policy != a.gfx_buffer_cache_write_combining) return error.Invalid;
        const ptr: [*]volatile u64 = @ptrFromInt(v.cpu_address); return ptr[0..@intCast(v.byte_length / 8)];
    }
};
pub fn handle(value: a.GfxBufferHandle) bool { return value.id != 0 and value.generation != 0 and value.reserved0 == 0; }
pub const Registers = struct {
    window: Window = .{}, clock: ?r4os.r4dev.DriverResourceContext = null,
    pub fn open(self: *Registers, ctx: *const r4os.r4dev.DriverContext, base: u64) Error!void {
        self.clock = ctx.resources() orelse return error.Unsupported;
        try self.window.open(ctx.memory() orelse return error.Unsupported, base, regs.required_prefix, 0, regs.required_prefix, false);
    }
    pub fn read(self: *Registers, offset: u32) Error!u32 {
        if (!handle(self.window.value.handle) or offset & 3 != 0 or offset >= self.window.value.byte_length) return error.Invalid;
        const ptr: [*]const volatile u32 = @ptrFromInt(self.window.value.cpu_address); return ptr[offset / 4];
    }
    pub fn write(self: *Registers, offset: u32, value: u32) Error!void {
        if (!handle(self.window.value.handle) or offset & 3 != 0 or offset >= self.window.value.byte_length) return error.Invalid;
        const ptr: [*]volatile u32 = @ptrFromInt(self.window.value.cpu_address); ptr[offset / 4] = value;
    }
    pub fn barrier(_: *Registers) Error!void { asm volatile ("mfence" ::: .{ .memory = true }); }
    pub fn nowNs(self: *Registers) u64 { return self.clock.?.nowNs(); }
    pub fn close(self: *Registers) bool {
        if (!self.window.close()) return false; self.clock = null; return true;
    }
};
