const std = @import("std");
const IO_Uring = std.os.linux.IO_Uring;
const assert = std.debug.assert;
const builtin = std.builtin;
const mem = std.mem;
const net = std.net;
const os = std.os;
const linux = os.linux;
const testing = std.testing;
const Timer = std.time.Timer;

// TODO
usingnamespace @import("async_io_uring.zig");

pub fn benchmark(ring: *IO_Uring) !void {
    const address = try net.Address.parseIp4("127.0.0.1", 3131);

    const client = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);
    defer os.close(client);

    const cqe_connect = try AsyncIOUring.connect(ring, client, &address.any, address.getOsSockLen());
    assert(cqe_connect.res == 0);
    const buffer_read = "hello";

    var timer = try Timer.start();
    const start = timer.lap();
    var num_ops: u64 = 0;
    const max_ops = 100000;
    while (num_ops < max_ops) : (num_ops += 1) {
        const num_bytes_read = buffer_read.len;

        // Send it to the server.
        const send_result = try AsyncIOUring.send(ring, client, buffer_read[0..num_bytes_read], @intCast(u32, num_bytes_read));
        assert(send_result.res == num_bytes_read);

        // Receive
        var buffer_recv: [256]u8 = undefined;
        const cqe_recv = try AsyncIOUring.recv(ring, client, buffer_recv[0..], 0);
        const num_bytes_received = @intCast(usize, cqe_recv.res);
    }
    const end = timer.read();
    const elapsed_s = @intToFloat(f64, end - start) / std.time.ns_per_s;
    const ops_per_sec = max_ops / elapsed_s;
    std.debug.print("throughput: {d} ops per sec\n", .{ops_per_sec});
}

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

    var timer = try Timer.start();
    const start = timer.lap();
    var num_ops: u64 = 0;
    const max_ops = 100000;
    while (num_ops < max_ops) : (num_ops += 1) {
        // Read something from stdin. This is async :)
        const cqe_read = try AsyncIOUring.read(ring, stdin_fd, buffer_read[0..], buffer_read.len);
        const num_bytes_read = @intCast(usize, cqe_read.res);

        // Send it to the server.
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
