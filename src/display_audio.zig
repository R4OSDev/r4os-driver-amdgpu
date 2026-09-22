// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! One direct HDMI audio endpoint. Copied route metadata and original DCN
//! programming share the serialized display task, never the HDA PCM owner.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const edid = @import("r4gfx_edid");
const c = @import("panel.zig").c;
pub const Peer = struct { location: u32, device: u32 = 0x15de1002 };
/// Read-only companion capture is restricted to the actual driver Init.
pub fn capture(ctx: *const r4os.r4dev.DriverContext, gpu: a.PciDeviceInfo) ?Peer {
    const count = ctx.pciDeviceCount();
    if (count > 4096) return null;
    var found: ?Peer = null;
    for (0..count) |i| {
        var p: a.PciDeviceInfo = .{};
        if (ctx.pciDeviceAt(@intCast(i), &p) != 0) return null;
        if (p.vendor_id != 0x1002 or p.device_id != 0x15de or p.class_code != 4 or p.subclass != 3 or
            p.prog_if != 0 or p.bus != gpu.bus or p.device != gpu.device or p.function != 1 or gpu.function != 0 or (p.bus_kind != 1 and p.bus_kind != 2) or p.bus_kind != gpu.bus_kind) continue;
        if (found != null or ctx.pciReadConfig32(p, 0) != 0x15de1002 or ctx.pciReadConfig32(p, 8) >> 8 != 0x040300) return null;
        found = .{ .location = (@as(u32, p.bus_kind) << 24) | (@as(u32, p.bus) << 8) | (@as(u32, p.device) << 3) | p.function };
    }
    return found;
}
pub fn encoding(report: *const edid.Report, port: [8]u8) !edid.eld.Data {
    const full = try edid.eld.encode(report, port);
    if (!full.stereo_48k_s16) return error.Unsupported;
    const name: usize = full.bytes[4] & 31;
    if (name > 16) return error.Unsupported;
    var value = full;
    @memset(value.bytes[20 + name ..], 0);
    value.bytes[2] = @intCast((16 + name + 3 + 3) / 4);
    value.bytes[5] = (value.bytes[5] & 15) | 16;
    value.bytes[7] = 1; // The source only carries the sink's admitted FL/FR pair.
    value.bytes[20 + name ..][0..3].* = .{ 9, 4, 1 };
    value.max_frequency = 3;
    return value;
}
pub const Owner = struct {
    peer: ?Peer = null,
    outputs: ?r4os.driver_outputs.Context = null,
    source: a.GfxReceiverSource = .{},
    sequence: u64 = 0,
    revision: u64 = 0,
    connector: u32 = 0,
    head: u32 = 0,
    port: [8]u8 = @splat(0),
    eld: ?edid.eld.Data = null,
    bound: bool = false,
    endpoint: u32 = 0,
    configured: bool = false,
    enabled: bool = false,
    closing: bool = false,
    last_error: ?anyerror = null,
    state: u32 = a.gfx_audio_route_pending,
    pub fn attach(self: *Owner, outputs: r4os.driver_outputs.Context, output: a.GfxOutputId, sequence: u64) !void {
        if (self.peer == null or !outputs.supportsAudio() or !outputs.supportsReceivers() or self.closing) return;
        if (sequence == 0 or sequence <= self.sequence) return error.Stale;
        self.outputs = outputs;
        if (self.source.generation == 0) {
            if (outputs.registerSource(output.adapter_id, &self.source) != a.gfx_output_ok) return error.Publication;
            self.connector = output.connector_id;
            std.mem.writeInt(u32, self.port[0..4], output.adapter_id, .little);
            std.mem.writeInt(u32, self.port[4..8], output.connector_id, .little);
        }
        if (output.adapter_id != self.source.adapter_id or output.connector_id != self.connector) return error.Stale;
        // Native output publication already owns video geometry. This empty
        // receiver batch advances only the copied audio receiver generation.
        if (outputs.replaceReceivers(&.{ .source = self.source, .sequence = sequence }) != a.gfx_output_ok) return error.Publication;
        self.sequence = sequence;
        try self.publish(a.gfx_audio_route_pending);
    }
    fn publish(self: *Owner, state: u32) !void {
        if (self.source.generation == 0 or self.closing) return;
        if (self.revision == std.math.maxInt(u64)) return error.Exhausted;
        var value: a.GfxAudioRoute = .{ .source = self.source, .receiver_sequence = self.sequence, .revision = self.revision + 1, .connector_id = self.connector, .head_id = self.head, .hda_location = self.peer.?.location, .hda_device = self.peer.?.device, .state = state, .port_id = self.port };
        if (state == a.gfx_audio_route_ready) {
            const eld = self.eld orelse return error.State;
            value.eld_bytes = @intCast(eld.baselineBytes());
            @memcpy(value.eld[0..value.eld_bytes], eld.bytes[0..value.eld_bytes]);
        }
        if (self.outputs.?.publishAudio(&value) != a.gfx_output_ok) return error.Publication;
        self.revision = value.revision;
        self.state = state;
    }
    pub fn quiesce(self: *Owner, storage: *anyopaque, disconnected: bool) !void {
        // Withdraw availability before touching transport; HDA tears down its
        // old stream when the copied publication revision changes.
        try self.publish(if (disconnected) a.gfx_audio_route_absent else a.gfx_audio_route_pending);
        if (self.bound and c.r4dcn_audio_stop(storage, 1) != 0) return error.Unconfirmed;
        self.configured = false;
        self.enabled = false;
        self.eld = null;
    }
    pub fn configure(self: *Owner, storage: *anyopaque, report: *const edid.Report, head: u32) !void {
        if (self.source.generation == 0 or self.closing) return;
        self.head = head;
        self.last_error = null;
        self.eld = encoding(report, self.port) catch |err| {
            self.last_error = err;
            try self.publish(a.gfx_audio_route_unsupported);
            return;
        };
        if (!self.bound) {
            const result = c.r4dcn_audio_bind(storage, 1, &self.endpoint);
            if (result == c.R4DCN_UNSUPPORTED) {
                self.last_error = error.Unsupported;
                try self.publish(a.gfx_audio_route_unsupported);
                return;
            }
            if (result != 0) return error.Unconfirmed;
            self.bound = true;
        }
        const result = c.r4dcn_audio_configure(storage, 1, &self.eld.?.bytes, @intCast(self.eld.?.baselineBytes()));
        if (result == c.R4DCN_UNSUPPORTED) {
            self.last_error = error.Unsupported;
            try self.quiesce(storage, false);
            try self.publish(a.gfx_audio_route_unsupported);
            return;
        }
        if (result != 0) return error.Unconfirmed;
        self.configured = true;
    }
    /// Called after the confirmed video-address/frame receipt, never a timer.
    pub fn activate(self: *Owner, storage: *anyopaque) !void {
        if (!self.configured or self.closing) return;
        if (c.r4dcn_audio_enable(storage, 1) != 0) return error.Unconfirmed;
        self.enabled = true;
        try self.publish(a.gfx_audio_route_ready);
    }
    /// Requires the DCN task to be joined. Metadata removal is independent of
    /// physical quiescence and still happens when the GPU must be retained.
    pub fn closeMetadata(self: *Owner) bool {
        self.closing = true;
        if (self.source.generation != 0) {
            const result = self.outputs.?.closeSource(&self.source);
            if (result != a.gfx_output_ok and result != a.gfx_output_error_stale) return false;
            self.source = .{};
        }
        return true;
    }
};
