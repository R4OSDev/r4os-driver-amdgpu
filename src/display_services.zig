// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Copied DCN metadata crosses to the bounded BSP owner lane. No callback
//! references a DCN stack; a timed-out request retains this entire owner.
const r4os = @import("r4os");
const a = r4os.abi;
pub const Owner = struct {
    ctx: r4os.r4dev.DriverContext,
    threads: r4os.r4dev.DriverThreadContext,
    clock: r4os.r4dev.DriverResourceContext,
    outputs: r4os.driver_outputs.Context,
    call: @import("owned_work.zig").Call = .{},
    operation: enum { brightness_publish, brightness_read, source_register, receiver_advance, audio_publish, pause, withdraw } = .brightness_read,
    identity: a.GfxOutputId = .{},
    brightness: a.GfxOutputBrightness = .{},
    request: a.GfxBrightnessRequest = .{},
    source: a.GfxReceiverSource = .{},
    source_delivered: bool = true,
    sequence: u64 = 0,
    audio: a.GfxAudioRoute = .{},
    paused: bool = false,
    pub fn supportsBrightness(self: *const Owner) bool { return self.outputs.supportsBrightness(); }
    pub fn publishBrightness(self: *Owner, value: *const a.GfxOutputBrightness) i32 {
        if (self.call.handle != 0) return a.gfx_output_error_busy;
        self.brightness = value.*;
        return self.invoke(.brightness_publish);
    }
    pub fn readBrightness(self: *Owner, identity: *const a.GfxOutputId, out: *a.GfxBrightnessRequest) i32 {
        if (self.call.handle != 0) return a.gfx_output_error_busy;
        self.identity = identity.*; self.request = .{};
        const result = self.invoke(.brightness_read);
        if (result == a.gfx_output_ok) out.* = self.request;
        return result;
    }
    pub fn registerSource(self: *Owner, adapter: u32, out: *a.GfxReceiverSource) i32 {
        if (self.call.handle != 0) return a.gfx_output_error_busy;
        self.identity = .{ .adapter_id = adapter }; self.source = .{}; self.source_delivered = false;
        const result = self.invoke(.source_register);
        if (result == a.gfx_output_ok) { out.* = self.source; self.source_delivered = true; }
        return result;
    }
    pub fn advanceReceiver(self: *Owner, source: a.GfxReceiverSource, sequence: u64) i32 {
        if (self.call.handle != 0) return a.gfx_output_error_busy;
        self.source = source; self.sequence = sequence;
        return self.invoke(.receiver_advance);
    }
    pub fn publishAudio(self: *Owner, value: *const a.GfxAudioRoute) i32 {
        if (self.call.handle != 0) return a.gfx_output_error_busy;
        self.audio = value.*;
        return self.invoke(.audio_publish);
    }
    pub fn pauseOutput(self: *Owner, identity: *const a.GfxOutputId, paused: bool) i32 {
        if (self.call.handle != 0) return a.gfx_output_error_busy;
        self.identity = identity.*; self.paused = paused;
        return self.invoke(.pause);
    }
    pub fn withdraw(self: *Owner, identity: *const a.GfxOutputId) i32 {
        if (self.call.handle != 0) return a.gfx_output_error_busy;
        self.identity = identity.*;
        return self.invoke(.withdraw);
    }
    /// Parent calls only after DCN join, on the BSP owner lane. A source
    /// created after the DCN wait failed was never delivered to audio.Owner.
    pub fn retired(self: *Owner) bool {
        if (!self.call.retired(&self.ctx)) return false;
        if (!self.source_delivered and self.source.generation != 0) {
            const result = self.outputs.closeSource(&self.source);
            if (result != a.gfx_output_ok and result != a.gfx_output_error_stale) return false;
            self.source = .{}; self.source_delivered = true;
        }
        return true;
    }
    fn invoke(self: *Owner, operation: @FieldType(Owner, "operation")) i32 {
        self.operation = operation;
        return self.call.invoke(&self.ctx, self.threads, self.clock, execute, @intFromPtr(self)) catch a.gfx_output_error_unavailable;
    }
    fn execute(raw: usize) callconv(.c) i32 {
        const self: *Owner = @ptrFromInt(raw);
        return switch (self.operation) {
            .brightness_publish => self.outputs.publishBrightness(&self.brightness),
            .brightness_read => self.outputs.readBrightness(&self.identity, &self.request),
            .source_register => self.outputs.registerSource(self.identity.adapter_id, &self.source),
            .receiver_advance => self.outputs.replaceReceivers(&.{ .source = self.source, .sequence = self.sequence }),
            .audio_publish => self.outputs.publishAudio(&self.audio),
            .pause => self.outputs.pauseOutput(&self.identity, self.paused),
            .withdraw => self.outputs.withdraw(&self.identity),
        };
    }
};
