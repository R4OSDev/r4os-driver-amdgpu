const std = @import("std");
const t = std.testing;
const bios = @import("bios.zig");
const f = @import("bios_fixture.zig");
test "ATOM and VFCT validate source identity, revisions, topology, extents and malformed inputs" {
    var source: [f.vfct_bytes * 2]u8 = undefined;
    const bytes = source[0..f.vfct_bytes];
    f.vfct(bytes);
    const image = try bios.vfct(bytes, f.device);
    var board: bios.Board = undefined;
    try bios.parse(image, f.device, &board);
    try t.expectEqual(@as(usize, 1), board.path_count);
    try t.expectEqual(@as(u16, 0x3114), board.paths[0].connector);
    try t.expectEqual(@as(u8, 2), board.paths[0].aux_ddc_line.?);
    try t.expectEqual(@as(u8, 1), board.paths[0].i2c_engine);
    try t.expect(board.paths[0].i2c_hardware and board.paths[0].hpd_active == 1);
    try t.expectEqual(@as(u32, 0x1234), board.paths[0].i2c_pin.?.register);
    try t.expectEqual(@as(u32, 0x5678), board.paths[0].hpd_pin.?.register);
    try t.expectEqual(@as(u16, 20), board.integrated.?.panel_delays_ms[1]);
    try t.expectEqual(@as(u16, 1920), board.panel.?.width);
    try t.expectEqual(@as(u32, 148500), board.panel.?.pixel_clock_khz);
    try t.expectEqual(@as(u8, 8), board.panel.?.bpc);
    try t.expectEqual(@as(u64, 300000), board.firmware.?.core_clock_khz);
    try t.expectEqual(@as(u64, 1024 * 1024), board.reservation.?.bytes);
    // Every truncation boundary is rejected without reading outside the input.
    for (0..bytes.len) |length| if (bios.vfct(bytes[0..length], f.device)) |_| return error.AcceptedTruncation else |_| {};
    for (0..image.len) |length| if (bios.parse(image[0..length], f.device, &board)) |_| return error.AcceptedTruncation else |_| {};
    var different = f.device; different.bus += 1;
    try t.expectError(error.Missing, bios.vfct(bytes, different));
    different = f.device; different.subsystem += 1;
    try t.expectError(error.Identity, bios.parse(image, different, &board));
    try t.expectError(error.Missing, bios.vfct(bytes, different));
    // Real Raven2 descriptor: exact BDF/device, both subsystem IDs omitted.
    f.put(u16, bytes, 92, 0); f.put(u16, bytes, 94, 0); f.checksum(bytes, 9);
    try t.expectEqualSlices(u8, image, try bios.vfct(bytes, f.device));
    different = f.device; different.bus += 1;
    try t.expectError(error.Missing, bios.vfct(bytes, different));
    f.put(u16, bytes, 92, f.device.subvendor); f.checksum(bytes, 9);
    try t.expectError(error.Missing, bios.vfct(bytes, f.device)); f.vfct(bytes);
    bytes[9] +%= 1; try t.expectError(error.Checksum, bios.vfct(bytes, f.device)); f.checksum(bytes, 9);
    bytes[8] = 2; f.checksum(bytes, 9); try t.expectError(error.Revision, bios.vfct(bytes, f.device)); bytes[8] = 1;
    f.put(u32, bytes, 100, 0xffffffff); f.checksum(bytes, 9); try t.expectError(error.Short, bios.vfct(bytes, f.device)); f.vfct(bytes);
    f.put(u32, bytes, 0x38, 80); f.checksum(bytes, 9); try t.expectError(error.Short, bios.vfct(bytes, f.device)); f.vfct(bytes);
    const duplicate = source[0 .. f.vfct_bytes + 28 + f.image_bytes];
    @memcpy(duplicate[f.vfct_bytes..], bytes[76..]); f.put(u32, duplicate, 4, duplicate.len); f.checksum(duplicate, 9);
    try t.expectError(error.Ambiguous, bios.vfct(duplicate, f.device));
    // Empty VFCT/LIB1 descriptors are framing, not ROM candidates. The AMD
    // reference advances over their full header and keeps searching.
    f.vfct(bytes);
    const empty_tail = source[0 .. f.vfct_bytes + 28];
    @memset(empty_tail[f.vfct_bytes..], 0);
    f.put(u32, empty_tail, 4, empty_tail.len); f.checksum(empty_tail, 9);
    try t.expectEqualSlices(u8, bytes[104..], try bios.vfct(empty_tail, f.device));
    f.put(u32, empty_tail, 0x38, f.vfct_bytes); f.checksum(empty_tail, 9);
    try t.expectEqualSlices(u8, bytes[104..], try bios.vfct(empty_tail, f.device));
    f.put(u32, empty_tail, f.vfct_bytes + 24, 4); f.checksum(empty_tail, 9);
    try t.expectError(error.Short, bios.vfct(empty_tail, f.device));
    f.vfct(bytes); f.put(u32, bytes, 100, 0); f.put(u32, bytes, 4, 104);
    f.checksum(bytes[0..104], 9);
    try t.expectError(error.Missing, bios.vfct(bytes[0..104], f.device));
    var rom: [f.image_bytes]u8 = undefined; f.rom(&rom);
    // Original lcd_info_v2_1 byte 51 is an ATOM enum, not a bit count.
    // Check the full wire domain, including undefined/reserved encodings.
    for (0..256) |raw| {
        rom[0x933] = @intCast(raw);
        try bios.parse(&rom, f.device, &board);
        const expected: u8 = switch (raw) { 1 => 6, 2 => 8, 3 => 10, 4 => 12, 5 => 16, else => 0 };
        try t.expectEqual(expected, board.panel.?.bpc);
    }
    f.rom(&rom);
    // Original packed ATOM bytes, independent of Zig's translated padding.
    // Both integrated revisions occupy 1024 bytes; an encoder-capability
    // record has a two-byte header followed immediately by its u32 value.
    inline for (.{ 11, 12 }) |revision| {
        f.rom(&rom); f.header(rom[0x400..], 1024, 1, revision);
        try bios.parse(&rom, f.device, &board);
        try t.expectEqual(@as(u8, revision), board.integrated.?.revision);
        f.header(rom[0x400..], 1023, 1, revision);
        try t.expectError(error.Short, bios.parse(&rom, f.device, &board));
    }
    f.rom(&rom);
    f.put(u16, &rom, 0x210, 0x28); // First path's encoder_recordoffset.
    @memcpy(rom[0x228..0x230], &[_]u8{ bios.c.ATOM_ENCODER_CAP_RECORD_TYPE, 6, 0x78, 0x56, 0x34, 0x12, 0xff, 0 });
    try bios.parse(&rom, f.device, &board);
    try t.expectEqual(@as(u32, 0x12345678), board.paths[0].encoder_caps.?);
    rom[0x229] = 5; try t.expectError(error.Short, bios.parse(&rom, f.device, &board));
    f.rom(&rom);
    f.set(bios.c.struct_atom_rom_header_v2_2, "subsystem_vendor_id", rom[0x100..], 0x1002);
    f.set(bios.c.struct_atom_rom_header_v2_2, "subsystem_id", rom[0x100..], 0x1002);
    try bios.parse(&rom, f.device, &board);
    f.set(bios.c.struct_atom_rom_header_v2_2, "subsystem_id", rom[0x100..], 0x1003);
    try t.expectError(error.Identity, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    f.entry(&rom, "powerplayinfo", 0xb00);
    @memset(rom[0xb00..0xb04], 0);
    try bios.parse(&rom, f.device, &board); try t.expect(board.table("powerplayinfo") == null);
    rom[0xb03] = 1; try t.expectError(error.Length, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    f.entry(&rom, "lcd_info", 0xb00); @memset(rom[0xb00..0xb04], 0);
    try t.expectError(error.Length, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    rom[0x103] = 3; try t.expectError(error.Revision, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    f.entry(&rom, "lcd_info", 0x400); try t.expectError(error.Overlap, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    f.put(u16, &rom, 0x300, 0xffff); try t.expectError(error.Short, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    rom[0x303] = 2; try t.expectError(error.Revision, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    rom[0x403] = 13; try t.expectError(error.Revision, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    rom[0x203] = 5; try bios.parse(&rom, f.device, &board); f.rom(&rom);
    f.put(u16, &rom, 0x20a, 0x208); try t.expectError(error.Short, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    f.put(u16, &rom, 0x20a, 8); if (bios.parse(&rom, f.device, &board)) |_| return error.AcceptedDirectoryOverlap else |_| {} f.rom(&rom);
    rom[0x219] = 0; try t.expectError(error.RecordLength, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    rom[0x219] = 3; try t.expectError(error.Short, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    rom[0x222] = 0; // no effect beyond the explicit terminator
    try bios.parse(&rom, f.device, &board);
    rom[0x220] = 3; rom[0x221] = 2; try t.expectError(error.RecordLength, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    f.set(bios.c.struct_atom_gpio_pin_assignment, "gpio_id", rom[0x30c..], 0x92);
    try t.expectError(error.Ambiguous, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    f.set(bios.c.struct_atom_dtd_format, "h_sync_width", rom[0x904..], 0xffff);
    try t.expectError(error.Topology, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    const E = bios.c.struct_atom_external_display_connection_info;
    const external = rom[0x400 + bios.wireOffset(bios.c.struct_atom_integrated_system_info_v1_11, "extdispconninfo")..][0..bios.wireSize(E)];
    f.header(external, bios.wireSize(E), 1, 1);
    f.set(bios.c.struct_atom_ext_display_path, "connectorobjid", external[bios.wireOffset(E, "path")..], 0x3114);
    f.set(bios.c.struct_atom_ext_display_path, "auxddclut_index", external[bios.wireOffset(E, "path")..], 3);
    f.checksum(external, bios.wireOffset(E, "checksum"));
    try bios.parse(&rom, f.device, &board);
    try t.expectEqual(@as(u8, 3), board.integrated.?.external.?.paths[0].aux_ddc_index.?);
    external[bios.wireOffset(E, "checksum")] +%= 1;
    try t.expectError(error.Checksum, bios.parse(&rom, f.device, &board));
    f.set(bios.c.struct_atom_ext_display_path, "auxddclut_index", external[bios.wireOffset(E, "path")..], 8);
    f.checksum(external, bios.wireOffset(E, "checksum"));
    try t.expectError(error.Topology, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    f.put(u16, &rom, 0x200, 64);
    @memcpy(rom[0x220..0x236], &[_]u8{ 16, 10, 7, 6, 5, 4, 3, 2, 1, 0, 17, 10, 0x92, 0x91, 0x90, 0, 0, 0, 0, 0, 0xff, 0 });
    try bios.parse(&rom, f.device, &board);
    try t.expectEqual(@as(u8, 7), board.paths[0].hpd_lut.?[0]);
    try t.expectEqual(@as(u8, 0x92), board.paths[0].aux_ddc_lut.?[0]); f.rom(&rom);
    // Synthetic OEM checksum case: only this exact board and a verified
    // VFCT source may retain populated wiring with the absent checksum.
    const oem = rom[0x438..0x4c4];
    f.header(oem, 140, 1, 1);
    f.put(u16, oem, 24, 0x3114); oem[30] = 0xe4;
    f.set(bios.c.struct_atom_rom_header_v2_2, "subsystem_vendor_id", rom[0x100..], 0x1002);
    f.set(bios.c.struct_atom_rom_header_v2_2, "subsystem_id", rom[0x100..], 0x1002);
    var lenovo = f.device; lenovo.subsystem = 0x3808;
    try t.expectError(error.Checksum, bios.parse(&rom, lenovo, &board));
    try bios.parseDetailed(&rom, lenovo, &board, null, .{ .verified_vfct = true });
    try t.expectEqual(.oem_unavailable, board.integrated.?.external.?.checksum);
    try t.expectEqual(@as(u8, 0xe4), board.integrated.?.external.?.paths[0].lane_mapping);
    try t.expectError(error.Checksum, bios.parseDetailed(&rom, f.device, &board, null, .{ .verified_vfct = true }));
    oem[4] = 1; try t.expectError(error.Checksum, bios.parseDetailed(&rom, lenovo, &board, null, .{ .verified_vfct = true })); oem[4] = 0;
    oem[132] = 1; try t.expectError(error.Checksum, bios.parseDetailed(&rom, lenovo, &board, null, .{ .verified_vfct = true })); oem[132] = 0;
    oem[26] = 8; try t.expectError(error.Topology, bios.parseDetailed(&rom, lenovo, &board, null, .{ .verified_vfct = true }));
    f.rom(&rom);
    // Adjacent chains terminate with one FF byte. The last FF is exactly
    // the last table byte; a disabled slot and generic LUT are not ports.
    f.entry(&rom, "displayobjectinfo", 0xb00);
    const paths = rom[0xb00..0xb5e];
    f.header(paths, 94, 1, 4); paths[6] = 3;
    f.put(u16, paths, 8, 0x3114); f.put(u16, paths, 10, 56);
    f.put(u16, paths, 12, 0x2120); f.put(u16, paths, 16, 65); f.put(u16, paths, 20, 2);
    f.put(u16, paths, 26, 72); f.put(u16, paths, 28, 0x2120);
    f.put(u16, paths, 40, 0x7103); f.put(u16, paths, 42, 73);
    @memcpy(paths[56..73], &[_]u8{ 1, 4, 0x92, 0, 2, 4, 7, 1, 0xff, 20, 6, 15, 0, 0, 0, 0xff, 0xff });
    @memcpy(paths[73..94], &[_]u8{ 16, 10, 7, 6, 5, 4, 3, 2, 1, 0, 17, 10, 0x92, 0x91, 0x90, 0, 0, 0, 0, 0, 0xff });
    try bios.parse(&rom, f.device, &board);
    try t.expectEqual(@as(usize, 2), board.path_count);
    try t.expectEqual(@as(u32, 15), board.paths[0].encoder_caps.?);
    try t.expectEqual(@as(u8, 0x92), board.paths[0].aux_ddc_lut.?[0]);
    try t.expectEqual(@as(u8, 7), board.paths[0].hpd_lut.?[0]);
    f.put(u16, paths, 36, 2); try t.expectError(error.Topology, bios.parse(&rom, f.device, &board)); f.put(u16, paths, 36, 0);
    f.put(u16, paths, 26, 94); try t.expectError(error.Short, bios.parse(&rom, f.device, &board)); f.put(u16, paths, 26, 72);
    paths[93] = 1; try t.expectError(error.Short, bios.parse(&rom, f.device, &board)); paths[93] = 0xff;
    f.put(u16, paths, 44, 0x2120); try t.expectError(error.Topology, bios.parse(&rom, f.device, &board));
    f.rom(&rom);
    // Missing optional board data stays absent. It never creates invented ports.
    f.entry(&rom, "lcd_info", 0); f.entry(&rom, "integratedsysteminfo", 0); f.entry(&rom, "displayobjectinfo", 0);
    try bios.parse(&rom, f.device, &board); try t.expect(board.panel == null and board.integrated == null and board.path_count == 0);
}


test "board clocks use complete SMU and DCE revisions and reject absent or invalid declarations" {
    const c = bios.c;
    var rom: [f.image_bytes]u8 = undefined;
    var board: bios.Board = undefined;
    f.rom(&rom); try bios.parse(&rom, f.device, &board);
    try t.expectError(error.Missing, board.apuTimestampClock());
    inline for (.{ c.struct_atom_smu_info_v3_1, c.struct_atom_smu_info_v3_2, c.struct_atom_smu_info_v3_3 }, 1..) |T, minor| {
        f.rom(&rom); f.entry(&rom, "smu_info", 0xb00);
        f.header(rom[0xb00..], bios.wireSize(T), 3, minor);
        f.set(T, "core_refclk_10khz", rom[0xb00..], 10000);
        try bios.parse(&rom, f.device, &board);
        try t.expectEqual(@as(u32, 25000), try board.apuTimestampClock());
        f.set(T, "core_refclk_10khz", rom[0xb00..], 2700);
        try t.expectEqual(@as(u32, 6750), try board.apuTimestampClock());
        f.set(T, "core_refclk_10khz", rom[0xb00..], 2701);
        try t.expectError(error.Length, board.apuTimestampClock());
        f.set(T, "core_refclk_10khz", rom[0xb00..], 0);
        try t.expectError(error.Length, board.apuTimestampClock());
        f.header(rom[0xb00..], bios.wireSize(T) - 1, 3, minor);
        try bios.parse(&rom, f.device, &board);
        try t.expectError(error.Short, board.apuTimestampClock());
    }
    f.header(rom[0xb00..], bios.wireSize(c.struct_atom_smu_info_v3_3), 4, 3); try bios.parse(&rom, f.device, &board);
    try t.expectError(error.Revision, board.apuTimestampClock());
    inline for (.{ c.struct_atom_display_controller_info_v4_1, c.struct_atom_display_controller_info_v4_2 }, 1..) |T, minor| {
        f.rom(&rom); f.entry(&rom, "dce_info", 0xb00);
        f.header(rom[0xb00..], bios.wireSize(T), 4, minor);
        f.set(T, "dce_refclk_10khz", rom[0xb00..], 4800);
        try bios.parse(&rom, f.device, &board);
        try t.expectEqual(@as(u32, 48000), try board.displayReferenceClock());
        f.set(T, "dce_refclk_10khz", rom[0xb00..], 0);
        try t.expectError(error.Length, board.displayReferenceClock());
        f.header(rom[0xb00..], bios.wireSize(T) - 1, 4, minor);
        try bios.parse(&rom, f.device, &board); try t.expectError(error.Short, board.displayReferenceClock());
    }
}
