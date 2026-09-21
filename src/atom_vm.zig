//
// Copyright 2008 Advanced Micro Devices, Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
// THE COPYRIGHT HOLDER(S) OR AUTHOR(S) BE LIABLE FOR ANY CLAIM, DAMAGES OR
// OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
//
// Author: Stanislaw Skowronek
//
//! Bounded port of AMD's ATOM command semantics. This executes ATOM bytecode,
//! never x86 firmware. Only the display task may supply the register transport.
const std = @import("std");
const bios = @import("bios.zig");
const ops = @import("atom_opcodes.zig");
pub const Error = error{ Busy, Format, Bounds, Missing, Unsupported, Deadline, Capacity, Io };
pub const Space = enum { mmio, pll, mc };
pub const Io = struct {
    context: usize,
    read: *const fn (usize, Space, u32) Error!u32, // register indices, not bytes
    write: *const fn (usize, Space, u32, u32) Error!void,
    now: *const fn (usize) u64,
    delay: *const fn (usize, u32) Error!void,
    worker: *const fn (usize) bool,
};
const Frame = struct {
    first: usize = 0,
    end: usize = 0,
    pc: usize = 0,
    ps: usize = 0,
    shift: usize = 0,
    ws_count: usize = 0,
    workspace: [256]u32 = @splat(0),
};
const Segment = struct { first: usize = 0, end: usize = 0 };
const masks = [_]u32{ 0xffffffff, 0xffff, 0xffff00, 0xffff0000, 0xff, 0xff00, 0xff0000, 0xff000000 };
const shifts = [_]u5{ 0, 0, 8, 16, 0, 8, 16, 24 };
const defaults = [_]u8{ 0, 0, 1, 2, 0, 1, 2, 3 };
fn destination(attr: u8) u3 {
    const kind: u3 = @truncate(attr >> 3);
    const offset: u2 = @truncate(attr >> 6);
    return if (kind == 0) 0 else if (kind < 4) ([_]u3{ 1, 2, 3, 0 })[offset] else @as(u3, offset) + 4;
}
fn number(comptime T: type, bytes: []const u8, at: usize) Error!T {
    return bios.number(T, bytes, at) catch return error.Bounds;
}
/// Retain this object and scratch under the display owner, never on its task
/// stack. A failed command may have written hardware; effects stays latched.
pub const Vm = struct {
    image: []const u8 = &.{},
    commands: []const u8 = &.{},
    data: []const u8 = &.{},
    scratch: []u32 = &.{},
    parameters: []u32 = &.{},
    io: ?Io = null,
    iio: [256]Segment = @splat(.{}),
    frames: [32]Frame = undefined,
    depth: usize = 0,
    divmul: [2]u32 = .{ 0, 0 },
    data_block: u16 = 0,
    reg_block: u16 = 0,
    fb_base: u32 = 0,
    io_attr: u16 = 0,
    shift: u5 = 0,
    equal: bool = false,
    above: bool = false,
    io_mode: u16 = 0,
    running: bool = false,
    effects: bool = false,
    started: u64 = 0,
    budget: u32 = 0,
    last_pc: u32 = 0,
    last_opcode: u8 = 0,
    pub fn revision(self: *const Vm, command: u32) Error![2]u8 {
        if (self.commands.len < 4 or command >= (self.commands.len - 4) / 2) return error.Missing;
        const at = try number(u16, self.commands, 4 + command * 2);
        if (at == 0) return error.Missing;
        const table_bytes = try self.table(at);
        if (table_bytes.len < 6) return error.Format;
        return .{ table_bytes[2] & 0x3f, table_bytes[3] & 0x3f };
    }
    pub fn initialize(self: *Vm, board: *const bios.Board, scratch: []u32, io: Io) Error!void {
        if (self.running or self.effects) return error.Busy;
        if (!io.worker(io.context) or scratch.len > 16384) return error.Unsupported;
        const rom = board.image;
        const header: usize = try number(u16, rom, 0x48);
        const command_at = try number(u16, rom, header + @offsetOf(bios.c.struct_atom_rom_header_v2_2, "masterhwfunction_offset"));
        const data_at = try number(u16, rom, header + @offsetOf(bios.c.struct_atom_rom_header_v2_2, "masterdatatable_offset"));
        self.image = rom;
        self.commands = try self.table(command_at);
        self.data = try self.table(data_at);
        if (self.commands.len < 4 or (self.commands.len - 4) % 2 != 0 or self.commands.len > 196 or self.commands[2] != 2 or self.commands[3] != 1 or
            self.data.len != 74 or self.data[2] != 2 or self.data[3] != 1) return error.Format;
        self.scratch = scratch;
        self.io = io;
        self.iio = @splat(.{});
        self.data_block = 0;
        self.reg_block = 0;
        self.fb_base = 0;
        self.io_attr = 0;
        self.shift = 0;
        self.equal = false;
        self.above = false;
        // The ATOM v2.1 directory preserves the legacy indirect-IO slot (23).
        const iio_at = try number(u16, self.data, 0x32);
        if (iio_at != 0) {
            const bytes = try self.table(iio_at);
            var cursor: usize = 4;
            const lengths = [_]u8{ 1, 2, 3, 3, 3, 3, 4, 4, 4, 3 };
            while (cursor < bytes.len and bytes[cursor] == 1) {
                const id = try number(u8, bytes, cursor + 1);
                cursor += 2;
                if (self.iio[id].first != 0) return error.Format;
                const first = cursor;
                var done = false;
                while (cursor < bytes.len) {
                    const op = bytes[cursor];
                    if (op >= lengths.len or op == 1) return error.Unsupported;
                    if (lengths[op] > bytes.len - cursor) return error.Bounds;
                    cursor += lengths[op];
                    if (op == 9) {
                        done = true;
                        break;
                    }
                }
                if (!done) return error.Format;
                self.iio[id] = .{ .first = iio_at + first, .end = iio_at + cursor };
            }
        }
    }
    fn table(self: *const Vm, at: u16) Error![]const u8 {
        if (at < 0x4a) return error.Missing;
        const size = try number(u16, self.image, at);
        if (size < 4) return error.Format;
        return bios.part(self.image, at, size) catch return error.Bounds;
    }
    fn tick(self: *Vm) Error!void {
        if (self.budget == 0) return error.Capacity;
        self.budget -= 1;
        const io = self.io.?;
        const now = io.now(io.context);
        if (now < self.started or now - self.started >= 5_000_000_000) return error.Deadline;
    }
    fn push(self: *Vm, index: u8, ps: usize, required: bool) Error!void {
        const at = try number(u16, self.commands, 4 + @as(usize, index) * 2);
        if (at == 0) {
            if (required) return error.Missing;
            return;
        }
        if (self.depth == self.frames.len) return error.Capacity;
        const bytes = try self.table(at);
        if (bytes.len < 6 or bytes[5] & 0x7f != bytes[5] & 0x7c) return error.Format;
        const ps_shift = (bytes[5] & 0x7f) / 4;
        if (ps > self.parameters.len or ps_shift > self.parameters.len - ps) return error.Bounds;
        const f = &self.frames[self.depth];
        f.* = .{ .first = at, .end = at + bytes.len, .pc = at + 6, .ps = ps, .shift = ps_shift, .ws_count = bytes[4] };
        self.depth += 1;
    }
    fn fetch(self: *Vm, f: *Frame, comptime T: type) Error!T {
        if (f.pc < f.first + 6 or f.pc > f.end or @sizeOf(T) > f.end - f.pc) return error.Bounds;
        const value = try number(T, self.image, f.pc);
        f.pc += @sizeOf(T);
        return value;
    }
    fn jump(_: *Vm, f: *Frame, target: u16) Error!void {
        if (target < 6 or target >= f.end - f.first) return error.Bounds;
        f.pc = f.first + target;
    }
    fn direct(self: *Vm, f: *Frame, alignment: u3) Error!u32 {
        return if (alignment == 0) try self.fetch(f, u32) else if (alignment < 4) try self.fetch(f, u16) else try self.fetch(f, u8);
    }
    fn read(self: *Vm, space: Space, index: u32) Error!u32 {
        const io = self.io.?;
        return io.read(io.context, space, index);
    }
    fn write(self: *Vm, space: Space, index: u32, value: u32) Error!void {
        const io = self.io.?;
        self.effects = true;
        try io.write(io.context, space, index, value);
    }
    fn indirect(self: *Vm, id: u8, index: u32, data: u32) Error!u32 {
        const segment = self.iio[id];
        if (segment.first == 0) return error.Missing;
        var at = segment.first;
        var value: u32 = 0xcdcdcdcd;
        while (at < segment.end) {
            try self.tick();
            const op = self.image[at];
            at += 1;
            switch (op) {
                0 => {},
                2, 3 => {
                    const reg = try number(u16, self.image, at);
                    at += 2;
                    if (op == 2) value = try self.read(.mmio, reg) else try self.write(.mmio, reg, value);
                },
                4...8 => {
                    const bits = self.image[at];
                    const from = self.image[at + 1];
                    at += 2;
                    const to = if (op < 6) from else blk: {
                        const v = self.image[at];
                        at += 1;
                        break :blk v;
                    };
                    if (bits == 0 or bits > 32 or from >= 32 or to >= 32 or bits > 32 - to) return error.Format;
                    const mask = @as(u32, std.math.maxInt(u32)) >> @as(u5, @intCast(32 - bits));
                    const shifted = mask << @as(u5, @intCast(to));
                    if (op == 4) value &= ~shifted else if (op == 5) value |= shifted else {
                        if (bits > 32 - from) return error.Format;
                        const src = if (op == 6) index else if (op == 7) self.io_attr else data;
                        value = (value & ~shifted) | (((src >> @as(u5, @intCast(from))) & mask) << @as(u5, @intCast(to)));
                    }
                },
                9 => return value,
                else => return error.Unsupported,
            }
        }
        return error.Format;
    }
    fn regRead(self: *Vm, index: u32) Error!u32 {
        return if (self.io_mode == 0) self.read(.mmio, index) else if (self.io_mode & 0x80 != 0)
            self.indirect(@intCast(self.io_mode & 0x7f), index, 0)
        else
            error.Unsupported;
    }
    fn regWrite(self: *Vm, index: u32, value: u32) Error!void {
        if (self.io_mode == 0) try self.write(.mmio, index, if (index == 0) value << 2 else value) else if (self.io_mode & 0x80 != 0) {
            _ = try self.indirect(@intCast(self.io_mode & 0xff), index, value);
        } else return error.Unsupported;
    }
    fn slot(self: *Vm, f: *Frame, kind: u3, index: u32) Error!*u32 {
        if (kind == 1) {
            if (index >= self.parameters.len - f.ps) return error.Bounds;
            return &self.parameters[f.ps + index];
        }
        if (kind == 2) {
            if (index >= f.ws_count) return error.Bounds;
            return &f.workspace[index];
        }
        if (kind == 3) {
            if (self.fb_base % 4 != 0 or self.fb_base / 4 > self.scratch.len or index >= self.scratch.len - self.fb_base / 4) return error.Bounds;
            return &self.scratch[self.fb_base / 4 + index];
        }
        return error.Unsupported;
    }
    fn readRaw(self: *Vm, f: *Frame, kind: u3, index: u32) Error!u32 {
        return switch (kind) {
            0 => self.regRead(index + self.reg_block),
            1, 3 => (try self.slot(f, kind, index)).*,
            2 => switch (index) {
                0x40 => self.divmul[0],
                0x41 => self.divmul[1],
                0x42 => self.data_block,
                0x43 => self.shift,
                0x44 => @as(u32, 1) << self.shift,
                0x45 => ~(@as(u32, 1) << self.shift),
                0x46 => self.fb_base,
                0x47 => self.io_attr,
                0x48 => self.reg_block,
                else => (try self.slot(f, kind, index)).*,
            },
            4 => number(u32, self.image, index + self.data_block),
            6 => self.read(.pll, index),
            7 => self.read(.mc, index),
            else => error.Unsupported,
        };
    }
    fn writeRaw(self: *Vm, f: *Frame, kind: u3, index: u32, value: u32) Error!void {
        switch (kind) {
            0 => try self.regWrite(index + self.reg_block, value),
            1, 3 => (try self.slot(f, kind, index)).* = value,
            2 => switch (index) {
                0x40 => self.divmul[0] = value,
                0x41 => self.divmul[1] = value,
                0x42 => self.data_block = @truncate(value),
                0x43 => {
                    if (value >= 32) return error.Format;
                    self.shift = @intCast(value);
                },
                0x44, 0x45 => {},
                0x46 => self.fb_base = value,
                0x47 => self.io_attr = @truncate(value),
                0x48 => self.reg_block = @truncate(value),
                else => (try self.slot(f, kind, index)).* = value,
            },
            6 => try self.write(.pll, index, value),
            7 => try self.write(.mc, index, value),
            else => return error.Unsupported,
        }
    }
    fn readIndex(self: *Vm, f: *Frame, kind: u3) Error!u32 {
        return if (kind == 0 or kind == 4) try self.fetch(f, u16) else try self.fetch(f, u8);
    }
    fn source(self: *Vm, f: *Frame, attr: u8) Error!u32 {
        const kind: u3 = @truncate(attr);
        const alignment: u3 = @truncate(attr >> 3);
        if (kind == 5) return self.direct(f, alignment);
        const raw = try self.readRaw(f, kind, try self.readIndex(f, kind));
        return (raw & masks[alignment]) >> shifts[alignment];
    }
    fn arithmetic(self: *Vm, f: *Frame, op: ops.Operation, kind: u3) Error!void {
        var attr = try self.fetch(f, u8);
        if (op == .clear or op == .shift_left or op == .shift_right) attr = (attr & 0x38) | (defaults[(attr >> 3) & 7] << 6);
        const alignment = destination(attr);
        const idx = try self.readIndex(f, kind);
        // Full-width MOVE must not read a write-only register.
        const saved = if (op == .move and ((attr >> 3) & 7) == 0) 0 else try self.readRaw(f, kind, idx);
        const dst = (saved & masks[alignment]) >> shifts[alignment];
        const mask = if (op == .mask) try self.direct(f, @truncate(attr >> 3)) else 0;
        const src = if (op == .clear) 0 else if (op == .shift_left or op == .shift_right) try self.fetch(f, u8) else try self.source(f, attr);
        var value: u32 = undefined;
        switch (op) {
            .move => value = src,
            .bit_and => value = dst & src,
            .bit_or => value = dst | src,
            .bit_xor => value = dst ^ src,
            .add => value = dst +% src,
            .sub => value = dst -% src,
            .clear => value = 0,
            .mask => value = (dst & mask) | src,
            .shift_left, .shift_right, .shl, .shr => {
                if (src >= 32) return error.Format;
                const n: u5 = @intCast(src);
                if (op == .shift_left) value = dst << n else if (op == .shift_right) value = dst >> n else {
                    value = if (op == .shl) saved << n else saved >> n;
                    value = (value & masks[alignment]) >> shifts[alignment];
                }
            },
            .compare => {
                self.equal = dst == src;
                self.above = dst > src;
                return;
            },
            .test_bits => {
                self.equal = dst & src == 0;
                return;
            },
            .mul => {
                self.divmul[0] = dst *% src;
                return;
            },
            .div => {
                self.divmul = if (src == 0) .{ 0, 0 } else .{ dst / src, dst % src };
                return;
            },
            .mul32, .div32 => {
                const full = if (op == .mul32) @as(u64, dst) * src else if (src == 0) 0 else ((@as(u64, self.divmul[1]) << 32) | dst) / src;
                self.divmul = .{ @truncate(full), @truncate(full >> 32) };
                return;
            },
            else => return error.Unsupported,
        }
        try self.writeRaw(f, kind, idx, (saved & ~masks[alignment]) | ((value << shifts[alignment]) & masks[alignment]));
    }
    pub fn execute(self: *Vm, index_: u8, params: []u32) Error!void {
        const io = self.io orelse return error.Missing;
        if (self.running) return error.Busy;
        if (!io.worker(io.context) or params.len > 256) return error.Unsupported;
        self.running = true;
        defer self.running = false;
        self.parameters = params;
        defer self.parameters = &.{};
        self.data_block = 0;
        self.reg_block = 0;
        self.fb_base = 0;
        self.io_mode = 0;
        self.divmul = .{ 0, 0 };
        self.depth = 0;
        self.budget = 200000;
        self.started = io.now(io.context);
        try self.push(index_, 0, true);
        while (self.depth != 0) {
            try self.tick();
            const f = &self.frames[self.depth - 1];
            self.last_pc = @intCast(f.pc);
            const opcode = try self.fetch(f, u8);
            self.last_opcode = opcode;
            if (opcode == 0 or opcode >= ops.table.len) return error.Unsupported;
            const op = ops.table[opcode];
            switch (op.operation) {
                .move, .bit_and, .bit_or, .shift_left, .shift_right, .mul, .div, .add, .sub, .compare, .test_bits, .clear, .mask, .bit_xor, .shl, .shr, .mul32, .div32 => try self.arithmetic(f, op.operation, @intCast(op.arg)),
                .setport => {
                    if (op.arg != 0) return error.Unsupported;
                    const port = try self.fetch(f, u16);
                    if (port > 127) return error.Unsupported;
                    self.io_mode = if (port == 0) 0 else 0x80 | port;
                },
                .setregblock => self.reg_block = try self.fetch(f, u16),
                .setfbbase => {
                    const attr = try self.fetch(f, u8);
                    self.fb_base = try self.source(f, attr);
                },
                .switch_case => {
                    const attr = try self.fetch(f, u8);
                    const value = try self.source(f, attr);
                    while (true) {
                        try self.tick();
                        if (f.pc + 2 > f.end) return error.Bounds;
                        if (try number(u16, self.image, f.pc) == 0x5a5a) {
                            f.pc += 2;
                            break;
                        }
                        if (try self.fetch(f, u8) != 0x63) return error.Format;
                        const item = try self.direct(f, @truncate(attr >> 3));
                        const target = try self.fetch(f, u16);
                        if (item == value) {
                            try self.jump(f, target);
                            break;
                        }
                    }
                },
                .jump => {
                    const target = try self.fetch(f, u16);
                    const taken = switch (op.arg) {
                        0 => self.above,
                        1 => self.above or self.equal,
                        2 => true,
                        3 => !self.above and !self.equal,
                        4 => !self.above,
                        5 => self.equal,
                        6 => !self.equal,
                        else => return error.Format,
                    };
                    if (taken) try self.jump(f, target);
                },
                .delay => {
                    const amount = try self.fetch(f, u8);
                    try io.delay(io.context, @as(u32, amount) * (if (op.arg == 0) @as(u32, 1) else 1000));
                    try self.tick();
                },
                .calltable => {
                    const target = try self.fetch(f, u8);
                    try self.push(target, f.ps + f.shift, false);
                },
                .nop, .beep => {}, // diagnostic beep has no hardware meaning
                .eot => self.depth -= 1,
                .postcard, .debug => {
                    _ = try self.fetch(f, u8);
                },
                .setdatablock => {
                    const target = try self.fetch(f, u8);
                    self.data_block = if (target == 0) 0 else if (target == 255) @intCast(f.first) else try number(u16, self.data, 4 + @as(usize, target) * 2);
                },
                .processds => {
                    const size = try self.fetch(f, u16);
                    if (size > f.end - f.pc) return error.Bounds;
                    f.pc += size;
                },
                .repeat, .savereg, .restorereg, .invalid => return error.Unsupported,
            }
        }
    }
};
