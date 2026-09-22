// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 AND MIT
// Copyright 2012-16 Advanced Micro Devices, Inc.
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
// Authors: AMD
//
//! Worker-owned SMU10 display-clock acquisition. Driver and VBIOS mailboxes
//! are separate hardware channels. DPM values are firmware-supported points;
//! a successful hard-minimum request is a firmware guarantee, not a measured
//! frequency sample. Actual DISPCLK is returned by the original VBIOS protocol.
const std = @import("std");
const common = @import("start_common.zig");
const smu = @import("start_smu.zig");
pub const wire = @cImport({ @cInclude("display_clock_wire.h"); });
pub const Error = common.Error;

pub const Table = struct {
    dcf_khz: u32, soc_khz: u32, fabric_khz: u32, memory_khz: u32,
    /// Admit only populated, nondecreasing SMU entries inside the DCN1 model
    /// domain. Empty/broken tables are rejected; no Linux fallback array is
    /// substituted for missing physical firmware data.
    pub fn parse(bytes: []const u8) Error!Table {
        if (bytes.len != @sizeOf(wire.DpmClocks_t)) return error.Invalid;
        return .{ .dcf_khz = try maximum(bytes[0..32], 655), .soc_khz = try maximum(bytes[32..96], 1200),
            .fabric_khz = try maximum(bytes[96..128], 1200), .memory_khz = try maximum(bytes[128..160], 1600) };
    }
    fn maximum(bytes: []const u8, ceiling_mhz: u32) Error!u32 {
        var previous: u32 = 0; var selected: u32 = 0; var ended = false;
        var at: usize = 0;
        while (at < bytes.len) : (at += 8) {
            const mhz = std.mem.readInt(u32, bytes[at..][0..4], .little);
            if (mhz == 0) { ended = true; continue; }
            if (ended or mhz < previous or mhz < 100 or mhz > 4000) return error.Invalid;
            if (mhz <= ceiling_mhz) selected = mhz;
            previous = mhz;
        }
        if (selected == 0) return error.Unsupported;
        return selected * 1000;
    }
};

/// Caller pins a page of UMA for this entire transaction. Each step is a
/// bounded mailbox action; an unacknowledged table DMA never permits release.
pub const Acquisition = struct {
    mailbox: smu.Mailbox = .{},
    address: u64 = 0,
    stage: enum { empty, high, low, transfer, ready, retained } = .empty,
    dma_attempted: bool = false,
    dma_completed: bool = false,
    pub fn begin(self: *Acquisition, io: anytype, mc_address: u64, bytes: u64) Error!void {
        if (self.stage != .empty) return error.Busy;
        if (mc_address == 0 or mc_address % 4096 != 0 or mc_address >= 1 << 48 or bytes != 4096 or bytes > (1 << 48) - mc_address) return error.Invalid;
        self.address = mc_address; self.stage = .high;
        try common.hdpFlush(io);
        self.mailbox.begin(io, wire.PPSMC_MSG_SetDriverDramAddrHigh, @intCast(mc_address >> 32)) catch |err| {
            self.stage = .retained; return err;
        };
    }
    pub fn step(self: *Acquisition, io: anytype) Error!bool {
        if (self.stage == .ready) return true;
        if (self.stage == .empty or self.stage == .retained) return error.State;
        return self.advance(io) catch |err| { self.stage = .retained; return err; };
    }
    fn advance(self: *Acquisition, io: anytype) Error!bool {
        if (!try self.mailbox.poll(io, false)) return false;
        switch (self.stage) {
            .high => { self.stage = .low; try self.mailbox.begin(io, wire.PPSMC_MSG_SetDriverDramAddrLow, @truncate(self.address)); },
            .low => {
                self.stage = .transfer; self.dma_attempted = true;
                try self.mailbox.begin(io, wire.PPSMC_MSG_TransferTableSmu2Dram, wire.TABLE_DPMCLOCKS);
            },
            .transfer => {
                self.dma_completed = true;
                try common.hdpInvalidate(io);
                self.stage = .ready; return true;
            },
            else => return error.State,
        }
        return false;
    }
    pub fn releasable(self: *const Acquisition) bool {
        return !self.mailbox.active and (!self.dma_attempted or self.dma_completed);
    }
    /// Shutdown observes a late response without submitting the next stage.
    /// A failed/unknown transfer never supplies a DMA completion proof.
    pub fn drain(self: *Acquisition, io: anytype) Error!bool {
        if (!self.mailbox.active) return self.releasable();
        if (!try self.mailbox.poll(io, true)) return false;
        if (self.mailbox.message == wire.PPSMC_MSG_TransferTableSmu2Dram) self.dma_completed = true;
        return self.releasable();
    }
};

pub const Vbios = struct {
    // Original RV1 channel, byte offsets from MP1 base 0x16000 DWORDs.
    pub const message_register: u32 = (0x16000 + 0x283) * 4;
    pub const argument_register: u32 = (0x16000 + 0x293) * 4;
    pub const response_register: u32 = (0x16000 + 0x29b) * 4;
    active: bool = false, sent: bool = false,
    requested_khz: u32 = 0, actual_khz: u32 = 0,
    deadline: common.Deadline = .{},
    pub fn begin(self: *Vbios, io: anytype, requested_khz: u32) Error!void {
        if (self.active) return error.Busy;
        if (requested_khz < 100000 or requested_khz > 1108000) return error.Invalid;
        if (try common.read(io, response_register) == 0) return error.Busy;
        try self.deadline.start(io.nowNs(), 10_000_000, 0);
        self.active = true; self.sent = false; self.requested_khz = requested_khz; self.actual_khz = 0;
        try io.write(response_register, 0);
        if (try common.read(io, response_register) != 0) return error.Unconfirmed;
        try io.write(argument_register, (requested_khz + 999) / 1000);
        try io.barrier();
        try io.write(message_register, 4); // VBIOSSMC_MSG_SetDispclkFreq
        self.sent = true;
        _ = try common.read(io, message_register);
    }
    pub fn poll(self: *Vbios, io: anytype, cleanup: bool) Error!bool {
        if (!self.active or !self.sent) return error.State;
        if (!cleanup) _ = try self.deadline.check(io.nowNs());
        const response = try common.read(io, response_register);
        if (response == 0) return false;
        const actual = try common.read(io, argument_register);
        self.active = false;
        if (response != 1) return error.Response;
        if (actual > 1108 or actual * 1000 < self.requested_khz) return error.Unconfirmed;
        self.actual_khz = actual * 1000;
        return true;
    }
};

/// Raise confirmed DCF/fabric/SOC/deep-sleep floors before changing DISPCLK.
/// This initial mode owner changes clocks only with all frontends stopped;
/// live clock lowering and dynamic power policies belong to the power owner.
pub const Point = struct {
    driver: smu.Mailbox = .{}, vbios: Vbios = .{},
    table: Table = undefined, disp_khz: u32 = 0, actual_disp_khz: u32 = 0,
    phase: enum { empty, fabric, soc, dcf, deep_sleep, display, ready, retained } = .empty,
    pub fn begin(self: *Point, io: anytype, table: Table, requested_disp: u32, frontends_stopped: bool) Error!void {
        if (self.phase != .empty) return error.Busy;
        if (!frontends_stopped or requested_disp < 100000 or requested_disp > 1108000 or
            table.dcf_khz < 100000 or table.dcf_khz > 655000 or table.soc_khz < 100000 or table.soc_khz > 1200000 or
            table.fabric_khz < 100000 or table.fabric_khz > 1200000 or
            table.dcf_khz % 1000 != 0 or table.soc_khz % 1000 != 0 or table.fabric_khz % 1000 != 0) return error.Unconfirmed;
        self.table = table; self.disp_khz = requested_disp; self.phase = .fabric;
        self.driver.begin(io, wire.PPSMC_MSG_SetHardMinFclkByFreq, table.fabric_khz / 1000) catch |err| { self.phase = .retained; return err; };
    }
    pub fn step(self: *Point, io: anytype) Error!bool {
        if (self.phase == .ready) return true;
        if (self.phase == .empty or self.phase == .retained) return error.State;
        return self.advance(io) catch |err| { self.phase = .retained; return err; };
    }
    fn advance(self: *Point, io: anytype) Error!bool {
        if (self.phase == .display) {
            if (!try self.vbios.poll(io, false)) return false;
            self.actual_disp_khz = self.vbios.actual_khz; self.phase = .ready; return true;
        }
        if (!try self.driver.poll(io, false)) return false;
        switch (self.phase) {
            .fabric => { self.phase = .soc; try self.driver.begin(io, wire.PPSMC_MSG_SetHardMinSocclkByFreq, self.table.soc_khz / 1000); },
            .soc => { self.phase = .dcf; try self.driver.begin(io, wire.PPSMC_MSG_SetHardMinDcefclkByFreq, self.table.dcf_khz / 1000); },
            .dcf => { self.phase = .deep_sleep; try self.driver.begin(io, wire.PPSMC_MSG_SetMinDeepSleepDcefclk, self.table.dcf_khz / 1000); },
            .deep_sleep => { self.phase = .display; try self.vbios.begin(io, self.disp_khz); },
            else => return error.State,
        }
        return false;
    }
};
