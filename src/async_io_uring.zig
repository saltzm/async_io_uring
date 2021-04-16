const std = @import("std");
const IO_Uring = std.os.linux.IO_Uring;
const assert = std.debug.assert;
const builtin = std.builtin;
const mem = std.mem;
const net = std.net;
const os = std.os;
const linux = os.linux;
const testing = std.testing;

pub const ResumeNode = struct { frame: anyframe = undefined, result: linux.io_uring_cqe = undefined };

// TODO: Update comments to reflect that all functions queue an SQE and suspend until the CQE is ready
// and resumed by the event loop
pub const AsyncIOUring = struct {
    ring: *IO_Uring = undefined,

    /// Queues (but does not submit) an SQE to perform an `accept4(2)` on a socket.
    /// Returns a pointer to the SQE.
    pub fn accept(
        self: *AsyncIOUring,
        //        user_data: u64, TODO allow extra user data?
        fd: os.fd_t,
        addr: *os.sockaddr,
        addrlen: *os.socklen_t,
        flags: u32,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.accept(@ptrToInt(&node), fd, addr, addrlen, flags);
        suspend;
        //std.debug.print("Accepted: accept {}.\n", .{node.result.res});
        return node.result;
    }

    /// Queue (but does not submit) an SQE to perform a `connect(2)` on a socket.
    /// Returns a pointer to the SQE.
    pub fn connect(
        self: *AsyncIOUring,
        // user_data: u64,
        fd: os.fd_t,
        addr: *const os.sockaddr,
        addrlen: os.socklen_t,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.connect(@ptrToInt(&node), fd, addr, addrlen);
        suspend;
        //std.debug.print("Connected: {}.\n", .{node.result.res});
        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a `send(2)`.
    /// Returns a pointer to the SQE.
    pub fn send(
        self: *AsyncIOUring,
        //user_data: u64,
        fd: os.fd_t,
        buffer: []const u8,
        flags: u32,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.send(@ptrToInt(&node), fd, buffer, flags);
        suspend;
        //std.debug.print("Sent: {}.\n", .{node.result.res});
        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a `recv(2)`.
    /// Returns a pointer to the SQE.
    pub fn recv(
        self: *AsyncIOUring,
        // user_data: u64,
        fd: os.fd_t,
        buffer: []u8,
        flags: u32,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.recv(@ptrToInt(&node), fd, buffer, flags);
        suspend;
        // std.debug.print("Received: {}.\n", .{node.result.res});
        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a `read(2)`.
    /// Returns a pointer to the SQE.
    pub fn read(
        self: *AsyncIOUring,
        // user_data: u64,
        fd: os.fd_t,
        buffer: []u8,
        offset: u64,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.read(@ptrToInt(&node), fd, buffer, offset);
        suspend;
        //std.debug.print("Read: {}.\n", .{node.result.res});
        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a `write(2)`.
    /// Returns a pointer to the SQE.
    pub fn write(
        self: *IO_Uring,
        // user_data: u64,
        fd: os.fd_t,
        buffer: []const u8,
        offset: u64,
    ) !*io_uring_sqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.write(@ptrToInt(&node), fd, buffer, offset);
        suspend;
        return node.result;
    }

    pub fn run_event_loop(self: *AsyncIOUring) !void {
        var cqes: [256]linux.io_uring_cqe = undefined;
        const max_num_events_to_wait_for_in_kernel = 1;
        while (true) {
            //std.debug.print("Submitting...\n", .{});
            _ = try self.ring.submit();
            //std.debug.print("Done submitting.\n", .{});

            var num_ready_cqes = try self.ring.copy_cqes(cqes[0..], max_num_events_to_wait_for_in_kernel);
            for (cqes[0..num_ready_cqes]) |cqe| {
                //std.debug.print("About to resume.\n", .{});
                if (cqe.user_data != 0) {
                    var resume_node = @intToPtr(*ResumeNode, cqe.user_data);
                    resume_node.result = cqe;
                    resume resume_node.frame;
                }
            }
        }
    }
};
