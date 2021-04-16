const std = @import("std");
const IO_Uring = std.os.linux.IO_Uring;
const os = std.os;
const linux = os.linux;

// Used as user data for submission queue entries, so that the event loop can
// have resume the callers frame.
//
// TODO: Allow additional user_data.
const ResumeNode = struct { frame: anyframe = undefined, result: linux.io_uring_cqe = undefined };

// TODO: Update comments to reflect that all functions queue an SQE and suspend until the CQE is ready
//       and resumed by the event loop.
// TODO: Turn linux errors on the cqe into zig errors.
// TODO: Consider making AsyncIOUring own the ring and add init()/deinit()
//       functions.
pub const AsyncIOUring = struct {
    ring: *IO_Uring = undefined,

    /// Queues (but does not submit) an SQE to perform an `accept4(2)` on a socket.
    /// Returns a pointer to the SQE.
    pub fn accept(
        self: *AsyncIOUring,
        //        user_data: u64, TODO
        fd: os.fd_t,
        addr: *os.sockaddr,
        addrlen: *os.socklen_t,
        flags: u32,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.accept(@ptrToInt(&node), fd, addr, addrlen, flags);
        suspend;
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

    // Runs a loop to submit tasks on the underling IU_Uring and block waiting
    // for completion events. When a completion queue event (cqe) is available, it
    // will resume the coroutine that submitted the request corresponding to that cqe.
    pub fn run_event_loop(self: *AsyncIOUring) !void {
        var cqes: [256]linux.io_uring_cqe = undefined;
        const max_num_events_to_wait_for_in_kernel = 1;
        while (true) {
            _ = try self.ring.submit();

            var num_ready_cqes = try self.ring.copy_cqes(cqes[0..], max_num_events_to_wait_for_in_kernel);
            for (cqes[0..num_ready_cqes]) |cqe| {
                if (cqe.user_data != 0) {
                    var resume_node = @intToPtr(*ResumeNode, cqe.user_data);
                    resume_node.result = cqe;
                    resume resume_node.frame;
                }
            }
        }
    }
};
