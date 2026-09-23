// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Actual exported Shutdown with a late thread completion at the SDK boundary.
//! Hardware is untouched; this is part of the existing init/unbind test group.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
pub fn check(api: *a.DriverApi, owner: *@import("native_worker.zig").Owner, comptime shutdown: anytype) !void {
    const F = struct {
        var worker: *@import("native_worker.zig").Owner = undefined;
        var waits: u32 = 0;
        var done = false;
        var releases: u32 = 0;
        fn join(handle: u64, ticks: u64, result: *i32) callconv(.c) i32 {
            std.debug.assert(handle == 77 and ticks == 0);
            if (!done) return a.driver_thread_error_timeout;
            result.* = 0;
            return 0;
        }
        fn release(handle: u64) callconv(.c) i32 {
            std.debug.assert(handle == 77 and done);
            releases += 1;
            return 0;
        }
        fn now() callconv(.c) u64 { return (@as(u64, waits) + 1) * std.time.ns_per_ms; }
        fn wait(ticks: u64) callconv(.c) void {
            std.debug.assert(ticks == 1 and worker.stop == 1 and worker.thread == 77 and releases == 0);
            waits += 1;
            if (waits == 2) done = true;
        }
    };
    F.worker = owner; F.waits = 0; F.done = false; F.releases = 0;
    api.wait_ticks = F.wait;
    owner.* = .{
        .self_address = @intFromPtr(owner), .ctx = r4os.r4dev.DriverContext.init(api), .thread = 77,
        .threads = .{ .table = .{ .join = @intFromPtr(&F.join), .release = @intFromPtr(&F.release) } },
        .clock = .{ .table = .{ .now_ns = @intFromPtr(&F.now) } },
    };
    const result = shutdown();
    const waited = F.waits;
    // Restore the fixture after the expected pre-fix failure as well.
    if (result != 0) { F.done = true; _ = shutdown(); }
    try std.testing.expectEqual(@as(i32, 0), result);
    try std.testing.expect(waited == 2 and F.releases == 1 and owner.thread == 0);
    std.debug.print("[amd-shutdown] actual amdgpu_shutdown accepts late thread completion after two waits; boundary model only\n", .{});
}
