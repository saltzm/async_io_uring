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

// WHAT NEXT:
//  * Handle errors properly
//  * Handle connection closure
//  * Make into a KV store?
//      * First in-mem
//      * Then on-disk
//  * Figure out how to unit test?

pub fn handle_connection(ring: *AsyncIOUring, client: os.fd_t, conn_idx: u64, closed_conns: *[1000]u64, num_closed_conns: *usize) !void {
    defer {
        // TODO expose close
        _ = ring.ring.close(0, client) catch |err| {
            std.debug.print("Error closing\n", .{});
            std.os.exit(1);
        };
        closed_conns[num_closed_conns.*] = conn_idx;
        num_closed_conns.* += 1;
    }

    // Receive
    var buffer_recv: [256]u8 = undefined;

    while (true) {
        const cqe_recv = try ring.recv(client, buffer_recv[0..], 0);
        if (cqe_recv.res <= 0) {
            std.debug.print("Closing connection\n", .{});
            break;
        }
        const num_bytes_received = @intCast(usize, cqe_recv.res);
        // std.debug.print("Received: {s}\n", .{buffer_recv[0..num_bytes_received]});
        // std.debug.print("Sending {s} to client {}\n", .{ buffer_recv[0..num_bytes_received], client });

        // This is async!
        const result = try ring.send(client, buffer_recv[0..num_bytes_received], 0);
    }
}

pub fn acceptor(ring: *AsyncIOUring, server: os.fd_t) !void {
    var open_conns: [1000]@Frame(handle_connection) = undefined;
    var closed_conns: [1000]u64 = undefined;
    var num_open_conns: usize = 0;
    var num_closed_conns: usize = 0;
    while (true) {
        var accept_addr: os.sockaddr = undefined;
        var accept_addr_len: os.socklen_t = @sizeOf(@TypeOf(accept_addr));

        std.debug.print("Accepting\n", .{});

        // This is async!
        var new_conn = try ring.accept(server, &accept_addr, &accept_addr_len, 0);

        const can_reuse_conn = num_closed_conns > 0;
        const this_conn_idx = if (can_reuse_conn) closed_conns[num_closed_conns - 1] else num_open_conns;
        std.debug.print("Spawning new connection with index: {} \n", .{this_conn_idx});

        // Spawns a new connection in a different coroutine
        open_conns[this_conn_idx] = async handle_connection(ring, new_conn.res, this_conn_idx, &closed_conns, &num_closed_conns);
        if (can_reuse_conn) {
            num_closed_conns -= 1;
        } else {
            num_open_conns += 1;
        }
    }
}

pub fn server_loop() !void {
    var ring = try IO_Uring.init(16, 0);
    defer ring.deinit();

    var async_ring = AsyncIOUring{ .ring = &ring };

    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const kernel_backlog = 1;
    const server = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);
    defer os.close(server);
    try os.setsockopt(server, os.SOL_SOCKET, os.SO_REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try os.bind(server, &address.any, address.getOsSockLen());
    try os.listen(server, kernel_backlog);

    var acceptor_done = async acceptor(&async_ring, server);

    try async_ring.run_event_loop();
    try await acceptor_done;
}

pub fn main() !void {
    _ = async server_loop();
}
