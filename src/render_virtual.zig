// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Canonical VA requests -> pinned system/UMA pages and real VMID1 PTEs.
//! Fixed slots bound residency; neither an app token nor a close request is a
//! GPU completion proof. Only kernel-retained native bindings permit lookup.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const c = @import("r4amd");
const Memory = @import("memory_owner.zig").Owner;
const Mapping = @import("memory_mapping.zig").Mapping;
const Error = @import("start_common.zig").Error;
const valid = @import("memory_io.zig").handle;
pub const capacity = 32;
const stride: u64 = 64 * 1024 * 1024;
const Range = struct { serial: u64 = 0, resource: a.GfxBufferHandle = .{}, request: a.GfxVirtualRequest = .{}, address: u64 = 0, children: u32 = 0, ready: bool = false };
pub const Binding = struct { serial: u64 = 0, resource: a.GfxBufferHandle = .{}, parent: u8 = 0, map: Mapping = .{}, descriptor: a.GfxBufferDescriptor = .{}, ready: bool = false, pages: [stride / 4096]u64 = undefined };
pub const Owner = struct {
    memory: ?*Memory = null,
    rt: ?*@import("queue_runtime.zig").Owner = null,
    handle: a.GfxBufferHandle = .{},
    serial: u64 = 0,
    closing: bool = false,
    ranges: [capacity]Range = @splat(.{}),
    bindings: [capacity]Binding = @splat(.{}),
    pending: ?a.GfxVirtualJob = null,
    slot: ?u8 = null,
    result: ?i32 = null,
    detached: bool = false,
    fn notify(raw: usize) callconv(.c) i32 {
        const self: *Owner = @ptrFromInt(raw);
        @import("queue_runtime.zig").Owner.notify(@intFromPtr(self.rt.?));
        return 0;
    }
    pub fn prepare(self: *Owner, memory: *Memory, rt: *@import("queue_runtime.zig").Owner) Error!void {
        if (self.memory != null) return error.Busy;
        const span: @import("memory_layout.zig").Span = .{ .offset = c.native_va_start, .bytes = c.native_va_end - c.native_va_start };
        if (span.overlaps(memory.layout.?.mc) or span.overlaps(memory.layout.?.gart) or span.bytes != capacity * stride) return error.Invalid;
        self.memory = memory;
        self.rt = rt;
        if (memory.memory.?.virtualRegister(&.{ .adapter_id = memory.adapter, .memory_generation = memory.epoch, .notify = @intFromPtr(&notify), .context = @intFromPtr(self) }, &self.handle) != 1) return error.Unsupported;
    }
    fn token(self: *const Owner, serial: u64, kind: u32) a.GfxVirtualToken {
        return .{ .opaque0 = self.memory.?.epoch, .opaque1 = serial, .opaque2 = kind };
    }
    fn findRange(self: *Owner, t: a.GfxVirtualToken) Error!u8 {
        if (t.opaque0 != self.memory.?.epoch or t.opaque1 == 0 or t.opaque2 != 1) return error.Stale;
        for (&self.ranges, 0..) |*r, i| if (r.serial == t.opaque1) return @intCast(i);
        return error.Stale;
    }
    fn findBinding(self: *Owner, t: a.GfxVirtualToken) Error!u8 {
        if (t.opaque0 != self.memory.?.epoch or t.opaque1 == 0 or t.opaque2 != 2) return error.Stale;
        for (&self.bindings, 0..) |*b, i| if (b.serial == t.opaque1) return @intCast(i);
        return error.Stale;
    }
    pub fn execution(self: *Owner, value: a.GfxNativeBinding) Error!*Binding {
        if (self.closing or !valid(self.handle) or value.version != 1 or value.size != @sizeOf(a.GfxNativeBinding) or value.reserved0 != 0 or value.access > 1) return error.Stale;
        const slot = try self.findBinding(value.token);
        const b = &self.bindings[slot];
        if (!b.ready or !b.map.ready or !std.meta.eql(value.binding, b.resource) or value.address != b.map.address or value.byte_length != b.map.bytes or
            (value.access == 1 and !b.map.write_allowed)) return error.Stale;
        if (self.pending) |job| if (job.operation == 1 and std.meta.eql(job.resource, b.resource)) return error.Retained;
        return b;
    }
    fn create(self: *Owner, job: a.GfxVirtualJob) Error!void {
        const memory = self.memory.?;
        const r = job.request;
        if (self.closing) return error.Stale;
        if (r.version != 1 or r.size != @sizeOf(a.GfxVirtualRequest) or r.reserved0 != 0 or r.reserved1 != 0 or r.adapter_id != memory.adapter or
            r.memory_generation != memory.epoch or r.flags != 0 or r.byte_length == 0 or r.byte_length > stride or r.byte_length & 4095 != 0 or
            r.location > 1 or (r.kind != 1 and r.kind != 2) or r.deadline_ns <= memory.registers.nowNs() or self.serial == std.math.maxInt(u64)) return error.Invalid;
        if (r.kind == 1) {
            if (r.alignment < 4096 or r.alignment > stride or !std.math.isPowerOfTwo(r.alignment) or r.byte_offset != 0 or r.virtual_offset != 0 or
                !std.meta.eql(r.parent, a.GfxBufferHandle{}) or !std.meta.eql(r.reference, a.GfxBufferHandle{})) return error.Invalid;
            for (&self.ranges, 0..) |*entry, i| if (entry.serial == 0) {
                const address = c.native_va_start + i * stride;
                if (r.fixed_address != 0 and r.fixed_address != address) continue;
                self.serial += 1;
                entry.* = .{ .serial = self.serial, .resource = job.resource, .request = r, .address = address };
                self.slot = @intCast(i);
                return;
            };
            return error.Capacity;
        }
        if (r.byte_offset != 0 or r.virtual_offset != 0 or r.fixed_address != 0 or r.alignment != 0) return error.Unsupported;
        const parent = try self.findRange(job.parent_token);
        const range = &self.ranges[parent];
        if (!range.ready or !std.meta.eql(range.resource, r.parent) or r.byte_length != range.request.byte_length or range.children != 0 or
            job.reference.version != 1 or job.reference.size < @sizeOf(a.GfxBufferReference) or job.reference.flags != 0 or job.reference.reserved0 != 0 or
            !valid(job.reference.reference) or !valid(job.reference.buffer)) return error.Invalid;
        var desc: a.GfxBufferDescriptor = .{};
        if (memory.memory.?.bufferDescribe(&job.reference.reference, &desc) != 1 or desc.version != 1 or desc.size < @sizeOf(a.GfxBufferDescriptor) or
            desc.byte_length != r.byte_length or desc.reserved0 != 0 or @intFromBool(desc.location == a.gfx_buffer_location_device_local) != range.request.location) return error.Invalid;
        for (&self.bindings, 0..) |*entry, i| if (entry.serial == 0) {
            self.serial += 1;
            entry.serial = self.serial;
            entry.resource = job.resource;
            entry.parent = parent;
            entry.descriptor = desc;
            self.slot = @intCast(i);
            range.children += 1;
            const pages = entry.pages[0..@intCast(r.byte_length / 4096)];
            if (desc.location == a.gfx_buffer_location_device_local) try entry.map.prepareNative(memory, job.reference.reference, range.address, pages) else if (desc.location == a.gfx_buffer_location_system) try entry.map.prepare(memory, job.reference.reference, range.address, r.byte_length, 1, pages) else return error.Unsupported;
            try entry.map.publish(&memory.virtual, &memory.registers, entry.map.write_allowed, true);
            return;
        };
        return error.Capacity;
    }
    fn destroy(self: *Owner, kind: u32, slot: u8) bool {
        if (kind == 1) {
            if (self.ranges[slot].children != 0) return false;
            return true;
        }
        const b = &self.bindings[slot];
        const memory = self.memory.?;
        return b.map.close(&memory.virtual, &memory.registers);
    }
    fn clear(self: *Owner, kind: u32, slot: u8) void {
        if (kind == 1) {
            self.ranges[slot] = .{};
            return;
        }
        const b = &self.bindings[slot];
        std.debug.assert(b.map.self_address == 0 and self.ranges[b.parent].children != 0);
        self.ranges[b.parent].children -= 1;
        b.serial = 0;
        b.resource = .{};
        b.ready = false;
    }
    pub fn step(self: *Owner) bool {
        const memory = self.memory orelse return true;
        if (self.handle.id == 0) return true;
        if (self.pending == null) {
            var job: a.GfxVirtualJob = .{};
            const rc = memory.memory.?.virtualTake(&self.handle, &job);
            if (rc == a.gfx_buffer_error_busy) return true;
            if (rc == a.gfx_buffer_error_stale and self.empty()) {
                self.handle = .{};
                return true;
            }
            if (rc != 1) return false;
            self.pending = job;
            if (job.version != 1 or job.size < @sizeOf(a.GfxVirtualJob) or job.reserved0 != 0 or job.operation > 1) {
                self.result = a.gfx_buffer_error_invalid;
            }
        }
        const job = self.pending.?;
        const kind = job.request.kind;
        if (self.result == null) {
            if (job.operation == 0) {
                self.create(job) catch |err| {
                    self.result = switch (err) {
                        error.Capacity => a.gfx_buffer_error_oom,
                        error.Unsupported => a.gfx_buffer_error_unsupported,
                        error.Stale => a.gfx_buffer_error_stale,
                        else => a.gfx_buffer_error_invalid,
                    };
                };
                if (self.result == null) self.result = 1;
            } else {
                self.slot = if (kind == 1) self.findRange(job.token) catch return false else if (kind == 2) self.findBinding(job.token) catch return false else return false;
                const handle = if (kind == 1) self.ranges[self.slot.?].resource else self.bindings[self.slot.?].resource;
                if (!std.meta.eql(handle, job.resource)) return false;
                self.result = 1;
            }
        }
        var t: a.GfxVirtualToken = .{};
        var address: u64 = 0;
        if (self.slot) |slot| {
            if (job.operation == 1 or self.result.? != 1) {
                if (!self.detached) {
                    if (!self.destroy(kind, slot)) return false;
                    self.detached = true;
                }
            } else if (kind == 1) {
                const entry = &self.ranges[slot];
                t = self.token(entry.serial, 1);
                address = entry.address;
            } else {
                const entry = &self.bindings[slot];
                t = self.token(entry.serial, 2);
                address = entry.map.address;
            }
        }
        if (memory.memory.?.virtualComplete(&self.handle, &.{ .resource = job.resource, .operation = job.operation, .result = self.result.?, .token = t, .address = address }) != 1) return false;
        if (self.slot) |slot| {
            if (self.detached) self.clear(kind, slot) else if (kind == 1) self.ranges[slot].ready = true else self.bindings[slot].ready = true;
        }
        self.pending = null;
        self.slot = null;
        self.result = null;
        self.detached = false;
        return true;
    }
    fn empty(self: *const Owner) bool {
        if (self.pending != null) return false;
        for (&self.ranges) |*r| if (r.serial != 0) return false;
        for (&self.bindings) |*b| if (b.serial != 0) return false;
        return true;
    }
    pub fn close(self: *Owner) bool {
        self.closing = true;
        const memory = self.memory orelse return true;
        if (self.handle.id != 0) {
            const rc = memory.memory.?.virtualUnregister(&self.handle);
            if (rc == 1 or (rc == a.gfx_buffer_error_stale and self.empty())) self.handle = .{};
            // Unregister closes admission and schedules canonical retire jobs.
            // A bounded pass retains everything if an execution loan is live.
            for (0..4) |_| if (!self.step()) return false;
        }
        if (self.handle.id != 0 or !self.empty()) return false;
        self.memory = null;
        self.rt = null;
        return true;
    }
};
