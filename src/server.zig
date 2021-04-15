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
    // TODO make async
    var buffer_recv: [256]u8 = undefined;
    const recv = try ring.recv(0, client, buffer_recv[0..], 0);
    _ = try ring.submit();

    const cqe_recv = try ring.copy_cqe();
    const num_bytes_received = @intCast(usize, cqe_recv.res);
    std.debug.print("Received: {s}\n", .{buffer_recv[0..num_bytes_received]});

    std.debug.print("Sending\n", .{});
    //const buffer_send = "hello!";
    // This is async!
    const result = try AsyncIOUring.send(ring, client, buffer_recv[0..num_bytes_received], 0);
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

    const buffer_send = [_]u8{ 1, 0, 1, 0, 1, 0, 1, 0, 1, 0 };
    var buffer_recv = [_]u8{ 0, 1, 0, 1, 0 };

    var acceptor_done = async acceptor(&ring, server);

    //var accept_addr: os.sockaddr = undefined;
    //var accept_addr_len: os.socklen_t = @sizeOf(@TypeOf(accept_addr));

    while (true) {
        std.debug.print("Submitting...\n", .{});
        _ = try ring.submit();
        std.debug.print("Done submitting.\n", .{});

        var cqe_accept = try ring.copy_cqe();
        std.debug.print("About to resume.\n", .{});
        if (cqe_accept.user_data != 0) {
            var resume_node = @intToPtr(*ResumeNode, cqe_accept.user_data);
            resume_node.result = cqe_accept;
            resume resume_node.frame;
        }
    }
    AsyncIOUring.run_event_loop(ring);
    await acceptor_done;
}

pub fn main() !void {
    _ = async server_loop();
}

test "accept/connect/send/recv" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(16, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const kernel_backlog = 1;
    const server = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);
    defer os.close(server);
    try os.setsockopt(server, os.SOL_SOCKET, os.SO_REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try os.bind(server, &address.any, address.getOsSockLen());
    try os.listen(server, kernel_backlog);

    const buffer_send = [_]u8{ 1, 0, 1, 0, 1, 0, 1, 0, 1, 0 };
    var buffer_recv = [_]u8{ 0, 1, 0, 1, 0 };

    var accept_addr: os.sockaddr = undefined;
    var accept_addr_len: os.socklen_t = @sizeOf(@TypeOf(accept_addr));
    const accept = try ring.accept(0xaaaaaaaa, server, &accept_addr, &accept_addr_len, 0);
    testing.expectEqual(@as(u32, 1), try ring.submit());

    const client = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);
    defer os.close(client);
    const connect = try ring.connect(0xcccccccc, client, &address.any, address.getOsSockLen());
    testing.expectEqual(@as(u32, 1), try ring.submit());

    var cqe_accept = try ring.copy_cqe();
    if (cqe_accept.res == -linux.EINVAL) return error.SkipZigTest;
    var cqe_connect = try ring.copy_cqe();
    if (cqe_connect.res == -linux.EINVAL) return error.SkipZigTest;

    // The accept/connect CQEs may arrive in any order, the connect CQE will sometimes come first:
    if (cqe_accept.user_data == 0xcccccccc and cqe_connect.user_data == 0xaaaaaaaa) {
        const a = cqe_accept;
        const b = cqe_connect;
        cqe_accept = b;
        cqe_connect = a;
    }

    testing.expectEqual(@as(u64, 0xaaaaaaaa), cqe_accept.user_data);
    if (cqe_accept.res <= 0) std.debug.print("\ncqe_accept.res={}\n", .{cqe_accept.res});
    testing.expect(cqe_accept.res > 0);
    testing.expectEqual(@as(u32, 0), cqe_accept.flags);
    testing.expectEqual(linux.io_uring_cqe{
        .user_data = 0xcccccccc,
        .res = 0,
        .flags = 0,
    }, cqe_connect);

    const send = try ring.send(0xeeeeeeee, client, buffer_send[0..], 0);
    send.flags |= linux.IOSQE_IO_LINK;
    const recv = try ring.recv(0xffffffff, cqe_accept.res, buffer_recv[0..], 0);
    testing.expectEqual(@as(u32, 2), try ring.submit());

    const cqe_send = try ring.copy_cqe();
    if (cqe_send.res == -linux.EINVAL) return error.SkipZigTest;
    testing.expectEqual(linux.io_uring_cqe{
        .user_data = 0xeeeeeeee,
        .res = buffer_send.len,
        .flags = 0,
    }, cqe_send);

    const cqe_recv = try ring.copy_cqe();
    if (cqe_recv.res == -linux.EINVAL) return error.SkipZigTest;
    testing.expectEqual(linux.io_uring_cqe{
        .user_data = 0xffffffff,
        .res = buffer_recv.len,
        .flags = 0,
    }, cqe_recv);

    testing.expectEqualSlices(u8, buffer_send[0..buffer_recv.len], buffer_recv[0..]);
}
test "timeout_remove" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(2, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    const ts = os.__kernel_timespec{ .tv_sec = 3, .tv_nsec = 0 };
    const sqe_timeout = try ring.timeout(0x88888888, &ts, 0, 0);
    testing.expectEqual(linux.IORING_OP.TIMEOUT, sqe_timeout.opcode);
    testing.expectEqual(@as(u64, 0x88888888), sqe_timeout.user_data);

    const sqe_timeout_remove = try ring.timeout_remove(0x99999999, 0x88888888, 0);
    testing.expectEqual(linux.IORING_OP.TIMEOUT_REMOVE, sqe_timeout_remove.opcode);
    testing.expectEqual(@as(u64, 0x88888888), sqe_timeout_remove.addr);
    testing.expectEqual(@as(u64, 0x99999999), sqe_timeout_remove.user_data);

    testing.expectEqual(@as(u32, 2), try ring.submit());

    const cqe_timeout = try ring.copy_cqe();
    // IORING_OP_TIMEOUT_REMOVE is not supported by this kernel version:
    // Timeout remove operations set the fd to -1, which results in EBADF before EINVAL.
    // We use IORING_FEAT_RW_CUR_POS as a safety check here to make sure we are at least pre-5.6.
    // We don't want to skip this test for newer kernels.
    if (cqe_timeout.user_data == 0x99999999 and
        cqe_timeout.res == -linux.EBADF and
        (ring.features & linux.IORING_FEAT_RW_CUR_POS) == 0)
    {
        return error.SkipZigTest;
    }
    testing.expectEqual(linux.io_uring_cqe{
        .user_data = 0x88888888,
        .res = -linux.ECANCELED,
        .flags = 0,
    }, cqe_timeout);

    const cqe_timeout_remove = try ring.copy_cqe();
    testing.expectEqual(linux.io_uring_cqe{
        .user_data = 0x99999999,
        .res = 0,
        .flags = 0,
    }, cqe_timeout_remove);
}
test "fallocate" {
    if (builtin.os.tag != .linux) {
        std.debug.print("Not linux \n", .{});
        return error.SkipZigTest;
    }

    var ring = IO_Uring.init(1, 0) catch |err| switch (err) {
        error.SystemOutdated => {
            std.debug.print("SystemOutdated\n", .{});
            return error.SkipZigTest;
        },
        error.PermissionDenied => {
            std.debug.print("PermissionDenied\n", .{});
            return error.SkipZigTest;
        },
        else => {
            std.debug.print("other error: {}\n", .{err});

            return err;
        },
    };
    defer ring.deinit();

    const path = "test_io_uring_fallocate";
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o666 });
    defer file.close();
    defer std.fs.cwd().deleteFile(path) catch {};

    testing.expectEqual(@as(u64, 0), (try file.stat()).size);

    const len: u64 = 65536;
    const sqe = try ring.fallocate(0xaaaaaaaa, file.handle, 0, 0, len);
    testing.expectEqual(linux.IORING_OP.FALLOCATE, sqe.opcode);
    testing.expectEqual(file.handle, sqe.fd);
    testing.expectEqual(@as(u32, 1), try ring.submit());

    const cqe = try ring.copy_cqe();
    switch (-cqe.res) {
        0 => {},
        // This kernel's io_uring does not yet implement fallocate():
        linux.EINVAL => return error.SkipZigTest,
        // This kernel does not implement fallocate():
        linux.ENOSYS => return error.SkipZigTest,
        // The filesystem containing the file referred to by fd does not support this operation;
        // or the mode is not supported by the filesystem containing the file referred to by fd:
        linux.EOPNOTSUPP => return error.SkipZigTest,
        else => |errno| std.debug.panic("unhandled errno: {}", .{errno}),
    }
    testing.expectEqual(linux.io_uring_cqe{
        .user_data = 0xaaaaaaaa,
        .res = 0,
        .flags = 0,
    }, cqe);

    testing.expectEqual(len, (try file.stat()).size);
}
