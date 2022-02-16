const std = @import("std");
const builtin = @import("builtin");
const IO_Uring = std.os.linux.IO_Uring;
const os = std.os;
const testing = std.testing;

const aiou = @import("async_io_uring");
const AsyncIOUring = aiou.AsyncIOUring;

pub const AsyncWriter = struct {
    const Self = @This();

    ring: *AsyncIOUring,
    writer: std.io.Writer(AsyncWriterContext, ErrorSetOf(asyncWrite), asyncWrite) = undefined,

    /// Expects fd to be already open for appending.
    pub fn init(self: *Self, fd: os.fd_t) !void {
        self.writer = asyncWriter(self.ring, fd);
    }

    pub fn print(self: @This(), comptime format: []const u8, args: anytype) !void {
        try self.writer.print(format, args);
    }
};

const AsyncWriterContext = struct { ring: *AsyncIOUring, fd: os.fd_t };

fn asyncWrite(context: AsyncWriterContext, buffer: []const u8) !usize {
    const cqe = try context.ring.write(context.fd, buffer, 0);
    return @intCast(usize, cqe.res);
}

/// TODO Copied from x/net/tcp.zig
fn ErrorSetOf(comptime Function: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(Function)).Fn.return_type.?).ErrorUnion.error_set;
}

/// Wrap `tcp.Client` into `std.io.Writer`.
fn asyncWriter(ring: *AsyncIOUring, fd: os.fd_t) std.io.Writer(AsyncWriterContext, ErrorSetOf(asyncWrite), asyncWrite) {
    return .{ .context = .{ .ring = ring, .fd = fd } };
}

pub fn print(ring: *AsyncIOUring, comptime format: []const u8, args: anytype) !void {
    var writer = asyncWriter(ring, std.io.getStdErr().handle);
    try writer.print(format, args);
}

// TODO: This isn't really a test.
test "async writer" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(4, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    var async_ring = AsyncIOUring{ .ring = &ring };

    var logger = AsyncWriter{ .ring = &async_ring };
    try logger.init(std.io.getStdErr().handle);

    const something = 9;
    var print_frame = async logger.print("\n something: {}\n", .{something});

    // This should submit the write and wait for it to occur.
    try async_ring.run_event_loop();

    try nosuspend await print_frame;
}
