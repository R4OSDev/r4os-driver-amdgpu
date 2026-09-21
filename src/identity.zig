// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const a = @import("r4os").abi;
const regs = @import("registers.zig");
pub const Family = enum { raven, picasso, raven2 };
pub const Chip = struct {
    family: Family, asic_revision: u4, external_revision: u8,
    gc: u32, sdma: u32, dcn: u32, nbio: u32, psp: u32, smu: u32, vcn: u32,
    compiler: []const u8,
};
pub const BarKind = enum { absent, io, memory32, memory64, upper };
pub const Bar = struct { raw: u32 = 0, kind: BarKind = .absent, base: u64 = 0, bytes: u64 = 0, prefetch: bool = false };
pub const Snapshot = struct {
    pci: a.PciDeviceInfo = .{}, pci_revision: u8 = 0,
    subsystem_vendor: u16 = 0, subsystem_device: u16 = 0, command: u16 = 0,
    bars: [6]Bar = .{Bar{}} ** 6,
    pm_control: u16 = 0,
    rebar_offsets: [6]u16 = @splat(0),
    rebar_supported: [6]u32 = @splat(0),
    rebar_controls: [6]u32 = @splat(0),
};
pub const Error = error{ NotTarget, Disappeared, Header, Resource, Capability, Power, Decode, Revision };

pub fn target(pci: a.PciDeviceInfo) bool {
    return pci.vendor_id == 0x1002 and pci.device_id == 0x15d8 and pci.class_code == 3 and
        (pci.subclass == 0 or pci.subclass == 2) and pci.prog_if == 0 and pci.device < 32 and pci.function < 8 and
        (pci.bus_kind == 1 or pci.bus_kind == 2);
}
pub fn adapter(pci: a.PciDeviceInfo) u32 {
    return 0x01000000 | (@as(u32, pci.bus) << 8) | (@as(u32, pci.device) << 3) | pci.function;
}
// Classification is broader than admission. 15dd remains reference-only;
// Raven2 shares 15d8 but must not inherit Picasso's IP/firmware profile.
pub fn chip(device: u16, strap: u32) Error!Chip {
    if ((device != 0x15d8 and device != 0x15dd) or strap == 0xffffffff) return error.Revision;
    const revision: u4 = @intCast((strap & regs.revision_mask) >> regs.revision_shift);
    const family: Family = if (revision >= 8) .raven2 else if (device == 0x15d8) .picasso else .raven;
    return .{ .family = family, .asic_revision = revision,
        .external_revision = @as(u8, revision) + @as(u8, if (family == .raven2) 0x79 else if (family == .picasso) 0x41 else if (revision == 1) 0x20 else 1),
        .gc = if (family == .raven2) 0x090202 else 0x090100,
        .sdma = if (family == .raven2) 0x040101 else 0x040100,
        .dcn = if (family == .raven2) 0x010001 else 0x010000,
        .nbio = if (family == .raven2) 0x070001 else 0x070000,
        .psp = if (family == .raven2) 0x0a0001 else 0x0a0000,
        .smu = if (family == .raven2) 0x0a0001 else 0x0a0000,
        .vcn = if (family == .raven2) 0x010001 else 0x010000,
        .compiler = if (family == .raven2) "gfx909" else "gfx902" };
}

// Only the canonical inventory and read-only configuration accessor are used.
// No all-ones BAR sizing writes, D-state changes, MSI or bus mastering here.
pub fn capture(pci: a.PciDeviceInfo, reader: anytype) Error!Snapshot {
    if (!target(pci)) return error.NotTarget;
    const id = @as(u32, pci.device_id) << 16 | pci.vendor_id;
    if (reader.read(0) != id) return error.Disappeared;
    const header = reader.read(0x0c);
    if (header == 0xffffffff or ((header >> 16) & 0x7f) != 0) return error.Header;
    const class = reader.read(8);
    if (class >> 8 != (@as(u32, pci.class_code) << 16 | @as(u32, pci.subclass) << 8 | pci.prog_if)) return error.Disappeared;
    const command = reader.read(4);
    const subsystem = reader.read(0x2c);
    if (command == 0xffffffff or subsystem == 0xffffffff) return error.Disappeared;
    var result: Snapshot = .{ .pci = pci, .pci_revision = @truncate(class), .command = @truncate(command),
        .subsystem_vendor = @truncate(subsystem), .subsystem_device = @truncate(subsystem >> 16) };
    var index: usize = 0;
    while (index < 6) : (index += 1) {
        const raw = reader.read(@intCast(0x10 + index * 4));
        var bar = &result.bars[index]; bar.raw = raw;
        if (raw == 0) continue;
        if (raw == 0xffffffff) return error.Resource;
        if (raw & 1 != 0) { bar.kind = .io; bar.base = raw & 0xfffffffc; continue; }
        bar.base = raw & 0xfffffff0; bar.prefetch = raw & 8 != 0;
        switch ((raw >> 1) & 3) {
            0 => bar.kind = .memory32,
            2 => {
                if (index == 5) return error.Resource;
                const high = reader.read(@intCast(0x14 + index * 4));
                bar.kind = .memory64; bar.base |= @as(u64, high) << 32;
                index += 1; result.bars[index] = .{ .kind = .upper, .raw = high };
            },
            else => return error.Resource,
        }
    }
    var pcie = false;
    if (command & (1 << 20) != 0) {
        var pointer: u16 = @intCast(reader.read(0x34) & 0xff);
        var seen: u64 = 0; var pm = false;
        while (pointer != 0) {
            if (pointer < 0x40 or pointer > 0xfc or pointer & 3 != 0) return error.Capability;
            const bit = @as(u64, 1) << @as(u6, @intCast(pointer / 4));
            if (seen & bit != 0) return error.Capability;
            seen |= bit;
            const cap = reader.read(pointer);
            if (cap == 0xffffffff) return error.Capability;
            if (cap & 0xff == 1) {
                if (pm or pointer > 0xf8) return error.Capability;
                pm = true;
                if (reader.read(pointer + 4) & 3 != 0) return error.Power;
                result.pm_control = pointer + 4;
            }
            if (cap & 0xff == 0x10) { if (pcie) return error.Capability; pcie = true; }
            pointer = @intCast((cap >> 8) & 0xff);
        }
    }
    if (pci.bus_kind == 2 and pcie) try rebar(&result, reader);
    if (result.command & 2 == 0) return error.Decode;
    const mmio = result.bars[5];
    if (mmio.kind != .memory32 or mmio.prefetch or mmio.base == 0 or mmio.base & 0xfff != 0 or
        mmio.base + regs.required_prefix > (@as(u64, 1) << 32) or (mmio.bytes != 0 and mmio.bytes < regs.required_prefix)) return error.Resource;
    if (!stable(&result, reader)) return error.Disappeared;
    return result;
}
pub fn stable(snapshot: *const Snapshot, reader: anytype) bool {
    if (reader.read(0) != (@as(u32, snapshot.pci.device_id) << 16 | snapshot.pci.vendor_id) or
        reader.read(8) != (@as(u32, snapshot.pci.class_code) << 24 | @as(u32, snapshot.pci.subclass) << 16 | @as(u32, snapshot.pci.prog_if) << 8 | snapshot.pci_revision) or
        reader.read(4) & 0xffff != snapshot.command or
        reader.read(0x2c) != (@as(u32, snapshot.subsystem_device) << 16 | snapshot.subsystem_vendor)) return false;
    for (snapshot.bars, 0..) |bar, index| if (reader.read(@intCast(0x10 + index * 4)) != bar.raw) return false;
    if (snapshot.pm_control != 0 and reader.read(snapshot.pm_control) & 3 != 0) return false;
    for (snapshot.rebar_offsets, 0..) |offset, index| if (offset != 0) {
        if (reader.read(offset) != snapshot.rebar_supported[index] or reader.read(offset + 4) != snapshot.rebar_controls[index]) return false;
    };
    return true;
}
// Measured current PCIe Resizable BAR sizes are optional. They permit an
// aperture alias proof; a raw BAR base alone never substitutes for UMA data.
fn rebar(snapshot: *Snapshot, reader: anytype) Error!void {
    var pointer: u16 = 0x100; var seen: [16]u64 = @splat(0); var visits: usize = 0; var found = false;
    while (pointer != 0) : (visits += 1) {
        if (visits >= 256 or pointer < 0x100 or pointer > 0xffc or pointer & 3 != 0) return error.Capability;
        const bit = @as(u64, 1) << @as(u6, @intCast(pointer / 4 % 64));
        if (seen[pointer / 256] & bit != 0) return error.Capability;
        seen[pointer / 256] |= bit;
        const head = reader.read(pointer);
        if (head == 0 or head == 0xffffffff) { if (pointer == 0x100) return; return error.Capability; }
        if (head & 0xffff == 0x15) {
            if (found or (head >> 16) & 15 != 1 or pointer > 0xff4) return error.Capability;
            found = true;
            const count = (reader.read(pointer + 8) >> 5) & 7;
            if (count == 0 or count > 6 or pointer + 4 + count * 8 > 0x1000) return error.Capability;
            var bars_seen: u8 = 0;
            for (0..count) |i| {
                const offset: u16 = pointer + 4 + @as(u16, @intCast(i * 8));
                const capability = reader.read(offset);
                const supported = capability >> 4;
                const control = reader.read(offset + 4);
                const index = control & 7; const size = (control >> 8) & 0x3f;
                if (index >= 6 or size >= 28 or supported & (@as(u32, 1) << @as(u5, @intCast(size))) == 0) return error.Resource;
                const mask = @as(u8, 1) << @as(u3, @intCast(index));
                if (bars_seen & mask != 0) return error.Resource;
                bars_seen |= mask;
                var bar = &snapshot.bars[index];
                const bytes = @as(u64, 1024 * 1024) << @as(u6, @intCast(size));
                if ((bar.kind != .memory32 and bar.kind != .memory64) or bar.base == 0 or bar.base % bytes != 0 or
                    bar.base > std.math.maxInt(u64) - bytes or (bar.kind == .memory32 and bar.base + bytes > (@as(u64, 1) << 32))) return error.Resource;
                bar.bytes = bytes;
                snapshot.rebar_offsets[index] = offset;
                // Keep the complete register, including reserved low bits,
                // for the final identity check without sizing writes.
                snapshot.rebar_supported[index] = capability;
                snapshot.rebar_controls[index] = control;
            }
        }
        pointer = @intCast(head >> 20);
    }
}
