// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
// Parse bytes using the original packed AMD data layouts, never host casts.
pub const atom = @cImport({
    @cDefine("__counted_by(x)", "");
    @cInclude("stdint.h");
    @cInclude("atom_wire.h");
});
pub const legacy = @cImport({
    // Linux's flexible-array annotation has no layout effect. No code from
    // these headers is compiled, and parser bounds are checked explicitly.
    @cDefine("__counted_by(x)", "");
    @cDefine("ATOM_BIG_ENDIAN", "0");
    @cDefine("ULONG", "unsigned int");
    @cDefine("USHORT", "unsigned short");
    @cDefine("UCHAR", "unsigned char");
    @cInclude("atombios.h");
});
const wire_types = .{
    "atom_rom_header_v2_2", "atom_master_data_table_v2_1", "atom_master_list_of_data_tables_v2_1",
    "atom_display_controller_info_v4_1", "atom_display_controller_info_v4_2",
    "atom_smu_info_v3_1", "atom_smu_info_v3_2", "atom_smu_info_v3_3", "atom_gpio_pin_assignment",
    "atom_integrated_system_info_v1_11", "atom_integrated_system_info_v1_12",
    "atom_external_display_connection_info", "atom_ext_display_path", "lcd_info_v2_1", "atom_dtd_format",
    "atom_firmware_info_v3_1", "atom_firmware_info_v3_2", "vram_usagebyfirmware_v2_1",
    "display_object_info_table_v1_4", "display_object_info_table_v1_5",
    "atom_display_object_path_v2", "atom_display_object_path_v3", "atom_encoder_caps_record",
    "atom_i2c_record", "atom_hpd_int_record", "atom_connector_hpdpin_lut_record", "atom_connector_auxddc_lut_record",
};
fn name(comptime T: type) []const u8 {
    inline for (wire_types) |entry| if (T == @field(atom, "struct_" ++ entry)) return entry;
    @compileError("Unregistered ATOM wire type: " ++ @typeName(T));
}
pub fn size(comptime T: type) comptime_int {
    return @field(atom, "r4amd_size_" ++ name(T));
}
pub fn offset(comptime T: type, comptime field: []const u8) comptime_int {
    return @field(atom, "r4amd_offset_" ++ name(T) ++ "_" ++ field);
}
comptime {
    if (@sizeOf(legacy.UEFI_ACPI_VFCT) != 76 or @sizeOf(legacy.VFCT_IMAGE_HEADER) != 28 or
        @sizeOf(atom.struct_atom_rom_header_v2_2) != 40 or @sizeOf(atom.struct_atom_master_data_table_v2_1) != 74)
        @compileError("Unexpected original AMD packed layout");
    if (size(atom.struct_atom_integrated_system_info_v1_11) != 1024 or
        size(atom.struct_atom_integrated_system_info_v1_12) != 1024 or
        size(atom.struct_atom_encoder_caps_record) != 6 or offset(atom.struct_atom_encoder_caps_record, "encodercaps") != 2)
        @compileError("Unexpected original AMD packed wire layout");
}
