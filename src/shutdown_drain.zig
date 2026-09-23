// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Top-level Shutdown owns the driver's lifecycle lane. Its asynchronous
//! owners return pending until their callbacks and hardware receipts retire.
pub const timeout_ns: u64 = 30_000_000_000;
pub const max_waits: usize = 4096;

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
        fn step() bool {
            steps += 1;
            if (empty) return true;
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
            if (!stopped_clock) time += 1_000_000;
        }
        fn reset() void {
            time = 1; waits = 0; steps = 0; joins = 0; released = false;
            never = false; stopped_clock = false; backwards = false; expire = false; empty = false;
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
    @import("std").debug.print("[amd-shutdown] delayed join, phased cleanup, hard/clock deadlines and retained failure: OK; model only\n", .{});
}
