const std = @import("std");
const IO_Uring = std.os.linux.IO_Uring;
const assert = std.debug.assert;
const builtin = std.builtin;
const mem = std.mem;
const net = std.net;
const os = std.os;
const linux = os.linux;
const testing = std.testing;

pub const ResumeNode = struct {
    frame: anyframe = undefined, result: linux.io_uring_cqe = undefined
};

pub const AsyncIOUring = struct {
    /// Queues (but does not submit) an SQE to perform an `accept4(2)` on a socket.
    /// Returns a pointer to the SQE.
    pub fn accept(
        ring: *IO_Uring,
        //        user_data: u64, TODO
        fd: os.fd_t,
        addr: *os.sockaddr,
        addrlen: *os.socklen_t,
        flags: u32,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try ring.accept(@ptrToInt(&node), fd, addr, addrlen, flags);
        suspend;
        //std.debug.print("Accepted: accept {}.\n", .{node.result.res});
        return node.result;
    }

    /// Queue (but does not submit) an SQE to perform a `connect(2)` on a socket.
    /// Returns a pointer to the SQE.
    pub fn connect(
        ring: *IO_Uring,
        // user_data: u64,
        fd: os.fd_t,
        addr: *const os.sockaddr,
        addrlen: os.socklen_t,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try ring.connect(@ptrToInt(&node), fd, addr, addrlen);
        suspend;
        //std.debug.print("Connected: {}.\n", .{node.result.res});
        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a `send(2)`.
    /// Returns a pointer to the SQE.
    pub fn send(
        ring: *IO_Uring,
        //user_data: u64,
        fd: os.fd_t,
        buffer: []const u8,
        flags: u32,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try ring.send(@ptrToInt(&node), fd, buffer, flags);
        suspend;
        //std.debug.print("Sent: {}.\n", .{node.result.res});
        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a `recv(2)`.
    /// Returns a pointer to the SQE.
    pub fn recv(
        ring: *IO_Uring,
        // user_data: u64,
        fd: os.fd_t,
        buffer: []u8,
        flags: u32,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try ring.recv(@ptrToInt(&node), fd, buffer, flags);
        suspend;
        // std.debug.print("Received: {}.\n", .{node.result.res});
        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a `read(2)`.
    /// Returns a pointer to the SQE.
    pub fn read(
        ring: *IO_Uring,
        // user_data: u64,
        fd: os.fd_t,
        buffer: []u8,
        offset: u64,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try ring.read(@ptrToInt(&node), fd, buffer, offset);
        suspend;
        //std.debug.print("Read: {}.\n", .{node.result.res});
        return node.result;
    }

    pub fn run_event_loop(ring: *IO_Uring) !void {
        while (true) {
            //std.debug.print("Submitting...\n", .{});
            _ = try ring.submit();
            //std.debug.print("Done submitting.\n", .{});

            var cqe = try ring.copy_cqe();
            //std.debug.print("About to resume.\n", .{});
            if (cqe.user_data != 0) {
                var resume_node = @intToPtr(*ResumeNode, cqe.user_data);
                resume_node.result = cqe;
                resume resume_node.frame;
            }
        }
    }
};
