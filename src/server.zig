const std = @import("std");
const IO_Uring = std.os.linux.IO_Uring;
const assert = std.debug.assert;
const builtin = std.builtin;
const mem = std.mem;
const net = std.net;
const os = std.os;
const linux = os.linux;
const testing = std.testing;

const aiou = @import("async_io_uring.zig");
const AsyncIOUring = aiou.AsyncIOUring;
const NoUserData = aiou.NoUserData;

// Currently the number of max connections is hardcoded. This allows you to
// avoid heap allocation in growing and shrinking the list of active connections.
const max_connections = 1000;

// Does the main echo server loop for a single connection, recieving and
// echoing input over the file descriptor for the client.
pub fn handle_connection(ring: *AsyncIOUring, client: os.fd_t, conn_idx: u64, closed_conns: *[max_connections]u64, num_closed_conns: *usize) !void {
    defer {
        std.debug.print("Closing connection with index {}\n", .{conn_idx});
        // TODO: Expose close on AsyncIOUring.
        _ = ring.ring.close(0, client) catch |err| {
            std.debug.print("Error closing\n", .{});
            std.os.exit(1);
        };
        // Return this connection index to the list of free connection indices.
        closed_conns[num_closed_conns.*] = conn_idx;
        num_closed_conns.* += 1;
    }

    // Used to send and receive.
    var buffer: [256]u8 = undefined;

    // Loop until the connection is closed, receiving input and sending back
    // that input as output.
    while (true) {
        const recv_cqe = try ring.recv(NoUserData, client, buffer[0..], 0);

        const num_bytes_received = @intCast(usize, recv_cqe.res);

        _ = try ring.send(NoUserData, client, buffer[0..num_bytes_received], 0);
    }
}

// Loops accepting new connections and spawning new coroutines to handle those
// connections.
pub fn run_acceptor_loop(ring: *AsyncIOUring, server: os.fd_t) !void {
    // TODO: Put this in a struct and abstract away some of the connection
    // tracking.
    var open_conns: [max_connections]@Frame(handle_connection) = undefined;
    var closed_conns: [max_connections]u64 = undefined;
    var num_open_conns: usize = 0;
    var num_closed_conns: usize = 0;

    while (true) {
        std.debug.print("Accepting\n", .{});

        var accept_addr: os.sockaddr = undefined;
        var accept_addr_len: os.socklen_t = @sizeOf(@TypeOf(accept_addr));

        // Wait for a new connection request.
        var accept_cqe = try ring.accept(NoUserData, server, &accept_addr, &accept_addr_len, 0);
        var new_conn_fd = accept_cqe.res;

        // Get an index in the array of open connections for this new
        // connection.
        const this_conn_idx = blk: {
            if (num_closed_conns > 0) {
                // Reuse the last closed connection's index and decrement the
                // number of closed connections.
                num_closed_conns -= 1;
                break :blk closed_conns[num_closed_conns];
            } else {
                const next_idx = num_open_conns;
                // We need to expand the number of open connections.
                num_open_conns += 1;
                break :blk next_idx;
            }
        };

        std.debug.print("Spawning new connection with index: {} \n", .{this_conn_idx});

        // Spawns a new connection handler in a different coroutine.
        open_conns[this_conn_idx] = async handle_connection(ring, new_conn_fd, this_conn_idx, &closed_conns, &num_closed_conns);
    }

    // This isn't really needed since this only happens at process shutdown,
    // but why not.
    for (open_conns[0..num_open_conns]) |conn| {
        await conn;
    }
}

// Open a socket and run the echo server listening on that socket.
pub fn run_server(ring: *AsyncIOUring) !void {
    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const kernel_backlog = 1;
    const server = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);
    defer os.close(server);
    try os.setsockopt(server, os.SOL_SOCKET, os.SO_REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try os.bind(server, &address.any, address.getOsSockLen());
    try os.listen(server, kernel_backlog);

    try run_acceptor_loop(ring, server);
}

pub fn main() !void {
    var ring = try IO_Uring.init(128, 0);
    defer ring.deinit();

    var async_ring = AsyncIOUring{ .ring = &ring };

    _ = async run_server(&async_ring);

    try async_ring.run_event_loop();
}
