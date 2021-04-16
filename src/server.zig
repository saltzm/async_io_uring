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
const max_connections = 1; // 000;

// A silly type to keep track of which indexes are free in an array with size
// max_idx.
fn IndexAllocator(comptime max_idx: usize) type {
    return struct {
        const Self = @This();
        max_idx: usize = max_idx,
        free_list: [max_idx]u64 = undefined,
        num_allocated: usize = 0,
        num_free: usize = 0,

        pub fn alloc(self: *Self) ?usize {
            if (self.num_free > 0) {
                self.num_free -= 1;
                return self.free_list[self.num_free];
            } else {
                if (self.num_allocated == max_connections) {
                    return null;
                }
                const next_idx = self.num_allocated;
                self.num_allocated += 1;
                return next_idx;
            }
        }

        pub fn free(self: *Self, idx: usize) void {
            self.free_list[self.num_free] = idx;
            self.num_free += 1;
        }
    };
}

// Does the main echo server loop for a single connection, recieving and
// echoing input over the file descriptor for the client.
pub fn handle_connection(
    ring: *AsyncIOUring,
    client: os.fd_t,
    conn_idx_allocator: *IndexAllocator(max_connections),
    conn_idx: u64,
) !void {
    defer {
        std.debug.print("Closing connection with index {}\n", .{conn_idx});
        // TODO: Expose close on AsyncIOUring.
        _ = ring.ring.close(0, client) catch |err| {
            std.debug.print("Error closing\n", .{});
            std.os.exit(1);
        };
        // Return this connection index to the list of free connection indices.
        conn_idx_allocator.free(conn_idx);
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

    // Tracks which slots in open_conns are available. Silly way to avoid heap
    // allocation for open_conns. I can't put open_conns itself in another
    // struct because @Frame objects aren't copyable.
    var conn_idx_allocator = IndexAllocator(max_connections){};

    while (true) {
        std.debug.print("Accepting\n", .{});

        var accept_addr: os.sockaddr = undefined;
        var accept_addr_len: os.socklen_t = @sizeOf(@TypeOf(accept_addr));

        // Wait for a new connection request.
        var accept_cqe = try ring.accept(NoUserData, server, &accept_addr, &accept_addr_len, 0);
        var new_conn_fd = accept_cqe.res;

        // Get an open slot in open_conns with the IndexAllocator and launch a
        // coroutine to handle the connection.
        if (conn_idx_allocator.alloc()) |this_conn_idx| {
            std.debug.print("Spawning new connection with index: {} \n", .{this_conn_idx});

            // Spawns a new connection handler in a different coroutine.
            open_conns[this_conn_idx] = async handle_connection(ring, new_conn_fd, &conn_idx_allocator, this_conn_idx);
        } else {
            std.debug.print("Reached connection limit, refusing connection\n", .{});
            // We've reached the max number of connections, so close this one
            // right away.
            _ = try ring.ring.close(0, new_conn_fd);
        }
    }

    // This isn't really needed since this only happens at process shutdown,
    // but why not.
    for (open_conns[0..num_open_conns]) |conn| {
        await conn;
    }
}

// Open a socket and run the echo server listening on that socket. The server
// can handle up to max_connections concurrent connections, all in a single
// thread..
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
