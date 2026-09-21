// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const r4os = @import("r4os");
const a = r4os.abi;
const memregs = @import("memory_registers.zig");
const regs = @import("registers.zig");
const identity = @import("identity.zig");
const boot = @import("boot.zig");
pub const Error = error{ MemoryContract, Map, Window, Unstable, Cleanup, Busy } || identity.Error || boot.Error;
pub const Capture = struct {
    window: a.GfxMmioWindow = .{},
    cleanup_pending: bool = false,

    pub fn close(self: *Capture, ctx: *const r4os.r4dev.DriverContext) bool {
        if (self.window.handle.id == 0 and !self.cleanup_pending) return true;
        const memory = ctx.memory() orelse return false;
        // There are no DMA jobs, IRQs, callbacks or writes in the probe. The
        // synchronous register reads have ended before this quiesced release.
        if (self.window.handle.id != 0) {
            if (memory.mmioUnmap(&self.window.handle, 1) != a.gfx_buffer_result_ok) return false;
            self.window = .{};
        }
        // Failed maps can leave private partial mappings without a handle.
        if (memory.collect() != a.gfx_buffer_result_ok) return false;
        self.cleanup_pending = false;
        return true;
    }
    fn page(self: *Capture, ctx: *const r4os.r4dev.DriverContext, base: u64, offset: u64) Error!void {
        if (self.window.handle.id != 0 or self.cleanup_pending) return error.Busy;
        const memory = ctx.memory() orelse return error.MemoryContract;
        const request: a.GfxMmioRequest = .{ .resource_base = base, .resource_bytes = memregs.required_prefix,
            .byte_offset = offset, .byte_length = regs.page_bytes, .cache_policy = a.gfx_buffer_cache_uncached };
        self.cleanup_pending = true;
        if (memory.mmioMap(&request, &self.window) != a.gfx_buffer_result_ok) return error.Map;
        const window = self.window;
        if (window.version != 1 or window.size < @sizeOf(a.GfxMmioWindow) or window.handle.id == 0 or window.handle.generation == 0 or
            window.cpu_address == 0 or window.cpu_address & 3 != 0 or window.cpu_address > (~@as(u64, 0)) - regs.page_bytes or
            window.physical_address != base + offset or window.byte_length != regs.page_bytes or
            window.cache_policy != a.gfx_buffer_cache_uncached) return error.Window;
    }
    fn read(self: *const Capture, offset: u32) u32 {
        const words: [*]const volatile u32 = @ptrFromInt(self.window.cpu_address);
        return words[(offset % regs.page_bytes) / 4];
    }
    pub fn measure(self: *Capture, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot) Error!boot.Measurement {
        if (!identity.target(snapshot.pci) or snapshot.command & 2 == 0 or snapshot.bars[5].kind != .memory32 or
            (snapshot.bars[5].bytes != 0 and snapshot.bars[5].bytes < memregs.required_prefix) or
            snapshot.bars[5].prefetch or snapshot.bars[5].base == 0 or snapshot.bars[5].base & 0xfff != 0) return error.Resource;
        const base = snapshot.bars[5].base;
        try self.page(ctx, base, regs.strap & ~@as(u64, 0xfff));
        const strap = self.read(regs.strap); const megabytes = self.read(regs.memsize);
        if (strap != self.read(regs.strap) or megabytes != self.read(regs.memsize)) return error.Unstable;
        const chip = try identity.chip(snapshot.pci.device_id, strap);
        if (!self.close(ctx)) return error.Cleanup;
        // Raven2 is identified explicitly, but GC9.1 MMIO and Picasso
        // firmware/layout assumptions are not extended to its GC9.2.2 path.
        if (chip.family != .picasso) return .{ .chip = chip };
        try self.page(ctx, base, regs.fb_offset & ~@as(u64, 0xfff));
        const fb = self.read(regs.fb_offset);
        const gc_base = self.read(memregs.gfx.MC_VM_FB_LOCATION_BASE);
        const gc_top = self.read(memregs.gfx.MC_VM_FB_LOCATION_TOP);
        if (fb != self.read(regs.fb_offset) or gc_base != self.read(memregs.gfx.MC_VM_FB_LOCATION_BASE) or gc_top != self.read(memregs.gfx.MC_VM_FB_LOCATION_TOP)) return error.Unstable;
        if (!self.close(ctx)) return error.Cleanup;
        // MMHUB's MC aperture is not the CPU-physical UMA base.
        try self.page(ctx, base, memregs.mm.MC_VM_FB_LOCATION_BASE & ~@as(u64, 0xfff));
        const mc_base = self.read(memregs.mm.MC_VM_FB_LOCATION_BASE);
        const mc_top = self.read(memregs.mm.MC_VM_FB_LOCATION_TOP);
        if (mc_base != self.read(memregs.mm.MC_VM_FB_LOCATION_BASE) or mc_top != self.read(memregs.mm.MC_VM_FB_LOCATION_TOP) or
            gc_base != mc_base or gc_top != mc_top) return error.Unstable;
        if (!self.close(ctx)) return error.Cleanup;
        const mask = memregs.mm.MC_VM_FB_LOCATION_BASE__FB_BASE_MASK;
        if (mc_base == 0xffffffff or mc_top == 0xffffffff or mc_base & ~mask != 0 or mc_top & ~mask != 0 or mc_top < mc_base) return error.Uma;
        const mc: boot.Range = .{ .base = @as(u64, mc_base) << 24, .bytes = (@as(u64, mc_top) - mc_base + 1) << 24 };
        const physical = try boot.uma(fb, megabytes);
        if (mc.bytes < physical.bytes) return error.Uma;
        // Revalidate the first page after both independent hub pages.
        try self.page(ctx, base, regs.strap & ~@as(u64, 0xfff));
        if (strap != self.read(regs.strap) or megabytes != self.read(regs.memsize)) return error.Unstable;
        if (!self.close(ctx)) return error.Cleanup;
        return .{ .chip = chip, .uma = physical, .mc = mc };
    }
};
