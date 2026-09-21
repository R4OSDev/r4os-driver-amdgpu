// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Canonical reference -> pinned SG pages -> actual GPU PTEs -> GPU-VA lease.
//! The worker serializes this owner; IRQs only publish completion metadata.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const l = @import("memory_layout.zig");
const hubs = @import("memory_hubs.zig");
const valid = @import("memory_io.zig").handle;
pub const Error = hubs.Error;
pub const Mapping = struct {
    owner: ?*@import("memory_owner.zig").Owner = null,
    self_address: usize = 0, memory: ?r4os.driver_memory.Context = null,
    reference: a.GfxBufferReference = .{}, cpu: a.GfxBufferMap = .{}, dma: a.GfxDeviceLease = .{}, gpu: a.GfxDeviceLease = .{},
    adapter: u32 = 0, epoch: u64 = 0, address: u64 = 0, bytes: u64 = 0, vmid: u4 = 0,
    native_owner: u32 = 0, dma_only: bool = false,
    physical: []u64 = &.{}, prepared: bool = false, write_allowed: bool = false, ready: bool = false, translated: bool = false, flush_pending: bool = false,
    uses: [8]a.GfxFence = @splat(.{}),
    pub fn prepare(self: *Mapping, owner: *@import("memory_owner.zig").Owner, source: ?a.GfxBufferHandle,
        address: u64, bytes: u64, vmid: u4, physical: []u64) Error!void
    {
        return self.prepareSystem(owner, source, address, bytes, vmid, physical, false);
    }
    /// Retained canonical system BO plus actual DMA segments without inventing
    /// a GPU virtual address. Used for direct NBIO/IH auxiliary DMA reads.
    pub fn prepareDma(self: *Mapping, owner: *@import("memory_owner.zig").Owner, source: ?a.GfxBufferHandle, bytes: u64, physical: []u64) Error!void {
        return self.prepareSystem(owner, source, 0, bytes, 0, physical, true);
    }
    fn prepareSystem(self: *Mapping, owner: *@import("memory_owner.zig").Owner, source: ?a.GfxBufferHandle,
        address: u64, bytes: u64, vmid: u4, physical: []u64, dma_only: bool) Error!void
    {
        if (self.self_address != 0 or !owner.prepared or owner.self_address != @intFromPtr(owner) or owner.mapping_users >= 128) return error.Busy;
        const memory = owner.memory.?; const adapter = owner.adapter; const epoch = owner.epoch;
        _ = try l.pages(address, bytes, l.address_limit);
        if (adapter == 0 or epoch == 0 or vmid > 1 or (!dma_only and address == 0) or bytes / 4096 != physical.len) return error.Invalid;
        self.* = .{ .owner = owner, .self_address = @intFromPtr(self), .memory = memory, .adapter = adapter, .epoch = epoch, .address = address,
            .bytes = bytes, .vmid = vmid, .physical = physical, .dma_only = dma_only };
        owner.mapping_users += 1;
        if (source) |handle| {
            if (!valid(handle) or memory.bufferImport(&handle, &self.reference) != 1) return error.Unsupported;
        } else {
            if (memory.bufferCreate(&.{ .byte_length = bytes, .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write |
                a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_transfer_target }, &self.reference) != 1) return error.Capacity;
        }
        if (!valid(self.reference.reference) or !valid(self.reference.buffer) or self.reference.version != 1 or
            self.reference.size < @sizeOf(a.GfxBufferReference) or self.reference.flags != 0 or self.reference.reserved0 != 0) return error.Invalid;
        var desc: a.GfxBufferDescriptor = .{};
        if (memory.bufferDescribe(&self.reference.reference, &desc) != 1 or desc.version != 1 or desc.size < @sizeOf(a.GfxBufferDescriptor) or
            desc.byte_length != bytes or desc.location != a.gfx_buffer_location_system or desc.modifier != 0 or
            desc.adapter_id != 0 or desc.driver_owner != 0 or desc.device_generation != 0) return error.Invalid;
        self.write_allowed = desc.usage & (a.gfx_buffer_usage_transfer_target | a.gfx_buffer_usage_render) != 0;
        if (source == null) {
            if (memory.bufferMap(&self.reference.reference, a.gfx_buffer_map_write, 0, bytes, &self.cpu) != 1) return error.Busy;
            const cpu = self.cpu;
            if (cpu.version != 1 or cpu.size < @sizeOf(a.GfxBufferMap) or !valid(cpu.lease) or cpu.cpu_address == 0 or
                cpu.cpu_address & 4095 != 0 or cpu.cpu_address > std.math.maxInt(u64) - bytes or cpu.byte_length != bytes or
                cpu.cache_policy != a.gfx_buffer_cache_write_back or cpu.reserved0 != 0) return error.Invalid;
            const ptr: [*]u8 = @ptrFromInt(cpu.cpu_address); @memset(ptr[0..@intCast(bytes)], 0);
            if (memory.bufferUnmap(&cpu.lease) != 1) return error.Busy; self.cpu = .{};
        }
        if (memory.deviceAcquire(&self.reference.reference, &.{ .byte_length = bytes, .adapter_id = adapter, .device_generation = epoch,
            .access = 4, .dma_mask = l.address_limit - 1 }, &self.dma) != 1) return error.Unsupported;
        if (!self.leaseValid(self.dma, 4, 0) or self.dma.dma_mask != l.address_limit - 1) return error.Invalid;
        for (physical, 0..) |*page, i| {
            var segment: a.GfxDmaSegment = .{};
            if (memory.deviceSegment(&self.dma, i * 4096, &segment) != 1) return error.Unsupported;
            if (segment.version != 1 or segment.size < @sizeOf(a.GfxDmaSegment) or segment.dma_address == 0 or
                segment.dma_address & 4095 != 0 or segment.dma_address >= l.address_limit or segment.byte_length != 4096 or
                segment.next_offset != (i + 1) * 4096) return error.Sparse;
            for (physical[0..i]) |old| if (old == segment.dma_address) return error.Invalid;
            page.* = segment.dma_address;
        }
        self.prepared = true;
    }
    pub fn prepareNative(self: *Mapping, owner: *@import("memory_owner.zig").Owner, source: a.GfxBufferHandle, address: u64, physical: []u64) Error!void {
        if (self.self_address != 0 or !owner.prepared or owner.self_address != @intFromPtr(owner) or owner.mapping_users >= 128 or !valid(source)) return error.Busy;
        const bytes = std.math.mul(u64, physical.len, 4096) catch return error.Overflow;
        _ = try l.pages(address, bytes, l.address_limit);
        if (address == 0) return error.Invalid;
        const memory = owner.memory.?;
        self.* = .{ .owner = owner, .self_address = @intFromPtr(self), .memory = memory, .adapter = owner.adapter, .epoch = owner.epoch,
            .address = address, .bytes = bytes, .vmid = 1, .physical = physical };
        owner.mapping_users += 1;
        if (memory.bufferImport(&source, &self.reference) != 1) return error.Unsupported;
        var desc: a.GfxBufferDescriptor = .{};
        if (!valid(self.reference.reference) or !valid(self.reference.buffer) or memory.bufferDescribe(&self.reference.reference, &desc) != 1 or
            desc.version != 1 or desc.size < @sizeOf(a.GfxBufferDescriptor) or desc.location != a.gfx_buffer_location_device_local or
            desc.adapter_id != self.adapter or desc.device_generation != self.epoch or desc.driver_owner == 0 or
            desc.byte_length != bytes) return error.Invalid;
        const backing = try owner.backing(self.reference.buffer);
        if (backing.bytes != bytes) return error.Invalid;
        for (physical, 0..) |*page, i| page.* = backing.offset + i * 4096;
        self.native_owner = desc.driver_owner;
        self.write_allowed = desc.usage & (a.gfx_buffer_usage_transfer_target | a.gfx_buffer_usage_render) != 0;
        self.prepared = true;
    }
    /// Takes the queue's backing-only reference without sharing/importing it.
    /// The caller can always see whether ownership transferred: on transfer its
    /// handle is cleared, including subsequent partial-failure retention.
    pub fn adopt(self: *Mapping, owner: *@import("memory_owner.zig").Owner, reference: *a.GfxBufferReference,
        address: u64, physical: []u64) Error!void
    {
        if (self.self_address != 0 or !owner.prepared or owner.self_address != @intFromPtr(owner) or owner.mapping_users >= 128) return error.Busy;
        if (reference.version != 1 or reference.size < @sizeOf(a.GfxBufferReference) or reference.flags != a.gfx_buffer_reference_mapping_only or reference.reserved0 != 0 or
            !valid(reference.reference) or !valid(reference.buffer) or address == 0 or address & 4095 != 0) return error.Invalid;
        var desc: a.GfxBufferDescriptor = .{};
        const memory = owner.memory.?;
        if (memory.bufferDescribe(&reference.reference, &desc) != 1 or desc.version != 1 or desc.size < @sizeOf(a.GfxBufferDescriptor)) return error.Invalid;
        const rounded = try l.aligned(desc.byte_length, 4096);
        _ = try l.pages(address, rounded, l.address_limit);
        if (desc.byte_length == 0 or rounded / 4096 != physical.len) return error.Invalid;
        if (desc.location == a.gfx_buffer_location_system) {
            if (desc.modifier != 0) return error.Invalid;
            if (desc.adapter_id != 0 or desc.driver_owner != 0 or desc.device_generation != 0) return error.Stale;
        } else if (desc.location != a.gfx_buffer_location_device_local or desc.adapter_id != owner.adapter or desc.device_generation != owner.epoch or desc.driver_owner == 0) return error.Stale;
        self.* = .{ .owner = owner, .self_address = @intFromPtr(self), .memory = memory, .adapter = owner.adapter, .epoch = owner.epoch,
            .reference = reference.*, .address = address, .bytes = desc.byte_length, .vmid = 1, .physical = physical,
            .write_allowed = desc.usage & (a.gfx_buffer_usage_transfer_target | a.gfx_buffer_usage_render) != 0 };
        reference.* = .{}; owner.mapping_users += 1;
        if (desc.location == a.gfx_buffer_location_device_local) {
            const backing = try owner.backing(self.reference.buffer);
            if (backing.bytes < rounded) return error.Invalid;
            for (physical, 0..) |*page, i| page.* = backing.offset + i * 4096;
            self.native_owner = desc.driver_owner;
        } else {
            if (memory.deviceAcquire(&self.reference.reference, &.{ .byte_length = self.bytes, .adapter_id = owner.adapter,
                .device_generation = owner.epoch, .access = 4, .dma_mask = l.address_limit - 1 }, &self.dma) != 1) return error.Unsupported;
            if (!self.leaseValid(self.dma, 4, 0) or self.dma.dma_mask != l.address_limit - 1) return error.Invalid;
            for (physical, 0..) |*page, i| {
                var segment: a.GfxDmaSegment = .{};
                const offset = i * 4096; const count = @min(@as(u64, 4096), self.bytes - offset);
                if (memory.deviceSegment(&self.dma, offset, &segment) != 1) return error.Unsupported;
                if (segment.version != 1 or segment.size < @sizeOf(a.GfxDmaSegment) or segment.dma_address == 0 or
                    segment.dma_address & 4095 != 0 or segment.dma_address > l.address_limit - 4096 or segment.byte_length != count or
                    segment.next_offset != offset + count) return error.Sparse;
                page.* = segment.dma_address;
            }
        }
        self.prepared = true;
    }
    fn leaseValid(self: *const Mapping, lease: a.GfxDeviceLease, access: u32, address: u64) bool {
        return lease.version == 1 and lease.size >= @sizeOf(a.GfxDeviceLease) and valid(lease.lease) and lease.byte_offset == 0 and
            lease.byte_length == self.bytes and lease.gpu_virtual_address == address and lease.adapter_id == self.adapter and
            lease.device_generation == self.epoch and lease.driver_owner != 0 and lease.access == access and
            lease.address_space == @as(u32, if (access == 3) 1 else 0);
    }
    pub fn publish(self: *Mapping, tables: anytype, io: anytype, write: bool, execute: bool) Error!void {
        if (self.dma_only or !self.prepared or self.owner == null or !self.owner.?.controller.enabled or self.owner.?.controller.epoch != self.epoch or (write and !self.write_allowed) or self.self_address != @intFromPtr(self) or self.ready or self.translated or self.cpu.lease.id != 0 or (self.native_owner == 0 and !self.leaseValid(self.dma, 4, 0))) return error.Busy;
        try tables.map(self.address, self.physical, .{ .system = self.native_owner == 0, .write = write, .execute = execute });
        self.translated = true; self.flush_pending = true;
        try hubs.flush(io, self.vmid); self.flush_pending = false;
        if (self.memory.?.deviceAcquire(&self.reference.reference, &.{ .byte_length = self.bytes, .gpu_virtual_address = self.address,
            .adapter_id = self.adapter, .device_generation = self.epoch, .access = 3, .address_space = 1 }, &self.gpu) != 1) return error.Unsupported;
        if (!self.leaseValid(self.gpu, 3, self.address) or self.gpu.driver_owner != (if (self.native_owner != 0) self.native_owner else self.dma.driver_owner)) return error.Invalid;
        self.ready = true;
    }
    pub fn retain(self: *Mapping, fence: a.GfxFence) Error!void {
        if (!self.ready or self.self_address != @intFromPtr(self) or fence.adapter_id != self.adapter or
            fence.timeline == 0 or fence.point == 0 or fence.device_generation == 0 or fence.reset_generation == 0) return error.Invalid;
        // Queue/reset epoch is intentionally not compared with memory epoch.
        // Exact completion identity is required, even across multiple queues.
        for (&self.uses) |*use| if (std.meta.eql(use.*, fence)) return error.Busy;
        for (&self.uses) |*use| if (use.timeline == 0) { use.* = fence; return; };
        return error.Capacity;
    }
    /// Called by the completion worker after real fence/quiescence evidence.
    pub fn complete(self: *Mapping, fence: a.GfxFence) Error!void {
        if (self.self_address != @intFromPtr(self) or fence.timeline == 0) return error.Stale;
        for (&self.uses) |*use| if (std.meta.eql(use.*, fence)) { use.* = .{}; return; };
        return error.Stale;
    }
    pub fn close(self: *Mapping, tables: anytype, io: anytype) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        for (&self.uses) |*use| if (use.timeline != 0) return false;
        self.ready = false;
        if (self.translated) {
            tables.unmap(self.address, self.physical.len) catch return false;
            self.translated = false; self.flush_pending = true;
        }
        // PTE removal and both TLB ACKs precede any canonical lease release.
        if (self.flush_pending) { hubs.flush(io, self.vmid) catch return false; self.flush_pending = false; }
        const memory = self.memory orelse return false;
        if (self.gpu.lease.id != 0) { if (memory.deviceRelease(&self.gpu, 1) != 1) return false; self.gpu = .{}; }
        if (self.dma.lease.id != 0) { if (memory.deviceRelease(&self.dma, 1) != 1) return false; self.dma = .{}; }
        if (self.cpu.lease.id != 0) { if (memory.bufferUnmap(&self.cpu.lease) != 1) return false; self.cpu = .{}; }
        if (self.reference.reference.id != 0) { if (memory.bufferRelease(&self.reference.reference) != 1) return false; self.reference = .{}; }
        if (memory.collect() != 1) return false;
        const owner = self.owner orelse return false;
        if (owner.self_address != @intFromPtr(owner) or owner.epoch != self.epoch or owner.mapping_users == 0) return false;
        owner.mapping_users -= 1;
        self.* = .{}; return true;
    }
};
