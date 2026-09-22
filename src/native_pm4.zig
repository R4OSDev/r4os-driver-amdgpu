// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Validate a copied native packet against the canonical execution leases.
//! No output is written before every IB range has passed preflight.
const std = @import("std");
const a = @import("r4os").abi;
const amd = @import("r4amd");
const p = @import("r4amd_pm4");
const Error = @import("start_common.zig").Error;
pub const max_ibs = 32;
pub const max_resources = 32;
pub fn encode(header: amd.R4AmdNativeSubmit, ibs: []const amd.R4AmdNativeIb,
    bindings: []const a.GfxNativeBinding, words: []u32) Error!usize {
    if (header.version != 1 or header.size != @sizeOf(amd.R4AmdNativeSubmit) or header.engine > 1 or
        header.flags != 0 or header.reserved0 != 0 or header.reserved1 != 0 or header.ib_count != ibs.len or ibs.len == 0 or
        ibs.len > max_ibs or bindings.len == 0 or bindings.len > max_resources) return error.Invalid;
    if (words.len < ibs.len * 4) return error.Capacity;
    for (ibs) |ib| {
        if (ib.binding_index >= bindings.len or ib.dwords == 0 or ib.dwords > 0xfffff or ib.dwords & 7 != 0 or ib.address & 31 != 0) return error.Invalid;
        const value = bindings[ib.binding_index];
        const length = @as(u64, ib.dwords) * 4;
        if (value.version != 1 or value.size != @sizeOf(a.GfxNativeBinding) or value.reserved0 != 0 or value.access > 1 or
            value.address < amd.native_va_start or value.address >= amd.native_va_end or value.byte_length > amd.native_va_end - value.address or
            ib.address < value.address or ib.address - value.address >= value.byte_length or length > value.byte_length - (ib.address - value.address)) return error.Invalid;
    }
    for (ibs, 0..) |ib, i| {
        // Mesa ac_emit_cp_indirect_buffer: nested IBs inherit VMID1. VALID
        // belongs to the compute packet; neither CHAIN nor a VMID0 override.
        words[i * 4 ..][0..4].* = .{ p.packet(0x3f, 2), @truncate(ib.address), @truncate(ib.address >> 32),
            ib.dwords | (if (header.engine == 1) @as(u32, 1 << 23) else 0) };
    }
    return ibs.len * 4;
}
