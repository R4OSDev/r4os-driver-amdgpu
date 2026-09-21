// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Bounded save/restore of registers actually changed by GMC initialization.
//! Command/ACK registers are excluded; VM enables are restored last, after
//! original page table roots/apertures and cache invalidation acknowledgments.
const r = @import("memory_registers.zig");
const Error = @import("memory_hubs.zig").Error;
const Record = struct { address: u32 = 0, value: u32 = 0 };
pub const Journal = struct {
    records: [256]Record = @splat(.{}), count: usize = 0, restored: bool = false,
    fn transient(address: u32) bool {
        return address == r.nb.HDP_MEM_COHERENCY_FLUSH_CNTL or address == r.gfx.VM_INVALIDATE_ENG17_REQ or
            address == r.mm.VM_INVALIDATE_ENG17_REQ or address == r.gfx.VM_L2_CNTL2 or address == r.mm.VM_L2_CNTL2;
    }
    fn control(address: u32) bool {
        inline for (.{ r.gfx, r.mm }) |R| {
            const stride = R.VM_CONTEXT1_CNTL - R.VM_CONTEXT0_CNTL;
            if (address >= R.VM_CONTEXT0_CNTL and address < R.VM_CONTEXT0_CNTL + stride * 16 and (address - R.VM_CONTEXT0_CNTL) % stride == 0) return true;
        }
        return false;
    }
    pub fn capture(self: *Journal, io: anytype, address: u32) Error!void {
        if (transient(address)) return;
        for (self.records[0..self.count]) |record| if (record.address == address) return;
        if (self.count == self.records.len or self.restored) return error.Capacity;
        self.records[self.count] = .{ .address = address, .value = try io.read(address) }; self.count += 1;
    }
    pub fn restore(self: *Journal, io: anytype) Error!void {
        if (self.restored) return;
        for (self.records[0..self.count]) |record| if (!control(record.address)) try io.write(record.address, record.value);
        try @import("memory_hubs.zig").flush(io, 0); try @import("memory_hubs.zig").flush(io, 1);
        for (self.records[0..self.count]) |record| if (control(record.address)) try io.write(record.address, record.value);
        try io.barrier();
        for (self.records[0..self.count]) |record| if (try io.read(record.address) != record.value) return error.Unconfirmed;
        self.restored = true;
    }
};
pub fn Io(comptime T: type) type {
    return struct {
        target: T, journal: *Journal,
        pub fn read(self: *@This(), address: u32) Error!u32 { return self.target.read(address); }
        pub fn write(self: *@This(), address: u32, value: u32) Error!void {
            try self.journal.capture(self.target, address); try self.target.write(address, value);
        }
        pub fn barrier(self: *@This()) Error!void { return self.target.barrier(); }
        pub fn nowNs(self: *@This()) u64 { return self.target.nowNs(); }
    };
}
