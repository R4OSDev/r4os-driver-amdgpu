// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
// Bounded data parsing only: no ATOM command interpreter or x86 ROM calls.
const std = @import("std");
const layouts = @import("atom_layout.zig");
pub const c = layouts.atom;
const v = layouts.legacy;
pub const max_bytes = 1024 * 1024;
pub const Error = error{ Short, Signature, Revision, Length, Identity, Missing, Ambiguous, Overlap, Capacity, Checksum, Topology };
pub const Device = struct { bus: u8, device: u8, function: u8, vendor: u16, id: u16, subvendor: u16, subsystem: u16 };
pub fn part(bytes: []const u8, offset: usize, length: usize) Error![]const u8 {
    if (offset > bytes.len or length > bytes.len - offset) return error.Short;
    return bytes[offset..][0..length];
}
pub fn number(comptime T: type, bytes: []const u8, offset: usize) Error!T {
    return std.mem.readInt(T, (try part(bytes, offset, @sizeOf(T)))[0..@sizeOf(T)], .little);
}
pub fn field(comptime T: type, comptime name: []const u8, bytes: []const u8) Error!@FieldType(T, name) {
    return number(@FieldType(T, name), bytes, @offsetOf(T, name));
}
fn sum(bytes: []const u8) u8 { var value: u8 = 0; for (bytes) |byte| value +%= byte; return value; }

// R4OS preserves firmware BDFs. There is deliberately no Linux PCI-renumbering
// heuristic: an image for a different bus or board is not this adapter's ROM.
pub fn vfct(bytes: []const u8, device: Device) Error![]const u8 {
    _ = try part(bytes, 0, @sizeOf(v.UEFI_ACPI_VFCT));
    if (bytes.len > max_bytes or try number(u32, bytes, 4) != bytes.len) return error.Length;
    if (!std.mem.eql(u8, bytes[0..4], "VFCT")) return error.Signature;
    if (bytes[8] != 1) return error.Revision;
    if (sum(bytes) != 0) return error.Checksum;
    const start = try field(v.UEFI_ACPI_VFCT, "VBIOSImageOffset", bytes);
    const library = try field(v.UEFI_ACPI_VFCT, "Lib1ImageOffset", bytes);
    if (start < @sizeOf(v.UEFI_ACPI_VFCT) or start >= bytes.len) return error.Length;
    if (library != 0 and (library <= start or library >= bytes.len)) return error.Overlap;
    const end = if (library == 0) bytes.len else library;
    var selected: ?[]const u8 = null;
    var offset: usize = start;
    var count: usize = 0;
    while (offset < end) {
        count += 1; if (count > 64) return error.Capacity;
        const header = try part(bytes[0..end], offset, @sizeOf(v.VFCT_IMAGE_HEADER));
        const length = try field(v.VFCT_IMAGE_HEADER, "ImageLength", header);
        if (length == 0) return error.Length;
        offset += header.len;
        const image = try part(bytes[0..end], offset, length);
        offset += image.len;
        const bus = try field(v.VFCT_IMAGE_HEADER, "PCIBus", header);
        const slot = try field(v.VFCT_IMAGE_HEADER, "PCIDevice", header);
        const function = try field(v.VFCT_IMAGE_HEADER, "PCIFunction", header);
        if (bus > 255 or slot > 31 or function > 7) return error.Identity;
        // Revision belongs to the image descriptor, not the PCI revision byte.
        if (bus != device.bus or slot != device.device or function != device.function or
            try field(v.VFCT_IMAGE_HEADER, "VendorID", header) != device.vendor or
            try field(v.VFCT_IMAGE_HEADER, "DeviceID", header) != device.id or
            try field(v.VFCT_IMAGE_HEADER, "SSVID", header) != device.subvendor or
            try field(v.VFCT_IMAGE_HEADER, "SSID", header) != device.subsystem) continue;
        if (selected != null) return error.Ambiguous;
        selected = image;
    }
    // LIB1 is not executable input. Still validate its framing independently
    // so an image cannot escape into or overlap that second directory.
    if (library != 0) {
        offset = library;
        while (offset < bytes.len) {
            count += 1; if (count > 64) return error.Capacity;
            const header = try part(bytes, offset, @sizeOf(v.VFCT_IMAGE_HEADER));
            const length = try field(v.VFCT_IMAGE_HEADER, "ImageLength", header);
            if (length == 0) return error.Length;
            offset += header.len;
            _ = try part(bytes, offset, length); offset += length;
        }
    }
    return selected orelse error.Missing;
}

pub const Table = struct {
    offset: u16 = 0, bytes: []const u8 = &.{},
    fn load(rom: []const u8, offset: u16) Error!Table {
        if (offset < 0x4a) return error.Overlap;
        const length = try number(u16, rom, offset);
        if (length < 4) return error.Length;
        return .{ .offset = offset, .bytes = try part(rom, offset, length) };
    }
    fn revision(self: Table, major: u8, minor: u8, length: usize) Error!void {
        if (self.bytes.len < length) return error.Short;
        if (self.bytes[2] != major or self.bytes[3] != minor) return error.Revision;
    }
};
const Range = struct { first: usize, last: usize };
const Ranges = struct {
    values: [160]Range = undefined, count: usize = 0,
    fn add(self: *Ranges, first: usize, length: usize, alias: bool) Error!void {
        const last = std.math.add(usize, first, length) catch return error.Length;
        for (self.values[0..self.count]) |r| {
            if (alias and first == r.first and last == r.last) return;
            if (first < r.last and r.first < last) return error.Overlap;
        }
        if (self.count == self.values.len) return error.Capacity;
        self.values[self.count] = .{ .first = first, .last = last }; self.count += 1;
    }
};
pub const Pin = struct { id: u8, register: u32, shift: u8, mask_shift: u8 };
pub const Path = struct {
    connector: u16 = 0, encoder: u16 = 0, external_encoder: u16 = 0, device_tag: u16 = 0,
    i2c_id: ?u8 = null, i2c_slave: u8 = 0, i2c_hardware: bool = false, i2c_engine: u8 = 0, aux_ddc_line: ?u8 = null,
    i2c_pin: ?Pin = null, hpd_id: ?u8 = null, hpd_active: u8 = 0, hpd_pin: ?Pin = null,
    aux_ddc_lut: ?[8]u8 = null, hpd_lut: ?[8]u8 = null,
};
pub const ExternalPath = struct {
    connector: u16, encoder: u16, device_tag: u16, acpi_device: u16,
    aux_ddc_index: ?u8, hpd_index: ?u8, lane_mapping: u8, lane_invert: u8, caps: u16,
};
pub const External = struct { guid: [16]u8, paths: [7]ExternalPath };
pub const Integrated = struct {
    revision: u8, vbios_misc: u32, gpu_caps: u32, system_config: u32, memory_type: u8, uma_channels: u8,
    backlight_pwm_hz: u16, panel_delays_ms: [7]u16, min_backlight: u8,
    external: ?External,
};
pub const Panel = struct {
    pixel_clock_khz: u32, width: u16, height: u16, h_blank: u16, v_blank: u16,
    h_sync_offset: u16, h_sync_width: u16, v_sync_offset: u16, v_sync_width: u16,
    misc: u16, bpc: u8, pwm_hz: u16, delays_ms: [7]u16, min_bl: u8, max_bl: u8, boot_bl: u8,
};
pub const Firmware = struct { revision: u32, core_clock_khz: u64, memory_clock_khz: u64, scratch_register: u32 };
pub const Reservation = struct { offset: u64, bytes: u64, driver_bytes: u64 };
pub const Board = struct {
    image: []const u8, tables: [35]Table, integrated: ?Integrated = null, panel: ?Panel = null,
    firmware: ?Firmware = null, reservation: ?Reservation = null,
    paths: [16]Path = undefined, path_count: usize = 0, pins: [128]Pin = undefined, pin_count: usize = 0,
    pub fn table(self: *const Board, comptime name: []const u8) ?Table {
        const index = @offsetOf(c.struct_atom_master_list_of_data_tables_v2_1, name) / 2;
        return if (self.tables[index].offset == 0) null else self.tables[index];
    }
};

pub fn parse(bytes: []const u8, device: Device, board: *Board) Error!void {
    _ = try part(bytes, 0, 0x4a);
    if (bytes.len > max_bytes) return error.Length;
    if (try number(u16, bytes, 0) != 0xaa55) return error.Signature;
    // PCI 2.2 PCIR layout (EDK2 IndustryStandard/Pci22.h). Only the ATOM
    // legacy image is consumed; following UEFI executable images are ignored.
    const pcir = try number(u16, bytes, 0x18);
    if (pcir < 0x4a) return error.Overlap;
    const pci = try part(bytes, pcir, 24);
    if (!std.mem.eql(u8, pci[0..4], "PCIR")) return error.Signature;
    if (try number(u16, pci, 4) != device.vendor or try number(u16, pci, 6) != device.id) return error.Identity;
    if ((pci[12] != 0 and pci[12] != 3) or pci[20] != 0) return error.Revision;
    const pci_length = try number(u16, pci, 10);
    if (pci_length < 24 or (pci[12] == 3 and pci_length < 28)) return error.Length;
    const image_length = @as(usize, try number(u16, pci, 16)) * 512;
    if (image_length < 512) return error.Length;
    const rom = try part(bytes, 0, image_length);
    _ = try part(rom, pcir, pci_length);
    const header = try Table.load(rom, try number(u16, rom, 0x48));
    try header.revision(2, 2, @sizeOf(c.struct_atom_rom_header_v2_2));
    if (!std.mem.eql(u8, header.bytes[4..8], "ATOM") and !std.mem.eql(u8, header.bytes[4..8], "MOTA")) return error.Signature;
    if (try field(c.struct_atom_rom_header_v2_2, "subsystem_vendor_id", header.bytes) != device.subvendor or
        try field(c.struct_atom_rom_header_v2_2, "subsystem_id", header.bytes) != device.subsystem or
        try field(c.struct_atom_rom_header_v2_2, "pci_info_offset", header.bytes) != pcir) return error.Identity;
    const master = try Table.load(rom, try field(c.struct_atom_rom_header_v2_2, "masterdatatable_offset", header.bytes));
    try master.revision(2, 1, @sizeOf(c.struct_atom_master_data_table_v2_1));
    if (master.bytes.len != @sizeOf(c.struct_atom_master_data_table_v2_1)) return error.Length;
    var ranges: Ranges = .{};
    try ranges.add(0, 0x4a, false); try ranges.add(pcir, pci_length, false);
    try ranges.add(header.offset, header.bytes.len, false); try ranges.add(master.offset, master.bytes.len, false);
    board.* = .{ .image = rom, .tables = @splat(.{}) };
    for (&board.tables, 0..) |*entry, index| {
        const offset = try number(u16, master.bytes, 4 + index * 2);
        if (offset == 0) continue;
        entry.* = try Table.load(rom, offset);
        try ranges.add(offset, entry.bytes.len, false);
    }
    // Validate the command-directory extents as opaque data, without executing
    // or interpreting any function. Known shared command bodies may alias.
    const command_offset = try field(c.struct_atom_rom_header_v2_2, "masterhwfunction_offset", header.bytes);
    if (command_offset != 0) {
        const commands = try Table.load(rom, command_offset);
        try commands.revision(2, 1, 4);
        if ((commands.bytes.len - 4) % 2 != 0 or commands.bytes.len > 4 + 2 * 96) return error.Length;
        try ranges.add(commands.offset, commands.bytes.len, false);
        var command_ranges: Ranges = .{};
        for (0..(commands.bytes.len - 4) / 2) |index| {
            const offset = try number(u16, commands.bytes, 4 + index * 2);
            if (offset == 0) continue;
            const entry = try Table.load(rom, offset);
            for (ranges.values[0..ranges.count]) |r| if (offset < r.last and r.first < @as(usize, offset) + entry.bytes.len) return error.Overlap;
            try command_ranges.add(offset, entry.bytes.len, true);
        }
    }
    if (board.table("gpio_pin_lut")) |table| try parsePins(board, table);
    if (board.table("integratedsysteminfo")) |table| board.integrated = try parseIntegrated(table);
    if (board.table("lcd_info")) |table| board.panel = try parsePanel(table);
    if (board.table("firmwareinfo")) |table| {
        if (table.bytes[3] != 1 and table.bytes[3] != 2) return error.Revision;
        try table.revision(3, table.bytes[3], if (table.bytes[3] == 1) @sizeOf(c.struct_atom_firmware_info_v3_1) else @sizeOf(c.struct_atom_firmware_info_v3_2));
        const F = c.struct_atom_firmware_info_v3_1;
        board.firmware = .{ .revision = try field(F, "firmware_revision", table.bytes),
            .core_clock_khz = @as(u64, try field(F, "bootup_sclk_in10khz", table.bytes)) * 10,
            .memory_clock_khz = @as(u64, try field(F, "bootup_mclk_in10khz", table.bytes)) * 10,
            .scratch_register = try field(F, "bios_scratch_reg_startaddr", table.bytes) };
    }
    if (board.table("vram_usagebyfirmware")) |table| {
        const R = c.struct_vram_usagebyfirmware_v2_1;
        try table.revision(2, 1, @sizeOf(R));
        board.reservation = .{ .offset = @as(u64, try field(R, "start_address_in_kb", table.bytes)) * 1024,
            .bytes = @as(u64, try field(R, "used_by_firmware_in_kb", table.bytes)) * 1024,
            .driver_bytes = @as(u64, try field(R, "used_by_driver_in_kb", table.bytes)) * 1024 };
    }
    if (board.table("displayobjectinfo")) |table| try parsePaths(board, table);
}
fn parsePins(board: *Board, table: Table) Error!void {
    try table.revision(2, 1, 4);
    const P = c.struct_atom_gpio_pin_assignment;
    if ((table.bytes.len - 4) % @sizeOf(P) != 0) return error.Length;
    const count = (table.bytes.len - 4) / @sizeOf(P);
    if (count > board.pins.len) return error.Capacity;
    for (0..count) |index| {
        const bytes = table.bytes[4 + index * @sizeOf(P)..][0..@sizeOf(P)];
        const pin: Pin = .{ .id = try field(P, "gpio_id", bytes), .register = try field(P, "data_a_reg_index", bytes),
            .shift = try field(P, "gpio_bitshift", bytes), .mask_shift = try field(P, "gpio_mask_bitshift", bytes) };
        if (pin.shift >= 32 or pin.mask_shift >= 32) return error.Topology;
        for (board.pins[0..board.pin_count]) |existing| if (existing.id == pin.id) return error.Ambiguous;
        board.pins[board.pin_count] = pin; board.pin_count += 1;
    }
}
fn delays(comptime T: type, bytes: []const u8) Error![7]u16 {
    var result: [7]u16 = undefined;
    inline for (.{ "pwr_on_digon_to_de", "pwr_on_de_to_vary_bl", "pwr_down_vary_bloff_to_de", "pwr_down_de_to_digoff", "pwr_off_delay", "pwr_on_vary_bl_to_blon", "pwr_down_bloff_to_vary_bloff" }, 0..) |name, index|
        result[index] = @as(u16, try field(T, name, bytes)) * 4;
    return result;
}
fn parseIntegrated(table: Table) Error!Integrated {
    if (table.bytes[3] != 11 and table.bytes[3] != 12) return error.Revision;
    const I = c.struct_atom_integrated_system_info_v1_11;
    try table.revision(1, table.bytes[3], if (table.bytes[3] == 11) @sizeOf(I) else @sizeOf(c.struct_atom_integrated_system_info_v1_12));
    // The relevant prefix is byte-identical in both original layouts.
    comptime { if (@offsetOf(I, "extdispconninfo") != @offsetOf(c.struct_atom_integrated_system_info_v1_12, "extdispconninfo")) @compileError("Integrated info prefix drift"); }
    const E = c.struct_atom_external_display_connection_info;
    const external = try part(table.bytes, @offsetOf(I, "extdispconninfo"), @sizeOf(E));
    var valid_external: ?External = null;
    if (!std.mem.allEqual(u8, external, 0)) {
        if (try number(u16, external, 0) != @sizeOf(E)) return error.Length;
        if (external[2] != 1 or external[3] != 1) return error.Revision;
        if (sum(external) != 0) return error.Checksum;
        var result: External = undefined;
        @memcpy(&result.guid, external[@offsetOf(E, "guid")..][0..16]);
        const P = c.struct_atom_ext_display_path;
        for (&result.paths, 0..) |*path, index| {
            const data = external[@offsetOf(E, "path") + index * @sizeOf(P)..][0..@sizeOf(P)];
            const connector = try field(P, "connectorobjid", data);
            const aux = try field(P, "auxddclut_index", data); const hpd = try field(P, "hpdlut_index", data);
            if (connector != 0 and ((aux >= 8 and aux != 0xff) or (hpd >= 8 and hpd != 0xff))) return error.Topology;
            path.* = .{ .connector = connector, .encoder = try field(P, "ext_encoder_objid", data),
                .device_tag = try field(P, "device_tag", data), .acpi_device = try field(P, "device_acpi_enum", data),
                .aux_ddc_index = if (connector == 0 or aux == 0xff) null else aux,
                .hpd_index = if (connector == 0 or hpd == 0xff) null else hpd,
                .lane_mapping = try field(P, "channelmapping", data), .lane_invert = try field(P, "chpninvert", data),
                .caps = try field(P, "caps", data) };
        }
        valid_external = result;
    }
    return .{ .revision = table.bytes[3], .vbios_misc = try field(I, "vbios_misc", table.bytes),
        .gpu_caps = try field(I, "gpucapinfo", table.bytes), .system_config = try field(I, "system_config", table.bytes),
        .memory_type = try field(I, "memorytype", table.bytes), .uma_channels = try field(I, "umachannelnumber", table.bytes),
        .backlight_pwm_hz = try field(I, "backlight_pwm_hz", table.bytes), .panel_delays_ms = try delays(I, table.bytes),
        .min_backlight = try field(I, "min_allowed_bl_level", table.bytes), .external = valid_external };
}
fn parsePanel(table: Table) Error!Panel {
    const P = c.struct_lcd_info_v2_1; const D = c.struct_atom_dtd_format;
    try table.revision(2, 1, @sizeOf(P));
    const timing = try part(table.bytes, @offsetOf(P, "lcd_timing"), @sizeOf(D));
    const width = try field(D, "h_active", timing); const height = try field(D, "v_active", timing);
    const h_blank = try field(D, "h_blanking_time", timing); const v_blank = try field(D, "v_blanking_time", timing);
    const h_offset = try field(D, "h_sync_offset", timing); const h_sync = try field(D, "h_sync_width", timing);
    const v_offset = try field(D, "v_sync_offset", timing); const v_sync = try field(D, "v_syncwidth", timing);
    const clock = try field(D, "pixclk", timing);
    if (width == 0 or height == 0 or clock == 0 or h_sync == 0 or v_sync == 0 or
        @as(u32, h_offset) + h_sync > h_blank or @as(u32, v_offset) + v_sync > v_blank or
        @as(u32, width) + h_blank > 65535 or @as(u32, height) + v_blank > 65535) return error.Topology;
    return .{ .pixel_clock_khz = @as(u32, clock) * 10, .width = width, .height = height, .h_blank = h_blank, .v_blank = v_blank,
        .h_sync_offset = h_offset, .h_sync_width = h_sync, .v_sync_offset = v_offset, .v_sync_width = v_sync,
        .misc = try field(D, "miscinfo", timing), .bpc = try field(P, "panel_bpc", table.bytes),
        .pwm_hz = try field(P, "backlight_pwm", table.bytes), .delays_ms = try delays(P, table.bytes),
        .min_bl = try field(P, "min_allowed_bl_level", table.bytes), .max_bl = try field(P, "max_allowed_bl_level", table.bytes),
        .boot_bl = try field(P, "bootup_bl_level", table.bytes) };
}
fn parsePaths(board: *Board, table: Table) Error!void {
    const T = c.struct_display_object_info_table_v1_4; const P = c.struct_atom_display_object_path_v2;
    if (table.bytes[3] != 4 and table.bytes[3] != 5) return error.Revision;
    try table.revision(1, table.bytes[3], @sizeOf(T));
    const count = try field(T, "number_of_path", table.bytes);
    if (count > board.paths.len) return error.Capacity;
    const directory_end = @sizeOf(T) + @as(usize, count) * @sizeOf(P);
    _ = try part(table.bytes, 0, directory_end);
    var ranges: Ranges = .{}; try ranges.add(0, directory_end, false);
    for (0..count) |index| {
        const data = table.bytes[@sizeOf(T) + index * @sizeOf(P)..][0..@sizeOf(P)];
        var path: Path = .{ .connector = try field(P, "display_objid", data), .encoder = try field(P, "encoderobjid", data),
            .external_encoder = if (table.bytes[3] == 4) try field(P, "extencoderobjid", data) else 0,
            .device_tag = try field(P, "device_tag", data) };
        if (path.connector == 0 or (path.connector & 0x7000 != 0x3000 and path.connector & 0x7000 != 0x7000) or
            (path.encoder != 0 and path.encoder & 0x7000 != 0x2000) or
            (path.external_encoder != 0 and path.external_encoder & 0x7000 != 0x2000)) return error.Topology;
        for (board.paths[0..board.path_count]) |existing| if (existing.connector == path.connector) return error.Ambiguous;
        try records(table.bytes, try field(P, "disp_recordoffset", data), &ranges, &path);
        if (table.bytes[3] == 4) {
            try records(table.bytes, try field(P, "encoder_recordoffset", data), &ranges, null);
            try records(table.bytes, try field(P, "extencoder_recordoffset", data), &ranges, null);
        }
        if (path.i2c_id) |id| {
            path.i2c_hardware = id & @as(u8, c.I2C_HW_CAP) != 0; path.i2c_engine = (id & @as(u8, c.I2C_HW_ENGINE_ID_MASK)) >> 4;
            path.aux_ddc_line = id & @as(u8, c.I2C_HW_LANE_MUX);
            for (board.pins[0..board.pin_count]) |pin| if (pin.id == id) { path.i2c_pin = pin; break; };
        }
        if (path.hpd_id) |id| for (board.pins[0..board.pin_count]) |pin| { if (pin.id == id) { path.hpd_pin = pin; break; } };
        board.paths[board.path_count] = path; board.path_count += 1;
    }
}
fn records(bytes: []const u8, start: u16, ranges: *Ranges, path: ?*Path) Error!void {
    if (start == 0) return;
    var offset: usize = start; var count: usize = 0;
    while (true) {
        count += 1; if (count > 128) return error.Capacity;
        const header = try part(bytes, offset, 2);
        if (header[0] == c.ATOM_RECORD_END_TYPE) { offset += 2; break; }
        if (header[1] < 2) return error.Length;
        const data = try part(bytes, offset, header[1]);
        if (path) |p| switch (header[0]) {
            c.ATOM_I2C_RECORD_TYPE => {
                if (data.len < @sizeOf(c.struct_atom_i2c_record)) return error.Short;
                if (p.i2c_id != null) return error.Ambiguous;
                p.i2c_id = try field(c.struct_atom_i2c_record, "i2c_id", data);
                p.i2c_slave = try field(c.struct_atom_i2c_record, "i2c_slave_addr", data);
            },
            c.ATOM_HPD_INT_RECORD_TYPE => {
                if (data.len < @sizeOf(c.struct_atom_hpd_int_record)) return error.Short;
                if (p.hpd_id != null) return error.Ambiguous;
                p.hpd_id = try field(c.struct_atom_hpd_int_record, "pin_id", data);
                p.hpd_active = try field(c.struct_atom_hpd_int_record, "plugin_pin_state", data);
                if (p.hpd_active > 1) return error.Topology;
            },
            c.ATOM_CONNECTOR_HPDPIN_LUT_RECORD_TYPE => {
                if (p.hpd_lut != null) return error.Ambiguous;
                const data_offset = @offsetOf(c.struct_atom_connector_hpdpin_lut_record, "hpd_pin_map");
                p.hpd_lut = (try part(data, data_offset, 8))[0..8].*;
            },
            c.ATOM_CONNECTOR_AUXDDC_LUT_RECORD_TYPE => {
                if (p.aux_ddc_lut != null) return error.Ambiguous;
                const data_offset = @offsetOf(c.struct_atom_connector_auxddc_lut_record, "aux_ddc_map");
                p.aux_ddc_lut = (try part(data, data_offset, 8))[0..8].*;
            },
            else => {}, // Length-framed records not consumed by this stage.
        };
        offset += data.len;
    }
    try ranges.add(start, offset - start, true);
}
