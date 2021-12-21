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

const aiou = @import("async_io_uring.zig");
const AsyncIOUring = aiou.AsyncIOUring;

// Silly echo server benchmark that sends "hello" 100k times in a loop and then
// outputs throughput.
pub fn benchmark(ring: *AsyncIOUring) !void {
    const address = try net.Address.parseIp4("127.0.0.1", 3131);

var num_clients: u64 = 0;
const max_clients = 10;
var timer = try Timer.start();
const start = timer.lap();
const buffer_to_send = "hello";
const num_bytes_to_send = buffer_to_send.len;
const max_ops = 100000;

while (num_clients < max_clients) : (num_clients += 1) {
    const client = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);
    defer os.close(client);

    const cqe_connect = try ring.connect(client, &address.any, address.getOsSockLen());
    assert(cqe_connect.res == 0);
    var input_buffer: [256]u8 = undefined;

    var num_ops: u64 = 0;
    while (num_ops < max_ops) : (num_ops += 1) {
        // Send it to the server.
        const send_result = try ring.send(client, buffer_to_send[0..num_bytes_to_send], @intCast(u32, num_bytes_to_send));
        assert(send_result.res == num_bytes_to_send);

        // Receive the response.
        const cqe_recv = try ring.recv(client, input_buffer[0..], 0);
        const num_bytes_received = @intCast(usize, cqe_recv.res);
    }
}
    const end = timer.read();
    const elapsed_s = @intToFloat(f64, end - start) / std.time.ns_per_s;
    const ops_per_sec = @intToFloat(f64, max_ops * num_clients) / elapsed_s;
    std.debug.print("throughput: {d} ops per sec\n", .{ops_per_sec});
}

pub fn main() !void {
    var ring = try IO_Uring.init(16, 0);
    defer ring.deinit();

    var async_ring = AsyncIOUring{ .ring = &ring };

    _ = async benchmark(&async_ring);
    try async_ring.run_event_loop();
}
