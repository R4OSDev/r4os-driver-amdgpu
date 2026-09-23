// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const t = std.testing;
const fw = @import("firmware.zig");
const identity = @import("identity.zig");
const samples = @import("firmware_samples");
fn sample(role: fw.Role) []const u8 {
    for (fw.lock.firmware, 0..) |entry, i| if (entry.role == role and entry.family != .raven2) return samples.files[i + fw.firmware_first];
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
    const raven2_chip = try identity.chip(0x15d8, 0x090015d8);
    snapshot.pci_revision = 0xc4;
    const raven2 = try fw.select(&snapshot, raven2_chip);
    try t.expect(raven2.family == .raven2 and raven2.socket == .fp5);
    try t.expect(raven2.secureDisplayAllowed(0x27000008));
    for (fw.lock.firmware) |entry| try t.expectEqual(entry.family == .raven2 or entry.family == .shared, raven2.selects(entry));
    inline for (.{ "gc", "sdma", "dcn", "nbio", "psp", "smu", "vcn" }) |ip| {
        var foreign = raven2_chip; @field(foreign, ip) -= 1;
        try t.expectError(error.Profile, fw.select(&snapshot, foreign));
    }
    try t.expectError(error.Hash, fw.verify(sample(.pfp), fw.specification(.raven2, .pfp)));
    try t.expectEqual(@as(u32, 73), fw.specification(.raven2, .rlc).ucode_version);
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
        const original = samples.files[index + fw.firmware_first];
        const layout = try fw.verify(original, entry);
        if (entry.family == .raven2 and entry.role == .rlc) {
            const Plan = @import("gc_rlc.zig").Plan;
            var plan: Plan = .{};
            try plan.parse(original, entry);
            try t.expect(plan.ready);
            try t.expectEqual(@as(usize, 65), plan.count);
            try t.expectEqual(@as(usize, 9240), plan.restore.len);
            try t.expectEqualSlices(u32, &.{ 34, 35, 54, 61, 0, 0, 0, 0, 0, 0 }, &plan.starts);
            try t.expectEqualSlices(u32, &.{ 0xc41d, 0x5025c8, 0xc41a, 0x30fa02, 0x30fa00, 0xb003280, 0, 0 }, &plan.indirect);
            try t.expectEqual(@as(u32, 5), plan.format[63]);
            // Reject scratch overflow/overlap, odd direct lists and missing
            // terminators before a plan can become executable.
            for ([_][2]usize{ .{ 60, 500 }, .{ 56, 0x60 }, .{ 68, 510 }, .{ 104, 35 },
                .{ layout.segments[0].span.offset + 64 * 4, 0 } }) |bad| {
                const changed = buffer[0..original.len]; @memcpy(changed, original);
                put(u32, changed, bad[0], @intCast(bad[1])); plan = .{};
                try t.expectError(error.Firmware, plan.parse(changed, entry));
                try t.expect(!plan.ready and plan.restore.len == 0);
            }
        }
        try t.expectEqual(entry.payload_bytes, layout.payload.bytes);
        try t.expectEqual(entry.payload_offset, layout.payload.offset);
        if (entry.kind == .gpu_info) {
            const changed = buffer[0..original.len]; @memcpy(changed, original);
            put(u32, changed, layout.payload.offset + 4, if (entry.family == .raven2) 11 else 3);
            try t.expectError(error.Topology, fw.inspect(changed, entry));
        }
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
    try t.expectEqual(@as(u32, 111), fw.specification(.picasso, .rlc).ucode_version);
    try t.expectEqual(@as(u32, 551), fw.specification(.picasso, .rlc_am4).ucode_version);
    try t.expectError(error.Version, fw.inspect(sample(.rlc), fw.specification(.picasso, .rlc_am4)));
    try t.expectError(error.Hash, fw.verify(sample(.rlc), fw.specification(.picasso, .rlc_am4)));
    const rlc = try fw.verify(sample(.rlc), fw.specification(.picasso, .rlc));
    try t.expectEqual(@as(usize, 608), rlc.segments[4].span.bytes);
    try t.expectEqual(@as(usize, 1312), rlc.segments[5].span.bytes);
    try t.expectEqual(@as(usize, 10144), rlc.segments[6].span.bytes);
    @memcpy(buffer[0..sample(.rlc).len], sample(.rlc));
    put(u32, &buffer, 76, 256); try t.expectError(error.Overlap, fw.inspect(buffer[0..sample(.rlc).len], fw.specification(.picasso, .rlc)));
    const ta = try fw.verify(sample(.ta), fw.specification(.picasso, .ta));
    try t.expectEqual(@as(usize, 0), ta.segments[0].span.bytes); try t.expectEqual(@as(usize, 0), ta.segments[1].span.bytes);
    try t.expectEqual(@as(usize, 28928), ta.segments[2].span.bytes);
    try t.expectEqual(@as(usize, 8448), ta.segments[3].span.bytes);
    snapshot.pci_revision = 0xa1; try t.expect(ta.secureDisplay(try fw.select(&snapshot, chip)) == null);
    snapshot.pci_revision = 0xc1; try t.expect(ta.secureDisplay(try fw.select(&snapshot, chip)) != null);
    @memcpy(buffer[0..sample(.ta).len], sample(.ta));
    put(u32, &buffer, 72, 0); try t.expectError(error.Overlap, fw.inspect(buffer[0..sample(.ta).len], fw.specification(.picasso, .ta)));
    const dmcu = try fw.verify(sample(.dmcu), fw.specification(.picasso, .dmcu));
    try t.expectEqual(@as(usize, 22384), dmcu.segments[0].span.bytes);
    try t.expectEqual(@as(usize, 544), dmcu.segments[1].span.bytes);
    @memcpy(buffer[0..sample(.dmcu).len], sample(.dmcu));
    put(u32, &buffer, 32, 0xffffffff); try t.expectError(error.Range, fw.inspect(buffer[0..sample(.dmcu).len], fw.specification(.picasso, .dmcu)));
    @memcpy(buffer[0..sample(.mec).len], sample(.mec));
    put(u32, &buffer, 36, 0xffffffff); try t.expectError(error.Range, fw.inspect(buffer[0..sample(.mec).len], fw.specification(.picasso, .mec)));
    for (fw.lock.metadata, 0..) |entry, i| try t.expect(fw.hashMatches(samples.files[i + 1], entry.sha256));
}
