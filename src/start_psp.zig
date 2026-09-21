// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 AND MIT
// Copyright 2016 Advanced Micro Devices, Inc.
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
// Author: Huang Rui
// 
//  
//! PSP10 GPCOM protocol, ported from psp_v10_0.c / amdgpu_psp.c.
//! Full original AMD MIT notices are preserved with those unchanged sources.
const c = @import("start_common.zig");
const r = @import("start_registers.zig").psp;
const s = @import("start_storage.zig");
const w = c.wire;
pub const Error = c.Error;
pub const Operation = enum { none, tmr, firmware, asd, unload, destroy };
pub const Controller = struct {
    ring_possible: bool = false, ring_ready: bool = false, mailbox: enum { none, create, stop } = .none,
    operation: Operation = .none, deadline: c.Deadline = .{}, token: u32 = 0,
    tmr_possible: bool = false, tmr_ready: bool = false, asd_ready: bool = false,
    asd_session: u32 = 0, response: u32 = 0, firmware_address: u64 = 0,
    pub fn create(self: *Controller, io: anytype, view: s.View) Error!void {
        if (self.ring_possible or self.mailbox != .none or self.operation != .none) return error.Busy;
        try self.deadline.start(io.nowNs(), 500_000_000, 20_000_000);
        try c.hdpFlush(io);
        try io.write(r.MP0_SMN_C2PMSG_69, @truncate(view.address(s.ring)));
        try io.write(r.MP0_SMN_C2PMSG_70, @truncate(view.address(s.ring) >> 32));
        try io.write(r.MP0_SMN_C2PMSG_71, 4096);
        self.ring_possible = true; self.mailbox = .create;
        try io.write(r.MP0_SMN_C2PMSG_64, 2 << 16);
    }
    pub fn stop(self: *Controller, io: anytype) Error!void {
        if (!self.ring_possible) return;
        if (self.operation != .none or self.mailbox != .none or self.tmr_possible or self.asd_ready) return error.Busy;
        try self.deadline.start(io.nowNs(), 500_000_000, 20_000_000);
        self.mailbox = .stop; try io.write(r.MP0_SMN_C2PMSG_64, 3 << 16);
    }
    pub fn pollMailbox(self: *Controller, io: anytype, cleanup: bool) Error!bool {
        if (self.mailbox == .none) return error.State;
        const now = io.nowNs();
        if (cleanup) {
            if (now < self.deadline.last) return error.Deadline;
            if (now < self.deadline.earliest) return false;
        } else if (!try self.deadline.check(now)) return false;
        const value = try c.read(io, r.MP0_SMN_C2PMSG_64);
        if (value & 0x80000000 == 0) return false;
        // PSP10 specifies the response flag. Do not invent a modern mailbox
        // result layout or a Mode1 reset (not supported by this PSP revision).
        const mode = self.mailbox; self.mailbox = .none;
        if (mode == .create) self.ring_ready = true else { self.ring_ready = false; self.ring_possible = false; }
        return true;
    }
    pub fn submit(self: *Controller, io: anytype, view: s.View, operation: Operation, args: []const u32) Error!void {
        if (!self.ring_ready or self.mailbox != .none or self.operation != .none) return error.Busy;
        if (operation == .none or (operation == .destroy and !self.tmr_possible) or args.len > 6 or self.token == 0xfffffffe) return error.Invalid;
        const command: u32 = switch (operation) {
            .tmr => w.GFX_CMD_ID_SETUP_TMR, .firmware => w.GFX_CMD_ID_LOAD_IP_FW,
            .asd => w.GFX_CMD_ID_LOAD_ASD, .unload => w.GFX_CMD_ID_UNLOAD_TA,
            .destroy => w.GFX_CMD_ID_DESTROY_TMR, .none => unreachable,
        };
        if ((operation == .tmr and self.tmr_possible) or (operation != .tmr and operation != .destroy and !self.tmr_ready)) return error.State;
        var write = try c.read(io, r.MP0_SMN_C2PMSG_67);
        if (write == 1024) write = 0;
        if (write >= 1024 or write & 15 != 0) return error.Invalid;
        try self.deadline.start(io.nowNs(), 2_000_000_000, 0);
        view.zero(s.command, 4096); view.words[(s.command + w.R4_PSP_COMMAND_ID) / 4] = command;
        for (args, 0..) |value, i| view.words[(s.command + w.R4_PSP_ARGUMENTS) / 4 + i] = value;
        view.words[(s.command + w.R4_PSP_RESPONSE) / 4] = 0xffffffff;
        view.words[s.fence / 4] = 0xffffffff;
        self.token += 1;
        const frame: usize = s.ring + @as(usize, write) * 4;
        view.zero(frame, w.R4_PSP_FRAME_BYTES);
        view.write64(frame, view.address(s.command));
        view.write64(frame + w.R4_PSP_FRAME_FENCE, view.address(s.fence));
        view.words[(frame + w.R4_PSP_FRAME_TOKEN) / 4] = self.token;
        // GPCOM leaves buf_size/buf_version/frame cmd_buf_size and RBI fields
        // zero, exactly as the pinned kernel. Only addresses refer to UMA MC.
        try c.hdpFlush(io);
        self.operation = operation;
        if (operation == .tmr) self.tmr_possible = true;
        try io.write(r.MP0_SMN_C2PMSG_67, (write + 16) % 1024);
    }
    pub fn poll(self: *Controller, io: anytype, view: s.View, cleanup: bool) Error!bool {
        if (self.operation == .none) return error.State;
        if (!cleanup) _ = try self.deadline.check(io.nowNs());
        try c.hdpInvalidate(io);
        if (view.words[s.fence / 4] != self.token) return false;
        try io.barrier(); if (view.words[s.fence / 4] != self.token) return false;
        const offset = (s.command + w.R4_PSP_RESPONSE) / 4;
        self.response = view.words[offset];
        self.firmware_address = @as(u64, view.words[offset + 3]) << 32 | view.words[offset + 2];
        const operation = self.operation; self.operation = .none;
        if (self.response != 0) return error.Response;
        switch (operation) {
            .tmr => self.tmr_ready = true,
            .asd => { self.asd_session = view.words[offset + 1]; self.asd_ready = true; },
            .unload => { self.asd_ready = false; self.asd_session = 0; },
            .destroy => { self.tmr_ready = false; self.tmr_possible = false; },
            else => {},
        }
        return true;
    }
    pub fn safeToRelease(self: *const Controller) bool {
        return !self.ring_possible and self.mailbox == .none and self.operation == .none and !self.tmr_possible and !self.asd_ready;
    }
};
