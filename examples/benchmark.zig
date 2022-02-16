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

const aiou = @import("async_io_uring");
const AsyncIOUring = aiou.AsyncIOUring;

const BenchmarkResult = struct { num_ops: u64 };

const max_ops = 10000;
const buffer_to_send: [512]u8 = [_]u8{0} ** 512;
const num_bytes_to_send = buffer_to_send.len;

pub fn run_client(ring: *AsyncIOUring) !void {
    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const client = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    defer os.close(client);

    // Connect to the server.
    const cqe_connect = ring.connect(client, &address.any, address.getOsSockLen()) catch |err| {
        std.debug.print("Error in run_client: connect {} \n", .{err});
        return err;
    };

    assert(cqe_connect.res == 0);

    var input_buffer: [512]u8 = undefined;
    var num_ops: u64 = 0;

    while (num_ops < max_ops) : (num_ops += 1) {
        // Send it to the server.
        const send_result = ring.send(client, buffer_to_send[0..num_bytes_to_send], @intCast(u32, num_bytes_to_send)) catch |err| {
            std.debug.print("Error in run_client: send {} \n", .{err});
            return err;
        };

        assert(send_result.res == num_bytes_to_send);

        // Receive the response.
        const cqe_recv = ring.recv(client, input_buffer[0..], 0) catch |err| {
            std.debug.print("Error in run_client: recv {} \n", .{err});
            return err;
        };
        const num_bytes_received = @intCast(usize, cqe_recv.res);

        // TODO
        assert(num_bytes_received == num_bytes_to_send - 1);
    }
}

// Silly echo server benchmark that sends "hello" 100k times in a loop and then
// outputs throughput.
pub fn benchmark(ring: *AsyncIOUring, result: *BenchmarkResult) !void {
    const max_clients = 30;
    var client_frames: [max_clients]@Frame(run_client) = undefined;

    var i: u64 = 0;
    while (i < max_clients) : (i += 1) {
        client_frames[i] = async run_client(ring);
    }

    i = 0;
    while (i < max_clients) : (i += 1) {
        await client_frames[i] catch |err| {
            std.debug.print("client had err {}", .{err});
        };
    }
    result.num_ops = max_clients * max_ops;
}

pub fn run_benchmark_event_loop(_: u64, result: *BenchmarkResult) !void {
    var ring = try IO_Uring.init(4096, 0);
    defer ring.deinit();
    var async_ring = AsyncIOUring{ .ring = &ring };
    _ = async benchmark(&async_ring, result);
    try async_ring.run_event_loop();
}

pub fn main() !void {
    const num_threads = 16;
    var threads: [num_threads]std.Thread = undefined;
    var results: [num_threads]BenchmarkResult = undefined;

    var timer = try Timer.start();
    const start = timer.lap();

    var i: u64 = 0;
    while (i < num_threads) : (i += 1) {
        std.debug.print("Spawning\n", .{});
        threads[i] = try std.Thread.spawn(.{}, run_benchmark_event_loop, .{ i, &results[i] });
    }

    i = 0;

    var total_ops: u64 = 0;
    while (i < num_threads) : (i += 1) {
        std.debug.print("Joining {}\n", .{i});
        std.Thread.join(threads[i]);
        total_ops += results[i].num_ops;
    }

    const end = timer.read();

    const elapsed_s = @intToFloat(f64, end - start) / std.time.ns_per_s;

    const ops_per_sec = @intToFloat(f64, total_ops) / elapsed_s;

    std.debug.print("Total throughput: {d} ops per sec\n", .{ops_per_sec});
}
