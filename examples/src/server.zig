const std = @import("std");

const io = @import("async_io_uring");

const builtin = @import("builtin");
const IO_Uring = std.os.linux.IO_Uring;
const assert = std.debug.assert;
const mem = std.mem;
const net = std.net;
const os = std.os;
const linux = os.linux;

const AsyncIOUring = io.AsyncIOUring;
const AsyncWriter = io.AsyncWriter;
const AsyncMutex = @import("async_mutex.zig").AsyncMutex;

// TODO: Try out using register_files for all connections and for the listener
// connection  especially

// Currently the number of max connections is hardcoded. This allows you to
// avoid heap allocation in growing and shrinking the list of active connections.

pub fn main() !void {
    // TODO: May need to allocate the array of threads on the heap so you can
    // do this.
    // const num_threads = comptime try std.Thread.getCpuCount();
    const num_threads = 1;
    const max_num_connections = 10000;
    try runServer(
        num_threads,
        max_num_connections,
        handleEchoClientConnection,
        ServerConfig{
            .address = try net.Address.parseIp4("127.0.0.1", 3131),
        },
    );
}

fn handleEchoClientConnection(serverCtx: ServerContext, client: TcpConnection) !void {
    // Used to send and receive.
    var buffer: [512]u8 = undefined;

    try serverCtx.logger.print(
        "Accepted new connection on thread {}\n",
        .{serverCtx.thread_id},
    );

    var num_msgs_received: u64 = 0;

    defer {
        serverCtx.logger.print(
            "\nFinished with connection on thread {}, received {} messages\n",
            .{ serverCtx.thread_id, num_msgs_received },
        ) catch |err| {
            std.debug.print("Error logging connection closure: {}\n", .{err});
            std.os.exit(1);
        };
    }

    // Loop until the connection is closed, receiving input and sending back
    // that input as output.
    while (true) {
        const num_bytes_received = try client.recv(buffer[0..], null, null);
        if (num_bytes_received == 0) {
            // 0 bytes received indicates orderly connection closure.
            break;
        }
        _ = try client.send(buffer[0..num_bytes_received], null, null);
        num_msgs_received += 1;
    }
}

/// Class to allow multiple concurrent coroutines to write to the same file
/// handle without interfering with one another. This is required even with a
/// single threaded server since the kernel can fulfill multiple io_uring
/// requests to the same file in parallel.
pub const ConcurrentAsyncWriter = struct {
    mutex: AsyncMutex = .{},
    writer: *AsyncWriter,

    pub fn print(self: *@This(), comptime format: []const u8, args: anytype) !void {
        try self.mutex.lock();
        defer self.mutex.unlock() catch {
            std.os.exit(1);
        };

        try self.writer.print(format, args);
    }
};

pub const ServerContext = struct {
    thread_id: usize,
    io_service: *AsyncIOUring,
    // TODO: Put this in some kind of "global user data" field that can be
    // configured? Not everyone will want this.
    logger: *ConcurrentAsyncWriter,
};

pub const ServerConfig = struct {
    address: std.net.Address,
    kernel_backlog: u31 = 128,
    reuse_address: bool = false,
};

pub const TcpConnection = struct {
    ring: *AsyncIOUring,
    socket_fd: os.fd_t,

    pub fn send(
        self: @This(),
        buffer: []const u8,
        maybe_timeout: ?io.Timeout,
        maybe_id: ?*u64,
    ) !usize {
        const cqe = try self.ring.send(self.socket_fd, buffer, 0, maybe_timeout, maybe_id);
        return @intCast(usize, cqe.res);
    }

    /// Returns number of bytes received.
    pub fn recv(
        self: @This(),
        buffer: []u8,
        maybe_timeout: ?io.Timeout,
        maybe_id: ?*u64,
    ) !usize {
        const cqe = try self.ring.recv(self.socket_fd, buffer, 0, maybe_timeout, maybe_id);
        return @intCast(usize, cqe.res);
    }
};

const ConnHandler = fn (ServerContext, TcpConnection) anyerror!void;

fn runServerEventLoop(id: u64, server_config: ServerConfig, comptime max_num_connections: usize, comptime handleConnection: ConnHandler) !void {
    var ring = try IO_Uring.init(4096, 0);
    defer ring.deinit();

    var async_ring = AsyncIOUring{ .ring = &ring };

    const Wrapper = struct {
        ring: *AsyncIOUring,
        id: u64,
        server_config: ServerConfig,

        fn run(self: @This()) !void {
            try runServerSingleThreaded(self.ring, self.id, self.server_config, max_num_connections, handleConnection);
        }
    };

    // The frame size is very large when the max number of connections is high.
    // We could increase stack size but for now we're just allocating it on the
    // heap - doesn't seem to have much of an affect on performance (and that
    // makes sense because we're only doing it once).
    const frame = try std.heap.page_allocator.create(@Frame(Wrapper.run));
    defer std.heap.page_allocator.destroy(frame);
    const wrapper = Wrapper{
        .ring = &async_ring,
        .id = id,
        .server_config = server_config,
    };
    frame.* = async wrapper.run();

    try async_ring.run_event_loop();
    try nosuspend await frame;
}

pub fn runServer(
    comptime num_threads: usize,
    comptime max_num_connections: usize,
    comptime handleConnection: ConnHandler,
    server_config: ServerConfig,
) !void {
    var threads: [num_threads]std.Thread = undefined;

    const Wrapper = struct {
        id: u64,
        server_config: ServerConfig,

        fn run(self: @This()) !void {
            try runServerEventLoop(self.id, self.server_config, max_num_connections, handleConnection);
        }
    };

    // Starts at 1 to reserve id 0 for the main thread.
    var i: u64 = 1;
    while (i < num_threads) : (i += 1) {
        std.debug.print("Spawning thread {}\n", .{i});

        const wrapper = Wrapper{ .id = i, .server_config = server_config };
        threads[i] = try std.Thread.spawn(.{}, Wrapper.run, .{wrapper});
    }

    std.debug.print("Starting event loop in main thread (thread 0)\n", .{});

    // Use the main thread as an event loop as well.
    try runServerEventLoop(0, server_config, max_num_connections, handleConnection);
    std.debug.print("Joining all threads\n", .{});
    for (threads) |t| {
        std.Thread.join(t);
    }
}

// Open a socket and run the echo server listening on that socket. The server
// can handle up to max_num_connections concurrent connections, all in a single
// thread..
fn runServerSingleThreaded(
    ring: *AsyncIOUring,
    id: u64,
    server_config: ServerConfig,
    comptime max_num_connections: usize,
    comptime handleConnection: ConnHandler,
) !void {
    // TODO: Experiment with NONBLOCK
    const server = try os.socket(server_config.address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    defer os.close(server);
    try os.setsockopt(server, os.SOL.SOCKET, os.SO.REUSEPORT, &mem.toBytes(@as(c_int, 1)));
    try os.bind(server, &server_config.address.any, server_config.address.getOsSockLen());
    try os.listen(server, server_config.kernel_backlog);

    try runAcceptorLoop(ring, server, id, max_num_connections, handleConnection);
}

// Loops accepting new connections and spawning new coroutines to handle those
// connections.
fn runAcceptorLoop(ring: *AsyncIOUring, server: os.fd_t, thread_id: u64, comptime max_num_connections: usize, comptime handleConnection: ConnHandler) !void {
    const Wrapper = struct {
        ring: *AsyncIOUring,
        writer: *ConcurrentAsyncWriter,
        thread_id: usize,
        client: os.fd_t,
        conn_idx: u64,
        closed_conns: *[max_num_connections]u64,
        num_closed_conns: *usize,

        fn run(self: @This()) !void {
            try handle_connection(
                self.ring,
                self.writer,
                self.thread_id,
                max_num_connections,
                self.client,
                self.conn_idx,
                self.closed_conns,
                self.num_closed_conns,
                handleConnection,
            );
        }
    };
    // TODO: Put this in a struct and abstract away some of the connection
    // tracking.
    var open_conns: [max_num_connections]@Frame(Wrapper.run) = undefined;
    var closed_conns: [max_num_connections]u64 = undefined;
    var num_open_conns: usize = 0;
    var num_closed_conns: usize = 0;

    var writer = try AsyncWriter.init(ring, std.io.getStdErr().handle);
    var concurrent_writer = ConcurrentAsyncWriter{ .writer = &writer };
    while (true) {
        var accept_addr: os.sockaddr = undefined;
        var accept_addr_len: os.socklen_t = @sizeOf(@TypeOf(accept_addr));

        // Wait for a new connection request.
        var accept_cqe = ring.accept(
            server,
            &accept_addr,
            &accept_addr_len,
            0,
            null,
            null,
        ) catch |err| {
            try writer.print("Error accepting connection: {} \n", .{err});
            continue;
        };

        var new_conn_fd = accept_cqe.res;

        // Get an index in the array of open connections for this new
        // connection. If we already have max_num_connections open connections,
        // this_conn_idx will be null.
        const this_conn_idx = blk: {
            if (num_closed_conns > 0) {
                // Reuse the last closed connection's index and decrement the
                // number of closed connections.
                num_closed_conns -= 1;
                break :blk closed_conns[num_closed_conns];
            } else {
                if (num_open_conns == max_num_connections) break :blk null;

                const next_idx = num_open_conns;
                // We need to expand the number of open connections.
                num_open_conns += 1;
                break :blk next_idx;
            }
        };

        if (this_conn_idx) |idx| {
            const wrapper = Wrapper{
                .ring = ring,
                .writer = &concurrent_writer,
                .thread_id = thread_id,
                .client = new_conn_fd,
                .conn_idx = idx,
                .closed_conns = &closed_conns,
                .num_closed_conns = &num_closed_conns,
            };
            // std.debug.print("Spawning new connection with index: {} in thread: {} \n", .{idx, id});
            // Spawns a new connection handler in a different coroutine.
            open_conns[idx] = async wrapper.run();
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
fn handle_connection(
    ring: *AsyncIOUring,
    writer: *ConcurrentAsyncWriter,
    thread_id: usize,
    comptime max_num_connections: u64,
    client: os.fd_t,
    conn_idx: u64,
    closed_conns: *[max_num_connections]u64,
    num_closed_conns: *usize,
    comptime handleConnection: ConnHandler,
) !void {
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

    try await async handleConnection(
        ServerContext{
            .thread_id = thread_id,
            .io_service = ring,
            .logger = writer,
        },
        TcpConnection{ .ring = ring, .socket_fd = client },
    );
}
