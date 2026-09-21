// Synthetic format fixture built from AMD's public structures. This is NOT a
// Lenovo VBIOS, a hardware capture, or a reference for this laptop's topology.
const std = @import("std");
const bios = @import("bios.zig");
const c = bios.c;
pub const device: bios.Device = .{ .bus = 5, .device = 0, .function = 0, .vendor = 0x1002, .id = 0x15d8, .subvendor = 0x17aa, .subsystem = 0x3812 };
pub const image_bytes = 4096;
pub const vfct_bytes = 76 + 28 + image_bytes;
pub fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void { std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little); }
pub fn set(comptime T: type, comptime name: []const u8, bytes: []u8, value: @FieldType(T, name)) void { put(@FieldType(T, name), bytes, @offsetOf(T, name), value); }
pub fn header(bytes: []u8, length: u16, major: u8, minor: u8) void { put(u16, bytes, 0, length); bytes[2] = major; bytes[3] = minor; }
pub fn entry(bytes: []u8, comptime name: []const u8, offset: u16) void { put(u16, bytes, 0x144 + @offsetOf(c.struct_atom_master_list_of_data_tables_v2_1, name), offset); }
pub fn checksum(bytes: []u8, offset: usize) void { bytes[offset] = 0; var sum: u8 = 0; for (bytes) |b| sum +%= b; bytes[offset] = 0 -% sum; }
pub fn rom(bytes: []u8) void {
    @memset(bytes, 0); put(u16, bytes, 0, 0xaa55); put(u16, bytes, 0x18, 0x80); put(u16, bytes, 0x48, 0x100);
    @memcpy(bytes[0x80..0x84], "PCIR"); put(u16, bytes, 0x84, device.vendor); put(u16, bytes, 0x86, device.id);
    put(u16, bytes, 0x8a, 24); put(u16, bytes, 0x90, image_bytes / 512); bytes[0x95] = 0x80;
    const R = c.struct_atom_rom_header_v2_2;
    header(bytes[0x100..], @sizeOf(R), 2, 2); @memcpy(bytes[0x104..0x108], "ATOM");
    set(R, "subsystem_vendor_id", bytes[0x100..], device.subvendor); set(R, "subsystem_id", bytes[0x100..], device.subsystem);
    set(R, "pci_info_offset", bytes[0x100..], 0x80); set(R, "masterdatatable_offset", bytes[0x100..], 0x140);
    header(bytes[0x140..], @sizeOf(c.struct_atom_master_data_table_v2_1), 2, 1);
    entry(bytes, "displayobjectinfo", 0x200); header(bytes[0x200..], 48, 1, 4); bytes[0x206] = 1;
    const P = c.struct_atom_display_object_path_v2;
    set(P, "display_objid", bytes[0x208..], 0x3114); set(P, "encoderobjid", bytes[0x208..], 0x2120);
    set(P, "device_tag", bytes[0x208..], c.ATOM_DISPLAY_LCD1_SUPPORT); set(P, "disp_recordoffset", bytes[0x208..], 24);
    @memcpy(bytes[0x218..0x222], &[_]u8{ c.ATOM_I2C_RECORD_TYPE, 4, 0x92, 0, c.ATOM_HPD_INT_RECORD_TYPE, 4, 7, 1, 0xff, 0 });
    entry(bytes, "gpio_pin_lut", 0x300); header(bytes[0x300..], 20, 2, 1);
    const G = c.struct_atom_gpio_pin_assignment;
    set(G, "gpio_id", bytes[0x304..], 0x92); set(G, "data_a_reg_index", bytes[0x304..], 0x1234); set(G, "gpio_bitshift", bytes[0x304..], 3);
    set(G, "gpio_id", bytes[0x30c..], 7); set(G, "data_a_reg_index", bytes[0x30c..], 0x5678); set(G, "gpio_bitshift", bytes[0x30c..], 4);
    entry(bytes, "firmwareinfo", 0x340); const F = c.struct_atom_firmware_info_v3_1;
    header(bytes[0x340..], @sizeOf(F), 3, 1); set(F, "bootup_sclk_in10khz", bytes[0x340..], 30000);
    entry(bytes, "integratedsysteminfo", 0x400); const I = c.struct_atom_integrated_system_info_v1_11;
    header(bytes[0x400..], @sizeOf(I), 1, 11); set(I, "memorytype", bytes[0x400..], 0x1a); set(I, "umachannelnumber", bytes[0x400..], 2);
    set(I, "pwr_on_de_to_vary_bl", bytes[0x400..], 5); set(I, "backlight_pwm_hz", bytes[0x400..], 200);
    entry(bytes, "lcd_info", 0x900); const L = c.struct_lcd_info_v2_1; const D = c.struct_atom_dtd_format;
    header(bytes[0x900..], @sizeOf(L), 2, 1); const timing = bytes[0x900 + @offsetOf(L, "lcd_timing")..];
    set(D, "pixclk", timing, 14850); set(D, "h_active", timing, 1920); set(D, "v_active", timing, 1080);
    set(D, "h_blanking_time", timing, 280); set(D, "v_blanking_time", timing, 45);
    set(D, "h_sync_offset", timing, 88); set(D, "h_sync_width", timing, 44); set(D, "v_sync_offset", timing, 4); set(D, "v_syncwidth", timing, 5);
    set(L, "panel_bpc", bytes[0x900..], 8); set(L, "max_allowed_bl_level", bytes[0x900..], 255);
    entry(bytes, "vram_usagebyfirmware", 0xa00); header(bytes[0xa00..], @sizeOf(c.struct_vram_usagebyfirmware_v2_1), 2, 1);
    set(c.struct_vram_usagebyfirmware_v2_1, "start_address_in_kb", bytes[0xa00..], 511 * 1024);
    set(c.struct_vram_usagebyfirmware_v2_1, "used_by_firmware_in_kb", bytes[0xa00..], 1024);
}
pub fn vfct(bytes: []u8) void {
    @memset(bytes, 0); @memcpy(bytes[0..4], "VFCT"); put(u32, bytes, 4, @intCast(bytes.len)); bytes[8] = 1;
    put(u32, bytes, 0x34, 76); put(u32, bytes, 76, device.bus); put(u16, bytes, 88, device.vendor); put(u16, bytes, 90, device.id);
    put(u16, bytes, 92, device.subvendor); put(u16, bytes, 94, device.subsystem); put(u32, bytes, 100, image_bytes);
    rom(bytes[104..][0..image_bytes]); checksum(bytes, 9);
}
