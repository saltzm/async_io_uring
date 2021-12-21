const std = @import("std");
const IO_Uring = std.os.linux.IO_Uring;
const os = std.os;
const linux = os.linux;

// Used as user data for submission queue entries, so that the event loop can
// have resume the callers frame.
const ResumeNode = struct { frame: anyframe = undefined, user_data: u64, result: linux.io_uring_cqe = undefined };

// TODO: Use existing codes and make them more semantically meaningful. This is
// just a bandaid so that callers don't have to check the 'res' field on CQEs
// after calling functions on AsyncIOUring.
pub const AsyncIOUringError = error{UnknownError};

// Wrapper for IO_Uring that turns its functions into async functions that
// suspend after enqueuing entries to the submission queue and resume and
// return once a result is available in the completion queue.
//
// Usage requires calling AsyncIOUring.run_event_loop to submit and process
// completion queue entries.
//
// As an overview for the unfamiliar, io_uring works by allowing users to
// enqueue requests into a submission queue (e.g. a request to read from a
// socket) and then submit the submission queue to the kernel for processing.
// When requests from the submission queue have been satisfied, the result is
// placed onto completion queue by the kernel. The user is able to either poll
// the kernel for completion queue results or block until results are
// available. This event loop takes the blocking approach.
//
// Parts of the function-level comments were copied from the IO_Uring library.
//
// Note on abbreviations:
//      SQE == submission queue entry
//      CQE == completion queue entry
//
// TODO: Turn linux errors on the resulting CQEs into zig errors.
// TODO: Consider making AsyncIOUring own the ring and add init()/deinit()
//       functions.
// TODO: Consider making another class that's higher level with sensible defaults for everything.
pub const AsyncIOUring = struct {
    ring: *IO_Uring = undefined,

    /// Queues (but does not submit) an SQE to perform an `accept4(2)` on a socket.
    /// Suspends execution until the resulting CQE is available and returns
    /// that CQE.
    pub fn accept(
        self: *AsyncIOUring,
        fd: os.fd_t,
        addr: *os.sockaddr,
        addrlen: *os.socklen_t,
        flags: u32,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .user_data = 0, .result = undefined };
        _ = try self.ring.accept(@ptrToInt(&node), fd, addr, addrlen, flags);
        suspend {}

        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
    }

    /// Queue (but does not submit) an SQE to perform a `connect(2)` on a socket.
    /// Suspends execution until the resulting CQE is available and returns
    /// that CQE.
    pub fn connect(
        self: *AsyncIOUring,
        fd: os.fd_t,
        addr: *const os.sockaddr,
        addrlen: os.socklen_t,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .user_data = 0, .result = undefined };
        _ = try self.ring.connect(@ptrToInt(&node), fd, addr, addrlen);
        suspend {}

        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a `send(2)`.
    /// Suspends execution until the resulting CQE is available and returns
    /// that CQE.
    pub fn send(
        self: *AsyncIOUring,
        fd: os.fd_t,
        buffer: []const u8,
        flags: u32,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .user_data = 0, .result = undefined };
        _ = try self.ring.send(@ptrToInt(&node), fd, buffer, flags);
        suspend {}
        if (node.result.res <= 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a `recv(2)`.
    /// Suspends execution until the resulting CQE is available and returns
    /// that CQE.
    pub fn recv(
        self: *AsyncIOUring,
        fd: os.fd_t,
        buffer: []u8,
        flags: u32,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .user_data = 0, .result = undefined };
        _ = try self.ring.recv(@ptrToInt(&node), fd, buffer, flags);
        suspend {}

        // TODO: Is it ever valid to receive 0 bytes?
        if (node.result.res <= 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a `read(2)`.
    /// Suspends execution until the resulting CQE is available and returns
    /// that CQE.
    pub fn read(
        self: *AsyncIOUring,
        fd: os.fd_t,
        buffer: []u8,
        offset: u64,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .user_data = 0, .result = undefined };
        _ = try self.ring.read(@ptrToInt(&node), fd, buffer, offset);
        suspend {}

        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a `write(2)`.
    /// Suspends execution until the resulting CQE is available and returns
    /// that CQE.
    pub fn write(
        self: *IO_Uring,
        fd: os.fd_t,
        buffer: []const u8,
        offset: u64,
    ) !*io_uring_sqe {
        var node = ResumeNode{ .frame = @frame(), .user_data = 0, .result = undefined };
        _ = try self.ring.write(@ptrToInt(&node), fd, buffer, offset);
        suspend {}
        return node.result;
    }

    // Runs a loop to submit tasks on the underling IU_Uring and block waiting
    // for completion events. When a completion queue event (cqe) is available, it
    // will resume the coroutine that submitted the request corresponding to that cqe.
    pub fn run_event_loop(self: *AsyncIOUring) !void {
        var cqes: [4096]linux.io_uring_cqe = undefined;
        // We want our program to resume as soon as any event we've submitted
        // is ready, so we set this to 1.
        const max_num_events_to_wait_for_in_kernel = 1;

        // Number of events submitted minus number of events completed. We can
        // exit when this is 0.
        //
        // TODO: See if there's a way to do this with builtin IO_Uring methods.
        //       Didn't see how at first glance. Specifically I don't know how
        //       to find if there are previously submitted events that aren't
        //       complete yet.
        var num_outstanding_events: u64 = 0;

        while (true) {
            const num_submited = try self.ring.submit();
            num_outstanding_events += num_submited;

            // If we have no outstanding events even after submitting, that
            // means there's no more work to be done and we can exit.
            if (num_outstanding_events == 0) {
                break;
            }

            const num_ready_cqes = try self.ring.copy_cqes(cqes[0..], max_num_events_to_wait_for_in_kernel);

            num_outstanding_events -= num_ready_cqes;
            for (cqes[0..num_ready_cqes]) |cqe| {
                if (cqe.user_data != 0) {
                    var resume_node = @intToPtr(*ResumeNode, cqe.user_data);
                    resume_node.result = cqe;
                    // Set this back to the user-specified user_data.
                    resume_node.result.user_data = resume_node.user_data;
                    resume resume_node.frame;
                }
            }
        }
    }
};
