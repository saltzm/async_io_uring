const std = @import("std");
const IO_Uring = std.os.linux.IO_Uring;
const assert = std.debug.assert;
const builtin = std.builtin;
const mem = std.mem;
const net = std.net;
const os = std.os;
const linux = os.linux;
const testing = std.testing;

// TODO
usingnamespace @import("async_io_uring.zig");

pub fn client_loop(ring: *IO_Uring) !void {
    const address = try net.Address.parseIp4("127.0.0.1", 3131);

    const client = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);
    defer os.close(client);

    const cqe_connect = try AsyncIOUring.connect(ring, client, &address.any, address.getOsSockLen());
    assert(cqe_connect.res == 0);
    // Wait for stdin
    const stdin_file = std.io.getStdIn();
    const stdin_fd = stdin_file.handle;
    var buffer_read: [256]u8 = undefined;

    while (true) {
        std.debug.print("About to read\n", .{});
        const sqe_read = try ring.read(0, stdin_fd, buffer_read[0..], buffer_read.len);
        _ = try ring.submit();
        std.debug.print("About to read 2\n", .{});
        const cqe_read = try ring.copy_cqe();
        std.debug.print("About to read 3\n", .{});
        const num_bytes_read = @intCast(usize, cqe_read.res);

        // Send
        //    const hello = "hello!";
        const send_result = try AsyncIOUring.send(ring, client, buffer_read[0..num_bytes_read], @intCast(u32, num_bytes_read));
        assert(send_result.res == num_bytes_read);

        // Receive
        var buffer_recv: [256]u8 = undefined;
        const cqe_recv = try AsyncIOUring.recv(ring, client, buffer_recv[0..], 0);
        const num_bytes_received = @intCast(usize, cqe_recv.res);
        std.debug.print("Received: {s}\n", .{buffer_recv[0..num_bytes_received]});
    }
}

pub fn main() !void {
    var ring = try IO_Uring.init(16, 0);
    defer ring.deinit();

    _ = async client_loop(&ring);
    try AsyncIOUring.run_event_loop(&ring);
}
