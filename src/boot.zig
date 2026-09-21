// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const a = @import("r4os").abi;
const id = @import("identity.zig");
pub const Range = struct {
    base: u64, bytes: u64,
    pub fn contains(self: Range, base: u64, bytes: u64) bool {
        return self.base != 0 and self.bytes != 0 and self.base <= (~@as(u64, 0)) - self.bytes and bytes != 0 and
            base >= self.base and base - self.base < self.bytes and bytes <= self.bytes - (base - self.base);
    }
};
pub const Measurement = struct { chip: id.Chip, uma: ?Range = null };
pub const Device = struct { snapshot: id.Snapshot, measured: Measurement };
pub const Path = enum { uma_direct, measured_bar0_alias };
pub const Association = struct { index: usize, adapter: u32, generation: u64, path: Path, uma_offset: u64 };
pub const Error = error{ BootUnavailable, Policy, Uma, NoBootAdapter, AmbiguousBootAdapter, UnsupportedVariant };
pub fn uma(offset: u32, megabytes: u32) Error!Range {
    if (offset == 0 or offset == 0xffffffff or megabytes == 0 or megabytes == 0xffffffff) return error.Uma;
    const range: Range = .{ .base = @as(u64, offset) << 24, .bytes = @as(u64, megabytes) * 1024 * 1024 };
    if (range.base >= (@as(u64, 1) << 52) or range.bytes > (@as(u64, 1) << 52) - range.base) return error.Uma;
    return range;
}
pub fn validate(info: a.GfxNativeBootInfo) Error!void {
    if (info.version != 1 or info.size < @sizeOf(a.GfxNativeBootInfo) or info.generation == 0 or
        info.state != a.display_state_bootfb or info.physical_address == 0 or info.byte_length == 0 or
        info.physical_address > (~@as(u64, 0)) - info.byte_length or info.width == 0 or info.height == 0 or
        @as(u64, info.width) * 4 > info.pitch or @as(u64, info.pitch) * info.height > info.byte_length or
        (info.format != a.gfx_buffer_format_xrgb8888 and info.format != a.gfx_buffer_format_argb8888)) return error.BootUnavailable;
    if (info.policy != 0) return error.Policy;
}
pub fn select(devices: []const Device, info: a.GfxNativeBootInfo) Error!Association {
    try validate(info);
    var result: ?Association = null;
    var unsupported_variant = false;
    for (devices, 0..) |*device, index| {
        if (!id.target(device.snapshot.pci)) continue;
        if (device.measured.chip.family != .picasso) { unsupported_variant = true; continue; }
        const stolen = device.measured.uma orelse continue;
        var path: ?Path = null; var offset: u64 = 0;
        if (stolen.contains(info.physical_address, info.byte_length)) { path = .uma_direct; offset = info.physical_address - stolen.base; }
        const bar = device.snapshot.bars[0];
        if ((bar.kind == .memory32 or bar.kind == .memory64) and bar.prefetch and bar.bytes != 0 and
            (Range{ .base = bar.base, .bytes = bar.bytes }).contains(info.physical_address, info.byte_length)) {
            const alias_offset = info.physical_address - bar.base;
            if (alias_offset < stolen.bytes and info.byte_length <= stolen.bytes - alias_offset) {
                if (path != null and offset != alias_offset) return error.AmbiguousBootAdapter;
                if (path == null) { path = .measured_bar0_alias; offset = alias_offset; }
            }
        }
        if (path) |selected| {
            if (result != null) return error.AmbiguousBootAdapter;
            result = .{ .index = index, .adapter = id.adapter(device.snapshot.pci), .generation = info.generation, .path = selected, .uma_offset = offset };
        }
    }
    return result orelse if (unsupported_variant) error.UnsupportedVariant else error.NoBootAdapter;
}
