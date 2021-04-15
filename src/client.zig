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

pub fn handle_connection(ring: *IO_Uring, client: os.fd_t) !void {
    defer {
        _ = ring.close(0, client) catch |err| {
            std.debug.print("Error closing\n", .{});
            std.os.exit(1);
        };
    }

    std.debug.print("Sending\n", .{});
    const buffer_send = "hello!";
    // This is async!
    const result = try AsyncIOUring.send(ring, client, buffer_send[0..], 0);
}

pub fn acceptor(ring: *IO_Uring, server: os.fd_t) !void {
    while (true) {
        var accept_addr: os.sockaddr = undefined;
        var accept_addr_len: os.socklen_t = @sizeOf(@TypeOf(accept_addr));

        std.debug.print("Accepting\n", .{});

        // This is async!
        var new_conn = try AsyncIOUring.accept(ring, server, &accept_addr, &accept_addr_len, 0);

        // Spawns a new connection in a different coroutine.
        try handle_connection(ring, new_conn.res);
    }
}

pub fn client_loop(ring: *IO_Uring) !void {
    const address = try net.Address.parseIp4("127.0.0.1", 3131);

    const client = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);
    defer os.close(client);

    //const connect = try ring.connect(0xcccccccc, client, &address.any, address.getOsSockLen());
    const cqe_connect = try AsyncIOUring.connect(ring, client, &address.any, address.getOsSockLen());
    //_ = try ring.submit();
    //var cqe_connect = try ring.copy_cqe();
    assert(cqe_connect.res == 0);

    var server_fd = cqe_connect.res;

    // Send
    const hello = "hello!";
    const send_result = try AsyncIOUring.send(ring, client, hello[0..], 0);
    assert(send_result.res == hello.len);

    // Receive
    var buffer_recv: [256]u8 = undefined;
    const cqe_recv = try AsyncIOUring.recv(ring, client, buffer_recv[0..], 0);

    const num_bytes_received = @intCast(usize, cqe_recv.res);
    std.debug.print("Received: {s}\n", .{buffer_recv[0..num_bytes_received]});
}

pub fn main() !void {
    var ring = try IO_Uring.init(16, 0);
    defer ring.deinit();

    _ = async client_loop(&ring);
    try AsyncIOUring.run_event_loop(&ring);
}
