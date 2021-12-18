const std = @import("std");
const IO_Uring = std.os.linux.IO_Uring;
const assert = std.debug.assert;
const net = std.net;
const os = std.os;
const linux = os.linux;

const aiou = @import("async_io_uring.zig");
const AsyncIOUring = aiou.AsyncIOUring;
const NoUserData = aiou.NoUserData;

// Echo client. Reads a string from stdin, sends it to the server, and prints
// the response.
//
// Note to the reader: CQE stands for completion queue entry in variable names.
// This is the data structure returned by the kernel when an io_uring event is
// complete.
pub fn run_client(ring: *AsyncIOUring) !void {
    // Address of the echo server.
    const address = try net.Address.parseIp4("127.0.0.1",3131);

    // Open a socket for connecting to the server.
    const server = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);
    defer {
        std.debug.print("Closing connection\n", .{});
        // TODO: Expose close on AsyncIOUring.
        _ = ring.ring.close(0, server) catch |err| {
            std.debug.print("Error closing\n", .{});
            std.os.exit(1);
        };
    }

    // Connect to the server.
    _ = try ring.connect(NoUserData, server, &address.any, address.getOsSockLen());

    const stdin_file = std.io.getStdIn();
    const stdin_fd = stdin_file.handle;
    var input_buffer: [256]u8 = undefined;

    while (true) {
        // Read a line from stdin.
        std.debug.print("Input: ", .{});
        const read_cqe = try ring.read(NoUserData, stdin_fd, input_buffer[0..], input_buffer.len);
        const num_bytes_read = @intCast(usize, read_cqe.res);

        // Send it to the server.
        const send_result = try ring.send(NoUserData, server, input_buffer[0..num_bytes_read], 0);

        // Receive response.
        const recv_cqe = try ring.recv(NoUserData, server, input_buffer[0..], 0);
        const num_bytes_received = @intCast(usize, recv_cqe.res);
        std.debug.print("Received: {s}\n", .{input_buffer[0..num_bytes_received]});
    }
}

pub fn main() !void {
    var ring = try IO_Uring.init(16, 0);
    defer ring.deinit();

    var async_ring = AsyncIOUring{ .ring = &ring };

    _ = async run_client(&async_ring);

    try async_ring.run_event_loop();
}
