// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
// Driver-owned CPU admission. No DMA, PSP authentication or GPU upload.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const fw = @import("firmware.zig");
const identity = @import("identity.zig");
pub const Error = fw.Error || error{ Busy, ResourceApi, Missing, Stat, Changed, Deadline, Read, Heap, Allocation };
pub const count = 16; // lock, original WHENCE/license, thirteen binaries
const lock_hash = blk: {
    @setEvalBranchQuota(3000000);
    var digest: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(fw.lock_bytes, &digest, .{});
    break :blk std.fmt.bytesToHex(digest, .lower);
};
pub fn artifact(index: usize) fw.Artifact {
    if (index == 0) return .{ .path = "src/firmware_lock.json", .resource = "AMD-FIRMWARE-LOCK.json", .bytes = fw.lock_bytes.len,
        .sha256 = &lock_hash, .upstream_path = "", .git_blob = "" };
    if (index < 3) return fw.lock.metadata[index - 1];
    return fw.lock.firmware[index - 3].artifact();
}
pub const Store = struct {
    heap: ?r4os.r4dev.DriverHeapContext = null,
    allocation: a.DriverHeapAllocation = .{},
    info: [count]a.DriverResourceInfo = .{a.DriverResourceInfo{}} ** count,
    offsets: [count]usize = @splat(0),
    layouts: [13]fw.Layout = .{fw.Layout{}} ** 13,
    profile: ?fw.Profile = null,
    valid: bool = false,
    bytes: usize = 0,
    generation: u64 = 0,
    last_resource: []const u8 = "",
    last_ns: u64 = 0,
    deadline: u64 = 0,

    pub fn load(self: *Store, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, chip: identity.Chip) Error!void {
        if (self.allocation.handle != 0 or self.profile != null or self.valid) return error.Busy;
        self.last_resource = "profile";
        const profile = try fw.select(snapshot, chip);
        self.profile = profile;
        const resources = ctx.resources() orelse return error.ResourceApi;
        self.heap = ctx.heap() orelse return error.Heap;
        self.last_ns = resources.nowNs();
        self.deadline = std.math.add(u64, self.last_ns, 2 * std.time.ns_per_s) catch return error.Deadline;
        if (self.deadline == std.math.maxInt(u64)) return error.Deadline;
        for (0..count) |i| {
            if (i >= 3 and !profile.includes(fw.lock.firmware[i - 3].role)) continue;
            const spec = artifact(i); self.last_resource = spec.resource;
            try self.tick(resources);
            const status = resources.stat(spec.resource, &self.info[i]);
            if (status == a.driver_resource_error_not_found) return error.Missing;
            if (status != a.driver_resource_ok) return error.Stat;
            const info = self.info[i];
            if (info.version != 1 or info.size < @sizeOf(a.DriverResourceInfo) or info.handle == 0 or info.module_generation == 0) return error.Stat;
            if (info.byte_length != spec.bytes or info.byte_length > fw.max_blob_bytes) return error.Size;
            if (self.generation == 0) self.generation = info.module_generation;
            if (info.module_generation != self.generation) return error.Changed;
            for (self.info[0..i]) |prior| if (prior.handle != 0 and prior.handle == info.handle) return error.Changed;
            self.offsets[i] = self.bytes;
            const aligned = std.mem.alignForward(usize, spec.bytes, 16);
            if (aligned > fw.max_package_bytes - self.bytes) return error.Size;
            self.bytes += aligned;
        }
        try self.tick(resources);
        const heap = self.heap.?;
        if (heap.allocate(self.bytes, 16, &self.allocation) != a.driver_heap_ok) return error.Allocation;
        const allocation = self.allocation;
        if (allocation.version != 1 or allocation.size < @sizeOf(a.DriverHeapAllocation) or allocation.handle == 0 or allocation.cpu_address == 0 or
            allocation.cpu_address > std.math.maxInt(u64) - self.bytes or allocation.byte_length < self.bytes or allocation.alignment < 16 or
            allocation.cpu_address % 16 != 0 or allocation.reserved != 0) return error.Allocation;
        const arena: [*]u8 = @ptrFromInt(allocation.cpu_address);
        for (0..count) |i| {
            if (self.info[i].handle == 0) continue;
            const spec = artifact(i); self.last_resource = spec.resource;
            const destination = arena[self.offsets[i]..][0..spec.bytes];
            var offset: usize = 0;
            while (offset < destination.len) {
                try self.tick(resources);
                const output = destination[offset..@min(destination.len, offset + a.driver_resource_max_read_bytes)];
                const result = resources.readAt(self.info[i].handle, offset, output, self.deadline);
                if (result == a.driver_resource_error_deadline) return error.Deadline;
                if (result != @as(i32, @intCast(output.len))) return error.Read;
                offset += output.len;
            }
            try self.stable(resources, i);
            if (i < 3) {
                if (!fw.hashMatches(destination, spec.sha256)) return error.Hash;
            } else self.layouts[i - 3] = try fw.verify(destination, &fw.lock.firmware[i - 3]);
            try self.tick(resources);
        }
        // Recheck the complete package after all reads; no mixed module epoch.
        for (0..count) |i| if (self.info[i].handle != 0) try self.stable(resources, i);
        try self.tick(resources);
        self.last_resource = ""; self.valid = true;
    }
    fn tick(self: *Store, resources: r4os.r4dev.DriverResourceContext) Error!void {
        const now = resources.nowNs();
        if (now < self.last_ns or now >= self.deadline) return error.Deadline;
        self.last_ns = now;
    }
    fn stable(self: *Store, resources: r4os.r4dev.DriverResourceContext, i: usize) Error!void {
        self.last_resource = artifact(i).resource;
        var after: a.DriverResourceInfo = .{};
        if (resources.stat(artifact(i).resource, &after) != a.driver_resource_ok or !std.meta.eql(after, self.info[i])) return error.Changed;
    }
    pub fn container(self: *const Store, role: fw.Role) ?[]const u8 {
        if (!self.valid) return null;
        for (&fw.lock.firmware, 0..) |*spec, index| {
            if (spec.role != role) continue;
            if (self.info[index + 3].handle == 0) return null;
            const base: [*]const u8 = @ptrFromInt(self.allocation.cpu_address);
            return base[self.offsets[index + 3]..][0..spec.bytes];
        }
        return null;
    }
    pub fn close(self: *Store) bool {
        if (self.allocation.handle != 0) {
            const heap = self.heap orelse return false;
            if (heap.release(self.allocation.handle) != a.driver_heap_ok) return false;
        }
        self.* = .{}; return true;
    }
};
