const std = @import("std");
const RingBuffer = @import("ring_buffer.zig").RingBuffer;

pub const AsyncMutex = struct {
    is_locked: bool = false,
    // TODO: Make size of this configurable or use a growable buffer.
    waiters: RingBuffer(anyframe, 1024) = .{},

    const Self = @This();

    pub fn lock(self: *Self) !void {
        if (self.is_locked) {
            suspend {
                try self.waiters.enqueue(@frame());
            }
        }
        std.debug.assert(!self.is_locked);
        self.is_locked = true;
    }

    pub fn unlock(self: *Self) !void {
        std.debug.assert(self.is_locked);
        self.is_locked = false;
        if (self.waiters.getSize() > 0) {
            resume try self.waiters.dequeue();
        }
    }
};

fn takeLock(mutex: *AsyncMutex, got_lock: *bool) !void {
    try mutex.lock();
    got_lock.* = true;
    try mutex.unlock();
}

fn testAsyncMutexSingleWaiter() !void {
    var mutex = AsyncMutex{};
    var got_lock = false;

    // Lock from this thread.
    try mutex.lock();

    // Kick off async task to try to take the lock and set got_lock to true.
    _ = async takeLock(&mutex, &got_lock);

    // Should still be false because this thread still is holding the lock.
    try std.testing.expectEqual(got_lock, false);

    // This will resume the code inside takeLock.
    try mutex.unlock();

    try std.testing.expectEqual(got_lock, true);
}

fn takeLockMulti(mutex: *AsyncMutex, id: usize, lock_order: *RingBuffer(usize, 3)) !void {
    try mutex.lock();
    try lock_order.enqueue(id);
    try mutex.unlock();
}

fn testAsyncMutexMultiWaiter() !void {
    var mutex = AsyncMutex{};

    // Lock from this thread.
    try mutex.lock();

    var lock_order = RingBuffer(usize, 3){};

    // Kick off async tasks to try to take the lock and enqueue themselves in
    // the lock order.
    var f1 = async takeLockMulti(&mutex, 0, &lock_order);
    var f2 = async takeLockMulti(&mutex, 1, &lock_order);
    var f3 = async takeLockMulti(&mutex, 2, &lock_order);

    // Should still be false because this thread still is holding the lock.
    try std.testing.expectEqual(lock_order.getSize(), 0);

    // This will resume the code inside the first call to takeLockMulti, which
    // in turn will resume the other waiting coroutines.
    try mutex.unlock();

    try nosuspend await f1;
    try nosuspend await f2;
    try nosuspend await f3;

    try std.testing.expectEqual(lock_order.dequeue(), 0);
    try std.testing.expectEqual(lock_order.dequeue(), 1);
    try std.testing.expectEqual(lock_order.dequeue(), 2);
}

test "async mutex single waiter" {
    var f = async testAsyncMutexSingleWaiter();
    try nosuspend await f;
}

test "async mutex multi waiter" {
    var f = async testAsyncMutexMultiWaiter();
    try nosuspend await f;
}

// TODO: Add a test where a function suspends while holding the lock.
