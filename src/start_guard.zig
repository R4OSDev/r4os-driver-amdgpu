// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Read-only guard for the original linear boot plane during PSP/SMU bringup.
//! This is deliberately not a DCN modeset/restore engine. Any changed plane,
//! routing or timing requires the later display owner and retains the hold.
const c = @import("start_common.zig");
const d = @import("start_registers.zig").dc;
pub const Error = c.Error;
const fields = .{ "hubp_cntl", "format", "tiling", "pitch", "primary", "primary_hi", "inuse", "inuse_hi", "flip", "surface",
    "top", "bottom", "opp", "otg", "control", "htotal", "vtotal", "blank" };
pub const Guard = struct {
    values: [4][fields.len]u32 = @splat(@splat(0)), valid: bool = false, boot_mc: u64 = 0,
    firmware_pitch: bool = false,
    pub fn capture(self: *Guard, io: anytype, address: u64, pitch: u32) Error!void {
        return self.captureFirmware(io, address, pitch, .standard);
    }
    pub fn captureFirmware(self: *Guard, io: anytype, address: u64, pitch: u32, policy: @import("boot_pitch.zig").Policy) Error!void {
        if (self.valid or address == 0 or address >= (@as(u64, 1) << 48) or pitch == 0 or pitch & 3 != 0) return error.Invalid;
        self.firmware_pitch = false;
        var matched: usize = 0;
        for (0..4) |pipe| {
            inline for (fields, 0..) |name, index| self.values[pipe][index] = try sample(io, name, pipe);
            const v = &self.values[pipe];
            if (v[0] & (d.HUBP0_DCHUBP_CNTL__HUBP_BLANK_EN_MASK | d.HUBP0_DCHUBP_CNTL__HUBP_DISABLE_MASK) != 0) continue;
            // DCN1 hubp1_is_flip_pending/read_state uses EARLIEST_INUSE.
            // SURFACE_INUSE is a different register and remained zero on
            // the active Raven2 firmware plane; it is not a scanout receipt.
            const primary = @as(u64, v[5]) << 32 | v[4]; const inuse = @as(u64, v[7]) << 32 | v[6];
            if (primary != address or inuse != address) continue;
            const raw_pitch = v[3] & d.HUBPREQ0_DCSURF_SURFACE_PITCH__PITCH_MASK;
            const firmware_pitch = @import("boot_pitch.zig").direct(policy, raw_pitch, pitch);
            const otg: usize = @intCast((v[0] & d.HUBP0_DCHUBP_CNTL__HUBP_VTG_SEL_MASK) >> d.HUBP0_DCHUBP_CNTL__HUBP_VTG_SEL__SHIFT);
            if (otg >= 4 or try sample(io, "otg", otg) & d.OTG0_OTG_MASTER_EN__OTG_MASTER_EN_MASK == 0 or
                v[2] & d.HUBP0_DCSURF_TILING_CONFIG__SW_MODE_MASK != 0 or
                v[1] & d.HUBP0_DCSURF_SURFACE_CONFIG__SURFACE_PIXEL_FORMAT_MASK != 8 or
                v[9] & d.HUBPREQ0_DCSURF_SURFACE_CONTROL__PRIMARY_SURFACE_DCC_EN_MASK != 0 or
                (!firmware_pitch and (raw_pitch + 1) * 4 != pitch) or
                v[8] & d.HUBPREQ0_DCSURF_FLIP_CONTROL__SURFACE_FLIP_PENDING_MASK != 0) return error.Unconfirmed;
            self.firmware_pitch = self.firmware_pitch or firmware_pitch;
            matched += 1;
        }
        if (matched == 0) return error.Unconfirmed;
        self.boot_mc = address; self.valid = true;
        if (!try self.matches(io)) { self.valid = false; return error.Unconfirmed; }
    }
    pub fn matches(self: *const Guard, io: anytype) Error!bool {
        if (!self.valid) return false;
        for (0..4) |pipe| inline for (fields, 0..) |name, index| {
            if (try sample(io, name, pipe) != self.values[pipe][index]) return false;
        };
        return true;
    }
    /// Initial display takeover admits one directly timed linear boot plane.
    /// Other live pipes need the later multihead transaction, never guesswork.
    pub fn singlePipe(self: *const Guard) Error!u32 {
        if (!self.valid) return error.Unconfirmed;
        var selected: ?u32 = null;
        for (0..4) |pipe| {
            const v = &self.values[pipe];
            if (v[0] & (d.HUBP0_DCHUBP_CNTL__HUBP_BLANK_EN_MASK | d.HUBP0_DCHUBP_CNTL__HUBP_DISABLE_MASK) != 0) continue;
            const address = @as(u64, v[5]) << 32 | v[4];
            if (address != self.boot_mc) continue;
            if (selected != null or (v[0] & d.HUBP0_DCHUBP_CNTL__HUBP_VTG_SEL_MASK) >> d.HUBP0_DCHUBP_CNTL__HUBP_VTG_SEL__SHIFT != pipe) return error.Unsupported;
            selected = @intCast(pipe);
        }
        const pipe = selected orelse return error.Unconfirmed;
        for (0..4) |other| if (other != pipe and self.values[other][14] &
            (d.OTG0_OTG_CONTROL__OTG_MASTER_EN_MASK | d.OTG0_OTG_CONTROL__OTG_CURRENT_MASTER_EN_STATE_MASK) != 0) return error.Unsupported;
        return pipe;
    }
};
fn sample(io: anytype, comptime name: []const u8, pipe: usize) Error!u32 {
    const value = try c.read(io, @field(d, name)[pipe]);
    if (comptime @import("std").mem.eql(u8, name, "hubp_cntl")) return value &
        (d.HUBP0_DCHUBP_CNTL__HUBP_BLANK_EN_MASK | d.HUBP0_DCHUBP_CNTL__HUBP_DISABLE_MASK |
        d.HUBP0_DCHUBP_CNTL__HUBP_VTG_SEL_MASK | d.HUBP0_DCHUBP_CNTL__HUBP_TTU_DISABLE_MASK | d.HUBP0_DCHUBP_CNTL__HUBP_TTU_MODE_MASK);
    return value;
}
