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
usingnamespace @import("./async_io_uring.zig");

pub fn handle_connection(ring: *IO_Uring, client: os.fd_t) !void {
    defer {
        _ = ring.close(0, client) catch |err| {
            std.debug.print("Error closing\n", .{});
            std.os.exit(1);
        };
    }
    // Receive
    var buffer_recv: [256]u8 = undefined;

    while (true) {
        const cqe_recv = try AsyncIOUring.recv(ring, client, buffer_recv[0..], 0);
        if (cqe_recv.res <= 0) {
            std.debug.print("Closing connection\n", .{});
            break;
        }
        const num_bytes_received = @intCast(usize, cqe_recv.res);
        // std.debug.print("Received: {s}\n", .{buffer_recv[0..num_bytes_received]});
        // std.debug.print("Sending {s} to client {}\n", .{ buffer_recv[0..num_bytes_received], client });

        // This is async!
        const result = try AsyncIOUring.send(ring, client, buffer_recv[0..num_bytes_received], 0);
    }
}

pub fn acceptor(ring: *IO_Uring, server: os.fd_t) !void {
    var open_conns: [16]@Frame(handle_connection) = undefined;
    var num_open_conns: u64 = 0;
    while (true) {
        var accept_addr: os.sockaddr = undefined;
        var accept_addr_len: os.socklen_t = @sizeOf(@TypeOf(accept_addr));

        std.debug.print("Accepting\n", .{});

        // This is async!
        var new_conn = try AsyncIOUring.accept(ring, server, &accept_addr, &accept_addr_len, 0);

        // Spawns a new connection in a different coroutine.
        open_conns[num_open_conns] = async handle_connection(ring, new_conn.res);
        num_open_conns += 1;
        // TODO handle when connection closes
    }
}

pub fn server_loop() !void {
    var ring = try IO_Uring.init(16, 0);
    defer ring.deinit();

    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const kernel_backlog = 1;
    const server = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);
    defer os.close(server);
    try os.setsockopt(server, os.SOL_SOCKET, os.SO_REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try os.bind(server, &address.any, address.getOsSockLen());
    try os.listen(server, kernel_backlog);

    var acceptor_done = async acceptor(&ring, server);

    try AsyncIOUring.run_event_loop(&ring);
    try await acceptor_done;
}

pub fn main() !void {
    _ = async server_loop();
}
