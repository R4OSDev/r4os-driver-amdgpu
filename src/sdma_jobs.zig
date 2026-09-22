// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Worker-owned common copy jobs. Queue execution leases stay canonical; the
//! driver adopts backing references only and releases them after exact fences.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const c = @import("start_common.zig");
const copy = @import("r4amd_copy");
const q = @import("queue_timeline.zig");
const storage = @import("queue_storage.zig");
const mem = @import("memory_owner.zig");
const Mapping = @import("memory_mapping.zig").Mapping;
pub const capacity = 8;
pub const max_pages = copy.max_transfer_bytes / 4096;
pub const resource_va: u64 = 0x4000000000;
pub const arena_va: u64 = 0x8000000000;
pub const Error = c.Error || copy.Error;
/// An optional serialized display client uses the same SDMA ring and real
/// timeline. It never owns a second queue consumer or an IRQ-side allocator.
pub const Client = struct {
    context: usize,
    work: *const fn (usize) void,
    available: *const fn (usize) bool,
    accept: *const fn (usize, a.GfxDriverJob) bool,
    drain: ?*const fn (usize) bool = null,
    lost: ?*const fn (usize) void = null,
};
const Job = struct {
    owner: ?*Owner = null,
    fence: a.GfxFence = .{},
    ticket: ?q.Ticket = null,
    maps: [2]Mapping = .{ .{}, .{} },
    references: [2]a.GfxBufferReference = .{ .{}, .{} },
    pages: [2][max_pages]u64 = undefined,
    retained: [2]bool = .{ false, false },
    submitted: bool = false,
    fence_retired: bool = false,
    fn retire(raw: usize, fence: a.GfxFence) bool {
        const self: *Job = @ptrFromInt(raw);
        const owner = self.owner orelse return false;
        if (!std.meta.eql(self.fence, fence)) return false;
        const memory = owner.memory.?;
        // Exact fence callback runs once logically; partial teardown remains
        // retryable without completing/releasing the same hold twice.
        for (&self.maps, &self.retained) |*map, *held| {
            if (held.*) {
                map.complete(fence) catch return false;
                held.* = false;
            }
            if (!map.close(&memory.virtual, &memory.registers)) return false;
        }
        for (&self.references) |*reference| if (reference.reference.id != 0) {
            if (memory.memory.?.bufferRelease(&reference.reference) != 1) return false;
            reference.* = .{};
        };
        self.fence_retired = true;
        return true;
    }
    fn clear(self: *Job) void {
        // Leave the bounded SG scratch in place; never copy its large arrays.
        self.owner = null;
        self.fence = .{};
        self.ticket = null;
        self.submitted = false;
        self.fence_retired = false;
    }
};
pub const Owner = struct {
    client: ?Client = null,
    graphics: ?*@import("gc_runtime.zig").Owner = null,
    self_address: usize = 0,
    memory: ?*mem.Owner = null,
    runtime: ?*@import("queue_runtime.zig").Owner = null,
    engine: @import("sdma_ring.zig").Engine = .{},
    binding: a.GfxBackendBinding = .{},
    registered: bool = false,
    active: bool = false,
    queue: ?r4os.driver_queue.Context = null,
    jobs: [capacity]Job = @splat(.{}),
    commands: [copy.max_words]u32 = undefined,
    arena_pages: [storage.bytes / 4096]u64 = undefined,
    arena_translated: bool = false,
    arena_flush_pending: bool = false,
    gc_stop: @import("start_engines.zig").Park = .{},
    gc_stop_started: bool = false,
    closed: bool = false,
    selftest_submitted: bool = false,
    verified: bool = false,
    deadline: c.Deadline = .{},
    pub fn prepare(self: *Owner, memory: *mem.Owner, runtime: *@import("queue_runtime.zig").Owner, native: *const @import("start_runtime.zig").Owner) Error!void {
        if (self.self_address != 0 or native.memory != memory or native.self_address != @intFromPtr(native) or
            !native.flow.firmwareReady() or native.hold.held_generation == 0 or !native.hold.effects or
            !memory.controller.enabled or memory.controller.epoch != memory.epoch or runtime.self_address != 0) return error.Unconfirmed;
        self.self_address = @intFromPtr(self);
        self.memory = memory;
        self.runtime = runtime;
        const layout = memory.layout.?;
        const virtual_span: @import("memory_layout.zig").Span = .{ .offset = resource_va, .bytes = capacity * 0x10000000 };
        const arena_span: @import("memory_layout.zig").Span = .{ .offset = arena_va, .bytes = storage.bytes };
        if (virtual_span.overlaps(layout.mc) or virtual_span.overlaps(layout.gart) or arena_span.overlaps(layout.mc) or arena_span.overlaps(layout.gart)) return error.Invalid;
        try runtime.arena.prepare(memory, native.snapshot.bars[2], .{ .memory_epoch = memory.epoch, .boot_held = true, .engines_quiesced = true });
        const physical = try layout.physicalAddress(layout.rings.span);
        for (&self.arena_pages, 0..) |*page, i| page.* = physical + i * 4096;
        // The outer ring addresses UMA directly in VMID0. Its indirect buffers
        // execute in VMID1, so that entire retained arena needs explicit PTEs.
        try memory.virtual.map(arena_va, &self.arena_pages, .{ .system = false, .write = true, .execute = false });
        self.arena_translated = true;
        self.arena_flush_pending = true;
        try @import("memory_hubs.zig").flush(&memory.registers, 1);
        self.arena_flush_pending = false;
        try self.engine.open(&memory.registers, &runtime.arena, .{ .firmware_ready = true, .boot_held = true, .gmc_enabled = true });
        try self.selftest();
    }
    const test_offset = storage.wb_offset + 0x400;
    const test_token: u64 = 0x52414d4453444d41;
    fn selftest(self: *Owner) Error!void {
        const runtime = self.runtime.?;
        const memory = self.memory.?;
        const data = try runtime.arena.words32(test_offset, 32);
        for (data) |*word| word.* = 0;
        data[0] = 0xffffffff;
        data[1] = 0xffffffff;
        var count = try copy.encodeFill(&self.commands, .{ .target = arena_va + test_offset + 8, .bytes = 8, .value = 0xa5c39e17 });
        count += try copy.encodeCopy(self.commands[count..], .{ .source = arena_va + test_offset + 8, .target = arena_va + test_offset + 16, .bytes = 8 });
        self.commands[count] = 0;
        count += 1; // drain outstanding SDMA memory operations
        const ib = try runtime.arena.ib(0);
        for (self.commands[0..count], 0..) |word, i| ib[i] = word;
        var commands: [32]u32 = undefined;
        _ = try @import("sdma_ring.zig").frame(&commands, self.engine.ring.write, arena_va + storage.ib_offset, count, try runtime.arena.address(test_offset, 8), test_token, false);
        const ticket = try self.engine.ring.stage(&commands);
        try self.deadline.start(memory.registers.nowNs(), 2_000_000_000, 0);
        self.selftest_submitted = true;
        try self.engine.kick(&memory.registers, &runtime.arena, ticket);
    }
    pub fn pollSelftest(self: *Owner) Error!bool {
        if (self.self_address != @intFromPtr(self) or !self.selftest_submitted or self.engine.stopping) return error.State;
        if (self.verified) return true;
        const io = &self.memory.?.registers;
        _ = try self.deadline.check(io.nowNs());
        try c.hdpInvalidate(io);
        try self.engine.observe(io);
        const data = try self.runtime.?.arena.words32(test_offset, 32);
        const first = (@as(u64, data[1]) << 32) | data[0];
        try io.barrier();
        const second = (@as(u64, data[1]) << 32) | data[0];
        if (first != test_token or second != test_token) return false;
        if (data[2] != 0xa5c39e17 or data[3] != 0xa5c39e17 or data[4] != 0xa5c39e17 or data[5] != 0xa5c39e17) return error.Unconfirmed;
        // RPTR reclaim is separate from memory/fence completion.
        if (self.engine.ring.read != self.engine.ring.write) return false;
        self.verified = true;
        return true;
    }
    pub fn activate(self: *Owner, native: *const @import("start_runtime.zig").Owner) Error!void {
        if (self.self_address != @intFromPtr(self) or !self.verified or self.registered or native.memory != self.memory or !native.flow.firmwareReady()) return error.Unconfirmed;
        const ctx = native.ctx.?;
        const queue = ctx.graphicsQueue() orelse return error.Unsupported;
        self.queue = queue;
        const amd = @import("r4amd");
        const details: amd.R4AmdDriverProfile = .{ .version = 1, .size = @sizeOf(amd.R4AmdDriverProfile), .vendor_id = amd.vendor_id, .device_id = 0x15d8, .gc_version = amd.gc_9_1_0, .sdma_version = amd.sdma_4_1_0, .command_abi = amd.command_abi, .reserved = 0 };
        var profile: a.GfxBackendProfile = .{ .interface_id_lo = amd.backend_v1_header.interface_id_lo, .interface_id_hi = amd.backend_v1_header.interface_id_hi, .revision = 1, .data_bytes = @sizeOf(amd.R4AmdDriverProfile) };
        @memcpy(profile.data[0..@sizeOf(amd.R4AmdDriverProfile)], std.mem.asBytes(&details));
        if (queue.registerProfile(&.{ .adapter_id = self.memory.?.adapter, .memory_generation = self.memory.?.epoch, .milestone = a.gfx_queue_milestone_device_execution, .operations = (@as(u64, 1) << a.gfx_queue_operation_copy) | (@as(u64, 1) << a.gfx_queue_operation_copy_rows), .notify_callback = @intFromPtr(&@import("queue_runtime.zig").Owner.notify), .context = @intFromPtr(self.runtime.?) }, &profile, &self.binding) != 1) return error.Unsupported;
        self.registered = true;
        const graphics = self.graphics orelse return error.Unconfirmed;
        const chip = native.chip orelse return error.Unconfirmed;
        if (graphics.engine.phase != .ready or graphics.engine.gb_addr_config == 0) return error.Unconfirmed;
        const architecture: amd.R4AmdArchitecture = .{ .version = 1, .size = @sizeOf(amd.R4AmdArchitecture), .vendor_id = amd.vendor_id, .device_id = 0x15d8, .gc_version = amd.gc_9_1_0, .sdma_version = amd.sdma_4_1_0, .gb_addr_config = graphics.engine.gb_addr_config, .chip_revision = chip.external_revision, .bind_alignment = 4096, .memory_generation = self.memory.?.epoch, .flags = 0, .reserved = 0, .max_image_bytes = 64 * 1024 * 1024 };
        graphics.architecture = architecture;
        var properties: a.GfxBackendProperties = .{ .interface_id_lo = amd.image_v1_header.interface_id_lo, .interface_id_hi = amd.image_v1_header.interface_id_hi, .revision = 1, .data_bytes = @sizeOf(amd.R4AmdArchitecture) };
        @memcpy(properties.data[0..@sizeOf(amd.R4AmdArchitecture)], std.mem.asBytes(&architecture));
        if (queue.publishProperties(&self.binding, &properties) != 1) return error.Unsupported;
        try self.runtime.?.prepare(&ctx, self.memory.?, &native.snapshot, self.binding, .{ .memory_epoch = self.memory.?.epoch, .boot_held = true, .engines_quiesced = false });
        try self.runtime.?.start(&native.snapshot, .{ .context = self.self_address, .work = work, .event = event, .quiesce = quiesce, .before_poll = beforePoll, .irq_ready = irqReady });
        self.active = true;
    }
    fn irqReady(raw: usize) @import("queue_runtime.zig").Error!void {
        const self: *Owner = @ptrFromInt(raw);
        self.engine.interrupts(&self.memory.?.registers) catch return error.Unconfirmed;
        if (self.graphics) |graphics| graphics.irqReady() catch return error.Unconfirmed;
        // Publish only once code, descriptors, PTEs and GC context are ready.
        const ops = (@as(u64, 1) << a.gfx_queue_operation_copy) | (@as(u64, 1) << a.gfx_queue_operation_copy_rows) | @import("render_jobs.zig").operations;
        if (self.queue.?.updateOperations(&self.binding, ops) != 1) return error.Unsupported;
    }
    /// Outer native shutdown joins the worker before touching its ring/maps.
    /// A false return keeps every outstanding mapping and owning object live.
    pub fn close(self: *Owner) bool {
        if (self.self_address == 0 or self.closed) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        const runtime = self.runtime.?;
        const memory = self.memory.?;
        if (!runtime.stopWorker()) return false;
        if (self.graphics) |graphics| if (!graphics.close()) return false;
        if (!(self.engine.stop(&memory.registers) catch false)) return false;
        if (!self.gc_stop_started) {
            self.gc_stop.begin(&memory.registers) catch return false;
            self.gc_stop_started = true;
        }
        if (!self.gc_stop.confirmed and !(self.gc_stop.poll(&memory.registers) catch false)) return false;
        if (self.client) |client| if (client.drain) |drain| if (!drain(client.context)) return false;
        for (&self.jobs) |*job| if (job.owner != null and job.ticket == null) {
            if (!Job.retire(@intFromPtr(job), job.fence) or runtime.queue.?.complete(&job.fence, a.gfx_queue_result_failed, 1) != 1) return false;
            job.clear();
        };
        const proof: ?q.Quiescence = if (runtime.timeline.self_address != 0) .{ .epoch = runtime.timeline.epoch, .engines = 7 } else null;
        if (!runtime.close(proof)) return false;
        if (self.client) |client| if (client.drain) |drain| if (!drain(client.context)) return false;
        // prepare() owns the arena even before a common backend/timeline exists.
        if (!runtime.arena.close(true)) return false;
        self.engine.restoreRouting(&memory.registers) catch return false;
        if (self.arena_translated) {
            memory.virtual.unmap(arena_va, self.arena_pages.len) catch return false;
            self.arena_translated = false;
            self.arena_flush_pending = true;
        }
        if (self.arena_flush_pending) {
            @import("memory_hubs.zig").flush(&memory.registers, 1) catch return false;
            self.arena_flush_pending = false;
        }
        if (self.registered) {
            const queue = self.queue orelse return false;
            if (queue.unregister(&self.binding, 1) != 1) return false;
            self.registered = false;
        }
        for (&self.jobs) |*job| if (job.owner != null) {
            if (!job.fence_retired) return false;
            job.clear();
        };
        self.active = false;
        self.closed = true;
        return true;
    }
    fn beforePoll(runtime: *@import("queue_runtime.zig").Owner, raw: usize) void {
        const self: *Owner = @ptrFromInt(raw);
        c.hdpInvalidate(&self.memory.?.registers) catch runtime.timeline.fault(1);
        if (self.graphics) |graphics| graphics.poll();
    }
    fn event(_: usize, _: @import("queue_ih.zig").Event) void {}
    fn quiesce(raw: usize, epoch: q.Epoch, engines: u3) ?q.Quiescence {
        const self: *Owner = @ptrFromInt(raw);
        if (!std.meta.eql(epoch, self.runtime.?.timeline.epoch)) return null;
        if (self.client) |client| if (client.lost) |lost| lost(client.context);
        var confirmed: u3 = 0;
        if (engines & 1 != 0 and (self.engine.stop(&self.memory.?.registers) catch false)) confirmed |= 1;
        if (engines & 6 != 0) if (self.graphics) |graphics| {
            if (graphics.quiesce(epoch)) |proof| confirmed |= proof.engines;
        };
        return if (confirmed != 0) .{ .epoch = epoch, .engines = confirmed } else null;
    }
    fn work(runtime: *@import("queue_runtime.zig").Owner, raw: usize) void {
        const self: *Owner = @ptrFromInt(raw);
        if (self.client) |client| client.work(client.context);
        if (self.graphics) |graphics| graphics.work();
        if (!self.registered or !self.verified or self.engine.stopping) return;
        self.engine.observe(&self.memory.?.registers) catch |err| {
            if (err != error.Busy) runtime.timeline.fault(1);
            return;
        };
        for (&self.jobs) |*job| {
            if (job.owner == null) continue;
            if (job.ticket) |ticket| {
                _ = runtime.timeline.entry(ticket) catch {
                    if (job.fence_retired) job.clear();
                    continue;
                };
            } else if (Job.retire(@intFromPtr(job), job.fence)) {
                if (runtime.queue.?.complete(&job.fence, a.gfx_queue_result_failed, 1) == 1) job.clear();
            }
        }
        // One job per step bounds validation, page walks and encoding. Pending
        // notifications coalesce; periodic polling guarantees further progress.
        if (self.engine.ring.available() < 32) return;
        if (self.graphics) |graphics| if (!graphics.renderer.available()) return;
        if (self.client) |client| if (!client.available(client.context)) return;
        for (&self.jobs, 0..) |*job, index| if (job.owner == null) {
            var input: a.GfxDriverJob = .{};
            if (runtime.queue.?.take(&self.binding, &input) != 1) return;
            if (self.client) |client| if (client.accept(client.context, input)) return;
            if (@import("render_jobs.zig").supports(input.operation)) if (self.graphics) |graphics| {
                graphics.renderer.accept(input);
                return;
            };
            job.owner = self;
            job.fence = input.fence;
            self.submit(job, index, input) catch {
                if (job.submitted) {
                    runtime.timeline.fault(1);
                    return;
                }
                if (job.ticket) |ticket| {
                    runtime.timeline.cancelUnsubmitted(ticket) catch {};
                }
                return;
            };
            return;
        };
    }
    /// Submit an already reserved timeline/IB slot from this worker. The
    /// caller must retain every mapping first. `armed` is latched before the
    /// doorbell; failure after that point requires an actual stop/fence.
    pub fn submitIndirect(self: *Owner, ticket: q.Ticket, words: []const u32, deadline: u64, armed: *bool) Error!void {
        if (self.self_address != @intFromPtr(self) or !self.verified or !self.registered or self.engine.stopping or armed.* or
            words.len == 0 or words.len > storage.ib_bytes / 4) return error.State;
        const runtime = self.runtime.?;
        const entry = try runtime.timeline.entry(ticket);
        if (entry.phase != .reserved or entry.engine != .sdma or entry.deadline != deadline) return error.Stale;
        const ib = try runtime.arena.ib(ticket.slot);
        for (words, 0..) |word, i| ib[i] = word;
        var commands: [32]u32 = undefined;
        _ = try @import("sdma_ring.zig").frame(&commands, self.engine.ring.write,
            arena_va + storage.ib_offset + @as(u64, ticket.slot) * storage.ib_bytes, @intCast(words.len),
            try runtime.arena.address(storage.fence_offset + @as(usize, ticket.slot) * 8, 8), ticket.token, true);
        if (self.memory.?.registers.nowNs() >= deadline) return error.Deadline;
        const staged = try self.engine.ring.stage(&commands);
        runtime.timeline.arm(ticket) catch |err| { try self.engine.ring.cancel(staged); return err; };
        armed.* = true;
        try self.engine.kick(&self.memory.?.registers, &runtime.arena, staged);
    }
    fn submit(self: *Owner, job: *Job, index: usize, input: a.GfxDriverJob) Error!void {
        const runtime = self.runtime.?;
        const memory = self.memory.?;
        const queue = runtime.queue.?;
        if (input.version != 1 or input.size < 224 or !runtime.timeline.epoch.matches(input.fence) or input.reserved0 != 0 or input.reserved1 != 0 or
            (input.operation != a.gfx_queue_operation_copy and input.operation != a.gfx_queue_operation_copy_rows) or
            std.meta.eql(input.source_buffer, input.target_buffer)) return error.Invalid;
        const rows: u32 = if (input.operation == a.gfx_queue_operation_copy) 1 else input.row_count;
        for (0..2) |side| {
            if (queue.retainResource(&input.fence, @intCast(side), &job.references[side]) != 1) return error.Stale;
            var desc: a.GfxBufferDescriptor = .{};
            if (memory.memory.?.bufferDescribe(&job.references[side].reference, &desc) != 1 or desc.byte_length == 0 or desc.byte_length > copy.max_transfer_bytes or
                !std.meta.eql(job.references[side].buffer, if (side == 0) input.source_buffer else input.target_buffer)) return error.Invalid;
            const offset = if (side == 0) input.source_offset else input.target_offset;
            const length = try copy.extent(input.byte_length, if (side == 0) input.source_pitch else input.target_pitch, rows);
            if (offset >= desc.byte_length or length > desc.byte_length - offset or desc.modifier != 0) return error.Invalid;
            const va = resource_va + index * 0x10000000 + side * 0x08000000;
            try job.maps[side].adopt(memory, &job.references[side], va, job.pages[side][0..@intCast((desc.byte_length + 4095) / 4096)]);
            try job.maps[side].publish(&memory.virtual, &memory.registers, side == 1, false);
        }
        var count = try copy.encodeCopy(&self.commands, .{ .source = job.maps[0].address + input.source_offset, .target = job.maps[1].address + input.target_offset, .bytes = input.byte_length, .rows = rows, .source_pitch = input.source_pitch, .target_pitch = input.target_pitch });
        if (count >= self.commands.len) return error.Capacity;
        self.commands[count] = 0;
        count += 1;
        const ticket = try runtime.timeline.reserve(input.fence, .sdma, input.deadline_ns, .{ .context = @intFromPtr(job), .retire = Job.retire });
        job.ticket = ticket;
        for (&job.maps, &job.retained) |*map, *held| {
            try map.retain(input.fence);
            held.* = true;
        }
        const ib = try runtime.arena.ib(ticket.slot);
        for (self.commands[0..count], 0..) |word, i| ib[i] = word;
        var commands: [32]u32 = undefined;
        _ = try @import("sdma_ring.zig").frame(&commands, self.engine.ring.write, arena_va + storage.ib_offset + @as(u64, ticket.slot) * storage.ib_bytes, count, try runtime.arena.address(storage.fence_offset + @as(usize, ticket.slot) * 8, 8), ticket.token, true);
        if (memory.registers.nowNs() >= input.deadline_ns) return error.Deadline;
        const staged = try self.engine.ring.stage(&commands);
        runtime.timeline.arm(ticket) catch |err| {
            try self.engine.ring.cancel(staged);
            return err;
        };
        job.submitted = true;
        try self.engine.kick(&memory.registers, &runtime.arena, staged);
    }
};

const Test = struct {
    var owner: Owner = .{};
    var memory: mem.Owner = .{};
    var runtime: @import("queue_runtime.zig").Owner = .{};
    var regs: [@import("memory_registers.zig").required_prefix / 4]u32 align(4096) = @splat(0);
    var arena: [storage.bytes / 4]u32 align(4096) = @splat(0);
    var bells: [1024]u32 align(4096) = @splat(0);
    var tables: [16 * 512]u64 align(4096) = undefined;
    var live: [2]bool = .{ false, false };
    var dma: [2]bool = .{ false, false };
    var gpu: [2]bool = .{ false, false };
    var descriptors: [2]a.GfxBufferDescriptor = undefined;
    var pending = false;
    var active = false;
    var complete_fail = false;
    var release_fail = false;
    var unmapped: usize = 0;
    var unregistered: bool = false;
    var completed: u32 = 0;
    var last_result: u32 = 0;
    var time: u64 = 1000;
    var request: a.GfxDriverJob = .{};
    fn reset() !void {
        // These are static fixtures: no large state copy on a kernel-sized stack.
        owner = .{};
        runtime = .{};
        memory = .{};
        regs = @splat(0);
        arena = @splat(0);
        bells = @splat(0);
        live = .{ false, false };
        dma = .{ false, false };
        gpu = .{ false, false };
        pending = false;
        active = false;
        unmapped = 0;
        unregistered = false;
        completed = 0;
        last_result = 0;
        complete_fail = false;
        release_fail = false;
        time = 1000;
        const context: r4os.driver_memory.Context = .{ .table = .{ .mmio_unmap = @intFromPtr(&unmap), .buffer_describe = @intFromPtr(&describe), .buffer_release = @intFromPtr(&release), .device_acquire = @intFromPtr(&acquire), .device_segment = @intFromPtr(&segment), .device_release = @intFromPtr(&releaseDevice), .collect = @intFromPtr(&collect) } };
        memory = .{ .self_address = @intFromPtr(&memory), .memory = context, .prepared = true, .adapter = 7, .epoch = 23, .controller = .{ .enabled = true, .epoch = 23 }, .registers = .{ .window = .{ .value = .{ .handle = .{ .id = 1, .generation = 1 }, .cpu_address = @intFromPtr(&regs), .byte_length = @sizeOf(@TypeOf(regs)) } }, .clock = .{ .table = .{ .now_ns = @intFromPtr(&now) } } } };
        try memory.virtual.init(&tables, 0x3000000);
        const mr = @import("memory_registers.zig");
        regs[mr.gfx.VM_INVALIDATE_ENG17_ACK / 4] = 3;
        regs[mr.mm.VM_INVALIDATE_ENG17_ACK / 4] = 3;
        const binding: a.GfxBackendBinding = .{ .adapter_id = 7, .device_generation = 11, .reset_generation = 5 };
        runtime = .{ .self_address = @intFromPtr(&runtime), .prepared = true, .memory = &memory, .queue = .{ .table = .{ .unregister_backend = @intFromPtr(&unregister), .take = @intFromPtr(&take), .retain_resource = @intFromPtr(&retain), .complete = @intFromPtr(&complete) } } };
        runtime.arena = .{ .self_address = @intFromPtr(&runtime.arena), .memory = &memory, .epoch = 23, .gpu = 0x120000000, .ready = true, .arena = .{ .value = .{ .handle = .{ .id = 2, .generation = 1 }, .cpu_address = @intFromPtr(&arena), .byte_length = storage.bytes } }, .doorbell = .{ .value = .{ .handle = .{ .id = 3, .generation = 1 }, .cpu_address = @intFromPtr(&bells), .byte_length = 4096 } } };
        try runtime.timeline.init(binding, try runtime.arena.fences(), time);
        owner.self_address = @intFromPtr(&owner);
        owner.memory = &memory;
        owner.runtime = &runtime;
        owner.binding = binding;
        owner.registered = true;
        owner.verified = true;
        owner.queue = runtime.queue;
        owner.engine.ring = try @import("queue_ring.zig").Ring.init(try runtime.arena.words32(storage.ringOffset(.sdma), storage.ring_bytes), 8, 0);
        owner.engine.running = true;
        request = .{ .fence = .{ .adapter_id = 7, .device_generation = 11, .reset_generation = 5, .timeline = 3, .point = 1, .slot = 2 }, .operation = a.gfx_queue_operation_copy_rows, .source_buffer = .{ .id = 1, .generation = 19 }, .target_buffer = .{ .id = 2, .generation = 19 }, .byte_length = 64, .source_offset = 3, .target_offset = 11, .row_count = 5, .source_pitch = 80, .target_pitch = 100, .deadline_ns = 1_000_000 };
        descriptors = @splat(.{ .byte_length = 5001, .usage = a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_transfer_target });
    }
    fn unmap(_: *const a.GfxBufferHandle, quiet: u32) callconv(.c) i32 {
        std.debug.assert(quiet == 1 and owner.engine.quiesced and owner.gc_stop.confirmed and !active);
        if (release_fail) return -4;
        unmapped += 1;
        return 1;
    }
    fn unregister(_: *const a.GfxBackendBinding, quiet: u32) callconv(.c) i32 {
        std.debug.assert(quiet == 1 and unmapped == 2 and !active and memory.mapping_users == 0);
        unregistered = true;
        return 1;
    }
    fn now() callconv(.c) u64 {
        time += 100;
        return time;
    }
    fn collect() callconv(.c) i32 {
        return 1;
    }
    fn take(_: *const a.GfxBackendBinding, output: *a.GfxDriverJob) callconv(.c) i32 {
        if (!pending) return 0;
        pending = false;
        active = true;
        output.* = request;
        return 1;
    }
    fn retain(fence: *const a.GfxFence, side: u32, output: *a.GfxBufferReference) callconv(.c) i32 {
        std.debug.assert(active and side < 2 and !live[side] and std.meta.eql(fence.*, request.fence));
        live[side] = true;
        output.* = .{ .reference = .{ .id = side + 10, .generation = 19 }, .buffer = if (side == 0) request.source_buffer else request.target_buffer, .flags = a.gfx_buffer_reference_mapping_only };
        return 1;
    }
    fn describe(reference: *const a.GfxBufferHandle, output: *a.GfxBufferDescriptor) callconv(.c) i32 {
        const side = reference.id - 10;
        std.debug.assert(side < 2 and live[side]);
        output.* = descriptors[side];
        return 1;
    }
    fn release(reference: *const a.GfxBufferHandle) callconv(.c) i32 {
        const side = reference.id - 10;
        std.debug.assert(active and live[side] and !gpu[side] and !dma[side]);
        if (release_fail) return -4;
        live[side] = false;
        return 1;
    }
    fn acquire(reference: *const a.GfxBufferHandle, input: *const a.GfxDeviceRequest, output: *a.GfxDeviceLease) callconv(.c) i32 {
        const side = reference.id - 10;
        std.debug.assert(active and live[side] and input.byte_offset == 0 and input.byte_length == descriptors[side].byte_length and input.adapter_id == 7 and input.device_generation == 23);
        if (input.access == 4) {
            std.debug.assert(!dma[side]);
            dma[side] = true;
        } else {
            std.debug.assert(input.access == 3 and !gpu[side]);
            gpu[side] = true;
        }
        output.* = .{ .lease = .{ .id = 100 + side * 10 + input.access, .generation = 19 }, .byte_length = input.byte_length, .gpu_virtual_address = input.gpu_virtual_address, .adapter_id = 7, .driver_owner = 9, .device_generation = 23, .access = input.access, .address_space = input.address_space, .dma_mask = input.dma_mask };
        return 1;
    }
    fn segment(lease: *const a.GfxDeviceLease, offset: u64, output: *a.GfxDmaSegment) callconv(.c) i32 {
        const side = (lease.lease.id - 100) / 10;
        std.debug.assert(dma[side] and offset < descriptors[side].byte_length);
        const bytes = @min(@as(u64, 4096), descriptors[side].byte_length - offset);
        output.* = .{ .dma_address = 0x1000000 + @as(u64, side) * 0x100000 + offset * 3, .byte_length = bytes, .next_offset = offset + bytes };
        return 1;
    }
    fn releaseDevice(lease: *const a.GfxDeviceLease, quiet: u32) callconv(.c) i32 {
        const side = (lease.lease.id - 100) / 10;
        std.debug.assert(active and quiet == 1);
        if (release_fail) return -4;
        if (lease.access == 3) {
            std.debug.assert(gpu[side]);
            gpu[side] = false;
        } else {
            std.debug.assert(dma[side] and !gpu[side]);
            dma[side] = false;
        }
        return 1;
    }
    fn complete(fence: *const a.GfxFence, result: u32, quiet: u32) callconv(.c) i32 {
        std.debug.assert(active and !live[0] and !live[1] and !dma[0] and !dma[1] and !gpu[0] and !gpu[1] and quiet == 1 and std.meta.eql(fence.*, request.fence));
        if (complete_fail) return -4;
        active = false;
        completed += 1;
        last_result = result;
        return 1;
    }
    fn submit() void {
        pending = true;
        Owner.work(&runtime, @intFromPtr(&owner));
    }
    fn fenceWrite(token: u64) !void {
        const words = try runtime.arena.fences();
        words[owner.jobs[0].ticket.?.slot] = token;
    }
};

test "SDMA common jobs retain exact BO tails and fences across stale completions abort and failed releases" {
    const t = std.testing;
    try Test.reset();
    Test.submit();
    const job = &Test.owner.jobs[0];
    const ticket = job.ticket.?;
    try t.expect(job.submitted and Test.live[0] and Test.live[1] and Test.memory.mapping_users == 2);
    try t.expectEqual(@as(u64, 5001), job.maps[0].bytes);
    try t.expectEqual(@as(usize, 2), job.maps[0].physical.len);
    try t.expectEqual(@as(u64, 0x1003000), job.maps[0].physical[1]);
    try t.expectEqual(@as(u64, 5001), job.maps[0].gpu.byte_length); // no fictitious 8192-byte lease
    const ib = try Test.runtime.arena.ib(ticket.slot);
    try t.expectEqual(@as(u32, 0x401), ib[0]); // byte-element rectangular copy for unaligned offsets
    try t.expectEqual(@as(u32, 3), ib[1]);
    try t.expectEqual(@as(u32, 0x0800000b), ib[6]);
    try t.expectEqual(@as(u32, 128), Test.bells[@import("queue_registers.zig").sdma_doorbell]);
    try Test.fenceWrite(ticket.token + 7);
    Test.runtime.timeline.poll(2000);
    try t.expect(Test.runtime.timeline.entries[ticket.slot].phase == .submitted and Test.active);
    var old = Test.request.fence;
    old.reset_generation += 1;
    try t.expect(!Job.retire(@intFromPtr(job), old));
    try t.expect(Test.live[0] and Test.live[1]);
    try Test.fenceWrite(ticket.token);
    Test.runtime.timeline.poll(3000);
    Test.release_fail = true;
    try t.expect(!Test.runtime.timeline.publish(Test.runtime.queue.?));
    try t.expect(Test.active and Test.live[0] and Test.live[1] and Test.completed == 0);
    Test.release_fail = false;
    Test.complete_fail = true;
    try t.expect(!Test.runtime.timeline.publish(Test.runtime.queue.?));
    try t.expect(Test.active and !Test.live[0] and !Test.live[1] and Test.memory.mapping_users == 0 and Test.memory.virtual.mapped_pages == 0);
    Test.complete_fail = false;
    try t.expect(Test.runtime.timeline.publish(Test.runtime.queue.?));
    try t.expectEqual(@as(u32, 1), Test.completed);
    try t.expectEqual(a.gfx_queue_result_complete, Test.last_result);
    Owner.work(&Test.runtime, @intFromPtr(&Test.owner));
    try t.expect(job.owner == null);
    // A missing TLB acknowledgement after PTE removal retains both leases.
    try Test.reset();
    Test.submit();
    const second = Test.owner.jobs[0].ticket.?;
    try Test.fenceWrite(second.token);
    Test.runtime.timeline.poll(4000);
    const mr = @import("memory_registers.zig");
    Test.regs[mr.mm.VM_INVALIDATE_ENG17_ACK / 4] = 0;
    try t.expect(!Test.runtime.timeline.publish(Test.runtime.queue.?));
    try t.expect(Test.gpu[0] and Test.dma[0] and Test.live[0]);
    Test.regs[mr.mm.VM_INVALIDATE_ENG17_ACK / 4] = 3;
    try t.expect(Test.runtime.timeline.publish(Test.runtime.queue.?));
    // Deadline is not DMA quiescence. Only the matching hardware stop epoch
    // may release an unfinished job; a stale proof leaves everything pinned.
    try Test.reset();
    Test.submit();
    Test.runtime.timeline.poll(Test.request.deadline_ns);
    try t.expect(Test.active and Test.runtime.timeline.failed_engines == 1 and Test.live[0]);
    try t.expectError(error.Unconfirmed, Test.runtime.timeline.abort(.{ .epoch = .{ .adapter = 7, .device = 11, .reset = 6 }, .engines = 1 }, a.gfx_queue_result_cancelled));
    try Test.runtime.timeline.abort(.{ .epoch = Test.runtime.timeline.epoch, .engines = 1 }, a.gfx_queue_result_cancelled);
    try t.expect(Test.runtime.timeline.publish(Test.runtime.queue.?));
    try t.expectEqual(a.gfx_queue_result_timeout, Test.last_result);
    // Unsupported tiled / out-of-bounds / same-object copies never ring.
    for (0..4) |case| {
        try Test.reset();
        switch (case) {
            0 => Test.descriptors[1].modifier = 1,
            1 => Test.request.source_offset = 4999,
            2 => Test.request.target_buffer = Test.request.source_buffer,
            3 => Test.request.fence.reset_generation = 6,
            else => unreachable,
        }
        Test.submit();
        Owner.work(&Test.runtime, @intFromPtr(&Test.owner));
        try t.expect(Test.owner.engine.ring.write == 0 and Test.completed == 1 and Test.memory.mapping_users == 0 and !Test.active);
    }
    // Actual outer shutdown: park proofs precede callbacks, and a BO release
    // that recovers after the hardware deadline must not repeat the park wait.
    try Test.reset();
    Test.submit();
    Test.memory.engine_users = 1;
    Test.runtime.arena.arena.memory = Test.memory.memory;
    Test.runtime.arena.doorbell.memory = Test.memory.memory;
    Test.owner.engine.touched = true;
    const sr = @import("start_registers.zig").sdma;
    Test.regs[sr.SDMA0_STATUS_REG / 4] = sr.SDMA0_STATUS_REG__IDLE_MASK | sr.SDMA0_STATUS_REG__MC_RD_IDLE_MASK | sr.SDMA0_STATUS_REG__MC_WR_IDLE_MASK;
    Test.release_fail = true;
    try t.expect(!Test.owner.close());
    Test.time += 100000;
    try t.expect(!Test.owner.close());
    Test.time += 100000;
    try t.expect(!Test.owner.close());
    try t.expect(Test.owner.engine.quiesced and Test.owner.gc_stop.confirmed and Test.active and Test.unmapped == 0);
    Test.time += 1_000_000_000;
    Test.release_fail = false;
    try t.expect(Test.owner.close());
    try t.expect(Test.owner.closed and !Test.active and Test.unregistered and Test.unmapped == 2 and Test.memory.engine_users == 0 and Test.memory.mapping_users == 0);
    try t.expect(Test.owner.close());
    try t.expectEqual(@as(usize, 2), Test.unmapped);
}

test "SDMA startup requires real fill copy fence and consumed ring before provider activation" {
    const t = std.testing;
    const sr = @import("start_registers.zig").sdma;
    try Test.reset();
    Test.owner.verified = false;
    Test.owner.registered = false;
    try Test.owner.selftest();
    try t.expect(!try Test.owner.pollSelftest());
    const data = try Test.runtime.arena.words32(Owner.test_offset, 32);
    const ib = try Test.runtime.arena.ib(0);
    try t.expectEqual(@as(u32, 0x8000000b), ib[0]);
    try t.expectEqual(@as(u32, 1), ib[5]);
    data[0] = @truncate(Owner.test_token);
    data[1] = @truncate(Owner.test_token >> 32);
    try t.expectError(error.Unconfirmed, Test.owner.pollSelftest());
    for (data[2..6]) |*word| word.* = 0xa5c39e17;
    try t.expect(!try Test.owner.pollSelftest()); // fence alone cannot reclaim IB0
    Test.regs[sr.SDMA0_GFX_RB_RPTR / 4] = 128;
    try t.expect(try Test.owner.pollSelftest());
    try t.expect(Test.owner.verified and !Test.owner.registered and !Test.owner.active);
    try Test.reset();
    Test.owner.verified = false;
    Test.owner.registered = false;
    try Test.owner.selftest();
    Test.time += 2_000_000_000;
    try t.expectError(error.Deadline, Test.owner.pollSelftest());
    try t.expect(Test.owner.selftest_submitted and !Test.owner.verified and Test.owner.engine.ring.write == 32);
}
