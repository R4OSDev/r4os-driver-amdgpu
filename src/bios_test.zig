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
    try t.expectEqual(@as(u64, 300000), board.firmware.?.core_clock_khz);
    try t.expectEqual(@as(u64, 1024 * 1024), board.reservation.?.bytes);
    // Every truncation boundary is rejected without reading outside the input.
    for (0..bytes.len) |length| if (bios.vfct(bytes[0..length], f.device)) |_| return error.AcceptedTruncation else |_| {};
    for (0..image.len) |length| if (bios.parse(image[0..length], f.device, &board)) |_| return error.AcceptedTruncation else |_| {};
    var different = f.device; different.bus += 1;
    try t.expectError(error.Missing, bios.vfct(bytes, different));
    different = f.device; different.subsystem += 1;
    try t.expectError(error.Identity, bios.parse(image, different, &board));
    bytes[9] +%= 1; try t.expectError(error.Checksum, bios.vfct(bytes, f.device)); f.checksum(bytes, 9);
    bytes[8] = 2; f.checksum(bytes, 9); try t.expectError(error.Revision, bios.vfct(bytes, f.device)); bytes[8] = 1;
    f.put(u32, bytes, 100, 0xffffffff); f.checksum(bytes, 9); try t.expectError(error.Short, bios.vfct(bytes, f.device)); f.vfct(bytes);
    f.put(u32, bytes, 0x38, 80); f.checksum(bytes, 9); try t.expectError(error.Short, bios.vfct(bytes, f.device)); f.vfct(bytes);
    const duplicate = source[0 .. f.vfct_bytes + 28 + f.image_bytes];
    @memcpy(duplicate[f.vfct_bytes..], bytes[76..]); f.put(u32, duplicate, 4, duplicate.len); f.checksum(duplicate, 9);
    try t.expectError(error.Ambiguous, bios.vfct(duplicate, f.device));
    var rom: [f.image_bytes]u8 = undefined; f.rom(&rom);
    rom[0x103] = 3; try t.expectError(error.Revision, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    f.entry(&rom, "lcd_info", 0x400); try t.expectError(error.Overlap, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    f.put(u16, &rom, 0x300, 0xffff); try t.expectError(error.Short, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    rom[0x303] = 2; try t.expectError(error.Revision, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    rom[0x403] = 13; try t.expectError(error.Revision, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    rom[0x203] = 5; try bios.parse(&rom, f.device, &board); f.rom(&rom);
    f.put(u16, &rom, 0x20a, 0x208); try t.expectError(error.Short, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    f.put(u16, &rom, 0x20a, 8); if (bios.parse(&rom, f.device, &board)) |_| return error.AcceptedDirectoryOverlap else |_| {} f.rom(&rom);
    rom[0x219] = 0; try t.expectError(error.Length, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    rom[0x219] = 3; try t.expectError(error.Short, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    rom[0x222] = 0; // no effect beyond the explicit terminator
    try bios.parse(&rom, f.device, &board);
    rom[0x220] = 3; rom[0x221] = 2; try t.expectError(error.Length, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    f.set(bios.c.struct_atom_gpio_pin_assignment, "gpio_id", rom[0x30c..], 0x92);
    try t.expectError(error.Ambiguous, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    f.set(bios.c.struct_atom_dtd_format, "h_sync_width", rom[0x904..], 0xffff);
    try t.expectError(error.Topology, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    const E = bios.c.struct_atom_external_display_connection_info;
    const external = rom[0x400 + @offsetOf(bios.c.struct_atom_integrated_system_info_v1_11, "extdispconninfo")..][0..@sizeOf(E)];
    f.header(external, @sizeOf(E), 1, 1);
    f.set(bios.c.struct_atom_ext_display_path, "connectorobjid", external[@offsetOf(E, "path")..], 0x3114);
    f.set(bios.c.struct_atom_ext_display_path, "auxddclut_index", external[@offsetOf(E, "path")..], 3);
    f.checksum(external, @offsetOf(E, "checksum"));
    try bios.parse(&rom, f.device, &board);
    try t.expectEqual(@as(u8, 3), board.integrated.?.external.?.paths[0].aux_ddc_index.?);
    external[@offsetOf(E, "checksum")] +%= 1;
    try t.expectError(error.Checksum, bios.parse(&rom, f.device, &board));
    f.set(bios.c.struct_atom_ext_display_path, "auxddclut_index", external[@offsetOf(E, "path")..], 8);
    f.checksum(external, @offsetOf(E, "checksum"));
    try t.expectError(error.Topology, bios.parse(&rom, f.device, &board)); f.rom(&rom);
    f.put(u16, &rom, 0x200, 64);
    @memcpy(rom[0x220..0x236], &[_]u8{ 16, 10, 7, 6, 5, 4, 3, 2, 1, 0, 17, 10, 0x92, 0x91, 0x90, 0, 0, 0, 0, 0, 0xff, 0 });
    try bios.parse(&rom, f.device, &board);
    try t.expectEqual(@as(u8, 7), board.paths[0].hpd_lut.?[0]);
    try t.expectEqual(@as(u8, 0x92), board.paths[0].aux_ddc_lut.?[0]); f.rom(&rom);
    // Missing optional board data stays absent. It never creates invented ports.
    f.entry(&rom, "lcd_info", 0); f.entry(&rom, "integratedsysteminfo", 0); f.entry(&rom, "displayobjectinfo", 0);
    try bios.parse(&rom, f.device, &board); try t.expect(board.panel == null and board.integrated == null and board.path_count == 0);
}


test "Picasso timestamp scale uses complete SMU tables and rejects absent or fractional clock declarations" {
    const c = bios.c;
    var rom: [f.image_bytes]u8 = undefined;
    var board: bios.Board = undefined;
    f.rom(&rom); try bios.parse(&rom, f.device, &board);
    try t.expectError(error.Missing, board.picassoTimestampClock());
    inline for (.{ c.struct_atom_smu_info_v3_1, c.struct_atom_smu_info_v3_2, c.struct_atom_smu_info_v3_3 }, 1..) |T, minor| {
        f.rom(&rom); f.entry(&rom, "smu_info", 0xb00);
        f.header(rom[0xb00..], @sizeOf(T), 3, minor);
        f.set(T, "core_refclk_10khz", rom[0xb00..], 10000);
        try bios.parse(&rom, f.device, &board);
        try t.expectEqual(@as(u32, 25000), try board.picassoTimestampClock());
        f.set(T, "core_refclk_10khz", rom[0xb00..], 2700);
        try t.expectEqual(@as(u32, 6750), try board.picassoTimestampClock());
        f.set(T, "core_refclk_10khz", rom[0xb00..], 2701);
        try t.expectError(error.Length, board.picassoTimestampClock());
        f.set(T, "core_refclk_10khz", rom[0xb00..], 0);
        try t.expectError(error.Length, board.picassoTimestampClock());
        f.header(rom[0xb00..], @sizeOf(T) - 1, 3, minor);
        try bios.parse(&rom, f.device, &board);
        try t.expectError(error.Short, board.picassoTimestampClock());
    }
    f.header(rom[0xb00..], @sizeOf(c.struct_atom_smu_info_v3_3), 4, 3); try bios.parse(&rom, f.device, &board);
    try t.expectError(error.Revision, board.picassoTimestampClock());
}
