// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 AND MIT
// Copyright 2014 Advanced Micro Devices, Inc.
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
//! PSP upload order/sections from AMD amdgpu_ucode.c and amdgpu_psp.c.
const fw = @import("firmware.zig");
const c = @import("start_common.zig");
const w = c.wire;
pub const Error = c.Error;
/// Qualification exception for the measured Lenovo ROM only. Rejected restore
/// microcode remains unavailable; callers must disable SRM/GC power saving.
pub fn restoreQuirk(snapshot: @import("identity.zig").Snapshot, chip: @import("identity.zig").Chip, digest: [32]u8) bool {
    return chip.family == .raven2 and @import("asic_profile.zig").Profile.nativeBoard(snapshot, chip) and
        @import("std").mem.eql(u8, &digest, &@import("boot_pitch.zig").rom_sha256);
}
pub const Entry = struct {
    role: fw.Role, span: fw.Range, fw_type: u32, version: u32,
    confirmed: bool = false, address: u64 = 0,
    receipt: bool = false, response: u32 = 0,
    pub fn restoreList(self: *const Entry) bool {
        return self.fw_type == w.GFX_FW_TYPE_RLC_RESTORE_LIST_SRM_CNTL or
            self.fw_type == w.GFX_FW_TYPE_RLC_RESTORE_LIST_GPM_MEM or
            self.fw_type == w.GFX_FW_TYPE_RLC_RESTORE_LIST_SRM_MEM;
    }
};
pub const Plan = struct {
    entries: [13]Entry = undefined, count: usize = 0, asd: fw.Range = .{}, generation: u64 = 0,
    pub fn prepare(self: *Plan, store: *const @import("firmware_store.zig").Store) Error!void {
        if (self.count != 0) return error.Busy;
        if (!store.valid or store.generation == 0 or store.profile == null) return error.Firmware;
        self.generation = store.generation;
        try self.add(store, .sdma, w.GFX_FW_TYPE_SDMA0, .payload);
        try self.add(store, .ce, w.GFX_FW_TYPE_CP_CE, .payload);
        try self.add(store, .pfp, w.GFX_FW_TYPE_CP_PFP, .payload);
        try self.add(store, .me, w.GFX_FW_TYPE_CP_ME, .payload);
        // GC9.1 exposes two MECs. Their jump tables are separate PSP images.
        try self.add(store, .mec, w.GFX_FW_TYPE_CP_MEC, .mec_code);
        try self.add(store, .mec, w.GFX_FW_TYPE_CP_MEC_ME1, .jump_table);
        try self.add(store, .mec2, w.GFX_FW_TYPE_CP_MEC, .mec_code);
        try self.add(store, .mec2, w.GFX_FW_TYPE_CP_MEC_ME2, .jump_table);
        const rlc: fw.Role = if (store.profile.?.socket == .am4) .rlc_am4 else .rlc;
        try self.add(store, rlc, w.GFX_FW_TYPE_RLC_RESTORE_LIST_SRM_CNTL, .cntl);
        try self.add(store, rlc, w.GFX_FW_TYPE_RLC_RESTORE_LIST_GPM_MEM, .gpm);
        try self.add(store, rlc, w.GFX_FW_TYPE_RLC_RESTORE_LIST_SRM_MEM, .srm);
        try self.add(store, rlc, w.GFX_FW_TYPE_RLC_G, .payload);
        try self.add(store, .vcn, w.GFX_FW_TYPE_VCN, .payload);
        const blob = store.container(.asd) orelse return error.Firmware;
        self.asd = (fw.inspect(blob, store.specification(.asd) orelse return error.Firmware) catch return error.Firmware).payload;
        // VCN is authenticated into the retained PSP TMR; its IP owner starts
        // the VCPU only after the media work arena and ring ownership exist.
        // DMCU and optional TAs remain CPU-admitted. No SMU/SOS image exists for Picasso.
    }
    const Part = enum { payload, mec_code, jump_table, cntl, gpm, srm };
    fn add(self: *Plan, store: *const @import("firmware_store.zig").Store, role: fw.Role, kind: u32, part: Part) Error!void {
        const blob = store.container(role) orelse return error.Firmware;
        const spec = store.specification(role) orelse return error.Firmware;
        const layout = fw.inspect(blob, spec) catch return error.Firmware;
        var span = switch (part) {
            .payload, .mec_code => layout.payload, .jump_table => layout.jump_table,
            .cntl => layout.segments[4].span, .gpm => layout.segments[5].span, .srm => layout.segments[6].span,
        };
        if (part == .mec_code) {
            if (layout.jump_table.bytes == 0 or layout.jump_table.offset + layout.jump_table.bytes != span.offset + span.bytes) return error.Firmware;
            span.bytes -= layout.jump_table.bytes;
        }
        if (span.bytes == 0 or span.bytes > fw.max_blob_bytes or self.count == self.entries.len) return error.Firmware;
        self.entries[self.count] = .{ .role = role, .span = span, .fw_type = kind, .version = spec.ucode_version }; self.count += 1;
    }
    pub fn confirmed(self: *const Plan) bool {
        if (self.count != self.entries.len) return false;
        for (&self.entries) |*entry| if (!entry.confirmed) return false;
        return true;
    }
    pub fn executionConfirmed(self: *const Plan, restore_optional: bool) bool {
        if (self.count != self.entries.len) return false;
        for (&self.entries) |*entry| {
            if (entry.confirmed) continue;
            if (!restore_optional or !entry.restoreList() or entry.role != .rlc or entry.version != 73 or !entry.receipt or
                (entry.response != 0xffff300f and entry.response != 0xffff000f)) return false;
        }
        return true;
    }
    pub fn restoreConfirmed(self: *const Plan) bool {
        if (self.count != self.entries.len) return false;
        for (&self.entries) |*entry| if (entry.restoreList() and !entry.confirmed) return false;
        return true;
    }
};
