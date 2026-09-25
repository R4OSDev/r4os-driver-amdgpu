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
            // The dedicated caller can park on this exact completion. A
            // finished BSP slice wakes it immediately, without a full tick
            // between every submission and observation. The timeout remains
            // one tick so the existing clock/iteration bounds still apply.
            var ignored_result: i32 = 0;
            const waited = ctx.completionWait(self.handle, 1, &ignored_result);
            // -7 is the completion API's cancellation receipt. Only poll's
            // status and successful release may retire that cancelled ticket.
            if (waited != 0 and waited != 1 and waited != -7) return error.Wait;
            if (try self.poll(ctx)) |result| {
                if (result != a.driver_work_owner_busy) return result;
                // The lifecycle owner was busy; this completion ran no code.
            } else if (waited == 1) continue;
            // A busy lifecycle owner or unfinished wake publication still
            // needs bounded pacing; neither permits reuse of a live ticket.
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
        const released = ctx.completionRelease(self.handle);
        // Final status is visible before the kernel finishes publishing its
        // wakeups. Release -2 keeps this exact ticket/context alive; retry in
        // the caller's existing bounded wait instead of resetting the GPU.
        if (released == -2) return null;
        if (released != 0) return error.Completion;
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
        var submits: u32 = 0;
        var waits: u32 = 0;
        var sleeps: u32 = 0;
        var complete_on_wait = false;
        var reject_sleep = false;
        var wait_timeouts: u32 = 0;
        var cancelled = false;
        var busy_release: u32 = 0;
        var held = false;
        var fail_wait = false;
        var fail_release = false;
        var result: i32 = 0;
        var pending: ?a.DriverWorkHandler = null;
        var context: usize = 0;
        var level: u32 = 0;
        var source_closed: u32 = 0;
        fn submit(handler: a.DriverWorkHandler, raw: usize, handle: *u32) callconv(.c) i32 {
            submits += 1;
            handle.* = 3;
            if (busy != 0) { busy -= 1; result = a.driver_work_owner_busy; }
            else if (held) { pending = handler; context = raw; }
            else result = handler(raw);
            return 0;
        }
        fn status(_: u32, out: *a.DriverCompletionStatus) callconv(.c) i32 {
            out.* = .{ .state = if (cancelled) a.driver_work_state_cancelled else if (held) a.driver_work_state_running else a.driver_work_state_completed, .result = result }; return 0;
        }
        fn release(_: u32) callconv(.c) i32 {
            if (fail_release) return -1;
            if (busy_release != 0) { busy_release -= 1; return -2; }
            releases += 1; return 0;
        }
        fn sleep(ticks: u64) callconv(.c) i32 { tryAssert(ticks == 1); sleeps += 1; now += 1000000; return if (fail_wait or reject_sleep) -1 else 0; }
        fn cancel(handle: u32) callconv(.c) i32 { tryAssert(handle == 3); return 0; }
        fn wait(handle: u32, ticks: u64, out: *i32) callconv(.c) i32 {
            tryAssert(handle == 3 and ticks == 1); waits += 1; out.* = 0;
            if (fail_wait) return -5;
            if (cancelled) { out.* = -7; return -7; }
            if (held) {
                if (wait_timeouts != 0) { wait_timeouts -= 1; now += 1000000; return 1; }
                if (complete_on_wait) { now += 1000; finish(); }
                else { now += 1000000; return 1; }
            }
            out.* = result; return 0;
        }
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
    F.api.driver_completion_wait = F.wait;
    F.api.driver_work_cancel = F.cancel;
    const ctx = r4os.r4dev.DriverContext.init(&F.api);
    const threads: r4os.r4dev.DriverThreadContext = .{ .table = .{ .sleep_ticks = @intFromPtr(&F.sleep) } };
    const clock: r4os.r4dev.DriverResourceContext = .{ .table = .{ .now_ns = @intFromPtr(&F.clock) } };
    var call: Call = .{};
    F.busy = 2;
    try t.expectEqual(@as(i32, 7), try call.invoke(&ctx, threads, clock, F.callback, 73));
    try t.expect(F.hits == 1 and F.releases == 3 and call.handle == 0);
    // Kernel final status precedes wake publication. The same ticket must
    // survive transient release -2 without a second callback submission.
    const hits_before = F.hits; const submits_before = F.submits; const releases_before = F.releases;
    F.busy_release = 2;
    try t.expectEqual(@as(i32, 7), try call.invoke(&ctx, threads, clock, F.callback, 73));
    try t.expect(F.hits == hits_before + 1 and F.submits == submits_before + 1 and
        F.releases == releases_before + 1 and F.busy_release == 0 and call.handle == 0);
    F.held = true; F.fail_wait = true;
    try t.expectError(error.Wait, call.invoke(&ctx, threads, clock, F.callback, 73));
    try t.expect(!call.retired(&ctx) and call.handle == 3 and F.hits == hits_before + 1);
    try t.expectError(error.Busy, call.invoke(&ctx, threads, clock, F.callback, 73));
    F.finish(); F.fail_release = true;
    try t.expect(!call.retired(&ctx) and call.handle == 3);
    F.fail_release = false;
    try t.expect(call.retired(&ctx) and F.hits == hits_before + 2);
    // A callback completing between ticks must wake its dedicated caller.
    // Two genuine timeouts are bounded waits, never an extra pacing sleep.
    const async_hits = F.hits; const async_submits = F.submits;
    const async_sleeps = F.sleeps; const async_waits = F.waits;
    F.fail_wait = false; F.held = true; F.complete_on_wait = true; F.wait_timeouts = 2; F.reject_sleep = true;
    try t.expectEqual(@as(i32, 7), try call.invoke(&ctx, threads, clock, F.callback, 73));
    try t.expect(F.hits == async_hits + 1 and F.submits == async_submits + 1 and
        F.sleeps == async_sleeps and F.waits == async_waits + 3 and call.handle == 0);
    F.complete_on_wait = false; F.reject_sleep = false;
    // Cancellation still retires the exact completion without running code.
    const cancel_hits = F.hits; const cancel_releases = F.releases;
    F.cancelled = true; F.held = true;
    try t.expectError(error.Cancelled, call.invoke(&ctx, threads, clock, F.callback, 73));
    try t.expect(call.handle == 0 and F.hits == cancel_hits and F.releases == cancel_releases + 1);
    F.cancelled = false; F.held = false; F.pending = null; F.fail_wait = true;
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
