// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const t = std.testing;
const fw = @import("firmware.zig");
const identity = @import("identity.zig");
const samples = @import("firmware_samples");
fn sample(role: fw.Role) []const u8 {
    for (fw.lock.firmware, 0..) |entry, i| if (entry.role == role) return samples.files[i + 3];
    unreachable;
}
fn put(comptime T: type, data: []u8, offset: usize, value: T) void { std.mem.writeInt(T, data[offset..][0..@sizeOf(T)], value, .little); }
test "AMD pinned original firmware containers and revision selection reject malformed or foreign profiles" {
    var snapshot: identity.Snapshot = .{ .pci = .{ .bus_kind = 2, .bus = 5, .vendor_id = 0x1002, .device_id = 0x15d8, .class_code = 3 }, .pci_revision = 0xa1 };
    const chip = try identity.chip(0x15d8, 0x010015d8);
    for (0..256) |revision| {
        snapshot.pci_revision = @intCast(revision);
        const profile = try fw.select(&snapshot, chip);
        const am4 = (revision >= 0xc8 and revision <= 0xcf) or (revision >= 0xd8 and revision <= 0xdf);
        try t.expectEqual(if (am4) fw.Socket.am4 else .fp5, profile.socket);
        try t.expect(profile.includes(.rlc) != profile.includes(.rlc_am4));
    }
    try t.expectError(error.Profile, fw.select(&snapshot, try identity.chip(0x15d8, 0x080015d8)));
    try t.expectError(error.Profile, fw.select(&snapshot, try identity.chip(0x15dd, 0x010015dd)));
    inline for (.{ "gc", "sdma", "dcn", "nbio", "psp", "smu", "vcn" }) |ip| {
        var wrong = chip; @field(wrong, ip) += 1;
        try t.expectError(error.Profile, fw.select(&snapshot, wrong));
    }
    var wrong = chip; wrong.external_revision += 1;
    try t.expectError(error.Profile, fw.select(&snapshot, wrong));
    snapshot.pci.device_id = 0x15dd; try t.expectError(error.Target, fw.select(&snapshot, chip));
    snapshot.pci.device_id = 0x15d8;
    var buffer: [fw.max_blob_bytes]u8 = undefined;
    for (&fw.lock.firmware, 0..) |*entry, index| {
        const original = samples.files[index + 3];
        const layout = try fw.verify(original, entry);
        try t.expectEqual(entry.payload_bytes, layout.payload.bytes);
        try t.expectEqual(entry.payload_offset, layout.payload.offset);
        for (0..original.len) |len| try t.expectError(error.Size, fw.inspect(original[0..len], entry));
        const data = buffer[0..original.len]; @memcpy(data, original);
        data[data.len - 1] ^= 1; try t.expectError(error.Hash, fw.verify(data, entry));
        @memcpy(data, original); put(u16, data, 8, entry.header_major + 1); try t.expectError(error.Revision, fw.inspect(data, entry));
        @memcpy(data, original); put(u16, data, 14, entry.ip_minor + 1); try t.expectError(error.Revision, fw.inspect(data, entry));
        @memcpy(data, original); put(u32, data, 16, entry.ucode_version + 1); try t.expectError(error.Version, fw.inspect(data, entry));
        @memcpy(data, original); put(u32, data, 24, 4); try t.expectError(error.Range, fw.inspect(data, entry));
        @memcpy(data, original); put(u32, data, 20, 0xffffffff); try t.expectError(error.Range, fw.inspect(data, entry));
        @memcpy(data, original); put(u32, data, 4, 0xffffffff); try t.expectError(error.Header, fw.inspect(data, entry));
    }
    try t.expectEqual(@as(u32, 111), fw.specification(.rlc).ucode_version);
    try t.expectEqual(@as(u32, 551), fw.specification(.rlc_am4).ucode_version);
    try t.expectError(error.Version, fw.inspect(sample(.rlc), fw.specification(.rlc_am4)));
    try t.expectError(error.Hash, fw.verify(sample(.rlc), fw.specification(.rlc_am4)));
    const rlc = try fw.verify(sample(.rlc), fw.specification(.rlc));
    try t.expectEqual(@as(usize, 608), rlc.segments[4].span.bytes);
    try t.expectEqual(@as(usize, 1312), rlc.segments[5].span.bytes);
    try t.expectEqual(@as(usize, 10144), rlc.segments[6].span.bytes);
    @memcpy(buffer[0..sample(.rlc).len], sample(.rlc));
    put(u32, &buffer, 76, 256); try t.expectError(error.Overlap, fw.inspect(buffer[0..sample(.rlc).len], fw.specification(.rlc)));
    const ta = try fw.verify(sample(.ta), fw.specification(.ta));
    try t.expectEqual(@as(usize, 0), ta.segments[0].span.bytes); try t.expectEqual(@as(usize, 0), ta.segments[1].span.bytes);
    try t.expectEqual(@as(usize, 28928), ta.segments[2].span.bytes);
    try t.expectEqual(@as(usize, 8448), ta.segments[3].span.bytes);
    snapshot.pci_revision = 0xa1; try t.expect(ta.secureDisplay(try fw.select(&snapshot, chip)) == null);
    snapshot.pci_revision = 0xc1; try t.expect(ta.secureDisplay(try fw.select(&snapshot, chip)) != null);
    @memcpy(buffer[0..sample(.ta).len], sample(.ta));
    put(u32, &buffer, 72, 0); try t.expectError(error.Overlap, fw.inspect(buffer[0..sample(.ta).len], fw.specification(.ta)));
    const dmcu = try fw.verify(sample(.dmcu), fw.specification(.dmcu));
    try t.expectEqual(@as(usize, 22384), dmcu.segments[0].span.bytes);
    try t.expectEqual(@as(usize, 544), dmcu.segments[1].span.bytes);
    @memcpy(buffer[0..sample(.dmcu).len], sample(.dmcu));
    put(u32, &buffer, 32, 0xffffffff); try t.expectError(error.Range, fw.inspect(buffer[0..sample(.dmcu).len], fw.specification(.dmcu)));
    @memcpy(buffer[0..sample(.mec).len], sample(.mec));
    put(u32, &buffer, 36, 0xffffffff); try t.expectError(error.Range, fw.inspect(buffer[0..sample(.mec).len], fw.specification(.mec)));
    for (fw.lock.metadata, 0..) |entry, i| try t.expect(fw.hashMatches(samples.files[i + 1], entry.sha256));
}
