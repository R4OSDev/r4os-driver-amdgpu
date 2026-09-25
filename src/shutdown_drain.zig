// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Top-level Shutdown owns the driver's lifecycle lane. Its asynchronous
//! owners return pending until their callbacks and hardware receipts retire.
pub const timeout_ns: u64 = 30_000_000_000;
pub const max_waits: usize = 4096;
/// Poll no faster than100Hz. Ceil division keeps4096 waits longer than the
///30s deadline for every supported timer frequency; stalled clocks still
///terminate at the independent iteration guard.
pub fn intervalTicks(frequency: u32) u64 { return @max((@as(u64, frequency) + 99) / 100, 1); }

pub fn run(io: anytype, comptime step: fn () bool) bool {
    if (step()) return true;
    const begin = io.nowNs();
    if (begin == ~@as(u64, 0)) return false;
    var previous = begin;
    for (0..max_waits) |_| {
        io.wait();
        const now = io.nowNs();
        if (now < previous or now == ~@as(u64, 0) or now - begin >= timeout_ns) return false;
        previous = now;
        if (step()) return true;
    }
    return false;
}

pub fn check() !void {
    const t = @import("std").testing;
    const F = struct {
        var time: u64 = 1;
        var waits: usize = 0;
        var steps: usize = 0;
        var joins: usize = 0;
        var released = false;
        var never = false;
        var stopped_clock = false;
        var backwards = false;
        var expire = false;
        var empty = false;
        var frequency: u32 = 1000;
        var ticks: u64 = 1;
        var delayed_until: u64 = 0;
        fn step() bool {
            steps += 1;
            if (empty) return true;
            if (time < delayed_until) return false;
            // First a late Task join, then several independently acknowledged
            // cleanup phases. Pending must never release retained DMA.
            if (waits < 2 or never) return false;
            joins += 1;
            if (joins < 4) return false;
            released = true;
            return true;
        }
        pub fn nowNs(_: *@This()) u64 { return time; }
        pub fn wait(_: *@This()) void {
            waits += 1;
            if (backwards) { time = 0; return; }
            if (expire) { time += timeout_ns; return; }
            if (!stopped_clock) time += ticks * 1_000_000_000 / frequency;
        }
        fn reset() void {
            time = 1; waits = 0; steps = 0; joins = 0; released = false;
            never = false; stopped_clock = false; backwards = false; expire = false; empty = false;
            frequency = 1000; ticks = 1; delayed_until = 0;
        }
    };
    var io: F = .{};
    F.reset();
    try t.expect(run(&io, F.step));
    try t.expect(F.waits == 5 and F.steps == 6 and F.released);
    F.reset(); F.never = true; F.expire = true;
    try t.expect(!run(&io, F.step));
    try t.expect(F.waits == 1 and F.steps == 1 and !F.released);
    F.reset(); F.never = true; F.stopped_clock = true;
    try t.expect(!run(&io, F.step));
    try t.expect(F.waits == max_waits and !F.released);
    F.reset(); F.backwards = true;
    try t.expect(!run(&io, F.step));
    try t.expect(F.steps == 1 and !F.released);
    F.reset(); F.time = ~@as(u64, 0);
    try t.expect(!run(&io, F.step));
    try t.expect(F.steps == 1 and F.waits == 0);
    F.reset(); F.empty = true;
    try t.expect(run(&io, F.step) and F.waits == 0);
    // The real wait interval must leave the advertised30s for a late task,
    // not exhaust4096 iterations near4s on the Lenovo's1000Hz timer.
    for ([_]u32{ 50, 100, 128, 199, 1000, 1024 }) |frequency| {
        F.reset(); F.frequency = frequency; F.ticks = intervalTicks(frequency);
        F.delayed_until = 8_000_000_000;
        try t.expect(run(&io, F.step));
        try t.expect(F.released and F.time >= F.delayed_until and F.time < timeout_ns and F.waits < max_waits);
        F.reset(); F.frequency = frequency; F.ticks = intervalTicks(frequency); F.never = true;
        try t.expect(!run(&io, F.step));
        try t.expect(!F.released and F.time >= timeout_ns and F.time < timeout_ns + 20_000_001 and F.waits < max_waits);
    }
    @import("std").debug.print("[amd-shutdown] delayed join, phased cleanup, hard/clock deadlines and retained failure: OK; model only\n", .{});
}
