// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
// Container admission only. Original Linux MIT layouts and selection rules:
// ThirdParty/Sources.json, amdgpu_ucode.h/.c, gfx_v9_0.c, amdgpu_rlc.c,
// psp_v10_0.c, amdgpu_psp.c and amdgpu_dm.c. No firmware code is executed.
const std = @import("std");
const identity = @import("identity.zig");
pub const Kind = enum { psp_asd, psp_ta, gfx, rlc, sdma, vcn, gpu_info, dmcu };
pub const Role = enum { asd, ta, pfp, me, ce, mec, mec2, rlc, rlc_am4, sdma, vcn, gpu_info, dmcu };
pub const Requirement = enum { boot, trusted_applications, second_compute_engine, video, topology_reference, display_abm };
pub const Family = enum { picasso, raven2, shared };
pub const firmware_count = 24;
pub const metadata_count = 2;
pub const firmware_first = 1 + metadata_count;
pub const Artifact = struct { path: []const u8, resource: []const u8, bytes: usize, sha256: []const u8, upstream_path: []const u8, upstream_revision: []const u8 = "", git_blob: []const u8 };
pub const Firmware = struct {
    path: []const u8, resource: []const u8, bytes: usize, sha256: []const u8, upstream_path: []const u8, upstream_revision: []const u8 = "", git_blob: []const u8,
    role: Role, kind: Kind, requirement: Requirement, family: Family,
    header_bytes: u32, header_major: u16, header_minor: u16, ip_major: u16, ip_minor: u16,
    ucode_version: u32, payload_offset: u32, payload_bytes: u32, crc32: u32,
    pub fn artifact(self: *const Firmware) Artifact {
        return .{ .path = self.path, .resource = self.resource, .bytes = self.bytes, .sha256 = self.sha256, .upstream_path = self.upstream_path, .upstream_revision = self.upstream_revision, .git_blob = self.git_blob };
    }
};
pub const Lock = struct { schema: u32, revision: []const u8, raven2_rlc_revision: []const u8, upstream: []const u8, driver_source: []const u8, firmware: [firmware_count]Firmware, metadata: [metadata_count]Artifact };
pub const lock_bytes = @embedFile("firmware_lock.json");
pub const lock: Lock = blk: {
    @setEvalBranchQuota(2000000);
    var storage: [128 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    break :blk std.json.parseFromSliceLeaky(Lock, allocator.allocator(), lock_bytes, .{}) catch @compileError("invalid AMD firmware lock");
};
pub const max_blob_bytes = 512 * 1024;
pub const max_package_bytes = 2 * 1024 * 1024;
pub const max_bundle_bytes = 4 * 1024 * 1024;
pub const Error = error{ Target, Profile, Size, Header, Revision, Version, Range, Overlap, Hash, Topology };
pub const Socket = enum { fp5, am4 };
pub const Profile = struct {
    family: Family = .picasso,
    socket: Socket,
    pci_revision: u8,
    pub fn includes(self: Profile, role: Role) bool {
        return switch (role) { .rlc => self.socket == .fp5, .rlc_am4 => self.socket == .am4, else => true };
    }
    pub fn selects(self: Profile, entry: Firmware) bool {
        return (entry.family == self.family or entry.family == .shared) and self.includes(entry.role);
    }
    pub fn secureDisplayAllowed(self: Profile, version: u32) bool {
        return self.family != .picasso or self.pci_revision != 0xa1 or version < 0x27000008;
    }
};
pub fn select(snapshot: *const identity.Snapshot, chip: identity.Chip) Error!Profile {
    if (!identity.target(snapshot.pci)) return error.Target;
    const raven2 = chip.family == .raven2;
    if ((!raven2 and chip.family != .picasso) or (chip.asic_revision >= 8) != raven2 or
        chip.external_revision != @as(u8, chip.asic_revision) + @as(u8, if (raven2) 0x79 else 0x41) or
        chip.gc != (if (raven2) @as(u32, 0x090202) else 0x090100) or
        chip.sdma != (if (raven2) @as(u32, 0x040101) else 0x040100) or
        chip.dcn != (if (raven2) @as(u32, 0x010001) else 0x010000) or
        chip.nbio != (if (raven2) @as(u32, 0x070001) else 0x070000) or
        chip.psp != (if (raven2) @as(u32, 0x0a0001) else 0x0a0000) or
        chip.smu != (if (raven2) @as(u32, 0x0a0001) else 0x0a0000) or
        chip.vcn != (if (raven2) @as(u32, 0x010001) else 0x010000) or
        !std.mem.eql(u8, chip.compiler, if (raven2) "gfx909" else "gfx902")) return error.Profile;
    const revision = snapshot.pci_revision;
    return .{ .family = if (raven2) .raven2 else .picasso, .pci_revision = revision,
        .socket = if (!raven2 and ((revision >= 0xc8 and revision <= 0xcf) or (revision >= 0xd8 and revision <= 0xdf))) .am4 else .fp5 };
}
pub fn specification(family: Family, role: Role) *const Firmware {
    for (&lock.firmware) |*entry| if (entry.role == role and (entry.family == family or entry.family == .shared)) return entry;
    unreachable;
}
pub fn hashMatches(bytes: []const u8, expected: []const u8) bool {
    var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.mem.eql(u8, &std.fmt.bytesToHex(hash, .lower), expected);
}
pub fn verify(data: []const u8, spec: *const Firmware) Error!Layout {
    if (data.len != spec.bytes) return error.Size;
    if (!hashMatches(data, spec.sha256)) return error.Hash;
    return inspect(data, spec);
}
pub const Range = struct {
    offset: usize = 0, bytes: usize = 0,
    pub fn slice(self: Range, data: []const u8) []const u8 { return data[self.offset..][0..self.bytes]; }
};
pub const Segment = struct { span: Range = .{}, version: u32 = 0, feature: u32 = 0 };
pub const Layout = struct {
    payload: Range = .{}, jump_table: Range = .{}, feature: u32 = 0,
    // RLC: format, list, separate format/list, CNTL, GPM, SRM.
    // TA: XGMI, RAS, HDCP, DTM, SecureDisplay. Empty spans stay absent.
    // DMCU: ERAM and interrupt vectors. No pointers into executable CPU code.
    segments: [7]Segment = .{Segment{}} ** 7,
    pub fn secureDisplay(self: *const Layout, profile: Profile) ?Range {
        const segment = self.segments[4];
        return if (segment.span.bytes != 0 and profile.secureDisplayAllowed(segment.version)) segment.span else null;
    }
};
fn read(comptime T: type, data: []const u8, offset: usize) Error!T {
    if (offset > data.len or @sizeOf(T) > data.len - offset) return error.Size;
    return std.mem.readInt(T, data[offset..][0..@sizeOf(T)], .little);
}
fn span(data: []const u8, minimum: usize, offset: usize, bytes: usize) Error!Range {
    if (bytes == 0) { if (offset != 0) return error.Range; return .{}; }
    if (offset < minimum or offset % 4 != 0 or bytes % 4 != 0 or offset > data.len or bytes > data.len - offset) return error.Range;
    return .{ .offset = offset, .bytes = bytes };
}
fn overlaps(a: Range, b: Range) bool { return a.bytes != 0 and b.bytes != 0 and a.offset < b.offset + b.bytes and b.offset < a.offset + a.bytes; }
fn jump(data: []const u8, payload: Range, offset: u32, bytes: u32) Error!Range {
    if (bytes == 0) { if (offset != 0) return error.Range; return .{}; }
    const start = @as(u64, offset) * 4; const len = @as(u64, bytes) * 4;
    if (start > payload.bytes or len > payload.bytes - start) return error.Range;
    return span(data, payload.offset, payload.offset + @as(usize, @intCast(start)), @intCast(len));
}
// The public container description is parsed independently of the whole-file
// hash, so host negatives exercise offsets/revisions rather than only SHA256.
// CRC32 is retained as pinned metadata. Upstream only checks total size; these
// original files do not all use zlib's payload CRC convention. SHA256 covers
// every original byte, including headers, padding and auxiliary RLC sections.
pub fn inspect(data: []const u8, spec: *const Firmware) Error!Layout {
    if (data.len < 32 or data.len > max_blob_bytes or try read(u32, data, 0) != data.len) return error.Size;
    const header = try read(u32, data, 4);
    if (header != spec.header_bytes or header > data.len) return error.Header;
    if (try read(u16, data, 8) != spec.header_major or try read(u16, data, 10) != spec.header_minor or
        try read(u16, data, 12) != spec.ip_major or try read(u16, data, 14) != spec.ip_minor) return error.Revision;
    if (try read(u32, data, 16) != spec.ucode_version) return error.Version;
    const offset = try read(u32, data, 24); const bytes = try read(u32, data, 20);
    if (bytes == 0) return error.Range;
    // RLC2.1 always exposes the complete 156-byte layout. The unchanged
    // Raven2 blob declares the older 104-byte prefix in header_size_bytes.
    const metadata_end = if (spec.kind == .rlc) @max(header, @as(u32, 156)) else header;
    var result: Layout = .{ .payload = try span(data, metadata_end, offset, bytes) };
    switch (spec.kind) {
        .psp_asd => {
            if (header != 44) return error.Header;
            // ASD uses the entire common payload; sos feature_version only.
            result.feature = try read(u32, data, 32);
        },
        .psp_ta => {
            if (header != 92) return error.Header;
            for (0..5) |i| {
                const pos = 32 + i * 12; const count = try read(u32, data, pos + 8);
                const relative = try read(u32, data, pos + 4);
                const version = try read(u32, data, pos);
                if (count == 0) { if (relative != 0 or version != 0) return error.Range; continue; }
                if (relative > bytes or count > bytes - relative or version == 0) return error.Range;
                const range = try span(data, offset, @as(usize, offset) + relative, count);
                for (result.segments[0..i]) |prior| if (overlaps(prior.span, range)) return error.Overlap;
                result.segments[i] = .{ .span = range, .version = version };
            }
        },
        .gfx, .sdma => {
            if (header != (if (spec.kind == .gfx) @as(u32, 44) else 48)) return error.Header;
            result.feature = try read(u32, data, 32);
            const jt: usize = if (spec.kind == .gfx) 36 else 40;
            result.jump_table = try jump(data, result.payload, try read(u32, data, jt), try read(u32, data, jt + 4));
        },
        .rlc => {
            const shared_ranges = spec.family == .raven2;
            if (header != (if (shared_ranges) @as(u32, 104) else 156) or spec.header_major != 2 or spec.header_minor != 1) return error.Header;
            result.feature = try read(u32, data, 32);
            result.jump_table = try jump(data, result.payload, try read(u32, data, 36), try read(u32, data, 40));
            for (0..7) |i| {
                const pos: usize = if (i < 4) 72 + i * 8 else 108 + (i - 4) * 16;
                const count = try read(u32, data, pos + (if (i < 4) @as(usize, 0) else 8));
                const begin = try read(u32, data, pos + (if (i < 4) @as(usize, 4) else 12));
                const range = try span(data, metadata_end, begin, count);
                // amdgpu_rlc.c consumes independent absolute offset/size
                // views. The pinned Raven2 restore views overlap its RLC
                // payload/register lists; no format rule makes them disjoint.
                // Every view stays file-bounded and whole-file SHA256 admission
                // still requires the exact unchanged original bytes.
                if (!shared_ranges) {
                    if (overlaps(range, result.payload)) return error.Overlap;
                    for (result.segments[0..i]) |prior| if (overlaps(prior.span, range)) return error.Overlap;
                }
                result.segments[i] = .{ .span = range, .version = if (i < 4) 0 else try read(u32, data, pos), .feature = if (i < 4) 0 else try read(u32, data, pos + 4) };
            }
            if (result.segments[0].span.bytes == 0 or result.segments[1].span.bytes == 0 or
                try read(u32, data, 104) > result.segments[0].span.bytes / 4) return error.Range;
        },
        .dmcu => {
            if (header != 40) return error.Header;
            const start = try read(u32, data, 32); const count = try read(u32, data, 36);
            if (start == 0 or count == 0 or start > bytes or count != bytes - start) return error.Range;
            result.segments[0].span = try span(data, offset, offset, start);
            result.segments[1].span = try span(data, offset, @as(usize, offset) + start, count);
        },
        .gpu_info => {
            if (header != 36 or try read(u16, data, 32) != 1 or try read(u16, data, 34) != 0 or bytes != 60) return error.Revision;
            // Reference topology, never a measured enabled-CU mask.
            const profile: @import("asic_profile.zig").Profile = switch (spec.family) { .picasso => .picasso, .raven2 => .raven2, .shared => return error.Topology };
            if (try read(u32, data, offset) != 1 or try read(u32, data, offset + 4) != @popCount(profile.cuMask()) or
                try read(u32, data, offset + 8) != 1 or try read(u32, data, offset + 12) != @popCount(profile.rbMask()) or
                try read(u32, data, offset + 44) != 64) return error.Topology;
        },
        .vcn => if (header != 32) return error.Header,
    }
    return result;
}
comptime {
    @setEvalBranchQuota(2000000);
    if (lock.schema != 3 or lock.revision.len != 40 or lock.raven2_rlc_revision.len != 40) @compileError("unsupported AMD firmware lock");
    var total: usize = lock_bytes.len;
    for (.{ Family.picasso, Family.raven2 }) |family| for (std.meta.tags(Role)) |role| {
        var count: usize = 0;
        for (lock.firmware) |entry| if (entry.role == role and (entry.family == family or entry.family == .shared)) { count += 1; };
        if (count != (if (family == .raven2 and role == .rlc_am4) @as(usize, 0) else 1)) @compileError("duplicate or absent AMD firmware family role");
    };
    for (lock.firmware, 0..) |entry, i| {
        if (!std.mem.eql(u8, entry.upstream_revision, if (entry.family == .raven2 and entry.role == .rlc) lock.raven2_rlc_revision else lock.revision)) @compileError("firmware source revision differs from pinned bundle");
        if (entry.bytes < 32 or entry.bytes > max_blob_bytes or entry.sha256.len != 64 or entry.resource.len > 63 or entry.resource.len == 0)
            @compileError("invalid AMD firmware limits");
        for (lock.firmware[0..i]) |old| if (std.ascii.eqlIgnoreCase(old.resource, entry.resource)) @compileError("duplicate firmware resource");
        total += std.mem.alignForward(usize, entry.bytes, 16);
    }
    for (lock.metadata) |entry| {
        if (entry.bytes == 0 or entry.bytes > max_blob_bytes or entry.sha256.len != 64) @compileError("invalid AMD firmware metadata");
        total += std.mem.alignForward(usize, entry.bytes, 16);
    }
    if (total > max_bundle_bytes) @compileError("AMD firmware bundle too large");
    for (.{ Profile{ .family = .picasso, .socket = .fp5, .pci_revision = 0 },
        Profile{ .family = .picasso, .socket = .am4, .pci_revision = 0xc8 },
        Profile{ .family = .raven2, .socket = .fp5, .pci_revision = 0xc4 } }) |profile| {
        var selected_bytes: usize = lock_bytes.len;
        for (lock.metadata) |entry| selected_bytes += std.mem.alignForward(usize, entry.bytes, 16);
        for (lock.firmware) |entry| if (profile.selects(entry)) { selected_bytes += std.mem.alignForward(usize, entry.bytes, 16); };
        if (selected_bytes > max_package_bytes) @compileError("selected AMD firmware package too large");
    }
}
