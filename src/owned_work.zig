// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! One resident BSP callback ticket. The dedicated caller owns pacing; a
//! timeout never releases a still queued/running callback's context.
const r4os = @import("r4os");
const a = r4os.abi;
pub const Error = error{ Unsupported, Busy, Admission, Completion, Cancelled, Deadline, Wait, Clock };
pub fn supported(ctx: *const r4os.r4dev.DriverContext) bool {
    return ctx.apiVersion() >= a.driver_api_owned_work_version and ctx.api.size >= @offsetOf(a.DriverApi, "driver_work_submit_owned") + 8 and
        ctx.api.driver_work_submit_owned != null;
}
pub const Call = struct {
    handle: u32 = 0,
    /// Context is resident owner storage, never a callback argument on the
    /// caller stack. A retained ticket blocks owner retirement after failure.
    pub fn invoke(self: *Call, ctx: *const r4os.r4dev.DriverContext, threads: r4os.r4dev.DriverThreadContext,
        clock: r4os.r4dev.DriverResourceContext, handler: a.DriverWorkHandler, context: usize) Error!i32
    {
        if (!supported(ctx)) return error.Unsupported;
        if (self.handle != 0) return error.Busy;
        const begin = clock.nowNs();
        if (begin == ~@as(u64, 0)) return error.Clock;
        var last = begin;
        // Time and iteration bounds cover both a stuck completion and clock.
        for (0..4096) |_| {
            const now = clock.nowNs();
            if (now < last or now == ~@as(u64, 0)) return error.Clock;
            last = now;
            if (now - begin >= 5_000_000_000) break;
            if (self.handle == 0 and (ctx.workSubmitOwned(handler, context, &self.handle) != 0 or self.handle == 0)) return error.Admission;
            if (try self.poll(ctx)) |result| {
                if (result != a.driver_work_owner_busy) return result;
                // The lifecycle owner was busy; this completion ran no code.
            }
            if (threads.sleepTicks(1) != 0) return error.Wait;
        }
        if (self.handle != 0) _ = ctx.workCancel(self.handle);
        return error.Deadline;
    }
    pub fn poll(self: *Call, ctx: *const r4os.r4dev.DriverContext) Error!?i32 {
        if (self.handle == 0) return null;
        var status: a.DriverCompletionStatus = .{};
        if (ctx.completionStatus(self.handle, &status) != 0) return error.Completion;
        if (status.state == a.driver_work_state_queued or status.state == a.driver_work_state_running) return null;
        if (status.state != a.driver_work_state_completed and status.state != a.driver_work_state_cancelled) return error.Completion;
        if (ctx.completionRelease(self.handle) != 0) return error.Completion;
        self.handle = 0;
        if (status.state == a.driver_work_state_cancelled) return error.Cancelled;
        return status.result;
    }
    pub fn retired(self: *Call, ctx: *const r4os.r4dev.DriverContext) bool {
        if (self.handle == 0) return true;
        _ = self.poll(ctx) catch {};
        return self.handle == 0;
    }
};

/// Existing native lifecycle test: BUSY never executes the callback, and a
/// failed wait never permits reuse or frees a still-live callback context.
pub fn check() !void {
    const t = @import("std").testing;
    const F = struct {
        var api: a.DriverApi = undefined;
        var now: u64 = 1;
        var busy: u32 = 0;
        var hits: u32 = 0;
        var releases: u32 = 0;
        var held = false;
        var fail_wait = false;
        var fail_release = false;
        var result: i32 = 0;
        var pending: ?a.DriverWorkHandler = null;
        var context: usize = 0;
        var level: u32 = 0;
        var source_closed: u32 = 0;
        fn submit(handler: a.DriverWorkHandler, raw: usize, handle: *u32) callconv(.c) i32 {
            handle.* = 3;
            if (busy != 0) { busy -= 1; result = a.driver_work_owner_busy; }
            else if (held) { pending = handler; context = raw; }
            else result = handler(raw);
            return 0;
        }
        fn status(_: u32, out: *a.DriverCompletionStatus) callconv(.c) i32 {
            out.* = .{ .state = if (held) a.driver_work_state_running else a.driver_work_state_completed, .result = result }; return 0;
        }
        fn release(_: u32) callconv(.c) i32 { if (fail_release) return -1; releases += 1; return 0; }
        fn sleep(ticks: u64) callconv(.c) i32 { tryAssert(ticks == 1); now += 1000000; return if (fail_wait) -1 else 0; }
        fn clock() callconv(.c) u64 { return now; }
        fn callback(raw: usize) callconv(.c) i32 { tryAssert(raw == 73); hits += 1; return 7; }
        fn brightness(value: *const a.GfxOutputBrightness) callconv(.c) i32 { level = value.current; return a.gfx_output_ok; }
        fn register(adapter: u32, out: *a.GfxReceiverSource) callconv(.c) i32 { out.* = .{ .adapter_id = adapter, .generation = 2 }; return a.gfx_output_ok; }
        fn replace(_: *const a.GfxReceiverUpdate) callconv(.c) i32 { return a.gfx_output_ok; }
        fn close(_: *const a.GfxReceiverSource) callconv(.c) i32 { source_closed += 1; return a.gfx_output_ok; }
        fn read(_: *const a.GfxOutputId, _: *a.GfxBrightnessRequest) callconv(.c) i32 { return a.gfx_output_ok; }
        fn tryAssert(ok: bool) void { @import("std").debug.assert(ok); }
        fn finish() void { held = false; result = pending.?(context); pending = null; }
    };
    F.api = undefined; F.api.magic = a.driver_magic; F.api.reserved = 0; F.api.version = a.driver_api_version; F.api.size = @sizeOf(a.DriverApi);
    F.api.driver_work_submit_owned = F.submit; F.api.driver_completion_status = F.status; F.api.driver_completion_release = F.release;
    const ctx = r4os.r4dev.DriverContext.init(&F.api);
    const threads: r4os.r4dev.DriverThreadContext = .{ .table = .{ .sleep_ticks = @intFromPtr(&F.sleep) } };
    const clock: r4os.r4dev.DriverResourceContext = .{ .table = .{ .now_ns = @intFromPtr(&F.clock) } };
    var call: Call = .{};
    F.busy = 2;
    try t.expectEqual(@as(i32, 7), try call.invoke(&ctx, threads, clock, F.callback, 73));
    try t.expect(F.hits == 1 and F.releases == 3 and call.handle == 0);
    F.held = true; F.fail_wait = true;
    try t.expectError(error.Wait, call.invoke(&ctx, threads, clock, F.callback, 73));
    try t.expect(!call.retired(&ctx) and call.handle == 3 and F.hits == 1);
    try t.expectError(error.Busy, call.invoke(&ctx, threads, clock, F.callback, 73));
    F.finish(); F.fail_release = true;
    try t.expect(!call.retired(&ctx) and call.handle == 3);
    F.fail_release = false;
    try t.expect(call.retired(&ctx) and F.hits == 2);
    var services: @import("display_services.zig").Owner = .{ .ctx = ctx, .threads = threads, .clock = clock, .outputs = .{ .table = .{
        .brightness_publish = @intFromPtr(&F.brightness), .brightness_read = @intFromPtr(&F.read),
        .register_source = @intFromPtr(&F.register), .replace_receivers = @intFromPtr(&F.replace), .close_source = @intFromPtr(&F.close),
    } } };
    F.held = true;
    var value: a.GfxOutputBrightness = .{ .current = 123 };
    try t.expect(services.publishBrightness(&value) != a.gfx_output_ok);
    value.current = 456;
    try t.expect(services.publishBrightness(&value) == a.gfx_output_error_busy and !services.retired());
    F.finish(); try t.expect(services.retired() and F.level == 123);
    F.held = true;
    var source: a.GfxReceiverSource = .{};
    try t.expect(services.registerSource(7, &source) != a.gfx_output_ok and source.generation == 0);
    F.finish(); try t.expect(services.retired() and F.source_closed == 1 and source.generation == 0);
    try t.expect(services.retired() and F.source_closed == 1);
}
