// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const ih = @import("queue_ih.zig");
const storage = @import("queue_storage.zig");
const timeline = @import("queue_timeline.zig");
pub const Error = ih.Error;
pub const Wake = struct { context: usize, signal: *const fn (usize) void };
pub const Owner = struct {
    self_address: usize = 0, ctx: ?r4os.r4dev.DriverContext = null,
    registers: ?*@import("memory_io.zig").Registers = null, arena: ?*storage.Owner = null,
    pci: a.PciDeviceInfo = .{}, wake: ?Wake = null, irq: u8 = 0,
    msi: bool = false, registered: bool = false, routing_uncertain: bool = false,
    controller: ih.Controller = .{}, mailbox: ih.Mailbox = .{},
    // IRQ/short poll admission, never a task-owned mutex: 0 off, 1 ready,
    // 2 capturing resident metadata, 3 close requested during capture.
    gate: u32 = 0, inflight: u32 = 0, fault_code: u32 = 0,
    interrupts: u64 = 0, vectors: u64 = 0,
    pub fn open(self: *Owner, ctx: *const r4os.r4dev.DriverContext, arena: *storage.Owner,
        snapshot: *const @import("identity.zig").Snapshot, epoch: timeline.Epoch, wake: Wake) Error!void
    {
        if (self.self_address != 0) return error.Busy;
        if (!arena.ready or arena.self_address != @intFromPtr(arena) or !arena.memory.?.controller.enabled or
            arena.memory.?.adapter != epoch.adapter) return error.Unconfirmed;
        // The native-init owner enables bus mastering only after admission.
        const command = ctx.pciReadConfig32(snapshot.pci, 4);
        if (command == 0xffffffff or command & 6 != 6) return error.Unconfirmed;
        self.self_address = @intFromPtr(self); self.ctx = ctx.*; self.arena = arena;
        self.registers = &arena.memory.?.registers; self.pci = snapshot.pci; self.wake = wake;
        const route = ctx.pciEnableMsi(self.pci);
        if (route >= 0 and route < 32) { self.irq = @intCast(route); self.msi = true; }
        else if (route == -1 or route == -2 or route == -3) {
            // These errors occur before MSI mutation in the common PCI owner.
            const route_config = ctx.pciReadConfig32(self.pci, 0x3c);
            const pin = (route_config >> 8) & 0xff;
            if (route_config == 0xffffffff or route_config & 0xff >= 24 or pin == 0 or pin > 4 or command & (1 << 10) != 0) return error.Unsupported;
            self.irq = @truncate(route_config);
        } else { self.routing_uncertain = true; return error.Unconfirmed; }
        try self.controller.configure(self.registers.?, .{ .epoch = epoch,
            .ring_gpu = try arena.address(0, storage.ih_bytes), .writeback_gpu = try arena.address(storage.wb_offset, 4),
            .dummy_dma = arena.dummy_pages[0], .bytes = storage.ih_bytes, .msi = self.msi });
        if (ctx.irqRegister(self.irq, interrupt, self.self_address,
            if (self.msi) a.irq_flag_msi else a.irq_flag_shared | a.irq_flag_level_low) != 0) return error.Unsupported;
        self.registered = true;
        self.controller.enable(self.registers.?) catch |err| { self.latch(1); return err; };
        // Publish after every mutable setup field is complete. An interrupt
        // arriving during setup is recovered by the first periodic poll.
        @atomicStore(u32, &self.gate, 1, .release);
    }
    fn latch(self: *Owner, value: u32) void { _ = @cmpxchgStrong(u32, &self.fault_code, 0, value, .release, .monotonic); }
    pub fn failed(self: *const Owner) bool { return @atomicLoad(u32, &self.fault_code, .acquire) != 0; }
    fn enter(self: *Owner) bool {
        if (self.self_address != @intFromPtr(self) or @cmpxchgStrong(u32, &self.gate, 1, 2, .acq_rel, .acquire) != null) return false;
        _ = @atomicRmw(u32, &self.inflight, .Add, 1, .acq_rel); return true;
    }
    fn leave(self: *Owner) void {
        if (@cmpxchgStrong(u32, &self.gate, 2, 1, .release, .monotonic) != null) @atomicStore(u32, &self.gate, 0, .release);
    }
    fn capture(self: *Owner) u32 {
        const count = self.controller.capture(self.registers.?, self.arena.?, &self.mailbox) catch {
            self.latch(2);
            self.controller.mask(self.registers.?) catch {};
            return 0;
        };
        _ = @atomicRmw(u64, &self.vectors, .Add, count, .monotonic); return count;
    }
    fn interrupt(irq: u8, raw: usize) callconv(.c) u32 {
        const self: *Owner = @ptrFromInt(raw);
        if (irq != self.irq or !self.enter()) return 0;
        defer _ = @atomicRmw(u32, &self.inflight, .Sub, 1, .release);
        _ = @atomicRmw(u64, &self.interrupts, .Add, 1, .monotonic);
        const count = self.capture(); const fault = self.failed();
        self.leave();
        // Wake one worker after releasing the hardware admission gate. The
        // inflight counter retains this callback/semaphore through the wake.
        if (count != 0 or fault) self.wake.?.signal(self.wake.?.context);
        return if (count != 0 or fault) a.irq_result_handled else 0;
    }
    pub fn poll(self: *Owner) u32 {
        if (!self.enter()) return 0;
        defer _ = @atomicRmw(u32, &self.inflight, .Sub, 1, .release);
        defer self.leave();
        return self.capture();
    }
    pub fn close(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.routing_uncertain) return false;
        for (0..4) |_| {
            const gate = @atomicLoad(u32, &self.gate, .acquire);
            if (gate == 0) break;
            if (gate == 3) return false;
            if (@cmpxchgStrong(u32, &self.gate, gate, if (gate == 2) 3 else 0, .acq_rel, .acquire) == null) {
                if (gate == 2) return false;
                break;
            }
        }
        if (@atomicLoad(u32, &self.gate, .acquire) != 0 or @atomicLoad(u32, &self.inflight, .acquire) != 0) return false;
        self.controller.close(self.registers.?) catch return false;
        if (self.registered) {
            if (self.ctx.?.irqUnregister(self.irq, interrupt, self.self_address) != 0) return false;
            self.registered = false;
        }
        if (self.msi) {
            if (self.ctx.?.pciDisableMsi(self.pci) != 0) return false;
            self.msi = false;
        }
        self.* = .{}; return true;
    }
};
