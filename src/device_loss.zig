// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Logical device loss is separate from physical retirement. This call never
//! advances a generation, frees backing, or asserts that an APU has stopped.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
pub fn announce(queue: r4os.driver_queue.Context, binding: a.GfxBackendBinding) bool {
    var unused: a.GfxBackendBinding = .{};
    const rc = queue.reset(&binding, 0, &unused);
    // reset(false) closes admission and wakes every queue of this device,
    // returning Busy until physical retirement. Stale is already inaccessible.
    return rc == a.gfx_queue_error_busy or rc == a.gfx_queue_error_stale;
}
pub fn restartBoot(previous: a.GfxNativeBootInfo, current: a.GfxNativeBootInfo) bool {
    if (current.policy != 0 or current.state != a.display_state_bootfb or
        current.generation <= previous.generation or current.generation == std.math.maxInt(u64)) return false;
    @import("boot.zig").validate(current) catch return false;
    var comparable = current;
    comparable.generation = previous.generation;
    comparable.state = previous.state;
    return std.meta.eql(previous, comparable);
}
