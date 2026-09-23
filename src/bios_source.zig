// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const bios = @import("bios.zig");
const identity = @import("identity.zig");
pub const Error = bios.Error || error{ Busy, Heap, Allocation, Source, Stale, Deadline, Read, Cleanup, Window, NoMeasuredShadow, NoRomShadow };
pub const Source = enum { none, vfct, measured_bar0_shadow };
pub const Acpi = enum { unavailable, missing, no_matching_image, present };
pub const Capture = struct {
    heap: ?r4os.r4dev.DriverHeapContext = null,
    memory: ?r4os.driver_memory.Context = null,
    allocation: a.DriverHeapAllocation = .{},
    window: a.GfxMmioWindow = .{}, cleanup_pending: bool = false,
    source: Source = .none, acpi: Acpi = .unavailable,
    stage: enum { source, vfct, atom } = .source,
    board: bios.Board = undefined, valid: bool = false,
    sha256: [32]u8 = @splat(0),

    pub fn capture(self: *Capture, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot) Error!void {
        if (self.allocation.handle != 0 or self.window.handle.id != 0 or self.cleanup_pending or self.valid) return error.Busy;
        self.heap = ctx.heap() orelse return error.Heap;
        const device: bios.Device = .{ .bus = snapshot.pci.bus, .device = snapshot.pci.device, .function = snapshot.pci.function,
            .vendor = snapshot.pci.vendor_id, .id = snapshot.pci.device_id, .subvendor = snapshot.subsystem_vendor, .subsystem = snapshot.subsystem_device };
        if (ctx.resources()) |resources| {
            if (resources.supportsAcpi()) {
                var info: a.DriverFirmwareTableInfo = .{};
                const status = resources.acpiStat("VFCT".*, 0, &info);
                if (status == a.driver_resource_error_not_found) self.acpi = .missing else {
                    if (status != a.driver_resource_ok) return error.Source;
                    self.acpi = .present;
                    if (info.version != 1 or info.size < @sizeOf(a.DriverFirmwareTableInfo) or info.handle == 0 or info.generation == 0 or
                        info.signature != std.mem.readInt(u32, "VFCT", .little) or info.revision != 1 or info.flags != 0 or info.reserved != 0 or
                        info.byte_length < 76 or info.byte_length > bios.max_bytes) return error.Source;
                    var extra: a.DriverFirmwareTableInfo = .{};
                    const next = resources.acpiStat("VFCT".*, 1, &extra);
                    if (next == a.driver_resource_ok) return error.Ambiguous;
                    if (next != a.driver_resource_error_not_found) return error.Source;
                    const destination = try self.allocate(info.byte_length);
                    const started = resources.nowNs();
                    const deadline = std.math.add(u64, started, 250 * std.time.ns_per_ms) catch return error.Deadline;
                    if (deadline == std.math.maxInt(u64)) return error.Deadline;
                    var offset: usize = 0;
                    while (offset < destination.len) {
                        const output = destination[offset..@min(destination.len, offset + a.driver_resource_max_read_bytes)];
                        const read = resources.acpiReadAt(info.handle, offset, output, deadline);
                        if (read == a.driver_resource_error_deadline) return error.Deadline;
                        if (read != @as(i32, @intCast(output.len))) return error.Read;
                        offset += output.len;
                    }
                    var after: a.DriverFirmwareTableInfo = .{};
                    if (resources.acpiStat("VFCT".*, 0, &after) != 0 or !std.meta.eql(info, after)) return error.Stale;
                    const finished = resources.nowNs();
                    if (finished < started or finished >= deadline) return error.Deadline;
                    self.stage = .vfct;
                    const vfct_start = bios.number(u32, destination, 0x34) catch 0;
                    const vfct_library = bios.number(u32, destination, 0x38) catch 0;
                    logPrefix(ctx, "vfct-header", destination, 32);
                    logPrefix(ctx, "vfct-image", destination, vfct_start);
                    if (vfct_library != 0) logPrefix(ctx, "vfct-library", destination, vfct_library);
                    if (destination.len >= 32) logPrefix(ctx, "vfct-tail", destination, destination.len - 32);
                    const image = bios.vfct(destination, device) catch |err| switch (err) {
                        error.Missing => { self.acpi = .no_matching_image; if (!self.releaseAllocation()) return error.Cleanup; return self.shadow(ctx, snapshot, device); },
                        else => return err,
                    };
                    try self.parseBoard(ctx, image, device, true);
                    self.source = .vfct; self.valid = true;
                    std.crypto.hash.sha2.Sha256.hash(self.board.image, &self.sha256, .{});
                    return;
                }
            }
        }
        try self.shadow(ctx, snapshot, device);
    }
    fn allocate(self: *Capture, bytes: u64) Error![]u8 {
        const heap = self.heap orelse return error.Heap;
        if (heap.allocate(bytes, 16, &self.allocation) != a.driver_heap_ok) return error.Allocation;
        const allocation = self.allocation;
        if (allocation.version != 1 or allocation.size < @sizeOf(a.DriverHeapAllocation) or allocation.handle == 0 or
            allocation.cpu_address == 0 or allocation.cpu_address > std.math.maxInt(u64) - bytes or
            allocation.byte_length < bytes or allocation.alignment < 16 or allocation.cpu_address % 16 != 0 or allocation.reserved != 0) return error.Allocation;
        const pointer: [*]u8 = @ptrFromInt(allocation.cpu_address);
        return pointer[0..@intCast(bytes)];
    }
    fn shadow(self: *Capture, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, device: bios.Device) Error!void {
        // amdgpu_bios.c APU shadow source, but without PCI BAR sizing or writes.
        // A bare BAR address is insufficient. Direct UMA cache aliases are not
        // invented when the measured prefetchable aperture is unavailable.
        const bytes = 256 * 1024;
        const bar = snapshot.bars[0];
        if ((bar.kind != .memory32 and bar.kind != .memory64) or !bar.prefetch or bar.base == 0 or bar.base % 4096 != 0 or
            bar.bytes < bytes or bar.base > std.math.maxInt(u64) - bar.bytes) return error.NoMeasuredShadow;
        const memory = ctx.memory() orelse return error.Window; self.memory = memory;
        const destination = try self.allocate(bytes);
        self.cleanup_pending = true;
        if (memory.mmioMap(&.{ .resource_base = bar.base, .resource_bytes = bar.bytes, .byte_length = bytes,
            .resource_flags = 1, .cache_policy = a.gfx_buffer_cache_write_combining }, &self.window) != a.gfx_buffer_result_ok) return error.Window;
        const window = self.window;
        if (window.version != 1 or window.size < @sizeOf(a.GfxMmioWindow) or window.handle.id == 0 or window.handle.generation == 0 or
            window.cpu_address == 0 or window.cpu_address > std.math.maxInt(u64) - bytes or window.physical_address != bar.base or
            window.byte_length != bytes or window.cache_policy != a.gfx_buffer_cache_write_combining) return error.Window;
        const source: [*]const volatile u8 = @ptrFromInt(window.cpu_address);
        if (source[0] != 0x55 or source[1] != 0xaa) return error.NoRomShadow;
        for (destination, 0..) |*byte, index| byte.* = source[index];
        // A stable complete copy is required; a checksummed but changing ROM
        // must not yield mixed board information.
        for (destination, 0..) |byte, index| if (byte != source[index]) return error.Stale;
        if (!self.closeWindow()) return error.Cleanup;
        try self.parseBoard(ctx, destination, device, false);
        self.source = .measured_bar0_shadow; self.valid = true;
        std.crypto.hash.sha2.Sha256.hash(self.board.image, &self.sha256, .{});
    }
    fn parseBoard(self: *Capture, ctx: *const r4os.r4dev.DriverContext, image: []const u8, device: bios.Device, verified_vfct: bool) Error!void {
        self.stage = .atom;
        var diagnostic: bios.Diagnostic = .{};
        bios.parseDetailed(image, device, &self.board, &diagnostic, .{ .verified_vfct = verified_vfct }) catch |err| {
            var failure: [192]u8 = undefined;
            if (std.fmt.bufPrintZ(&failure, "AMDGPU ROM failure: stage={s} index={d} offset={x} error={s}",
                .{ @tagName(diagnostic.stage), diagnostic.index, diagnostic.offset, @errorName(err) })) |line| ctx.logInfo(line) else |_| {}
            logTable(ctx, "failure", image, diagnostic.offset);
            // Bounded structural evidence for real OEM variants. Diagnostic
            // offsets never relax parser bounds or authorize firmware execution.
            const pcir = bios.number(u16, image, 0x18) catch 0;
            const atom = bios.number(u16, image, 0x48) catch 0;
            const master = bios.number(u16, image, atom + @offsetOf(bios.c.struct_atom_rom_header_v2_2, "masterdatatable_offset")) catch 0;
            logPrefix(ctx, "rom", image, 0);
            logPrefix(ctx, "pcir", image, pcir);
            logPrefix(ctx, "atom", image, atom);
            logPrefix(ctx, "master", image, master);
            const commands = bios.number(u16, image, atom + @offsetOf(bios.c.struct_atom_rom_header_v2_2, "masterhwfunction_offset")) catch 0;
            logPrefix(ctx, "commands", image, commands);
            if (master >= 0x4a) for (0..35) |i| {
                const offset = bios.number(u16, image, @as(usize, master) + 4 + i * 2) catch continue;
                if (offset >= 0x4a) {
                    if (i == bios.wireOffset(bios.c.struct_atom_master_list_of_data_tables_v2_1, "displayobjectinfo") / 2)
                        logTable(ctx, "display-paths", image, offset)
                    else
                        logPrefix(ctx, "table", image, offset);
                }
            };
            return err;
        };
    }
    fn logTable(ctx: *const r4os.r4dev.DriverContext, label: []const u8, image: []const u8, offset: usize) void {
        const declared = bios.number(u16, image, offset) catch 0;
        if (offset >= image.len) return;
        const length: usize = @min(image.len - offset, if (declared >= 4) @min(declared, 256) else 32);
        var relative: usize = 0;
        while (relative < length) : (relative += 32) logPrefix(ctx, label, image[0 .. offset + length], offset + relative);
    }
    fn logPrefix(ctx: *const r4os.r4dev.DriverContext, label: []const u8, image: []const u8, offset: usize) void {
        if (offset >= image.len) return;
        const length: usize = @min(image.len - offset, 32);
        var bytes: [32]u8 = @splat(0);
        @memcpy(bytes[0..length], image[offset..][0..length]);
        const hex = std.fmt.bytesToHex(bytes, .lower);
        var output: [224]u8 = undefined;
        const line = std.fmt.bufPrintZ(&output, "AMDGPU ROM {s}: source-bytes={d} offset={x} prefix={s}",
            .{ label, image.len, offset, hex[0..length * 2] }) catch return;
        ctx.logInfo(line);
    }
    fn closeWindow(self: *Capture) bool {
        if (self.window.handle.id == 0 and !self.cleanup_pending) return true;
        const memory = self.memory orelse return false;
        if (self.window.handle.id != 0) {
            if (memory.mmioUnmap(&self.window.handle, 1) != a.gfx_buffer_result_ok) return false;
            self.window = .{};
        }
        if (memory.collect() != a.gfx_buffer_result_ok) return false;
        self.cleanup_pending = false; return true;
    }
    fn releaseAllocation(self: *Capture) bool {
        if (self.allocation.handle != 0) {
            const heap = self.heap orelse return false;
            if (heap.release(self.allocation.handle) != a.driver_heap_ok) return false;
            self.allocation = .{};
        }
        self.valid = false; return true;
    }
    pub fn close(self: *Capture) bool {
        if (!self.closeWindow() or !self.releaseAllocation()) return false;
        self.* = .{}; return true;
    }
};
