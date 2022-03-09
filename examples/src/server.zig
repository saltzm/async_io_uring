const std = @import("std");
const io = @import("async_io_uring");
const IO_Uring = std.os.linux.IO_Uring;
const assert = std.debug.assert;
const mem = std.mem;
const net = std.net;
const os = std.os;
const linux = os.linux;

const AsyncIOUring = io.AsyncIOUring;
const AsyncWriter = io.AsyncWriter;

// Currently the number of max connections is hardcoded. This allows you to
// avoid heap allocation in growing and shrinking the list of active connections.
const max_connections = 10000;

pub fn main() !void {
    const num_threads = 1;
    var threads: [num_threads]std.Thread = undefined;

    // Starts at 1 to reserve id 0 for the main thread.
    var i: u64 = 1;
    while (i < num_threads) : (i += 1) {
        std.debug.print("Spawning thread {}\n", .{i});
        threads[i] = try std.Thread.spawn(.{}, run_server_event_loop, .{i});
    }

    std.debug.print("Starting event loop in main thread (thread 0)\n", .{});

    // Use the main thread as an event loop as well.
    try run_server_event_loop(0);

    std.debug.print("Joining all threads\n", .{});
    for (threads) |t| {
        std.Thread.join(t);
    }
}

pub fn run_server_event_loop(id: u64) !void {
    var ring = try IO_Uring.init(4096, 0);
    defer ring.deinit();

    var async_ring = AsyncIOUring{ .ring = &ring };

    // The frame size is very large when the max number of connections is high.
    // We could increase stack size but for now we're just allocating it on the
    // heap - doesn't seem to have much of an affect on performance (and that
    // makes sense because we're only doing it once).
    const frame = try std.heap.page_allocator.create(@Frame(run_server));
    defer std.heap.page_allocator.destroy(frame);
    frame.* = async run_server(&async_ring, id);

    try async_ring.run_event_loop();
    try nosuspend await frame;
}

// Open a socket and run the echo server listening on that socket. The server
// can handle up to max_connections concurrent connections, all in a single
// thread..
pub fn run_server(ring: *AsyncIOUring, id: u64) !void {
    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const kernel_backlog = 1;
    const server = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    defer os.close(server);
    try os.setsockopt(server, os.SOL.SOCKET, os.SO.REUSEPORT, &mem.toBytes(@as(c_int, 1)));
    try os.bind(server, &address.any, address.getOsSockLen());
    try os.listen(server, kernel_backlog);

    try run_acceptor_loop(ring, server, id);
}

// Loops accepting new connections and spawning new coroutines to handle those
// connections.
pub fn run_acceptor_loop(ring: *AsyncIOUring, server: os.fd_t, _: u64) !void {
    // TODO: Put this in a struct and abstract away some of the connection
    // tracking.
    var open_conns: [max_connections]@Frame(handle_connection) = undefined;
    var closed_conns: [max_connections]u64 = undefined;
    var num_open_conns: usize = 0;
    var num_closed_conns: usize = 0;

    var writer = try AsyncWriter.init(ring, std.io.getStdErr().handle);

    while (true) {
        var accept_addr: os.sockaddr = undefined;
        var accept_addr_len: os.socklen_t = @sizeOf(@TypeOf(accept_addr));

        // Wait for a new connection request.
        var accept_cqe = ring.accept(server, &accept_addr, &accept_addr_len, 0, null, null) catch |err| {
            try writer.print("Error in run_acceptor_loop: accept {} \n", .{err});
            continue;
        };

        var new_conn_fd = accept_cqe.res;

        // Get an index in the array of open connections for this new
        // connection. If we already have max_connections open connections,
        // this_conn_idx will be null.
        const this_conn_idx = blk: {
            if (num_closed_conns > 0) {
                // Reuse the last closed connection's index and decrement the
                // number of closed connections.
                num_closed_conns -= 1;
                break :blk closed_conns[num_closed_conns];
            } else {
                if (num_open_conns == max_connections) break :blk null;

                const next_idx = num_open_conns;
                // We need to expand the number of open connections.
                num_open_conns += 1;
                break :blk next_idx;
            }
        };

        if (this_conn_idx) |idx| {
            // std.debug.print("Spawning new connection with index: {} in thread: {} \n", .{idx, id});
            // Spawns a new connection handler in a different coroutine.
            open_conns[idx] = async handle_connection(ring, new_conn_fd, idx, &closed_conns, &num_closed_conns);
        } else {
            try writer.print("Reached connection limit, refusing connection. \n", .{});
            _ = try ring.close(new_conn_fd, null, null);
        }
    }

    // This isn't really needed since this only happens at process shutdown,
    // but why not.
    for (open_conns[0..num_open_conns]) |conn| {
        await conn;
    }
}

// Does the main echo server loop for a single connection, recieving and
// echoing input over the file descriptor for the client.
pub fn handle_connection(ring: *AsyncIOUring, client: os.fd_t, conn_idx: u64, closed_conns: *[max_connections]u64, num_closed_conns: *usize) !void {
    defer {
        // std.debug.print("Closing connection with index {}\n", .{conn_idx});
        _ = ring.close(client, null, null) catch |err| {
            std.debug.print("Error closing {}\n", .{err});
            std.os.exit(1);
        };
        // Return this connection index to the list of free connection indices.
        closed_conns[num_closed_conns.*] = conn_idx;
        num_closed_conns.* += 1;
    }

    // Used to send and receive.
    var buffer: [512]u8 = undefined;

    // Loop until the connection is closed, receiving input and sending back
    // that input as output.
    while (true) {
        const recv_cqe = try ring.recv(client, buffer[0..], 0, null, null);
        const num_bytes_received = @intCast(usize, recv_cqe.res);
        _ = try ring.send(client, buffer[0..num_bytes_received], 0, null, null);
    }
}
