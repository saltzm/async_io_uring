const std = @import("std");
const IO_Uring = std.os.linux.IO_Uring;
const assert = std.debug.assert;
const net = std.net;
const os = std.os;
const linux = os.linux;

const io = @import("async_io_uring");
const AsyncIOUring = io.AsyncIOUring;
const AsyncWriter = @import("async_writer.zig").AsyncWriter;

// Echo client. Reads a string from stdin, sends it to the server, and prints
// the response.
//
// Note to the reader: CQE stands for completion queue entry in variable names.
// This is the data structure returned by the kernel when an io_uring event is
// complete.
pub fn run_client(ring: *AsyncIOUring) !void {
    var writer = AsyncWriter{ .ring = ring };
    // TODO: This init pattern is a little weird. Fix it.
    try writer.init(std.io.getStdErr().handle);

    // Address of the echo server.
    const address = try net.Address.parseIp4("127.0.0.1", 3131);

    // Open a socket for connecting to the server.
    const server = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    defer {
        writer.print("Closing connection\n", .{}) catch {
            std.debug.print("Error logging connection closure\n", .{});
            std.os.exit(1);
        };

        _ = ring.close(server) catch {
            std.debug.print("Error closing\n", .{});
            std.os.exit(1);
        };
    }

    // Connect to the server.
    _ = try ring.connect(server, &address.any, address.getOsSockLen());

    const stdin_file = std.io.getStdIn();
    const stdin_fd = stdin_file.handle;
    var input_buffer: [256]u8 = undefined;

    while (true) {
        // Prompt the user for input.
        try writer.print("Input: ", .{});

        const read_timeout = os.linux.kernel_timespec{ .tv_sec = 10, .tv_nsec = 0 };
        // Read a line from stdin with a 10 second timeout.
        const read_cqe = ring.do(
            io.Read{ .fd = stdin_fd, .buffer = input_buffer[0..], .offset = input_buffer.len },
            io.Timeout{
                .ts = &read_timeout,
                .flags = 0,
            },
            null,
        ) catch |err| {
            if (err == error.Cancelled) {
                try writer.print("\nTimed out waiting for input, exiting...\n", .{});
                return;
            } else return err;
        };

        const num_bytes_read = @intCast(usize, read_cqe.res);

        // Send it to the server.
        _ = try ring.send(server, input_buffer[0..num_bytes_read], 0);

        // Receive response.
        const recv_cqe = try ring.do(io.Recv{ .fd = server, .buffer = input_buffer[0..], .flags = 0 }, null, null);

        const num_bytes_received = @intCast(usize, recv_cqe.res);
        try writer.print("Received: {s}\n", .{input_buffer[0..num_bytes_received]});
    }
}

pub fn main() !void {
    var ring = try IO_Uring.init(16, 0);
    defer ring.deinit();

    var async_ring = AsyncIOUring{ .ring = &ring };

    var client_frame = async run_client(&async_ring);

    try async_ring.run_event_loop();
    // Important for propagating any errors received in run_client.
    try nosuspend await client_frame;
}
