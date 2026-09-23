// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Initial firmware-plane exception, never a DCN programming convention.
//! The Lenovo Raven2 GOP reports 7680 bytes while leaving PITCH=1920.
//! Keep that measured case separate from AMD hubp1_program_size's minus one.
const std = @import("std");
const a = @import("r4os").abi;
const identity = @import("identity.zig");
pub const Policy = enum { standard, lenovo_gop_1920 };
pub const rom_sha256 = blk: {
    var value: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&value, "9de4aa4bdc8b8a5004856eaf5e52c07786b39090ff1b659e4c0b3ef950642294") catch unreachable;
    break :blk value;
};
pub fn select(snapshot: identity.Snapshot, chip: identity.Chip, digest: [32]u8, boot: a.GfxNativeBootInfo) Policy {
    if (!@import("asic_profile.zig").Profile.nativeBoard(snapshot, chip) or chip.family != .raven2 or
        !std.mem.eql(u8, &digest, &rom_sha256) or boot.version != 1 or boot.size < @sizeOf(a.GfxNativeBootInfo) or
        boot.state != a.display_state_bootfb or boot.format != a.gfx_buffer_format_xrgb8888 or
        boot.width != 1920 or boot.height != 1080 or boot.pitch != 7680 or boot.byte_length != 8294400) return .standard;
    return .lenovo_gop_1920;
}
pub fn direct(policy: Policy, raw: u32, bytes: u32) bool {
    return policy == .lenovo_gop_1920 and raw == 1920 and bytes == 7680;
}
