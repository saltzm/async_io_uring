const std = @import("std");
const IO_Uring = std.os.linux.IO_Uring;
const assert = std.debug.assert;
const net = std.net;
const os = std.os;
const linux = os.linux;

const AsyncIOUring = @import("async_io_uring.zig").AsyncIOUring;

// Echo client. Reads a string from stdin, sends it to the server, and prints
// the response.
//
// Note to the reader: CQE stands for completion queue entry in variable names.
// This is the data structure returned by the kernel when an io_uring event is
// complete.
pub fn client_loop(ring: *AsyncIOUring) !void {
    const address = try net.Address.parseIp4("127.0.0.1", 3131);

    const client = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);
    defer {
        std.debug.print("Closing connection\n", .{});
        // TODO: Expose close on AsyncIOUring.
        _ = ring.ring.close(0, client) catch |err| {
            std.debug.print("Error closing\n", .{});
            std.os.exit(1);
        };
    }

    const connect_cqe = try ring.connect(client, &address.any, address.getOsSockLen());
    assert(connect_cqe.res == 0);

    const stdin_file = std.io.getStdIn();
    const stdin_fd = stdin_file.handle;
    var input_buffer: [256]u8 = undefined;

    while (true) {
        std.debug.print("Input: ", .{});
        // Read something from stdin.
        const read_cqe = try ring.read(stdin_fd, input_buffer[0..], input_buffer.len);
        if (read_cqe.res < 0) {
            // TODO: Convert these errors into zig errors inside AsyncIOUring.
            break;
        }
        const num_bytes_read = @intCast(usize, read_cqe.res);

        // Send it to the server.
        const send_result = try ring.send(client, input_buffer[0..num_bytes_read], @intCast(u32, num_bytes_read));
        if (send_result.res != num_bytes_read) {
            break;
        }

        // Receive response.
        const recv_cqe = try ring.recv(client, input_buffer[0..], 0);
        if (recv_cqe.res <= 0) {
            break;
        }
        const num_bytes_received = @intCast(usize, recv_cqe.res);
        std.debug.print("Received: {s}\n", .{input_buffer[0..num_bytes_received]});
    }
}

pub fn main() !void {
    var ring = try IO_Uring.init(16, 0);
    defer ring.deinit();

    var async_ring = AsyncIOUring{ .ring = &ring };

    _ = async client_loop(&async_ring);

    try async_ring.run_event_loop();
}
