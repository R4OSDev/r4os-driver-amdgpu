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
//  
//! SMU10 mailbox, derived from AMD's unchanged smu10_smumgr.c / rv_ppsmc.h.
//! Complete original copyright/license notices in ThirdParty/Sources.json.
const c = @import("start_common.zig");
const r = @import("start_registers.zig");
pub const Error = c.Error;
pub const Mailbox = struct {
    active: bool = false, sent: bool = false, message: u32 = 0, response: u32 = 0, argument: u32 = 0,
    deadline: c.Deadline = .{},
    pub fn begin(self: *Mailbox, io: anytype, message: u32, argument: ?u32) Error!void {
        if (self.active) return error.Busy;
        // A zero response still belongs to the previous request. Never erase it.
        if (try c.read(io, r.smu.MP1_SMN_C2PMSG_90) == 0) return error.Busy;
        try self.deadline.start(io.nowNs(), 500_000_000, 0);
        self.message = message; self.response = 0; self.active = true; self.sent = false;
        try io.write(r.smu.MP1_SMN_C2PMSG_90, 0);
        if (try c.read(io, r.smu.MP1_SMN_C2PMSG_90) != 0) return error.Unconfirmed;
        if (argument) |value| try io.write(r.smu.MP1_SMN_C2PMSG_82, value);
        try io.barrier(); try io.write(r.smu.MP1_SMN_C2PMSG_66, message);
        self.sent = true;
        _ = try io.read(r.smu.MP1_SMN_C2PMSG_66);
    }
    pub fn poll(self: *Mailbox, io: anytype, cleanup: bool) Error!bool {
        if (!self.active or !self.sent) return error.State;
        // Cleanup may observe a late response but never resubmits the message.
        if (!cleanup) _ = try self.deadline.check(io.nowNs());
        const value = try c.read(io, r.smu.MP1_SMN_C2PMSG_90);
        if (value == 0) return false;
        self.response = value; self.argument = try c.read(io, r.smu.MP1_SMN_C2PMSG_82); self.active = false;
        if (value != r.PPSMC_Result_OK) return error.Response;
        return true;
    }
};
