// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const t = std.testing;
const ve = @import("vcn_engine.zig");
const p = @import("vcn_packets.zig");
const r = @import("vcn_registers.zig");
const sr = @import("start_registers.zig");
const qr = @import("queue_ring.zig");
const q = @import("queue_timeline.zig");
const a = @import("r4os").abi;
const F = struct {
    var regs: [@import("memory_registers.zig").required_prefix / 4]u32 = undefined;
    var arena: [1024 * 1024 / 4]u32 = undefined;
    var now: u64 = 1;
    var writes: usize = 0;
    var ack_smu = true;
    var ack_tiles = true;
    var engine: ve.Owner = .{};
    fn reset() void {
        @memset(&regs, 0); @memset(&arena, 0); now = 1; writes = 0; ack_smu = true; ack_tiles = true; engine = .{};
        regs[sr.smu.MP1_SMN_C2PMSG_90 / 4] = 1;
    }
    pub fn read(_: *F, reg: u32) @import("start_common.zig").Error!u32 { return regs[reg / 4]; }
    pub fn write(_: *F, reg: u32, value: u32) @import("start_common.zig").Error!void {
        regs[reg / 4] = value; writes += 1;
        if (reg == sr.smu.MP1_SMN_C2PMSG_66 and ack_smu) regs[sr.smu.MP1_SMN_C2PMSG_90 / 4] = 1;
        if (reg == r.UVD_PGFSM_CONFIG and ack_tiles) regs[r.UVD_PGFSM_STATUS / 4] = if (value == 0x155555) 0 else 0x2aaaaa;
    }
    pub fn nowNs(_: *F) u64 { return now; }
    pub fn barrier(_: *F) @import("start_common.zig").Error!void {}
    pub fn words32(_: *F, offset: usize, bytes: usize) @import("start_common.zig").Error![]volatile u32 { return arena[offset / 4..][0..bytes / 4]; }
    fn setup() ve.Setup { return .{ .epoch = 9, .firmware = 0x100401000, .firmware_bytes = 372736, .workspace = 0x101000000, .ring = .{ 0x1010c0000, 0x1010d0000, 0x1010e0000 }, .gb_addr_config = 0x24000042, .boot_held = true }; }
    fn ready(io: *F) !void {
        try engine.begin(io, io, setup()); try t.expect(!try engine.advance(io)); try t.expect(!try engine.advance(io));
        try t.expectEqual(ve.Phase.firmware_wait, engine.phase);
        try t.expect(!try engine.advance(io)); // A submitted boot is not an ACK.
        regs[r.UVD_STATUS / 4] = 2;
        try t.expect(try engine.advance(io));
    }
};

test "VCN1 original C packet oracle matches decode encode JPEG and hardware wrap tail" {
    // Hashes were evaluated by compiling the unchanged Linux 7.2.4 AMD ring
    // emission functions, not by hashing this Zig implementation. Inputs are
    // fixed MC/VM addresses below; full provenance is in the 0.80.28 evidence.
    const expected = [_][]const u8{
        "0a2a4e34a1d3a43832a56fe50b0a323c541cd309401bf9b0203608496d4be6d0", "a18aa8f43f12c4d5fb6ee9c691a0a2d3476eced877e3a786fa105916eb732b70",
        "dc94554caff429822d61e0ddf79ca3f49dc958cb2341e279eae67544e830f067", "9ef87f7d3ecf2599e21476960ff710bbe5b019be63d4770e9090c5464d0bf2c9",
        "2f00e3919680487a19a0ef58e510209459859c554992b99e4dccab435e2cc1f6", "68dae1b48822d83b0b9a10132105f79c5ea3d84da195ed52431ac6ace49079f7",
    };
    var words: [128]u32 = @splat(0xcdcdcdcd);
    for (expected, 0..) |digest, i| {
        const engine: qr.Engine = @enumFromInt(i / 2 + 3);
        const ib: ?p.Ib = if (i & 1 != 0) .{ .address = 0x5000010000, .dwords = 32 } else null;
        const count = try p.frame(engine, ib, 0x1010b0000, 0x56434e01, 0x1010e0000, &words);
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(std.mem.sliceAsBytes(words[0..count]), &hash, .{});
        try t.expectEqualStrings(digest, &std.fmt.bytesToHex(hash, .lower));
    }
    try p.jpegPatch(0x1010e0000, &words);
    var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(std.mem.sliceAsBytes(words[0..64]), &hash, .{});
    try t.expectEqualStrings("ad9927f422a146d583d5252a2e79d8ba65c8ca4b998e70c260a854d57137bd3b", &std.fmt.bytesToHex(hash, .lower));
    const saved = words;
    try t.expectError(error.Invalid, p.frame(.decode, null, 0x1010b0004, 1, 0, &words));
    try t.expectError(error.Invalid, p.frame(.decode, .{ .address = 0x5000010000, .dwords = 17 }, 0x1010b0000, 1, 0, &words));
    try t.expectError(error.Invalid, p.frame(.encode, null, 0x1010b0000, 0xffffffff, 0, &words));
    try t.expectError(error.Capacity, p.frame(.jpeg, null, 0x1010b0000, 1, 0x1010e0000, words[0..8]));
    try t.expectEqualSlices(u32, &saved, &words);
}

test "VCN1 SMU power boot cache windows independent rings and retained DMA shutdown" {
    F.reset(); var io: F = .{};
    var setup = F.setup(); setup.boot_held = false;
    try t.expectError(error.Unconfirmed, F.engine.begin(&io, &io, setup)); try t.expectEqual(@as(usize, 0), F.writes);
    try F.ready(&io);
    try t.expectEqual(@as(u32, @truncate(setup.firmware)), F.regs[r.UVD_LMI_VCPU_CACHE_64BIT_BAR_LOW / 4]);
    try t.expectEqual(@as(u32, ve.stack_bytes), F.regs[r.UVD_VCPU_CACHE_SIZE1 / 4]);
    try t.expectEqual(@as(u32, ve.context_bytes), F.regs[r.UVD_VCPU_CACHE_SIZE2 / 4]);
    try t.expectEqual(@as(u32, @truncate(setup.workspace + ve.stack_bytes)), F.regs[r.UVD_LMI_VCPU_CACHE2_64BIT_BAR_LOW / 4]);
    try t.expectEqual(@as(u32, @truncate(setup.workspace + ve.spare_ring_offset)), F.regs[r.UVD_RB_BASE_LO2 / 4]);
    // All GC arena bytes remain untouched, including KIQ/MQD/CP tables.
    for (F.arena[0..0xc0000 / 4]) |word| try t.expectEqual(@as(u32, 0), word);
    try F.engine.interrupts(&io);
    try t.expect(F.regs[r.UVD_MASTINT_EN / 4] & r.UVD_MASTINT_EN__VCPU_EN_MASK != 0);
    var commands: [128]u32 = undefined;
    const count = try p.frame(.decode, null, 0x1010b0000, 1, 0, &commands);
    const ticket = try F.engine.stage(.decode, commands[0..count]); try F.engine.kick(&io, .decode, ticket);
    try t.expectEqual(@as(u64, count), F.engine.rings[0].write);
    try t.expectEqual(@as(u64, 0), F.engine.rings[0].read);
    try t.expect(!try F.engine.stop(&io)); try t.expect(!try F.engine.stop(&io));
    try t.expect(F.engine.powered and F.engine.phase == .stop_idle);
    F.regs[r.UVD_RBC_RB_RPTR / 4] = @intCast(count);
    try t.expect(!try F.engine.stop(&io));
    try t.expect(!try F.engine.stop(&io)); // RPTR + idle are not LMI clean.
    try t.expectEqual(ve.Phase.stop_clean, F.engine.phase);
    F.regs[r.UVD_LMI_STATUS / 4] = 15;
    try t.expect(!try F.engine.stop(&io)); try t.expectEqual(ve.Phase.stop_umc, F.engine.phase);
    try t.expect(!try F.engine.stop(&io)); // UMC writes still need to drain.
    F.regs[r.UVD_LMI_STATUS / 4] |= 0x240;
    try t.expect(!try F.engine.stop(&io)); try t.expect(!try F.engine.stop(&io));
    try t.expect(try F.engine.stop(&io)); try t.expectEqual(ve.Phase.closed, F.engine.phase);
    try t.expect(!F.engine.powered); try t.expect(try F.engine.stop(&io));
    F.reset(); F.ack_smu = false; try F.engine.begin(&io, &io, F.setup());
    F.now += 500_000_000; try t.expectError(error.Deadline, F.engine.advance(&io));
    try t.expect(F.engine.touched and F.engine.smu.active); try t.expect(!try F.engine.stop(&io));
    F.reset(); try F.ready(&io); F.regs[r.UVD_STATUS / 4] = 4;
    try t.expect(!try F.engine.stop(&io)); F.now += 3_000_000_000;
    try t.expectError(error.Deadline, F.engine.stop(&io)); try t.expect(F.engine.powered and F.engine.stopping);
    F.reset(); try F.ready(&io); F.regs[r.UVD_RBC_RB_RPTR / 4] = 0xffffffff;
    try t.expectError(error.Disconnected, F.engine.observe(&io)); try t.expect(F.engine.powered);
}

fn retire(_: usize, _: a.GfxFence) bool { return true; }
test "VCN 32-bit writebacks never wrap identity and IRQ hints cannot retire resources" {
    var timeline: q.Timeline = .{};
    var writeback: [q.capacity]u64 = undefined;
    const binding: a.GfxBackendBinding = .{ .adapter_id = 4, .device_generation = 7, .reset_generation = 11 };
    try timeline.init(binding, &writeback, 1);
    const fence: a.GfxFence = .{ .adapter_id = 4, .device_generation = 7, .reset_generation = 11, .timeline = 3, .point = 1, .slot = 0 };
    const ticket = try timeline.reserve(fence, .decode, 100, .{ .context = 0, .retire = retire }); try timeline.arm(ticket);
    const event = @import("queue_ih.zig").Event.decode(.{ 0x10 | 124 << 8, 0, 0, 0, 0, 0, 0, 0 }, timeline.epoch);
    timeline.fault(event.faultMask()); timeline.poll(2);
    try t.expectEqual(q.Phase.submitted, (try timeline.entry(ticket)).phase);
    writeback[ticket.slot] = 0xffffffff00000000 | ticket.token; timeline.poll(3);
    try t.expectEqual(q.Phase.retiring, (try timeline.entry(ticket)).phase);
    const fault = @import("queue_ih.zig").Event.decode(.{ 0x10 | 125 << 8, 0, 0, 0, 0, 0, 0, 0 }, timeline.epoch);
    try t.expectEqual(qr.media_engines, fault.faultMask());
    timeline.token = std.math.maxInt(u32) - 1;
    var other = fence; other.point = 2;
    try t.expectError(error.Overflow, timeline.reserve(other, .encode, 100, .{ .context = 0, .retire = retire }));
    timeline.token = std.math.maxInt(u32);
    // GC's actual 64-bit engine remains usable after the VCN token range ends.
    const graphics = try timeline.reserve(other, .gfx, 100, .{ .context = 0, .retire = retire }); try timeline.arm(graphics);
    writeback[graphics.slot] = graphics.token & 0xffffffff; timeline.poll(4);
    try t.expectEqual(q.Phase.submitted, (try timeline.entry(graphics)).phase);
    writeback[graphics.slot] = graphics.token; timeline.poll(5);
    try t.expectEqual(q.Phase.retiring, (try timeline.entry(graphics)).phase);
}
