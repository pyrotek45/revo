const std = @import("std");

const root = @import("root.zig");
const Data = root.Data;
const VM = root.VM;
const Fiber = VM.Fiber;
const FiberID = VM.FiberID;
const ChannelID = VM.ChannelID;

pub const Scheduler = @This();

pub const ChannelWaiter = struct {
    fiber_id: FiberID,
    value: ?Data = null,
};

pub const ChannelState = struct {
    cap: usize = 0,
    queue: std.ArrayList(Data),
    queue_head: usize = 0,
    send_waiters: std.ArrayList(ChannelWaiter),
    send_head: usize = 0,
    recv_waiters: std.ArrayList(ChannelWaiter),
    recv_head: usize = 0,

    pub fn init(alloc: std.mem.Allocator, cap: usize) !ChannelState {
        return .{
            .cap = cap,
            .queue = try std.ArrayList(Data).initCapacity(alloc, if (cap == 0) 1 else cap),
            .send_waiters = try std.ArrayList(ChannelWaiter).initCapacity(alloc, 2),
            .recv_waiters = try std.ArrayList(ChannelWaiter).initCapacity(alloc, 2),
        };
    }

    pub fn deinit(self: *ChannelState, alloc: std.mem.Allocator) void {
        self.queue.deinit(alloc);
        self.send_waiters.deinit(alloc);
        self.recv_waiters.deinit(alloc);
    }

    fn queueLen(self: *const ChannelState) usize {
        return self.queue.items.len - self.queue_head;
    }

    fn pushQueue(self: *ChannelState, alloc: std.mem.Allocator, value: Data) !void {
        try self.queue.append(alloc, value);
    }

    fn popQueue(self: *ChannelState) ?Data {
        if (self.queue_head >= self.queue.items.len) return null;
        const value = self.queue.items[self.queue_head];
        self.queue_head += 1;
        maybeCompactList(Data, &self.queue, &self.queue_head);
        return value;
    }

    fn popSendWaiter(self: *ChannelState) ?ChannelWaiter {
        if (self.send_head >= self.send_waiters.items.len) return null;
        const waiter = self.send_waiters.items[self.send_head];
        self.send_head += 1;
        maybeCompactList(ChannelWaiter, &self.send_waiters, &self.send_head);
        return waiter;
    }

    fn popRecvWaiter(self: *ChannelState) ?ChannelWaiter {
        if (self.recv_head >= self.recv_waiters.items.len) return null;
        const waiter = self.recv_waiters.items[self.recv_head];
        self.recv_head += 1;
        maybeCompactList(ChannelWaiter, &self.recv_waiters, &self.recv_head);
        return waiter;
    }
};

fn maybeCompactList(comptime T: type, list: *std.ArrayList(T), head: *usize) void {
    if (head.* == 0) return;
    if (head.* < list.items.len / 2) return;
    const remaining = list.items.len - head.*;
    std.mem.copyForwards(T, list.items[0..remaining], list.items[head.*..]);
    list.items.len = remaining;
    head.* = 0;
}

pub const SleepWaiter = struct {
    fiber_id: FiberID,
    wake_at_ns: u64,
};

current_fiber: FiberID,
fibers: std.ArrayList(Fiber),
runq: std.ArrayList(FiberID),
runq_head: usize,
sleepers: std.ArrayList(SleepWaiter),
channels: std.AutoHashMap(ChannelID, ChannelState),

pub fn init(alloc: std.mem.Allocator) !@This() {
    return .{
        .current_fiber = 0,
        .fibers = try std.ArrayList(Fiber).initCapacity(alloc, 1),
        .runq = try std.ArrayList(FiberID).initCapacity(alloc, 4),
        .runq_head = 0,
        .sleepers = try std.ArrayList(SleepWaiter).initCapacity(alloc, 4),
        .channels = std.AutoHashMap(ChannelID, ChannelState).init(alloc),
    };
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    for (self.fibers.items) |*fiber| fiber.deinit(alloc);
    self.fibers.deinit(alloc);
    self.runq.deinit(alloc);
    self.sleepers.deinit(alloc);
    var channel_it = self.channels.valueIterator();
    while (channel_it.next()) |channel| channel.deinit(alloc);
    self.channels.deinit();
}

pub fn currentFiber(self: *@This()) *Fiber {
    return &self.fibers.items[self.current_fiber];
}

pub fn mainFiber(self: *@This()) *Fiber {
    return &self.fibers.items[0];
}

pub fn enqueueRunnable(self: *@This(), alloc: std.mem.Allocator, fid: FiberID) !void {
    if (fid >= self.fibers.items.len) return;
    const fiber = &self.fibers.items[fid];
    if (fiber.in_runq or fiber.state != .ready) return;
    try self.runq.append(alloc, fid);
    fiber.in_runq = true;
}

pub fn dequeueRunnable(self: *@This()) ?FiberID {
    while (self.runq_head < self.runq.items.len) {
        const fid = self.runq.items[self.runq_head];
        self.runq_head += 1;
        self.fibers.items[fid].in_runq = false;
        return fid;
    }
    if (self.runq_head > 0) {
        self.runq.items.len = 0;
        self.runq_head = 0;
    }
    return null;
}

pub fn finishFiber(self: *@This(), alloc: std.mem.Allocator, fid: FiberID, result: Data) !void {
    var fiber = &self.fibers.items[fid];
    fiber.result = result;
    fiber.running = false;
    fiber.state = .dead;
    fiber.wait = .none;
    for (fiber.waiters.items) |waiter_id| {
        var waiter = &self.fibers.items[waiter_id];
        if (waiter.state == .waiting) {
            if (waiter.parked_result_slot) |slot| {
                waiter.slots.items[slot] = fiber.result;
            } else {
                try waiter.slots.append(alloc, fiber.result);
            }
            waiter.state = .ready;
            waiter.running = false;
            waiter.wait = .none;
            waiter.parked_result_slot = null;
            try self.enqueueRunnable(alloc, waiter_id);
        }
    }
    fiber.waiters.items.len = 0;
}

pub fn parkCurrentForSleepMS(self: *@This(), alloc: std.mem.Allocator, ms: u64, now_ns: u64) !void {
    const wake_at = now_ns + (ms * std.time.ns_per_ms);
    try self.sleepers.append(alloc, .{ .fiber_id = self.current_fiber, .wake_at_ns = wake_at });
    const fiber = self.currentFiber();
    fiber.state = .waiting;
    fiber.running = false;
    fiber.wait = .sleep;
}

pub fn wakeDueSleepers(self: *@This(), alloc: std.mem.Allocator, now_ns: u64) !void {
    var i: usize = 0;
    while (i < self.sleepers.items.len) {
        const sleeper = self.sleepers.items[i];
        if (sleeper.wake_at_ns <= now_ns) {
            _ = self.sleepers.swapRemove(i);
            var fiber = &self.fibers.items[sleeper.fiber_id];
            if (fiber.state == .waiting) {
                fiber.state = .ready;
                fiber.running = false;
                fiber.wait = .none;
                fiber.parked_result_slot = null;
                try self.enqueueRunnable(alloc, sleeper.fiber_id);
            }
            continue;
        }
        i += 1;
    }
}

pub fn nextSleepDelayNs(self: *@This(), now_ns: u64) ?u64 {
    if (self.sleepers.items.len == 0) return null;
    var min_wake = self.sleepers.items[0].wake_at_ns;
    for (self.sleepers.items[1..]) |sleeper| {
        if (sleeper.wake_at_ns < min_wake) min_wake = sleeper.wake_at_ns;
    }
    if (min_wake <= now_ns) return 0;
    return min_wake - now_ns;
}

pub fn channelCreate(
    self: *@This(),
    alloc: std.mem.Allocator,
    tables: anytype,
    cap: usize,
) !ChannelID {
    const id = try tables.create();
    var state = try ChannelState.init(alloc, cap);
    errdefer state.deinit(alloc);
    try self.channels.put(id, state);
    return id;
}

pub fn channelSend(
    self: *@This(),
    alloc: std.mem.Allocator,
    channel_id: ChannelID,
    value: Data,
) !void {
    var channel = self.channels.getPtr(channel_id) orelse return error.InvalidChannel;

    // maybe wake receiver, but validate fiber is still valid and waiting
    while (channel.popRecvWaiter()) |waiter| {
        // fiber id might be stale
        if (waiter.fiber_id >= self.fibers.items.len) continue;
        var recv_fiber = &self.fibers.items[waiter.fiber_id];
        // fiber must still be waiting on this channel
        if (recv_fiber.state != .waiting) continue;
        const waiting_on_recv = switch (recv_fiber.wait) {
            Fiber.WaitKind.recv => |cid| cid == channel_id,
            else => false,
        };
        if (!waiting_on_recv) continue;
        //
        // alr this is a valid waiter! wake it
        if (recv_fiber.parked_result_slot) |slot| {
            recv_fiber.slots.items[slot] = value;
            recv_fiber.parked_result_slot = null;
        } else {
            try recv_fiber.slots.append(alloc, value);
        }
        recv_fiber.state = .ready;
        recv_fiber.running = false;
        recv_fiber.wait = .none;
        try self.enqueueRunnable(alloc, waiter.fiber_id);
        return;
    }

    if (channel.cap > 0 and channel.queueLen() < channel.cap) {
        try channel.pushQueue(alloc, value);
        return;
    }

    try channel.send_waiters.append(alloc, .{ .fiber_id = self.current_fiber, .value = value });
    const fiber = self.currentFiber();
    fiber.state = .waiting;
    fiber.running = false;
    fiber.wait = .{ .send = channel_id };
}

pub fn channelRecv(self: *@This(), alloc: std.mem.Allocator, channel_id: ChannelID) !?Data {
    var channel = self.channels.getPtr(channel_id) orelse return error.InvalidChannel;

    if (channel.queueLen() > 0) {
        const value = channel.popQueue().?;

        // maybe wake sender, if fiber is still valid
        while (channel.cap > 0 and channel.queueLen() < channel.cap) {
            const sender = channel.popSendWaiter() orelse break;
            if (sender.fiber_id >= self.fibers.items.len) continue;
            var sender_fiber = &self.fibers.items[sender.fiber_id];
            if (sender_fiber.state != .waiting) continue;
            const waiting_on_send = switch (sender_fiber.wait) {
                Fiber.WaitKind.send => |cid| cid == channel_id,
                else => false,
            };
            if (!waiting_on_send) continue;
            try channel.pushQueue(alloc, sender.value.?);
            sender_fiber.state = .ready;
            sender_fiber.running = false;
            sender_fiber.wait = .none;
            sender_fiber.parked_result_slot = null;
            try self.enqueueRunnable(alloc, sender.fiber_id);
            break;
        }
        return value;
    }

    // maybe wake sender directly
    while (channel.popSendWaiter()) |sender| {
        if (sender.fiber_id >= self.fibers.items.len) continue;
        var sender_fiber = &self.fibers.items[sender.fiber_id];
        if (sender_fiber.state != .waiting) continue;
        const waiting_on_send = switch (sender_fiber.wait) {
            Fiber.WaitKind.send => |cid| cid == channel_id,
            else => false,
        };
        if (!waiting_on_send) continue;
        sender_fiber.state = .ready;
        sender_fiber.running = false;
        sender_fiber.wait = .none;
        sender_fiber.parked_result_slot = null;
        try self.enqueueRunnable(alloc, sender.fiber_id);
        return sender.value.?;
    }

    try channel.recv_waiters.append(alloc, .{ .fiber_id = self.current_fiber });
    const fiber = self.currentFiber();
    fiber.state = .waiting;
    fiber.running = false;
    fiber.wait = .{ .recv = channel_id };
    return null;
}
