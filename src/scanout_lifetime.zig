// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Single DCN pipe, mutated only in the serialized display worker. The memory
//! owner keeps all referenced BOs pinned until acknowledge/stop; this state
//! never fabricates a platform reference or frees an allocation on timeout.
const std = @import("std");
const a = @import("r4os").abi;
pub const c = @import("panel_runtime.zig").c;
pub const Error = error{ Invalid, State, Stale, Busy, Io, Timeout, Lost };
pub const Epoch = struct {
    backend: a.GfxBackendBinding,
    output: a.GfxOutputId,
    memory: u64,
    display: u64,
    mode: u64,
    fn valid(self: Epoch) bool {
        return self.backend.version == 1 and self.backend.size >= @sizeOf(a.GfxBackendBinding) and
            self.backend.adapter_id != 0 and self.backend.device_generation != 0 and self.backend.reset_generation != 0 and
            self.output.adapter_id == self.backend.adapter_id and self.output.device_generation == self.backend.device_generation and
            self.output.connector_id != 0 and self.output.connection_generation != 0 and self.memory != 0 and self.display != 0 and self.mode != 0;
    }
};
pub const Image = struct {
    reference: a.GfxBufferHandle,
    address: u64,
    bytes: u64,
    fn valid(self: Image, minimum: u64) bool {
        return self.reference.id != 0 and self.reference.generation != 0 and self.reference.reserved0 == 0 and
            self.address != 0 and self.address % 256 == 0 and self.address < 1 << 48 and
            self.bytes >= minimum and self.bytes <= (1 << 48) - self.address;
    }
};
pub const Receipt = struct {
    epoch: Epoch, sequence: u64, image: Image, previous: ?Image,
    frame: u64, submitted_ns: u64, observed_ns: u64,
    // No GPU timestamp and no measured VBlank phase: this is an observation
    // of actual OTG/HUBP state, not the estimated instant of the VUPDATE edge.
};
pub const Cursor = struct {
    image: ?Image = null,
    width: u32 = 0, height: u32 = 0,
    x: i32 = 0, y: i32 = 0, hot_x: u32 = 0, hot_y: u32 = 0,
    pub fn native(self: Cursor) Error!c.struct_r4dcn_cursor {
        if (self.image) |image| {
            if (self.width == 0 or self.width > 64 or self.height == 0 or self.height > 64 or
                self.hot_x >= self.width or self.hot_y >= self.height or !image.valid(@as(u64, self.height) * 256)) return error.Invalid;
            return .{ .mc_address = image.address, .buffer_bytes = image.bytes, .width = self.width, .height = self.height,
                .pitch_pixels = 64, .hot_x = self.hot_x, .hot_y = self.hot_y, .enable = 1, .x = self.x, .y = self.y };
        }
        return std.mem.zeroes(c.struct_r4dcn_cursor);
    }
    fn matches(self: Cursor, sample: c.struct_r4dcn_scanout_sample, mode: c.struct_r4dcn_mode) bool {
        const image = self.image orelse return sample.cursor_enabled == 0 and sample.cursor_dpp_enabled == 0;
        const left = @as(i64, self.x) - self.hot_x;
        const top = @as(i64, self.y) - self.hot_y;
        const visible = left < mode.width and top < mode.height and left + self.width > 0 and top + self.height > 0;
        if (sample.cursor_enabled != @intFromBool(visible) or sample.cursor_dpp_enabled != @intFromBool(visible) or
            sample.cursor_address != image.address or sample.cursor_width != self.width or sample.cursor_height != self.height) return false;
        return !visible or (sample.cursor_x == @max(left, 0) and sample.cursor_y == @max(top, 0) and
            sample.cursor_hot_x == @max(-left, 0) and sample.cursor_hot_y == @max(-top, 0));
    }
};
pub const CursorReceipt = struct {
    epoch: Epoch, sequence: u64, update: Cursor, previous: Cursor,
    frame: u64, submitted_ns: u64, observed_ns: u64,
};
const CursorPending = struct {
    sequence: u64, update: Cursor, previous: Cursor, frame: u64, submitted_ns: u64, deadline_ns: u64,
};
pub const Phase = enum { empty, ready, enabling, active, flipping, receipt, cursor, cursor_receipt, retained, stopped };
const Pending = struct {
    sequence: u64, image: Image, previous: ?Image, frame: u64,
    submitted_ns: u64, deadline_ns: u64,
    baseline_valid: bool = true,
};
pub const Owner = struct {
    self_address: usize = 0,
    storage: ?*anyopaque = null,
    epoch: Epoch = undefined,
    mode: c.struct_r4dcn_mode = undefined,
    phase: Phase = .empty,
    current: ?Image = null,
    pending: ?Pending = null,
    receipt: ?Receipt = null,
    cursor_current: Cursor = .{},
    cursor_pending: ?CursorPending = null,
    cursor_receipt: ?CursorReceipt = null,
    sequence: u64 = 0,
    cursor_sequence: u64 = 0,
    resume_cursor: bool = false,
    frame: u64 = 0,
    raw_frame: u32 = 0,
    last_ns: u64 = 0,
    pub fn bind(self: *Owner, storage: *anyopaque, epoch: Epoch, mode: c.struct_r4dcn_mode, first: Image) Error!void {
        if (self.self_address != 0) return error.Busy;
        if (!epoch.valid() or mode.pipe >= 4 or mode.width < 16 or mode.height < 16 or mode.width > 4096 or mode.height > 4096 or
            mode.h_total <= mode.width or mode.v_total <= mode.height or mode.h_total > 8192 or mode.v_total > 8192 or
            mode.pixel_khz < 10000 or mode.pixel_khz > 600000 or mode.pitch_bytes < mode.width * 4 or
            !first.valid(@as(u64, mode.pitch_bytes) * mode.height) or first.address != mode.mc_address or first.bytes != mode.buffer_bytes)
            return error.Invalid;
        var sample: c.struct_r4dcn_scanout_sample = undefined;
        try code(c.r4dcn_scanout_sample(storage, mode.pipe, &sample));
        if (sample.running != 0 or sample.locked != 0 or sample.blank != 1 or sample.frame > 0xffffff or sample.end_ns < sample.begin_ns or
            sample.requested_address != first.address) return error.State;
        self.* = .{ .self_address = @intFromPtr(self), .storage = storage, .epoch = epoch, .mode = mode,
            .current = first, .raw_frame = sample.frame, .last_ns = sample.end_ns, .phase = .ready };
    }
    fn identity(self: *const Owner, epoch: Epoch) Error!void {
        if (self.self_address != @intFromPtr(self) or !std.meta.eql(self.epoch, epoch)) return error.Stale;
    }
    /// A catalog promotion gives the same port a new common connection ID.
    /// Only an idle owner can adopt it; old jobs/receipts keep their old IDs.
    pub fn rekey(self: *Owner, next: Epoch) Error!void {
        if (self.self_address != @intFromPtr(self) or self.phase != .active or self.pending != null or self.cursor_pending != null or
            !next.valid() or !std.meta.eql(next.backend, self.epoch.backend) or next.memory != self.epoch.memory or
            next.display != self.epoch.display or next.mode != self.epoch.mode or next.output.adapter_id != self.epoch.output.adapter_id or
            next.output.device_generation != self.epoch.output.device_generation or next.output.connector_id != self.epoch.output.connector_id or
            next.output.connection_generation <= self.epoch.output.connection_generation) return error.Stale;
        self.epoch = next;
    }
    fn reserve(self: *Owner, sequence: u64, image: Image, deadline: u64) Error!Pending {
        if (self.pending != null or sequence <= self.sequence or sequence == std.math.maxInt(u64)) return error.Busy;
        if (!image.valid(@as(u64, self.mode.pitch_bytes) * self.mode.height) or deadline <= self.last_ns or
            deadline - self.last_ns > 2 * std.time.ns_per_s) return error.Invalid;
        const sample = self.observe() catch |err| {
            if (err != error.Busy) self.phase = .retained;
            return err;
        };
        if (sample.underflow != 0 or (self.phase == .active and (sample.running == 0 or sample.blank != 0))) {
            self.phase = .retained; return error.Lost;
        }
        if (sample.end_ns >= deadline) return error.Timeout;
        return .{ .sequence = sequence, .image = image, .previous = self.current, .frame = self.frame,
            .submitted_ns = sample.end_ns, .deadline_ns = deadline };
    }
    pub fn enable(self: *Owner, epoch: Epoch, sequence: u64, deadline: u64) Error!void {
        try self.identity(epoch);
        if (self.phase != .ready) return error.State;
        const work = try self.reserve(sequence, self.current.?, deadline);
        self.pending = work; self.phase = .enabling;
        self.pending.?.baseline_valid = false;
        // Arm before the first hardware write. Even a partial C call must
        // retain the scanout reference and the transaction's restore context.
        code(c.r4dcn_scanout_enable(self.storage, self.mode.pipe)) catch |err| {
            self.phase = .retained; return err;
        };
        self.sequence = sequence;
    }
    /// Screen wake retains the exact image/epoch and advances only the private
    /// scanout sequence. The outer present owner adopts it after task join.
    pub fn wake(self: *Owner, epoch: Epoch, now: u64, deadline: u64) Error!void {
        try self.identity(epoch);
        if (self.phase != .stopped or self.pending != null or self.cursor_pending != null or
            self.current == null or now < self.last_ns or self.sequence >= std.math.maxInt(u64) - 1) return error.State;
        var sample: c.struct_r4dcn_scanout_sample = undefined;
        try code(c.r4dcn_scanout_sample(self.storage, self.mode.pipe, &sample));
        if (sample.running != 0 or sample.blank != 1 or sample.locked != 0 or
            sample.requested_address != self.current.?.address or sample.end_ns < now) return error.State;
        self.raw_frame = sample.frame; self.last_ns = sample.end_ns; self.phase = .ready;
        self.resume_cursor = self.cursor_current.image != null;
        try self.enable(epoch, self.sequence + 1, deadline);
    }
    /// Restore the already acknowledged cursor without consuming a new
    /// common cursor job sequence. Its BO remains pinned across screen sleep.
    pub fn restoreCursor(self: *Owner, epoch: Epoch, deadline: u64) Error!void {
        try self.identity(epoch);
        if (!self.resume_cursor or self.cursor_current.image == null) return error.State;
        try self.cursorImpl(epoch, self.cursor_sequence, self.cursor_current, deadline, true);
    }
    pub fn flip(self: *Owner, epoch: Epoch, sequence: u64, image: Image, deadline: u64) Error!void {
        try self.identity(epoch);
        if (self.phase != .active) return error.Busy;
        // The same BO may be presented again after an upload. A fresh frame
        // and a later observation are still required, never immediate success.
        const work = try self.reserve(sequence, image, deadline);
        self.pending = work; self.phase = .flipping;
        const result = c.r4dcn_scanout_flip(self.storage, self.mode.pipe, image.address, image.bytes);
        if (result == c.R4DCN_BUSY or result == c.R4DCN_INVALID) {
            // These two C results are guaranteed to precede all flip writes.
            self.pending = null; self.phase = .active; try code(result);
        }
        code(result) catch |err| { self.phase = .retained; return err; };
        self.sequence = sequence;
    }
    fn observe(self: *Owner) Error!c.struct_r4dcn_scanout_sample {
        var sample: c.struct_r4dcn_scanout_sample = undefined;
        try code(c.r4dcn_scanout_sample(self.storage, self.mode.pipe, &sample));
        if (sample.frame > 0xffffff or sample.begin_ns < self.last_ns or sample.end_ns < sample.begin_ns) return error.Stale;
        // Enabling a previously stopped TG starts a new counter domain. The
        // first running sample establishes its baseline; it completes nothing.
        const rebasing = self.phase == .enabling and self.pending != null and !self.pending.?.baseline_valid;
        const delta = if (rebasing) 0 else (sample.frame -% self.raw_frame) & 0xffffff;
        if (delta >= 0x800000 or self.frame > std.math.maxInt(u64) - @as(u64, delta)) return error.Stale;
        const maximum = (@as(u128, sample.end_ns - self.last_ns) * self.mode.pixel_khz) /
            (@as(u64, self.mode.h_total) * self.mode.v_total * 1_000_000) + 2;
        if (delta > maximum) return error.Stale;
        self.frame += delta; self.raw_frame = sample.frame; self.last_ns = sample.end_ns;
        return sample;
    }
    pub fn poll(self: *Owner, epoch: Epoch, now: u64) Error!?Receipt {
        try self.identity(epoch);
        if (self.phase == .receipt) return self.receipt;
        if (self.phase != .enabling and self.phase != .flipping) return error.State;
        const work = self.pending.?;
        if (now < self.last_ns or now >= work.deadline_ns) {
            self.phase = .retained; return if (now < self.last_ns) error.Stale else error.Timeout;
        }
        const sample = self.observe() catch |err| {
            if (err == error.Busy) return null;
            self.phase = .retained; return err;
        };
        if (sample.end_ns >= work.deadline_ns or sample.underflow != 0) {
            self.phase = .retained; return if (sample.underflow != 0) error.Lost else error.Timeout;
        }
        if (sample.running == 0 or sample.blank != 0 or sample.locked != 0 or sample.pending != 0 or
            sample.inuse_address != work.image.address or sample.requested_address != work.image.address) return null;
        if (!work.baseline_valid) { self.pending.?.baseline_valid = true; self.pending.?.frame = self.frame; return null; }
        if (self.frame <= work.frame or sample.begin_ns <= work.submitted_ns) return null;
        self.receipt = .{ .epoch = epoch, .sequence = work.sequence, .image = work.image,
            .previous = work.previous, .frame = self.frame, .submitted_ns = work.submitted_ns, .observed_ns = sample.end_ns };
        self.phase = .receipt;
        return self.receipt;
    }
    /// Transfers the receipt to the outer publication owner. That owner keeps
    /// both BOs and excludes another job until common completion succeeds.
    pub fn acknowledge(self: *Owner, epoch: Epoch, sequence: u64) Error!void {
        try self.identity(epoch);
        if (self.phase != .receipt or self.receipt.?.sequence != sequence) return error.Stale;
        self.current = self.receipt.?.image; self.pending = null; self.receipt = null; self.phase = .active;
    }
    pub fn invalidate(self: *Owner, epoch: Epoch) Error!void {
        try self.identity(epoch);
        if (self.phase != .stopped) self.phase = .retained;
    }
    pub fn cursor(self: *Owner, epoch: Epoch, sequence: u64, update: Cursor, deadline: u64) Error!void {
        return self.cursorImpl(epoch, sequence, update, deadline, false);
    }
    fn cursorImpl(self: *Owner, epoch: Epoch, sequence: u64, update: Cursor, deadline: u64, restoring: bool) Error!void {
        try self.identity(epoch);
        if (self.phase != .active or self.cursor_pending != null or sequence == std.math.maxInt(u64) or
            (if (restoring) !self.resume_cursor or sequence != self.cursor_sequence else sequence <= self.cursor_sequence)) return error.Busy;
        const native = try update.native();
        if (deadline <= self.last_ns or deadline - self.last_ns > 2 * std.time.ns_per_s) return error.Invalid;
        const sample = self.observe() catch |err| { if (err != error.Busy) self.phase = .retained; return err; };
        if (sample.underflow != 0 or sample.running == 0 or sample.blank != 0) { self.phase = .retained; return error.Lost; }
        if (sample.end_ns >= deadline) return error.Timeout;
        self.cursor_pending = .{ .sequence = sequence, .update = update, .previous = self.cursor_current,
            .frame = self.frame, .submitted_ns = sample.end_ns, .deadline_ns = deadline };
        self.phase = .cursor;
        const result = c.r4dcn_scanout_cursor(self.storage, self.mode.pipe, &native);
        if (result == c.R4DCN_BUSY or result == c.R4DCN_INVALID) {
            self.cursor_pending = null; self.phase = .active; try code(result);
        }
        code(result) catch |err| { self.phase = .retained; return err; };
        self.cursor_sequence = sequence;
    }
    pub fn pollCursor(self: *Owner, epoch: Epoch, now: u64) Error!?CursorReceipt {
        try self.identity(epoch);
        if (self.phase == .cursor_receipt) return self.cursor_receipt;
        if (self.phase != .cursor) return error.State;
        const work = self.cursor_pending.?;
        if (now < self.last_ns or now >= work.deadline_ns) { self.phase = .retained; return if (now < self.last_ns) error.Stale else error.Timeout; }
        const sample = self.observe() catch |err| {
            if (err == error.Busy) return null;
            self.phase = .retained; return err;
        };
        if (sample.end_ns >= work.deadline_ns or sample.underflow != 0 or sample.running == 0 or sample.blank != 0) {
            self.phase = .retained; return if (sample.end_ns >= work.deadline_ns) error.Timeout else error.Lost;
        }
        // Cursor registers are shadowed; register equality alone cannot retire
        // its previous image. Require an unlocked, later physical OTG frame.
        if (sample.locked != 0 or self.frame <= work.frame or sample.begin_ns <= work.submitted_ns or
            !work.update.matches(sample, self.mode)) return null;
        self.cursor_receipt = .{ .epoch = epoch, .sequence = work.sequence, .update = work.update, .previous = work.previous,
            .frame = self.frame, .submitted_ns = work.submitted_ns, .observed_ns = sample.end_ns };
        self.phase = .cursor_receipt;
        return self.cursor_receipt;
    }
    pub fn acknowledgeCursor(self: *Owner, epoch: Epoch, sequence: u64) Error!void {
        try self.identity(epoch);
        if (self.phase != .cursor_receipt or self.cursor_receipt.?.sequence != sequence) return error.Stale;
        self.cursor_current = self.cursor_receipt.?.update; self.resume_cursor = false;
        self.cursor_pending = null; self.cursor_receipt = null; self.phase = .active;
    }
    /// A physical stop is required before cancelling a pending flip or losing
    /// a connector. BO references remain in current/pending for outer cleanup.
    pub fn stop(self: *Owner, epoch: Epoch) Error!void {
        try self.identity(epoch);
        if (self.phase == .stopped) return;
        self.phase = .retained;
        try code(c.r4dcn_scanout_stop(self.storage, @as(u32, 1) << @intCast(self.mode.pipe)));
        self.receipt = null; self.cursor_receipt = null; self.phase = .stopped;
    }
};
fn code(result: c_int) Error!void {
    return switch (result) {
        0 => {}, c.R4DCN_BUSY => error.Busy, c.R4DCN_INVALID => error.Invalid,
        c.R4DCN_TIMEOUT => error.Timeout, c.R4DCN_STATE => error.State,
        else => error.Io,
    };
}
