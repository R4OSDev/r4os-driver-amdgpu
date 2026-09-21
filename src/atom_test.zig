// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const t = std.testing;
const atom = @import("atom_vm.zig");
const bios = @import("bios.zig");
const fixture = @import("bios_fixture.zig");
const F = struct {
    var rom: [4096]u8 = undefined;
    var board: bios.Board = undefined;
    var vm: atom.Vm = .{};
    var scratch: [16]u32 = undefined;
    var regs: [32]u32 = undefined;
    var now_ns: u64 = 0;
    var writes: usize = 0;
    var reads: usize = 0;
    var fail_write: usize = 0;
    var allowed = true;
    var expire = false;
    const io: atom.Io = .{ .context = 0, .read = read, .write = write, .now = now, .delay = delay, .worker = worker };
    fn read(_: usize, space: atom.Space, index: u32) atom.Error!u32 {
        if (space != .mmio) return error.Unsupported;
        if (index >= regs.len) return error.Bounds;
        reads += 1;
        return regs[index];
    }
    fn write(_: usize, space: atom.Space, index: u32, value: u32) atom.Error!void {
        if (space != .mmio) return error.Unsupported;
        if (index >= regs.len) return error.Bounds;
        writes += 1;
        if (writes == fail_write) return error.Io;
        regs[index] = value;
    }
    fn now(_: usize) u64 {
        now_ns += if (expire) @as(u64, 3_000_000_000) else 1000;
        return now_ns;
    }
    fn delay(_: usize, us: u32) atom.Error!void {
        now_ns += @as(u64, us) * 1000;
    }
    fn worker(_: usize) bool {
        return allowed;
    }
    fn table(id: usize, at: u16, ps: u8, code: []const u8) void {
        fixture.put(u16, &rom, 0xb04 + id * 2, at);
        fixture.header(rom[at..], @intCast(code.len + 6), 1, 6);
        rom[at + 4] = 4;
        rom[at + 5] = ps;
        @memcpy(rom[at + 6 ..][0..code.len], code);
    }
    fn reset() !void {
        fixture.rom(&rom);
        @memset(&scratch, 0);
        @memset(&regs, 0);
        writes = 0;
        reads = 0;
        now_ns = 0;
        fail_write = 0;
        allowed = true;
        expire = false;
        vm = .{};
        fixture.set(bios.c.struct_atom_rom_header_v2_2, "masterhwfunction_offset", rom[0x100..], 0xb00);
        fixture.header(rom[0xb00..], 16, 2, 1);
        // Root uses two PS DWORDs; CALLTABLE shifts only the child's PS base.
        table(0, 0xc00, 8, &.{ 2, 5, 0, 3, 0, 0, 0, 82, 1, 2, 0x65, 0, 0xab, 32, 5, 0, 2, 0, 0, 0, 2, 2, 1, 0x40, 58, 8, 0, 1, 5, 2, 0, 0x21, 0x43, 0x65, 0x87, 58, 0, 0, 55, 1, 0, 1, 5, 3, 0, 0x44, 0x33, 0x22, 0x11, 2, 0, 4, 3, 0, 91 });
        table(1, 0xd00, 4, &.{ 44, 5, 0, 9, 0, 0, 0, 91 });
        table(2, 0xd40, 0, &.{ 67, 6, 0 }); // unconditional loop, no EOT
        table(3, 0xd80, 0, &.{ 82, 3, 91 }); // recursive CALLTABLE
        table(4, 0xe00, 0, &.{ 1, 5, 10, 0, 9, 0, 0, 0, 1, 5, 11, 0, 7, 0, 0, 0, 91 });
        table(5, 0xe40, 0, &.{ 1, 5, 10, 0, 9 }); // truncated immediate
        // IIO read method1 and write method129, explicit original bytecode.
        fixture.put(u16, &rom, 0x140 + 0x32, 0xe80);
        fixture.header(rom[0xe80..], 22, 1, 1);
        @memcpy(rom[0xe84..0xe96], &[_]u8{ 1, 1, 2, 14, 0, 9, 0, 0, 1, 129, 8, 32, 0, 0, 3, 14, 0, 9 });
        // END owns two trailing bytes, included in the declared table.
        fixture.put(u16, &rom, 0xe80, 24);
        try bios.parse(&rom, fixture.device, &board);
        try vm.initialize(&board, &scratch, io);
    }
};
test "ATOM executes nested parameter windows, partial values, MMIO and indirect methods" {
    try F.reset();
    var params = [_]u32{ 0, 0, 11, 0, 0, 0 };
    try F.vm.execute(0, &params);
    try t.expectEqual(@as(u32, 0xab03), params[0]);
    try t.expectEqual(@as(u32, 0x15606), params[1]);
    try t.expectEqual(@as(u32, 20), params[2]);
    try t.expectEqual(@as(u32, 0x11223344), params[4]);
    try t.expectEqual(@as(u32, 0x87654321), F.regs[10]);
    try t.expectEqual(@as(u32, 0x11223344), F.regs[14]);
    try t.expectEqual(@as(usize, 2), F.writes);
    try t.expectEqual(@as(usize, 1), F.reads);
    try t.expect(F.vm.effects and !F.vm.running and F.vm.parameters.len == 0);
    try t.expectError(error.Busy, F.vm.initialize(&F.board, &F.scratch, F.io));
}
test "ATOM rejects truncated commands, loops, recursion, unsupported I/O and failed writes" {
    try F.reset();
    var params = [_]u32{0} ** 8;
    try t.expectError(error.Bounds, F.vm.execute(5, &params));
    try t.expectEqual(@as(usize, 0), F.writes);
    F.expire = true;
    try t.expectError(error.Deadline, F.vm.execute(2, &params));
    F.expire = false;
    try t.expectError(error.Capacity, F.vm.execute(2, &params)); // instruction budget, clock does not advance
    try t.expectError(error.Capacity, F.vm.execute(3, &params));
    F.fail_write = 1;
    try t.expectError(error.Io, F.vm.execute(4, &params));
    try t.expectEqual(@as(usize, 1), F.writes);
    try t.expect(F.vm.effects and !F.vm.running);
    F.allowed = false;
    try t.expectError(error.Unsupported, F.vm.execute(0, &params));
    F.allowed = true;
    try F.reset();
    F.rom[0xc06] = 0xff;
    try t.expectError(error.Unsupported, F.vm.execute(0, &params));
    try F.reset();
    F.table(0, 0xc00, 0, &.{ 2, 0x85, 0, 1, 0, 0, 0, 91 });
    try F.vm.execute(0, &params);
    // Byte-aligned destination with an invalid shift must not trap or write.
    F.table(0, 0xc00, 0, &.{ 19, 0, 10, 0, 32, 91 });
    try t.expectError(error.Format, F.vm.execute(0, &params));
    F.table(0, 0xc00, 0, &.{ 4, 5, 16, 1, 0, 0, 0, 91 });
    try t.expectError(error.Bounds, F.vm.execute(0, &params));
    F.table(0, 0xc00, 0, &.{ 5, 5, 1, 1, 0, 0, 0, 91 });
    try t.expectError(error.Unsupported, F.vm.execute(0, &params));
}
