// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
// Parse bytes using the original packed AMD data layouts, never host casts.
pub const atom = @cImport({
    @cDefine("__counted_by(x)", "");
    @cInclude("stdint.h");
    @cInclude("atomfirmware.h");
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
comptime {
    if (@sizeOf(legacy.UEFI_ACPI_VFCT) != 76 or @sizeOf(legacy.VFCT_IMAGE_HEADER) != 28 or
        @sizeOf(atom.struct_atom_rom_header_v2_2) != 40 or @sizeOf(atom.struct_atom_master_data_table_v2_1) != 74)
        @compileError("Unexpected original AMD packed layout");
}
