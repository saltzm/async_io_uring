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

// Currently the number of max connections is hardcoded. This allows you to
// avoid heap allocation in growing and shrinking the list of active connections.
const max_connections = 10000;

pub fn main() !void {
    const num_threads = 11;
    var threads: [num_threads]std.Thread = undefined;
    var i: u64 = 0;
    while (i < num_threads) : (i += 1) {
        std.debug.print("Spawning\n", .{});
        threads[i] = try std.Thread.spawn(.{}, really_run_server, .{i});
    }
    i = 0;
    while (i < num_threads) : (i += 1) {
        std.debug.print("Joining {}\n", .{i});
        std.Thread.join(threads[i]);
    }
    try really_run_server(0);
}

pub fn really_run_server(id: u64) !void {
    // Seems slower in first silly test benchmarks
    // var ring = try IO_Uring.init(4096, linux.IORING_SETUP_SQPOLL);

    var ring = try IO_Uring.init(4096, 0);
    defer ring.deinit();

    var async_ring = AsyncIOUring{ .ring = &ring };

    _ = async run_server(&async_ring, id);

    try async_ring.run_event_loop();
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

    while (true) {
        // std.debug.print("Accepting\n", .{});

        var accept_addr: os.sockaddr = undefined;
        var accept_addr_len: os.socklen_t = @sizeOf(@TypeOf(accept_addr));

        // Wait for a new connection request.
        var accept_cqe = try ring.accept(server, &accept_addr, &accept_addr_len, 0);
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
            // std.debug.print("Reached connection limit, refusing connection. \n", .{});
            _ = try ring.ring.close(0, new_conn_fd);
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
        // TODO: Expose close on AsyncIOUring.
        _ = ring.ring.close(0, client) catch {
            // std.debug.print("Error closing\n", .{});
            std.os.exit(1);
        };
        // Return this connection index to the list of free connection indices.
        closed_conns[num_closed_conns.*] = conn_idx;
        num_closed_conns.* += 1;
    }

    // Used to send and receive.
    var buffer: [512]u8 = undefined;

    //std.debug.print("about to assert\n", .{});
    //    assert(num_closed_conns.* == 72);
    //std.debug.print("done asserting \n", .{});

    // TODO: Try out using read_fixed/write_fixed and maybe polling
    //    var buffers = [1]os.iovec{
    //        .{ .iov_base = &buffer, .iov_len = buffer.len },
    //        //.{ .iov_base = &raw_buffers[1], .iov_len = raw_buffers[1].len },
    //    };
    // TODO Doesn't exist till zig 0.9.0
    //try ring.ring.register_buffers(&buffers);

    //    const sqe_write = try ring.write_fixed(0x45454545, fd, &buffers[0], 3, 0);

    // Loop until the connection is closed, receiving input and sending back
    // that input as output.
    while (true) {
        const recv_cqe = try ring.recv(client, buffer[0..], 0);
        // _ = try ring.recv(client, buffer[0..], 0);
        // std.time.sleep(50000);
        //const start = std.time.nanoTimestamp();
        //while (std.time.nanoTimestamp() - start < 50 * ns_per_us) {  }

        const num_bytes_received = @intCast(usize, recv_cqe.res);
        _ = try ring.send(client, buffer[0..num_bytes_received], 0);

        // buffers[0].iov_len = num_bytes_received;

        // _ = try ring.write_fixed(client, &buffers[0], 0, // file offset
        //     0 // buffer index
        // );
    }
}
