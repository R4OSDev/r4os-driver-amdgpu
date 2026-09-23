// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const l = @import("memory_layout.zig");
const pages = @import("memory_pages.zig");
const io = @import("memory_io.zig");
const hubs = @import("memory_hubs.zig");
pub const Error = hubs.Error;
pub const Owner = struct {
    const Record = struct {
        allocation: l.Allocation = .{}, reservation: a.GfxOwnedBufferReservation = .{}, reference: a.GfxBufferReference = .{},
        release: a.GfxOwnedBufferRelease = .{}, committed: bool = false,
    };
    self_address: usize = 0, memory: ?r4os.driver_memory.Context = null, layout: ?*l.Layout = null,
    heap: ?r4os.r4dev.DriverHeapContext = null,
    adapter: u32 = 0, epoch: u64 = 0, budget_live: bool = false, prepared: bool = false, mapping_users: u32 = 0, engine_users: u32 = 0, firmware_users: u32 = 0, start_users: u32 = 0,
    registers: io.Registers = .{}, table_window: io.Window = .{}, context_window: io.Window = .{},
    gart: ?pages.Flat = null, virtual: pages.Virtual = .{}, controller: hubs.Controller = .{},
    records: [128]Record = @splat(.{}), orphan_release: a.GfxOwnedBufferRelease = .{},
    pub fn prepare(self: *Owner, ctx: *const r4os.r4dev.DriverContext, map: *l.Layout, bar: u64, adapter: u32, memory_epoch: u64) Error!void {
        if (self.self_address != 0) return error.Busy;
        if (adapter == 0 or memory_epoch == 0 or map.native_budget == 0) return error.Invalid;
        const memory = ctx.memory() orelse return error.Unsupported;
        if (memory.unmanagedSpan(map.physical.offset, map.physical.bytes) != 1) return error.Unsupported;
        self.self_address = @intFromPtr(self); self.memory = memory; self.layout = map; self.adapter = adapter; self.epoch = memory_epoch;
        self.heap = ctx.heap();
        try self.registers.open(ctx, bar);
        try self.table_window.open(memory, map.physical.offset, map.physical.bytes, map.tables.span.offset, map.tables.span.bytes, true);
        try self.context_window.open(memory, map.physical.offset, map.physical.bytes, map.contexts.span.offset, map.contexts.span.bytes, true);
        self.gart = try pages.Flat.init(try self.table_window.words(), map.gart);
        const words = try self.context_window.words();
        for (words) |*word| word.* = 0;
        try self.virtual.init(words[0 .. words.len - 512], try map.physicalAddress(map.contexts.span));
        try self.registers.barrier();
        var state: a.GfxDeviceBudgetState = .{};
        if (memory.memoryBudget(&.{ .adapter_id = adapter, .memory_generation = memory_epoch,
            .operation = a.gfx_memory_budget_configure, .limit_bytes = map.native_budget }, &state) != 1) return error.Capacity;
        self.budget_live = true;
        if (state.version != 1 or state.size < @sizeOf(a.GfxDeviceBudgetState) or state.adapter_id != adapter or
            state.memory_generation != memory_epoch or state.flags != 0 or state.limit_bytes != map.native_budget or state.charged_bytes != 0) return error.Invalid;
        self.prepared = true;
    }
    pub fn enable(self: *Owner, gate: hubs.Gate) Error!void {
        if (!self.prepared or self.self_address != @intFromPtr(self) or gate.memory_epoch != self.epoch) return error.Unconfirmed;
        const map = self.layout.?;
        const scratch = try map.physicalAddress(.{ .offset = map.contexts.span.end() - 4096, .bytes = 4096 });
        try self.controller.enable(&self.registers, map, try self.virtual.root(), scratch, gate);
    }
    /// Copy-only identity/table reads; safe for the parent while the queue
    /// worker is still draining. It must not mutate that worker's BO pool.
    pub fn closeAdmission(self: *const Owner) bool {
        if (!self.budget_live) return true;
        return (self.memory orelse return false).deviceLost(self.adapter, self.epoch, false) == 1;
    }
    /// Device-local means opaque driver-owned storage. On Picasso those pages
    /// come from the BIOS UMA carveout, not an additional RAM allocation.
    /// WINSVC's location_device_local + adapter + memory_generation checks fit.
    pub fn create(self: *Owner, request: a.GfxBufferDescriptor) Error!a.GfxBufferReference {
        if (!self.prepared or self.self_address != @intFromPtr(self)) return error.Busy;
        if (request.version != 1 or request.size < @sizeOf(a.GfxBufferDescriptor) or request.byte_length == 0 or
            request.alignment == 0 or !imageModifier(request.modifier) or request.location != a.gfx_buffer_location_device_local or
            request.adapter_id != self.adapter or request.device_generation != self.epoch or
            request.usage & (a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write) != 0) return error.Invalid;
        if (try l.aligned(request.byte_length, @max(@as(u64, 4096), request.alignment)) != request.byte_length) return error.Invalid;
        var slot: ?*Record = null; for (&self.records) |*entry| if (entry.allocation.serial == 0) { slot = entry; break; };
        const record = slot orelse return error.Capacity;
        record.allocation = try self.layout.?.pool.allocate(request.byte_length, request.alignment, .buffer);
        const memory = self.memory.?;
        if (memory.bufferReserve(&request, record.allocation.serial, &record.reservation) != 1) return error.Capacity;
        const ticket = record.reservation;
        if (ticket.version != 1 or ticket.size < @sizeOf(a.GfxOwnedBufferReservation) or !io.handle(ticket.buffer) or !io.handle(ticket.reference) or
            ticket.cookie != record.allocation.serial or ticket.allocation_bytes != record.allocation.span.bytes or ticket.adapter_id != self.adapter or
            ticket.device_generation != self.epoch or ticket.driver_owner == 0 or ticket.driver_generation == 0 or ticket.reserved0 != 0) return error.Invalid;
        if (memory.bufferCommit(&ticket, &record.reference) != 1) return error.Busy;
        record.committed = true;
        if (!io.handle(record.reference.reference) or !std.meta.eql(record.reference.buffer, ticket.buffer) or
            !std.meta.eql(record.reference.reference, ticket.reference)) return error.Invalid;
        return record.reference;
    }
    // Allocation admits opaque uncompressed GFX9 layouts. Actual access still
    // requires measured AddrLib geometry, exact pitch, size and usage checks.
    pub fn imageModifier(value: u64) bool {
        if (value == 0) return true;
        const allowed: u64 = 0x0200000000000001 | (31 << 8) | (7 << 21) | (7 << 24);
        if (value & ~allowed != 0 or value & 0xff000000000000ff != 0x0200000000000001) return false;
        const sw = (value >> 8) & 31;
        return sw == 9 or sw == 10 or sw == 22 or sw == 25 or sw == 26 or sw == 27;
    }
    pub fn backing(self: *const Owner, handle: a.GfxBufferHandle) Error!l.Span {
        if (!self.prepared or self.self_address != @intFromPtr(self)) return error.Stale;
        for (&self.records) |*record| if (record.committed and std.meta.eql(record.reference.buffer, handle)) {
            if (!self.layout.?.pool.owns(record.allocation)) return error.Stale;
            return .{ .offset = try self.layout.?.physicalAddress(record.allocation.span), .bytes = record.allocation.span.bytes };
        };
        return error.Stale;
    }
    pub fn drop(self: *Owner, reference: a.GfxBufferHandle) bool {
        if (self.self_address != @intFromPtr(self)) return false;
        for (&self.records) |*record| if (record.committed and std.meta.eql(record.reference.reference, reference)) {
            if (self.memory.?.bufferRelease(&reference) != 1) return false;
            record.reference.reference = .{}; return true;
        };
        return false;
    }
    pub fn collect(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        const memory = self.memory orelse return false;
        for (&self.records) |*record| {
            if (record.allocation.serial == 0) continue;
            if (!record.committed) {
                if (record.reservation.cookie != 0 and memory.bufferAbort(&record.reservation, 1) != 1) return false;
                self.layout.?.pool.release(record.allocation) catch return false; record.* = .{};
            } else if (record.release.cookie != 0) {
                if (!self.finish(record)) return false;
            }
        }
        for (0..self.records.len) |_| {
            var release: a.GfxOwnedBufferRelease = .{};
            const rc = memory.bufferTakeRelease(self.adapter, self.epoch, &release);
            if (rc == a.gfx_buffer_error_busy) return true;
            if (rc != 1) return false;
            var found: ?*Record = null;
            for (&self.records) |*record| if (record.committed and record.allocation.serial == release.cookie and
                std.meta.eql(record.reservation.buffer, release.buffer) and record.reservation.driver_owner == release.driver_owner and
                record.reservation.driver_generation == release.driver_generation and record.allocation.span.bytes == release.byte_length) { found = record; break; };
            const record = found orelse { self.orphan_release = release; return false; };
            record.release = release;
            if (!self.finish(record)) return false;
        }
        return true;
    }
    fn finish(self: *Owner, record: *Record) bool {
        // The canonical release ticket is only available after every external
        // reference, CPU map, GPU mapping and queue/fence lease has retired.
        const ticket = record.release;
        if (ticket.version != 1 or ticket.size < @sizeOf(a.GfxOwnedBufferRelease) or ticket.attempt == 0 or
            ticket.adapter_id != self.adapter or ticket.device_generation != self.epoch or ticket.reserved0 != 0 or
            !self.layout.?.pool.owns(record.allocation)) return false;
        if (self.memory.?.bufferFinishRelease(&ticket, 1) != 1) return false;
        self.layout.?.pool.release(record.allocation) catch return false;
        record.* = .{}; return true;
    }
    pub fn close(self: *Owner, gate: hubs.Gate) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        if (self.mapping_users != 0 or self.engine_users != 0 or self.firmware_users != 0 or self.start_users != 0 or self.orphan_release.cookie != 0 or self.virtual.mapped_pages != 0) return false;
        if (self.gart) |gart| if (gart.mapped_pages != 0) return false;
        // All child DMA/firmware/VM owners have retired. Invalidate backing
        // before collecting release tickets so idle application references
        // cannot deadlock recovery. Those invalid references stay closeable.
        self.controller.disable(&self.registers, gate) catch return false;
        if (self.budget_live) {
            if (self.memory.?.deviceLost(self.adapter, self.epoch, true) != 1) return false;
            self.budget_live = false;
        }
        if (!self.collect()) return false;
        for (&self.records) |*record| if (record.allocation.serial != 0) return false;
        self.prepared = false;
        if (!self.context_window.close() or !self.table_window.close() or !self.registers.close()) return false;
        self.* = .{}; return true;
    }
};
