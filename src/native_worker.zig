// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Preemptible start/recovery pump. GPU queues have their own serialized
//! worker; this owner joins it before cleanup touches that worker's resources.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
pub const Hooks = struct {
    advance: *const fn () anyerror!bool,
    recover: *const fn () bool,
    restart: ?*const fn () anyerror!void = null,
    fault: ?*const fn () bool = null, // atomic notification only, no owner APIs
};

/// Part of the existing init/unbind host test; every clock/Task event here is
/// modeled. The real Owner runs through its SDK start/join/release callbacks.
pub fn check() !void {
    try @import("owned_work.zig").check();
    const t = std.testing;
    const F = struct {
        var owner: Owner = .{};
        var output: @import("display_output.zig").Owner = .{};
        var api: a.DriverApi = undefined;
        var request: a.DriverThreadRequest = .{};
        var time: u64 = 1000;
        var advances: u32 = 0;
        var recovers: u32 = 0;
        var sleeps: u32 = 0;
        var ran = false;
        var fail_release = false;
        var hold_recovery = false;
        var fail_start = false;
        var fail_advance = false;
        var result: i32 = 0;
        var runtime_fault = false; var fail_restart = false; var stop_in_recover = false; var restart_calls: u32 = 0;
        var work_result: i32 = 0;
        var in_work = false;
        fn submit(handler: a.DriverWorkHandler, raw: usize, handle: *u32) callconv(.c) i32 {
            t.expect(!in_work) catch unreachable;
            in_work = true; work_result = handler(raw); in_work = false;
            handle.* = 19; return 0;
        }
        fn status(handle: u32, out: *a.DriverCompletionStatus) callconv(.c) i32 {
            std.debug.assert(handle == 19);
            out.* = .{ .state = a.driver_work_state_completed, .result = work_result }; return 0;
        }
        fn releaseWork(handle: u32) callconv(.c) i32 { std.debug.assert(handle == 19); return 0; }
        fn waitWork(handle: u32, ticks: u64, out: *i32) callconv(.c) i32 {
            std.debug.assert(!in_work and handle == 19 and ticks == 1); out.* = work_result; return 0;
        }
        fn log(_: [*:0]const u8) callconv(.c) void {}
        fn query(out: *a.DriverThreadApi) callconv(.c) i32 {
            out.* = .{ .start = @intFromPtr(&start), .join = @intFromPtr(&join), .release = @intFromPtr(&release),
                .sleep_ticks = @intFromPtr(&sleep), .current_request = @intFromPtr(&current), .abort_current = @intFromPtr(&abort) }; return 0;
        }
        fn resources(out: *a.DriverResourceApi) callconv(.c) i32 { out.* = .{ .now_ns = @intFromPtr(&now) }; return 0; }
        fn now() callconv(.c) u64 { return time; }
        fn frequency() callconv(.c) u32 { return 1000; }
        fn start(req: *const a.DriverThreadRequest, id: *u64) callconv(.c) i32 {
            std.debug.assert(req.flags == a.driver_thread_flag_parallel);
            request = req.*; id.* = 77; return if (fail_start) -1 else 0;
        }
        fn current(out: *a.DriverThreadRequest) callconv(.c) i32 { out.* = request; return 0; }
        fn abort(_: i32) callconv(.c) i32 { unreachable; }
        fn join(id: u64, ticks: u64, out: *i32) callconv(.c) i32 {
            std.debug.assert(id == 77 and ticks == 0); if (!ran) return -1;
            out.* = result; return 0;
        }
        fn release(id: u64) callconv(.c) i32 { std.debug.assert(id == 77 and ran); return if (fail_release) -1 else 0; }
        fn sleep(ticks: u64) callconv(.c) i32 {
            std.debug.assert(ticks == 10); time += ticks * std.time.ns_per_ms; sleeps += 1;
            if (sleeps == 4 or (restart_calls != 0 and sleeps == 8)) {
                @atomicStore(u32, &output.recovery_fault, if (runtime_fault) 2 else 0, .release);
                @atomicStore(u32, &output.restore_requested, 1, .release);
            }
            return 0;
        }
        fn advance() !bool { std.debug.assert(in_work); advances += 1; if (fail_advance) return error.Firmware; return advances % 2 == 0; }
        fn recover() bool {
            std.debug.assert(in_work);
            recovers += 1;
            if (hold_recovery or recovers < 3) return false;
            output = .{};
            if (stop_in_recover) owner.requestStop();
            return true;
        }
        fn restart() !void {
            std.debug.assert(in_work);
            std.debug.assert(recovers >= 3 and output.restore_requested == 0);
            restart_calls += 1; if (fail_restart) return error.Capture;
        }
        fn fault() bool { return advances >= 2; }
        fn reset() void {
            runtime_fault = false; fail_restart = false; stop_in_recover = false; restart_calls = 0;
            owner = .{}; output = .{}; time = 1000; advances = 0; recovers = 0; sleeps = 0; ran = false;
            fail_release = false; hold_recovery = false; fail_start = false; fail_advance = false;
            api = undefined; api.magic = a.driver_magic; api.version = a.driver_api_version; api.size = @sizeOf(a.DriverApi);
            api.thread_query = query; api.resource_query = resources; api.timer_frequency = frequency; api.log_error = log;
            api.driver_work_submit_owned = submit; api.driver_completion_status = status; api.driver_completion_release = releaseWork;
            api.driver_completion_wait = waitWork;
            in_work = false; work_result = 0;
        }
        fn run() void {
            const callback: *const fn (usize) callconv(.c) i32 = @ptrFromInt(request.handler);
            result = callback(request.context); ran = true;
        }
    };
    F.reset(); const ctx = r4os.r4dev.DriverContext.init(&F.api);
    try t.expect(supported(&ctx));
    try F.owner.start(&ctx, &F.output, .{ .advance = F.advance, .recover = F.recover });
    try t.expect(!F.owner.join()); F.run();
    try t.expect(F.owner.ready and F.advances == 2 and F.recovers == 3 and F.owner.recovered == 1);
    F.fail_release = true; try t.expect(!F.owner.join() and F.owner.thread == 77 and F.owner.joined);
    F.fail_release = false; try t.expect(F.owner.join() and F.owner.thread == 0);
    F.reset(); F.fail_advance = true; F.hold_recovery = true;
    try F.owner.start(&ctx, &F.output, .{ .advance = F.advance, .recover = F.recover }); F.run();
    try t.expect(F.owner.failure.? == error.Firmware and F.owner.recovered == 0 and F.result == -1 and F.time >= 30 * std.time.ns_per_s);
    try t.expect(F.owner.join());
    F.reset(); F.fail_start = true;
    try t.expectError(error.Capacity, F.owner.start(&ctx, &F.output, .{ .advance = F.advance, .recover = F.recover }));
    try t.expect(F.owner.thread == 77 and !F.owner.join());
    F.owner.requestStop(); F.run(); try t.expect(F.advances == 0 and F.owner.recovered == 1 and F.owner.join());
    // Use real worker control flow with injected boundary callbacks. A
    // second runtime loss, manual restore, failed capture or concurrent stop
    // must never create an unbounded restart loop.
    F.reset(); F.runtime_fault = true;
    try F.owner.start(&ctx, &F.output, .{ .advance = F.advance, .recover = F.recover, .restart = F.restart }); F.run();
    try t.expect(F.restart_calls == 1 and F.owner.restarts == 1 and F.advances == 4 and F.owner.recovered == 1);
    try t.expect(F.owner.join());
    F.reset();
    try F.owner.start(&ctx, &F.output, .{ .advance = F.advance, .recover = F.recover, .restart = F.restart }); F.run();
    try t.expect(F.restart_calls == 0 and F.owner.recovered == 1 and F.owner.join());
    F.reset(); F.runtime_fault = true; F.hold_recovery = true;
    try F.owner.start(&ctx, &F.output, .{ .advance = F.advance, .recover = F.recover, .restart = F.restart }); F.run();
    try t.expect(F.restart_calls == 0 and F.owner.recovered == 0 and F.result == -1 and F.owner.join());
    F.reset(); F.runtime_fault = true; F.fail_restart = true;
    try F.owner.start(&ctx, &F.output, .{ .advance = F.advance, .recover = F.recover, .restart = F.restart }); F.run();
    try t.expect(F.restart_calls == 1 and F.owner.failure.? == error.Capture and F.result == -1 and F.owner.join());
    F.reset(); F.runtime_fault = true; F.stop_in_recover = true;
    try F.owner.start(&ctx, &F.output, .{ .advance = F.advance, .recover = F.recover, .restart = F.restart }); F.run();
    try t.expect(F.restart_calls == 0 and F.owner.recovered == 1 and F.owner.join());
    F.reset();
    try F.owner.start(&ctx, &F.output, .{ .advance = F.advance, .recover = F.recover, .fault = F.fault }); F.run();
    try t.expect(F.advances == 2 and F.recovers == 3 and F.owner.recovered == 1 and F.owner.join());
    std.debug.print("[amd-native-worker] real Task callbacks, asynchronous admission, output-loss recovery, bounded retention and late join/release; model only\n", .{});
}
pub fn supported(ctx: *const r4os.r4dev.DriverContext) bool {
    if (!@import("owned_work.zig").supported(ctx)) return false;
    const threads = ctx.threads() orelse return false;
    const clock = ctx.resources() orelse return false;
    return threads.table.start != 0 and threads.table.join != 0 and threads.table.release != 0 and threads.table.sleep_ticks != 0 and
        threads.canAbort() and threads.hasCurrentRequest() and clock.table.now_ns != 0 and ctx.timerFrequency() != 0;
}
pub const Owner = struct {
    self_address: usize = 0,
    ctx: ?r4os.r4dev.DriverContext = null,
    threads: ?r4os.r4dev.DriverThreadContext = null,
    clock: ?r4os.r4dev.DriverResourceContext = null,
    hooks: ?Hooks = null,
    output: ?*@import("display_output.zig").Owner = null,
    thread: u64 = 0,
    joined: bool = false,
    result: i32 = 0,
    stop: u32 = 0,
    recovered: u32 = 0,
    ready: bool = false,
    restarts: u32 = 0,
    failure: ?anyerror = null,
    interval_ticks: u64 = 1,
    call: @import("owned_work.zig").Call = .{},
    operation: enum { advance, recover, restart } = .advance,
    call_failure: ?anyerror = null,
    pub fn start(self: *Owner, ctx: *const r4os.r4dev.DriverContext, output: *@import("display_output.zig").Owner, hooks: Hooks) !void {
        if (self.self_address != 0) return error.Busy;
        if (!supported(ctx)) return error.Unsupported;
        const threads = ctx.threads() orelse return error.Unsupported;
        const clock = ctx.resources() orelse return error.Unsupported;
        const frequency = ctx.timerFrequency();
        if (frequency == 0 or threads.table.sleep_ticks == 0) return error.Unsupported;
        self.* = .{ .self_address = @intFromPtr(self), .ctx = ctx.*, .threads = threads, .clock = clock, .hooks = hooks,
            .output = output, .interval_ticks = @import("shutdown_drain.zig").intervalTicks(frequency) };
        if (threads.start(worker, self.self_address, a.driver_thread_flag_parallel, &self.thread) != 0 or self.thread == 0) return error.Capacity;
    }
    pub fn requestStop(self: *Owner) void { if (self.self_address != 0) @atomicStore(u32, &self.stop, 1, .release); }
    pub fn join(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        if (self.thread == 0) return self.call.retired(&self.ctx.?);
        if (!self.joined) {
            if (self.threads.?.join(self.thread, 0, &self.result) != 0) return false;
            self.joined = true;
        }
        if (self.threads.?.release(self.thread) != 0) return false;
        self.thread = 0;
        return self.call.retired(&self.ctx.?);
    }
    fn invoke(self: *Owner, operation: @FieldType(Owner, "operation")) !bool {
        if (self.call.handle != 0) return error.Busy;
        self.operation = operation; self.call_failure = null;
        const result = try self.call.invoke(&self.ctx.?, self.threads.?, self.clock.?, ownedSlice, self.self_address);
        if (self.call_failure) |err| return err;
        if (result < 0) return error.Completion;
        return result == 1;
    }
    fn ownedSlice(raw: usize) callconv(.c) i32 {
        const self: *Owner = @ptrFromInt(raw);
        if (self.self_address != raw) return -1;
        const result = switch (self.operation) {
            .advance => self.hooks.?.advance() catch |err| { self.call_failure = err; return -1; },
            .recover => self.hooks.?.recover(),
            .restart => blk: { self.hooks.?.restart.?() catch |err| { self.call_failure = err; return -1; }; break :blk true; },
        };
        return @intFromBool(result);
    }
    fn worker(raw: usize) callconv(.c) i32 {
        const self: *Owner = @ptrFromInt(raw);
        if (self.self_address != raw) return -1;
        var last = self.clock.?.nowNs();
        var begin = last;
        var cleanup_begin: ?u64 = null;
        var recovering = false;
        var restart_allowed = false;
        while (true) {
            const now = self.clock.?.nowNs();
            if (now < last or now == std.math.maxInt(u64)) { self.failure = error.Clock; recovering = true; restart_allowed = false; }
            last = now;
            const worker_fault = if (self.hooks.?.fault) |fault| fault() else false;
            const requested = worker_fault or @atomicLoad(u32, &self.output.?.restore_requested, .acquire) != 0;
            if (!recovering and requested) {
                // A software switch uses the same restore callback but is not
                // a fault. Only a previously active output permits one retry.
                restart_allowed = self.ready and self.restarts == 0 and
                    (worker_fault or @atomicLoad(u32, &self.output.?.recovery_fault, .acquire) == 2);
                recovering = true;
            }
            if (@atomicLoad(u32, &self.stop, .acquire) != 0) { recovering = true; restart_allowed = false; }
            if (!recovering) {
                if (!self.ready) {
                    self.ready = self.invoke(.advance) catch |err| failed: {
                        if (self.call.handle != 0) {
                            self.failure = err;
                            self.ctx.?.logError("AMDGPU native start: owner callback retained; cleanup waits for completion");
                            return -1;
                        }
                        self.failure = err; recovering = true; restart_allowed = false;
                        var buffer: [128]u8 = undefined;
                        if (std.fmt.bufPrintZ(&buffer, "AMDGPU native start: failure={s}; recovery requested", .{@errorName(err)})) |message|
                            self.ctx.?.logError(message) else |_| {}
                        break :failed false;
                    };
                    if (!self.ready and now -| begin > 120 * std.time.ns_per_s) { self.failure = error.Deadline; recovering = true; }
                }
            } else {
                if (cleanup_begin == null) cleanup_begin = now;
                if (self.invoke(.recover) catch |err| failed: {
                    self.failure = err;
                    if (self.call.handle != 0) return -1;
                    break :failed false;
                }) {
                    if (restart_allowed and self.hooks.?.restart != null and @atomicLoad(u32, &self.stop, .acquire) == 0) {
                        self.restarts += 1; // consume before the fallible call
                        _ = self.invoke(.restart) catch |err| {
                            self.failure = err;
                            self.ctx.?.logError("AMDGPU recovery: fresh boot capture failed; restart required, select R4OS Software Graphics for one boot");
                            return -1;
                        };
                        self.ready = false; self.failure = null; recovering = false; restart_allowed = false;
                        cleanup_begin = null; begin = now;
                        continue;
                    }
                    @atomicStore(u32, &self.recovered, 1, .release);
                    self.ctx.?.logError("AMDGPU recovery: confirmed boot scanout restored; native owner stopped");
                    return 0;
                }
                if (now < cleanup_begin.? or now - cleanup_begin.? >= 30 * std.time.ns_per_s or (self.failure != null and self.failure.? == error.Clock)) {
                    self.ctx.?.logError("AMDGPU recovery: resources quarantined; unconfirmed scanout stays blocked; restart with R4OS Software Graphics if needed"); return -1;
                }
            }
            if (self.threads.?.sleepTicks(self.interval_ticks) != 0) {
                self.failure = error.Wait;
                // A cancelled pacing task cannot submit a new recovery call.
                // Its joined parent performs recovery under Shutdown's owner.
                self.ctx.?.logError("AMDGPU recovery: wait failed; resources quarantined, headless/restart required");
                return -1;
            }
        }
    }
};
