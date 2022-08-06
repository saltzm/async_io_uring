const std = @import("std");

/// Generic RingBuffer class with fixed size. Not thread-safe.
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        head: usize = 0,
        tail: usize = 0,
        size: usize = 0,
        data: [capacity]T = undefined,

        const Self = @This();

        pub fn getSize(self: Self) usize {
            return self.size;
        }

        /// Enqueues an item into the RingBuffer.
        pub fn enqueue(self: *Self, t: T) !void {
            if (self.getSize() == capacity) {
                return error.RingBufferFull;
            } else {
                self.data[self.tail] = t;
                self.tail = (self.tail + 1) % capacity;
                self.size += 1;
            }
        }

        /// Dequeues an item from the RingBuffer.
        /// TODO return optional?
        pub fn dequeue(self: *Self) !T {
            if (self.getSize() == 0) {
                return error.RingBufferEmpty;
            } else {
                var result = self.data[self.head];
                self.head = (self.head + 1) % capacity;
                self.size -= 1;
                return result;
            }
        }
    };
}

test "when RingBuffer is empty, size is 0" {
    var buf = RingBuffer(i32, 4){};
    try std.testing.expectEqual(buf.getSize(), 0);
}

test "when RingBuffer has one item and tail is > head, size is 1" {
    var buf = RingBuffer(i32, 4){};
    try buf.enqueue(3);
    try std.testing.expectEqual(buf.getSize(), 1);
}

test "when RingBuffer has one item and head < tail, size is 1" {
    var buf = RingBuffer(i32, 2){};
    try buf.enqueue(3); // head = 0, tail = 1
    _ = try buf.dequeue(); // head = 1, tail = 1
    try buf.enqueue(3); // head = 1, tail = 0
    try std.testing.expectEqual(buf.getSize(), 1);
}

test "when RingBuffer has no items and head == tail and head > 0, size is 0" {
    var buf = RingBuffer(i32, 2){};
    try buf.enqueue(3); // head = 0, tail = 1
    _ = try buf.dequeue(); // head = 1, tail = 1
    try std.testing.expectEqual(buf.getSize(), 0);
}

test "when RingBuffer is full, size is correct" {
    var buf = RingBuffer(i32, 2){};
    try buf.enqueue(3); // head = 0, tail = 1
    try buf.enqueue(4); // head = 0, tail = 0 // OOPS!
    try std.testing.expectEqual(buf.getSize(), 2);
}

test "when RingBuffer is full, dequeues are correct" {
    var buf = RingBuffer(i32, 2){};
    try buf.enqueue(3); // head = 0, tail = 1
    try buf.enqueue(4); // head = 0, tail = 0
    try std.testing.expectEqual(buf.dequeue(), 3);
    try std.testing.expectEqual(buf.dequeue(), 4);
}

test "when RingBuffer enqueues after having been full, dequeues are correct" {
    var buf = RingBuffer(i32, 2){};
    try buf.enqueue(3); // head = 0, tail = 1
    try buf.enqueue(4); // head = 0, tail = 0
    try std.testing.expectEqual(buf.dequeue(), 3); // head = 1, tail = 0
    try buf.enqueue(5); // head = 1, tail = 1
    try std.testing.expectEqual(buf.dequeue(), 4);
    try std.testing.expectEqual(buf.dequeue(), 5);
}

test "RingBuffer.enqueue increases size by 1" {
    var buf = RingBuffer(i32, 2){};
    const size = buf.getSize();
    try buf.enqueue(3);
    try std.testing.expectEqual(buf.getSize(), size + 1);
}

test "RingBuffer.dequeue decreases size by 1" {
    var buf = RingBuffer(i32, 2){};
    try buf.enqueue(3);
    const size = buf.getSize();
    _ = try buf.dequeue();
    try std.testing.expectEqual(buf.getSize(), size - 1);
}

test "RingBuffer.dequeue returns most recent element when tail > head" {
    var buf = RingBuffer(i32, 2){};
    const val_to_insert = 3;
    try buf.enqueue(val_to_insert);
    const val_dequeued = try buf.dequeue();
    try std.testing.expectEqual(val_dequeued, val_to_insert);
}

test "RingBuffer.dequeue returns most recent element when head > tail" {
    var buf = RingBuffer(i32, 2){};
    const val_to_insert = 3;
    try buf.enqueue(0);
    _ = try buf.dequeue();
    try buf.enqueue(val_to_insert); // head = 1, tail = 0
    const val_dequeued = try buf.dequeue();
    try std.testing.expectEqual(val_dequeued, val_to_insert);
}
