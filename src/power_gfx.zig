// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 AND MIT
// Copyright 2012-2016 Advanced Micro Devices, Inc.
// Copyright 2017 Advanced Micro Devices, Inc.
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
//! GC9 clock/idle power transitions derived from gfx_v9_0.c. Every RLC and
//! SMU acknowledgement is bounded; a pending transition blocks GC access.
const std = @import("std");
const c = @import("start_common.zig");
const l = @import("gc_layout.zig");
const r = l.r;
const sr = @import("start_registers.zig");
const Mailbox = @import("start_smu.zig").Mailbox;
const Profile = @import("asic_profile.zig").Profile;
const saved_registers = [_]u32{ r.RLC_CGTT_MGCG_OVERRIDE, r.RLC_MEM_SLP_CNTL, r.CP_MEM_SLP_CNTL,
    r.RLC_CGCG_CGLS_CTRL_3D, r.RLC_CGCG_CGLS_CTRL, r.CP_RB_WPTR_POLL_CNTL, r.RLC_PG_DELAY,
    r.RLC_PG_DELAY_2, r.RLC_PG_DELAY_3, r.RLC_AUTO_PG_CTRL, r.RLC_PG_CNTL };
pub fn quirk(snapshot: @import("identity.zig").Snapshot) bool {
    // Exact upstream board quirk; ASIC admission belongs to the native owner.
    return snapshot.pci.device_id == 0x15d8 and snapshot.subsystem_vendor == 0x19e5 and
        snapshot.subsystem_device == 0x3e14 and snapshot.pci_revision == 0xc2;
}
pub const Phase = enum { empty, safe_enter, safe_leave, awake, allow_send, allow_wait, allowed, wake_send, wake_wait, wake_status, closed };
const Change = enum { configure, allow, wake, restore };
pub const Owner = struct {
    profile: Profile = .picasso,
    phase: Phase = .empty, change: Change = .configure,
    mailbox: Mailbox = .{}, deadline: c.Deadline = .{},
    saved: [saved_registers.len]u32 = undefined, saved_pwr: u32 = 0,
    touched: bool = false, allowed: bool = false, stopping: bool = false,
    faulted: bool = false, gfxoff_supported: bool = false,
    pub fn begin(self: *Owner, io: anytype, profile: Profile, support: bool) c.Error!void {
        if (self.phase != .empty) return error.State;
        if (try c.read(io, r.RLC_CNTL) & r.RLC_CNTL__RLC_ENABLE_F32_MASK == 0 or
            try c.read(io, r.RLC_SRM_CNTL) & r.RLC_SRM_CNTL__SRM_ENABLE_MASK == 0) return error.Unconfirmed;
        for (saved_registers, &self.saved) |reg, *value| value.* = try c.read(io, reg);
        self.saved_pwr = try c.read(io, sr.pwr.PWR_MISC_CNTL_STATUS);
        self.gfxoff_supported = support;
        self.profile = profile;
        self.touched = true;
        try self.safe(io, .configure);
    }
    fn safe(self: *Owner, io: anytype, change: Change) c.Error!void {
        self.change = change;
        try self.deadline.start(io.nowNs(), 500_000_000, 0);
        self.phase = .safe_enter;
        try io.write(r.RLC_SAFE_MODE, r.RLC_SAFE_MODE__CMD_MASK | l.field("RLC_SAFE_MODE", "MESSAGE", 1));
    }
    pub fn awake(self: *const Owner) bool { return self.phase == .awake and !self.faulted; }
    pub fn step(self: *Owner, io: anytype, want_work: bool, idle_confirmed: bool, closing: bool) c.Error!void {
        if (!self.touched or self.phase == .closed) return;
        self.stopping = self.stopping or closing;
        errdefer self.faulted = true;
        switch (self.phase) {
            .safe_enter => {
                if (!closing) _ = try self.deadline.check(io.nowNs());
                if (try c.read(io, r.RLC_SAFE_MODE) & r.RLC_SAFE_MODE__CMD_MASK != 0) return;
                if (self.stopping and !self.allowed) self.change = .restore;
                switch (self.change) {
                    .configure => try self.configure(io),
                    .allow => try gating(io, true),
                    .wake => try gating(io, false),
                    .restore => {
                        // Reverse CG order: coarse/3D first, then medium grain.
                        try c.set(io, r.RLC_CGCG_CGLS_CTRL, r.RLC_CGCG_CGLS_CTRL__CGCG_EN_MASK | r.RLC_CGCG_CGLS_CTRL__CGLS_EN_MASK, 0);
                        try c.set(io, r.RLC_CGCG_CGLS_CTRL_3D, r.RLC_CGCG_CGLS_CTRL_3D__CGCG_EN_MASK | r.RLC_CGCG_CGLS_CTRL_3D__CGLS_EN_MASK, 0);
                        for (saved_registers, self.saved) |reg, value| try io.write(reg, value);
                        try c.set(io, sr.pwr.PWR_MISC_CNTL_STATUS, sr.pwr.PWR_MISC_CNTL_STATUS__PWR_GFX_RLC_CGPG_EN_MASK,
                            self.saved_pwr & sr.pwr.PWR_MISC_CNTL_STATUS__PWR_GFX_RLC_CGPG_EN_MASK);
                    },
                }
                self.phase = .safe_leave;
                try io.write(r.RLC_SAFE_MODE, r.RLC_SAFE_MODE__CMD_MASK);
            },
            .safe_leave => {
                if (!closing) _ = try self.deadline.check(io.nowNs());
                if (try c.read(io, r.RLC_SAFE_MODE) & r.RLC_SAFE_MODE__CMD_MASK != 0) return;
                self.phase = switch (self.change) { .allow => .allow_send, .restore => .closed, else => .awake };
                try self.deadline.start(io.nowNs(), 500_000_000, 0);
            },
            .awake => {
                if (self.stopping) try self.safe(io, .restore)
                else if (!self.faulted and self.gfxoff_supported and !want_work and idle_confirmed) try self.safe(io, .allow);
            },
            .allow_send => {
                if (want_work or self.stopping) { try self.safe(io, .wake); return; }
                if (!closing) _ = try self.deadline.check(io.nowNs());
                self.mailbox.begin(io, sr.PPSMC_MSG_EnableGfxOff, null) catch |err| {
                    if (self.mailbox.active) { self.allowed = true; self.phase = .allow_wait; }
                    if (err == error.Busy and !self.mailbox.active) return;
                    return err;
                };
                self.allowed = true; self.phase = .allow_wait;
            },
            .allow_wait => {
                const done = self.mailbox.poll(io, closing) catch |err| {
                    if (!self.mailbox.active) {
                        self.phase = .wake_send;
                        try self.deadline.start(io.nowNs(), 500_000_000, 0);
                    }
                    return err;
                };
                if (done) {
                    self.phase = if (want_work or self.stopping) .wake_send else .allowed;
                    try self.deadline.start(io.nowNs(), 500_000_000, 0);
                }
            },
            .allowed => if (want_work or self.stopping) {
                self.phase = .wake_send;
                try self.deadline.start(io.nowNs(), 500_000_000, 0);
            },
            .wake_send => {
                if (!closing) _ = try self.deadline.check(io.nowNs());
                self.mailbox.begin(io, sr.PPSMC_MSG_DisableGfxOff, null) catch |err| {
                    if (self.mailbox.active) self.phase = .wake_wait;
                    if (err == error.Busy and !self.mailbox.active) return;
                    return err;
                };
                self.phase = .wake_wait;
            },
            .wake_wait => {
                const done = self.mailbox.poll(io, closing) catch |err| {
                    if (!self.mailbox.active) self.phase = .wake_send;
                    return err;
                };
                if (done) {
                    try self.deadline.start(io.nowNs(), 500_000_000, 0); self.phase = .wake_status;
                }
            },
            .wake_status => {
                if (!closing) _ = try self.deadline.check(io.nowNs());
                const value = try c.read(io, sr.pwr.PWR_MISC_CNTL_STATUS);
                if (value & sr.pwr.PWR_MISC_CNTL_STATUS__PWR_GFXOFF_STATUS_MASK != 2 << sr.pwr.PWR_MISC_CNTL_STATUS__PWR_GFXOFF_STATUS__SHIFT) return;
                self.allowed = false;
                try self.safe(io, .wake); // Picasso compute workaround: PG off before submission.
            },
            else => {},
        }
    }
    fn configure(self: *Owner, io: anytype) c.Error!void {
        // Medium grain first. The RLC itself keeps its documented override.
        const clear = r.RLC_CGTT_MGCG_OVERRIDE__CPF_CGTT_SCLK_OVERRIDE_MASK | r.RLC_CGTT_MGCG_OVERRIDE__GRBM_CGTT_SCLK_OVERRIDE_MASK |
            r.RLC_CGTT_MGCG_OVERRIDE__GFXIP_MGCG_OVERRIDE_MASK | r.RLC_CGTT_MGCG_OVERRIDE__GFXIP_MGLS_OVERRIDE_MASK |
            r.RLC_CGTT_MGCG_OVERRIDE__GFXIP_GFX3D_CG_OVERRIDE_MASK | r.RLC_CGTT_MGCG_OVERRIDE__GFXIP_CGCG_OVERRIDE_MASK | r.RLC_CGTT_MGCG_OVERRIDE__GFXIP_CGLS_OVERRIDE_MASK;
        try c.set(io, r.RLC_CGTT_MGCG_OVERRIDE, clear | r.RLC_CGTT_MGCG_OVERRIDE__RLC_CGTT_SCLK_OVERRIDE_MASK, r.RLC_CGTT_MGCG_OVERRIDE__RLC_CGTT_SCLK_OVERRIDE_MASK);
        // Neither admitted family advertises RLC memory light-sleep (soc15.c).
        try c.set(io, r.CP_MEM_SLP_CNTL, r.CP_MEM_SLP_CNTL__CP_MEM_LS_EN_MASK, r.CP_MEM_SLP_CNTL__CP_MEM_LS_EN_MASK);
        const cg3d: u32 = if (self.profile == .raven2)
            l.field("RLC_CGCG_CGLS_CTRL_3D", "CGCG_GFX_IDLE_THRESHOLD", 0x36) | r.RLC_CGCG_CGLS_CTRL_3D__CGCG_EN_MASK else 0;
        try io.write(r.RLC_CGCG_CGLS_CTRL_3D, cg3d | l.field("RLC_CGCG_CGLS_CTRL_3D", "CGLS_REP_COMPANSAT_DELAY", 0xf) | r.RLC_CGCG_CGLS_CTRL_3D__CGLS_EN_MASK);
        try io.write(r.RLC_CGCG_CGLS_CTRL, l.field("RLC_CGCG_CGLS_CTRL", "CGCG_GFX_IDLE_THRESHOLD", 0x36) |
            l.field("RLC_CGCG_CGLS_CTRL", "CGLS_REP_COMPANSAT_DELAY", 0xf) | r.RLC_CGCG_CGLS_CTRL__CGCG_EN_MASK | r.RLC_CGCG_CGLS_CTRL__CGLS_EN_MASK);
        try io.write(r.CP_RB_WPTR_POLL_CNTL, l.field("CP_RB_WPTR_POLL_CNTL", "POLL_FREQUENCY", 0x100) | l.field("CP_RB_WPTR_POLL_CNTL", "IDLE_POLL_COUNT", 0x90));
        if (self.gfxoff_supported) {
            try io.write(r.RLC_PG_DELAY, l.field("RLC_PG_DELAY", "POWER_UP_DELAY", 0x10) | l.field("RLC_PG_DELAY", "POWER_DOWN_DELAY", 0x10) |
                l.field("RLC_PG_DELAY", "CMD_PROPAGATE_DELAY", 0x10) | l.field("RLC_PG_DELAY", "MEM_SLEEP_DELAY", 0x40));
            try l.set(io, "RLC_PG_DELAY_2", "SERDES_CMD_DELAY", 4);
            try l.set(io, "RLC_PG_DELAY_3", "CGCG_ACTIVE_BEFORE_CGPG", 0xff);
            try l.set(io, "RLC_AUTO_PG_CTRL", "GRBM_REG_SAVE_GFX_IDLE_THRESHOLD", 0x55f0);
            try c.set(io, sr.pwr.PWR_MISC_CNTL_STATUS, sr.pwr.PWR_MISC_CNTL_STATUS__PWR_GFX_RLC_CGPG_EN_MASK, sr.pwr.PWR_MISC_CNTL_STATUS__PWR_GFX_RLC_CGPG_EN_MASK);
        }
        try gating(io, false);
    }
    fn gating(io: anytype, enable: bool) c.Error!void {
        const mask = r.RLC_PG_CNTL__GFX_POWER_GATING_ENABLE_MASK | r.RLC_PG_CNTL__CP_PG_DISABLE_MASK |
            r.RLC_PG_CNTL__SMU_CLK_SLOWDOWN_ON_PU_ENABLE_MASK | r.RLC_PG_CNTL__SMU_CLK_SLOWDOWN_ON_PD_ENABLE_MASK;
        const value = if (enable) r.RLC_PG_CNTL__GFX_POWER_GATING_ENABLE_MASK |
            r.RLC_PG_CNTL__SMU_CLK_SLOWDOWN_ON_PU_ENABLE_MASK | r.RLC_PG_CNTL__SMU_CLK_SLOWDOWN_ON_PD_ENABLE_MASK else r.RLC_PG_CNTL__CP_PG_DISABLE_MASK;
        try c.set(io, r.RLC_PG_CNTL, mask, value);
    }
};
