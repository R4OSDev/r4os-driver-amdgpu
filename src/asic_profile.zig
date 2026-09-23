// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Immutable ASIC selection shared by memory, engines and context recovery.
//! This describes register programming, not admission to the native backend.
const std = @import("std");
const identity = @import("identity.zig");
pub const Profile = enum {
    picasso, raven2,
    pub fn select(chip: identity.Chip) error{Unsupported}!Profile {
        var expected = identity.chip(0x15d8, @as(u32, chip.asic_revision) << @import("registers.zig").revision_shift) catch return error.Unsupported;
        if (!std.mem.eql(u8, expected.compiler, chip.compiler)) return error.Unsupported;
        expected.compiler = chip.compiler; // meta.eql compares slice identity
        if (!std.meta.eql(chip, expected)) return error.Unsupported;
        return switch (chip.family) { .picasso => .picasso, .raven2 => .raven2, .raven => error.Unsupported };
    }
    /// Native Raven2 qualification currently targets this measured board.
    /// Other Dali/Pollock revisions have additional DCN quirks; discovery
    /// remains available without inheriting this board's native admission.
    pub fn nativeBoard(snapshot: identity.Snapshot, chip: identity.Chip) bool {
        if (!identity.target(snapshot.pci)) return false;
        const profile = select(chip) catch return false;
        return profile == .picasso or (snapshot.subsystem_vendor == 0x17aa and snapshot.subsystem_device == 0x3808 and
            snapshot.pci_revision == 0xc4 and chip.asic_revision == 9);
    }
    // gfx_v9_0.c / original *_gpu_info.bin: maxima, before harvesting fuses.
    pub fn cuMask(self: Profile) u32 { return if (self == .raven2) 7 else 0x7ff; }
    pub fn rbMask(self: Profile) u32 { return if (self == .raven2) 1 else 3; }
    pub fn gdsMaxWave(self: Profile) u32 { return if (self == .raven2) 0x77 else 0x15f; }
    // dc_resource.c DCN1.01 selection and dcn10_resource.c rv2_res_cap.
    pub fn displayPipes(self: Profile) u32 { return if (self == .raven2) 3 else 4; }
    // gfxhub_v1_0.c and mmhub_v1_0.c: Raven2 cannot use the last logical
    // VRAM page unless HIGH_ADDR extends by one. This is not extra owned RAM.
    pub fn apertureHigh(self: Profile, exclusive_end: u64) error{Invalid}!u32 {
        if (exclusive_end == 0 or exclusive_end > @as(u64, 1) << 48) return error.Invalid;
        const high = ((exclusive_end - 1) >> 18) + @as(u64, if (self == .raven2) 1 else 0);
        if (high > 0x3fffffff) return error.Invalid;
        return @intCast(high);
    }
};
