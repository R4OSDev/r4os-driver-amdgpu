// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std"); const t = std.testing;
const c = @import("start_common.zig");
const r = @import("start_registers.zig"); const s = r.sdma;
const q = @import("queue_registers.zig"); const store = @import("queue_storage.zig");
const ring = @import("sdma_ring.zig");
const original = @cImport({ @cInclude("../ThirdParty/Linux7.2.4/Original/drivers/gpu/drm/amd/amdgpu/vega10_sdma_pkt_open.h"); });
const Model = struct {
    ready: bool = true, clock: u64 = 10, lost: bool = false, fail_bell: bool = false, bell: u64 = 0,
    words: [r.required_prefix / 4]u32 = @splat(0), arena: [store.bytes / 4]u32 align(4096) = @splat(0),
    pub fn read(self: *@This(), offset: u32) c.Error!u32 { return if (self.lost) 0xffffffff else self.words[offset / 4]; }
    pub fn write(self: *@This(), offset: u32, value: u32) c.Error!void { self.words[offset / 4] = value; }
    pub fn barrier(_: *@This()) c.Error!void {}
    pub fn nowNs(self: *@This()) u64 { return self.clock; }
    pub fn address(_: *@This(), offset: usize, _: usize) c.Error!u64 { return 0x120000000 + offset; }
    pub fn words32(self: *@This(), offset: usize, bytes: usize) c.Error![]volatile u32 { return self.arena[offset / 4..][0..bytes / 4]; }
    pub fn doorbell64(self: *@This(), _: store.Engine, value: u64) c.Error!void { self.bell = value; if (self.fail_bell) return error.Unconfirmed; }
};
var model: Model = .{};
test "SDMA original packet fields ring units stop evidence and uncertain doorbell retention" {
    model = .{};
    model.words[s.SDMA0_F32_CNTL / 4] = s.SDMA0_F32_CNTL__HALT_MASK;
    model.words[s.SDMA0_STATUS_REG / 4] = s.SDMA0_STATUS_REG__IDLE_MASK;
    model.words[r.nb.BIF_SDMA0_DOORBELL_RANGE / 4] = 0x100;
    var engine: ring.Engine = .{};
    try t.expectError(error.Unconfirmed, engine.open(&model, &model, .{ .firmware_ready = false, .boot_held = true, .gmc_enabled = true }));
    try t.expect(!engine.touched);
    try engine.open(&model, &model, .{ .firmware_ready = true, .boot_held = true, .gmc_enabled = true });
    try t.expectEqual(@as(u32, 14), (model.words[s.SDMA0_GFX_RB_CNTL / 4] & s.SDMA0_GFX_RB_CNTL__RB_SIZE_MASK) >> s.SDMA0_GFX_RB_CNTL__RB_SIZE__SHIFT);
    var commands: [32]u32 = undefined;
    const ib: u64 = 0x8000080000; const fence: u64 = 0x120010100; const token: u64 = 0x123456789;
    _ = try ring.frame(&commands, 0, ib, 16, fence, token, true);
    try t.expectEqual(original.SDMA_PKT_HEADER_OP(@as(u32, original.SDMA_OP_INDIRECT)) | original.SDMA_PKT_INDIRECT_HEADER_VMID(@as(u32, 1)), commands[10]);
    try t.expectEqual(original.SDMA_PKT_HEADER_OP(@as(u32, original.SDMA_OP_POLL_REGMEM)) | original.SDMA_PKT_POLL_REGMEM_HEADER_HDP_FLUSH(@as(u32, 1)) |
        original.SDMA_PKT_POLL_REGMEM_HEADER_FUNC(@as(u32, 3)), commands[0]);
    try t.expectEqual(original.SDMA_PKT_POLL_REGMEM_DW5_RETRY_COUNT(@as(u32, 0xfff)) | original.SDMA_PKT_POLL_REGMEM_DW5_INTERVAL(@as(u32, 10)), commands[5]);
    try t.expectEqual(original.SDMA_PKT_HEADER_OP(@as(u32, original.SDMA_OP_FENCE)), commands[22]);
    try t.expectEqual(@as(u32, @truncate(token >> 32)), commands[29]);
    try t.expectEqual(@as(u32, original.SDMA_OP_TRAP), commands[30]);
    const ticket = try engine.ring.stage(&commands); try engine.kick(&model, &model, ticket);
    try t.expectEqual(@as(u64, 128), model.bell);
    model.words[s.SDMA0_GFX_RB_RPTR / 4] = 128; try engine.observe(&model);
    try t.expectEqual(engine.ring.write, engine.ring.read);
    // Reclaimed ring slots carry a monotone byte doorbell across physical wrap.
    engine.ring.write = store.ring_bytes / 4; engine.ring.read = engine.ring.write;
    const wrap = try engine.ring.stage(&commands); try engine.kick(&model, &model, wrap);
    try t.expectEqual(@as(u64, store.ring_bytes + 128), model.bell);
    model.words[s.SDMA0_GFX_RB_RPTR / 4] = store.ring_bytes + 128; try engine.observe(&model);
    const uncertain = try engine.ring.stage(&commands); model.fail_bell = true;
    try t.expectError(error.Unconfirmed, engine.kick(&model, &model, uncertain));
    try t.expect(engine.ring.write == uncertain.end and engine.ring.staged == null);
    try t.expectError(error.Stale, engine.ring.cancel(uncertain));
    try t.expect(!try engine.stop(&model));
    model.clock += 100000;
    try t.expect(!try engine.stop(&model)); // Core idle alone is not DMA idle.
    model.words[s.SDMA0_STATUS_REG / 4] |= s.SDMA0_STATUS_REG__MC_RD_IDLE_MASK | s.SDMA0_STATUS_REG__MC_WR_IDLE_MASK;
    try t.expect(try engine.stop(&model)); try engine.restoreRouting(&model);
    try t.expectEqual(@as(u32, 0x100), model.words[r.nb.BIF_SDMA0_DOORBELL_RANGE / 4]);
    try t.expectEqual(@as(u32, 0), model.words[q.nb.RCC_DOORBELL_APER_EN / 4]);
    model = .{}; model.words[s.SDMA0_F32_CNTL / 4] = s.SDMA0_F32_CNTL__HALT_MASK; model.words[s.SDMA0_STATUS_REG / 4] = 1;
    engine = .{}; try engine.open(&model, &model, .{ .firmware_ready = true, .boot_held = true, .gmc_enabled = true });
    try t.expect(!try engine.stop(&model)); model.clock += 500000001;
    try t.expectError(error.Deadline, engine.stop(&model)); try t.expect(engine.touched and !engine.quiesced);
    model.lost = true; engine = .{};
    try t.expectError(error.Disconnected, engine.open(&model, &model, .{ .firmware_ready = true, .boot_held = true, .gmc_enabled = true }));
    // Analyze the real native pump, including both prepare/activate branches.
    try t.expectError(error.State, @import("main.zig").advanceNative());
}
