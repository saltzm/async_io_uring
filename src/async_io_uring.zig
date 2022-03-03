const std = @import("std");
const builtin = @import("builtin");

const os = std.os;
const linux = os.linux;
const IO_Uring = linux.IO_Uring;

/// Wrapper for IO_Uring that turns its functions into async functions that
/// suspend after enqueuing entries to the submission queue, and resume and
/// return once a result is available in the completion queue.
///
/// Usage requires calling AsyncIOUring.run_event_loop to submit and process
/// completion queue entries.
///
/// As an overview for the unfamiliar, io_uring works by allowing users to
/// enqueue requests into a submission queue (e.g. a request to read from a
/// socket) and then submit the submission queue to the kernel for processing.
/// When requests from the submission queue have been satisfied, the result is
/// placed onto completion queue by the kernel. The user is able to either poll
/// the kernel for completion queue results or block until results are
/// available.
///
/// Parts of the function-level comments were copied from the IO_Uring library.
/// More details on each function can be found in the comments of the IO_Uring
/// library functions that this wraps, since this is just a thin wrapper for
/// those. If any of those functions require modification of the SQE before
/// submitting an operation, users of AsyncIOUring must make their own
/// operation struct with a custom run function. See 
/// testReadWithManualAPIAndOverridenSubmit for an example.
///
/// Note on abbreviations:
///      SQE == submission queue entry
///      CQE == completion queue entry
///
/// TODO: 
///     * Implement or demonstrate how to mimic the behavior of timeout and
///       timeout_remove (1 hr)
///     * Implement poll_add, poll_remove, poll_update - the latter two require
///       user_data from poll_add (30 min - 1 hr)
pub const AsyncIOUring = struct {
    // Users may access this field directly to call functionson the IO_Uring
    // which do not require use of the submission queue, such as register_files
    // and the other register_* functions.
    ring: *IO_Uring = undefined,

    // Number of events submitted minus number of events completed. We can
    // exit when this is 0.
    num_outstanding_events: u64 = 0,

    /// Runs a loop to submit tasks on the underlying IO_Uring and block waiting
    /// for completion events. When a completion queue event (cqe) is available, it
    /// will resume the coroutine that submitted the request corresponding to that cqe.
    pub fn run_event_loop(self: *AsyncIOUring) !void {
        // TODO: Make this a comptime parameter?
        var cqes: [4096]linux.io_uring_cqe = undefined;
        // We want our program to resume as soon as any event we've submitted
        // is ready, so we set this to 1.
        const max_num_events_to_wait_for_in_kernel = 1;

        while (true) {
            const num_submitted = try self.ring.submit();
            self.num_outstanding_events += num_submitted;

            // If we have no outstanding events even after submitting, that
            // means there's no more work to be done and we can exit.
            if (self.num_outstanding_events == 0) {
                break;
            }

            const num_ready_cqes = try self.ring.copy_cqes(cqes[0..], max_num_events_to_wait_for_in_kernel);

            self.num_outstanding_events -= num_ready_cqes;

            for (cqes[0..num_ready_cqes]) |cqe| {
                if (cqe.user_data != 0) {
                    var resume_node = @intToPtr(*ResumeNode, cqe.user_data);
                    resume_node.result = cqe;
                    // Resume the frame that enqueued the original request.
                    resume resume_node.frame;
                }
            }
        }
    }

    /// Submits a user-supplied IO_Uring operation to the submission queue and
    /// suspends until the result of that operation is available in the
    /// completion queue.
    ///
    /// If a timeout is supplied, that timeout will be set on the provided
    /// operation and if the timeout expires before the operation completes,
    /// the operation will return error.Cancelled. 
    ///
    /// If a pointer to an id is supplied, that id will be set to a value that
    /// can be used to cancel the operation using the function
    /// AsyncIOUring.cancel. This id is only valid prior to awaiting the result
    /// of the call to 'do'.
    ///
    /// Note that operations may non-deterministically return the error code
    /// error.Cancelled if cancelled by the kernel. (This corresponds to
    /// EINTR.) If you wish to retry on such errors, you must do so manually.
    /// TODO: Consider doing this automatically or allowing a parameter that
    /// lets users decide to retry on Cancelled. The problem is that if they set
    /// a timeout then Cancelled is actually expected. We could also possibly
    /// always retry unless timeout or id are set, since if neither are
    /// provided then we know the user did not expect cancellation to occur.
    pub fn do(
        self: *AsyncIOUring,
        op: anytype,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };

        // Check if the submission queue has enough space for this operation
        // and its timeout, and if not, submit the current entries in the queue
        // and wait for enough space to be available in the queue to submit
        // this operation.
        {
            const num_required_sqes_for_op = op.getNumRequiredSubmissionQueueEntries();
            const num_required_sqes = if (timeout) |_| num_required_sqes_for_op + 1 else num_required_sqes_for_op;

            const num_free_entries_in_sq = @intCast(u32, self.ring.sq.sqes.len - self.ring.sq_ready());
            if (num_free_entries_in_sq < num_required_sqes) {
                const num_submitted = try self.ring.submit_and_wait(num_required_sqes -
                    num_free_entries_in_sq);
                self.num_outstanding_events += num_submitted;
            }
        }

        // Submit the IO_Uring op to the submission queue.
        const sqe = try op.submit(self.ring, &node);
        // Attach a linked timeout if one is supplied.
        if (timeout) |t| {
            sqe.flags |= linux.IOSQE_IO_LINK;
            // No user data - we don't care about the result, since it
            // will show up in the result of sqe as -INTR if the
            // timeout expires before the operation completes.
            _ = try self.ring.link_timeout(0, t.ts, t.flags);
        }

        // Set the id for cancellation if one is supplied. Note: This must go
        // prior to suspend.
        if (id) |i| {
            i.* = @ptrToInt(&node);
        }

        // Suspend here until resumed by the event loop when the result of
        // this operation is processed in the completion queue.
        suspend {}

        // If the return code indicates success,
        // return the result.
        if (node.result.res >= 0) {
            return node.result;
        } else {
            return @TypeOf(op).convertError(@intToEnum(os.E, -node.result.res));
        }
    }

    /// Queues (but does not submit) an SQE to remove an existing operation and suspends until the
    /// operation has been cancelled (or been found not to exist).
    ///
    /// Returns a pointer to the CQE.
    ///
    /// The operation is identified by the operation id passed to
    /// AsyncIOUring.do.
    ///
    /// The completion event result will be `0` if the operation was found and
    /// cancelled successfully.
    ///
    /// If the operation was found but was already in progress, it will return
    /// error.OperationAlreadyInProgress.
    ///
    /// If the operation was not found, it will return error.OperationNotFound.
    pub fn cancel(
        self: *AsyncIOUring,
        operation_id: u64,
        flags: u32,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(Cancel{ .cancel_user_data = operation_id, .flags = flags }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform an `fsync(2)` and
    /// suspends until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn fsync(
        self: *AsyncIOUring,
        fd: os.fd_t,
        flags: u32,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(Fsync{ .fd = fd, .flags = flags }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a no-op and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn nop(
        self: *AsyncIOUring,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(Nop{}, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a `read(2)` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn read(
        self: *AsyncIOUring,
        fd: os.fd_t,
        buffer: []u8,
        offset: u64,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(Read{ .fd = fd, .buffer = buffer, .offset = offset }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a `write(2)` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn write(
        self: *AsyncIOUring,
        fd: os.fd_t,
        buffer: []const u8,
        offset: u64,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(Write{ .fd = fd, .buffer = buffer, .offset = offset }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a `preadv()` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn readv(
        self: *AsyncIOUring,
        fd: os.fd_t,
        iovecs: []const os.iovec,
        offset: u64,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(ReadV{ .fd = fd, .iovecs = iovecs, .offset = offset }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a IORING_OP_READ_FIXED and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn read_fixed(
        self: *AsyncIOUring,
        fd: os.fd_t,
        buffer: *os.iovec,
        offset: u64,
        buffer_index: u16,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(ReadFixed{ .fd = fd, .buffer = buffer, .offset = offset, .buffer_index = buffer_index }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a `pwritev()` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn writev(
        self: *AsyncIOUring,
        fd: os.fd_t,
        iovecs: []const os.iovec_const,
        offset: u64,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(WriteV{ .fd = fd, .iovecs = iovecs, .offset = offset }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a IORING_OP_WRITE_FIXED and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn write_fixed(
        self: *AsyncIOUring,
        fd: os.fd_t,
        buffer: *os.iovec,
        offset: u64,
        buffer_index: u16,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(WriteFixed{ .fd = fd, .buffer = buffer, .offset = offset, .buffer_index = buffer_index }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform an `accept4(2)` on a socket and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn accept(
        self: *AsyncIOUring,
        fd: os.fd_t,
        addr: *os.sockaddr,
        addrlen: *os.socklen_t,
        flags: u32,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(Accept{ .fd = fd, .addr = addr, .addrlen = addrlen, .flags = flags }, timeout, id);
    }

    /// Queue (but does not submit) an SQE to perform a `connect(2)` on a socket and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn connect(
        self: *AsyncIOUring,
        fd: os.fd_t,
        addr: *const os.sockaddr,
        addrlen: os.socklen_t,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(Connect{ .fd = fd, .addr = addr, .addrlen = addrlen }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a `epoll_ctl(2)` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn epoll_ctl(
        self: *AsyncIOUring,
        epfd: os.fd_t,
        fd: os.fd_t,
        op: u32,
        ev: ?*linux.epoll_event,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(EpollCtl{ .epfd = epfd, .fd = fd, .op = op, .ev = ev }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a `recv(2)` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn recv(
        self: *AsyncIOUring,
        fd: os.fd_t,
        buffer: []u8,
        flags: u32,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(Recv{ .fd = fd, .buffer = buffer, .flags = flags }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a `send(2)` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn send(
        self: *AsyncIOUring,
        fd: os.fd_t,
        buffer: []const u8,
        flags: u32,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(Send{ .fd = fd, .buffer = buffer, .flags = flags }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform an `openat(2)` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn openat(
        self: *AsyncIOUring,
        fd: os.fd_t,
        path: [*:0]const u8,
        flags: u32,
        mode: os.mode_t,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(OpenAt{ .fd = fd, .path = path, .flags = flags, .mode = mode }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a `close(2)` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn close(
        self: *AsyncIOUring,
        fd: os.fd_t,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(Close{ .fd = fd }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform an `fallocate(2)` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn fallocate(
        self: *AsyncIOUring,
        fd: os.fd_t,
        mode: i32,
        offset: u64,
        len: u64,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(Fallocate{ .fd = fd, .mode = mode, .offset = offset, .len = len }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform an `statx(2)` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn statx(
        self: *AsyncIOUring,
        fd: os.fd_t,
        path: [:0]const u8,
        flags: u32,
        mask: u32,
        buf: *linux.Statx,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(Statx{ .fd = fd, .path = path, .flags = flags, .mask = mask, .buf = buf }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a `shutdown(2)` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn shutdown(
        self: *AsyncIOUring,
        sockfd: os.socket_t,
        how: u32,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(Shutdown{ .sockfd = sockfd, .how = how }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a `renameat2(2)` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn renameat(
        self: *AsyncIOUring,
        old_dir_fd: os.fd_t,
        old_path: [*:0]const u8,
        new_dir_fd: os.fd_t,
        new_path: [*:0]const u8,
        flags: u32,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(RenameAt{
            .old_dir_fd = old_dir_fd,
            .old_path = old_path,
            .new_dir_fd = new_dir_fd,
            .new_path = new_path,
            .flags = flags,
        }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a `unlinkat(2)` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn unlinkat(
        self: *AsyncIOUring,
        dir_fd: os.fd_t,
        path: [*:0]const u8,
        flags: u32,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(UnlinkAt{ .dir_fd = dir_fd, .path = path, .flags = flags }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a `mkdirat(2)` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn mkdirat(
        self: *AsyncIOUring,
        dir_fd: os.fd_t,
        path: [*:0]const u8,
        mode: os.mode_t,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(MkdirAt{ .dir_fd = dir_fd, .path = path, .mode = mode }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a `symlinkat(2)` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn symlinkat(
        self: *AsyncIOUring,
        target: [*:0]const u8,
        new_dir_fd: os.fd_t,
        link_path: [*:0]const u8,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(SymlinkAt{ .target = target, .new_dir_fd = new_dir_fd, .link_path = link_path }, timeout, id);
    }

    /// Queues (but does not submit) an SQE to perform a `linkat(2)` and suspends
    /// until the operation has been completed.
    ///
    /// Returns the CQE for the operation.
    pub fn linkat(
        self: *AsyncIOUring,
        old_dir_fd: os.fd_t,
        old_path: [*:0]const u8,
        new_dir_fd: os.fd_t,
        new_path: [*:0]const u8,
        flags: u32,
        timeout: ?Timeout,
        id: ?*usize,
    ) !linux.io_uring_cqe {
        return self.do(LinkAt{
            .old_dir_fd = old_dir_fd,
            .old_path = old_path,
            .new_dir_fd = new_dir_fd,
            .new_path = new_path,
            .flags = flags,
        }, timeout, id);
    }
};

// Used as user data for submission queue entries, so that the event loop can
// have resume the callers frame.
const ResumeNode = struct {
    frame: anyframe = undefined,
    result: linux.io_uring_cqe = undefined,
};

/// Represents an operation timeout.
pub const Timeout = struct {
    ts: *const os.linux.kernel_timespec,
    flags: u32,
};

const DefaultError = error{Cancelled} || std.os.UnexpectedError;

// Fallback error-handling for interruption/cancellation errors.
fn defaultConvertError(linux_err: os.E) DefaultError {
    return switch (linux_err) {
        .INTR, .CANCELED => error.Cancelled,
        else => |err| os.unexpectedErrno(err),
    };
}

////////////////////////////////////////////////////////////////////////////////
// The following are structs defined for individual operations that may be    //
// passed directly to the `AsyncIOUring.do` function. Users may define their  //
// own structs with the same interface as these to implement custom use cases //
// that require e.g. modification of the SQE prior to submission. See test    //
// cases for examples.                                                        //
////////////////////////////////////////////////////////////////////////////////

pub const Read = struct {
    fd: os.fd_t,
    buffer: []u8,
    offset: u64,

    const Error = std.os.ReadError || DefaultError;

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return try ring.read(@ptrToInt(node), op.fd, op.buffer, op.offset);
    }

    /// See read man pages for specific meaning of possible errors: 
    /// http://manpages.ubuntu.com/manpages/impish/man2/read.2.html#errors
    pub fn convertError(linux_err: os.E) Error {
        return switch (linux_err) {
            // Copied from std.os.read.
            .INVAL => unreachable,
            .FAULT => unreachable,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForReading, // Can be a race condition.
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            else => |err| defaultConvertError(err),
        };
    }
};

pub const Write = struct {
    fd: os.fd_t,
    buffer: []const u8,
    offset: u64,

    const Error = std.os.WriteError || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        return switch (linux_err) {
            // Copied from std.os.write.
            .INVAL => unreachable,
            .FAULT => unreachable,
            .AGAIN => unreachable,
            .BADF => error.NotOpenForWriting, // can be a race condition.
            .DESTADDRREQ => unreachable, // `connect` was never called.
            .DQUOT => error.DiskQuota,
            .FBIG => error.FileTooBig,
            .IO => error.InputOutput,
            .NOSPC => error.NoSpaceLeft,
            .PERM => error.AccessDenied,
            .PIPE => error.BrokenPipe,
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.write(@ptrToInt(node), op.fd, op.buffer, op.offset);
    }
};

pub const ReadV = struct {
    fd: os.fd_t,
    iovecs: []const os.iovec,
    offset: u64,

    const Error = std.os.PReadError || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.preadv.
        return switch (linux_err) {
            .INVAL => unreachable,
            .FAULT => unreachable,
            .AGAIN => error.WouldBlock,
            .BADF => error.NotOpenForReading, // can be a race condition
            .IO => error.InputOutput,
            .ISDIR => error.IsDir,
            .NOBUFS => error.SystemResources,
            .NOMEM => error.SystemResources,
            .NXIO => error.Unseekable,
            .SPIPE => error.Unseekable,
            .OVERFLOW => error.Unseekable,
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.readv(@ptrToInt(node), op.fd, op.iovecs, op.offset);
    }
};

pub const ReadFixed = struct {
    fd: os.fd_t,
    buffer: *os.iovec,
    offset: u64,
    buffer_index: u16,

    // TODO: Double-check this.
    const convertError = Read.convertError;

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.read_fixed(@ptrToInt(node), op.fd, op.buffer, op.offset, op.buffer_index);
    }
};

pub const WriteV = struct {
    fd: os.fd_t,
    iovecs: []const os.iovec_const,
    offset: u64,

    const Error = std.os.PWriteError || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.pwritev.
        return switch (linux_err) {
            .INVAL => unreachable,
            .FAULT => unreachable,
            .AGAIN => error.WouldBlock,
            .BADF => error.NotOpenForWriting, // Can be a race condition.
            .DESTADDRREQ => unreachable, // `connect` was never called.
            .DQUOT => error.DiskQuota,
            .FBIG => error.FileTooBig,
            .IO => error.InputOutput,
            .NOSPC => error.NoSpaceLeft,
            .PERM => error.AccessDenied,
            .PIPE => error.BrokenPipe,
            .CONNRESET => error.ConnectionResetByPeer,
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.writev(@ptrToInt(node), op.fd, op.iovecs, op.offset);
    }
};

pub const WriteFixed = struct {
    fd: os.fd_t,
    buffer: *os.iovec,
    offset: u64,
    buffer_index: u16,

    // TODO: Double-check this.
    const convertError = Write.convertError;

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.write_fixed(@ptrToInt(node), op.fd, op.buffer, op.offset, op.buffer_index);
    }
};

pub const Accept = struct {
    fd: os.fd_t,
    addr: *os.sockaddr,
    addrlen: *os.socklen_t,
    flags: u32,

    const Error = std.os.AcceptError || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.accept.
        return switch (linux_err) {
            .AGAIN => error.WouldBlock,
            .BADF => unreachable, // always a race condition
            .CONNABORTED => error.ConnectionAborted,
            .FAULT => unreachable,
            .INVAL => error.SocketNotListening,
            .NOTSOCK => unreachable,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NOBUFS => error.SystemResources,
            .NOMEM => error.SystemResources,
            .OPNOTSUPP => unreachable,
            .PROTO => error.ProtocolFailure,
            .PERM => error.BlockedByFirewall,
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.accept(@ptrToInt(node), op.fd, op.addr, op.addrlen, op.flags);
    }
};

pub const Connect = struct {
    fd: os.fd_t,
    addr: *const os.sockaddr,
    addrlen: os.socklen_t,

    const Error = std.os.ConnectError || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.connect.
        return switch (linux_err) {
            .ACCES => error.PermissionDenied,
            .PERM => error.PermissionDenied,
            .ADDRINUSE => error.AddressInUse,
            .ADDRNOTAVAIL => error.AddressNotAvailable,
            .AFNOSUPPORT => error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => error.WouldBlock,
            .ALREADY => error.ConnectionPending,
            .BADF => unreachable, // sockfd is not a valid open file descriptor.
            .CONNREFUSED => error.ConnectionRefused,
            .CONNRESET => error.ConnectionResetByPeer,
            .FAULT => unreachable, // The socket structure address is outside the user's address space.
            .ISCONN => unreachable, // The socket is already connected.
            .NETUNREACH => error.NetworkUnreachable,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .PROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
            .TIMEDOUT => error.ConnectionTimedOut,
            .NOENT => error.FileNotFound, // Returned when socket is AF.UNIX and the given path does not exist.
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.connect(@ptrToInt(node), op.fd, op.addr, op.addrlen);
    }
};

pub const Recv = struct {
    fd: os.fd_t,
    buffer: []u8,
    flags: u32,

    const Error = std.os.RecvFromError || DefaultError;

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.recv(@ptrToInt(node), op.fd, op.buffer, op.flags);
    }

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.recvfrom.
        return switch (linux_err) {
            .BADF => unreachable, // always a race condition
            .FAULT => unreachable,
            .INVAL => unreachable,
            .NOTCONN => unreachable,
            .NOTSOCK => unreachable,
            .AGAIN => error.WouldBlock,
            .NOMEM => error.SystemResources,
            .CONNREFUSED => error.ConnectionRefused,
            .CONNRESET => error.ConnectionResetByPeer,
            else => |err| defaultConvertError(err),
        };
    }
};

pub const Fsync = struct {
    fd: os.fd_t,
    flags: u32,

    const Error = std.os.SyncError || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.fsync.
        return switch (linux_err) {
            .BADF, .INVAL, .ROFS => unreachable,
            .IO => error.InputOutput,
            .NOSPC => error.NoSpaceLeft,
            .DQUOT => error.DiskQuota,
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.fsync(@ptrToInt(node), self.fd, self.flags);
    }
};

pub const Fallocate = struct {
    fd: os.fd_t,
    mode: i32,
    offset: u64,
    len: u64,

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.fallocate(@ptrToInt(node), self.fd, self.mode, self.offset, self.len);
    }

    const Error = DefaultError;

    // TODO: fallocate can only return '1' as an error code according to the
    // manpages. Right now this will lead to "UnexpectedError" which is not
    // really correct.
    pub fn convertError(linux_err: os.E) Error {
        return defaultConvertError(linux_err);
    }
};

pub const Statx = struct {
    fd: os.fd_t,
    path: [:0]const u8,
    flags: u32,
    mask: u32,
    buf: *linux.Statx,

    // Comments for these errors were copied from Ubuntu manpages on Ubuntu 20.04, Linux
    // kernel version 5.13.0-25-generic.
    const Error = error{
        /// Search permission is denied for one of the directories in the path
        /// prefix of path.
        AccessDenied,
        /// Too many symbolic links encountered while traversing the path.
        SymLinkLoop,
        /// path is too long.
        NameTooLong,
        /// A component of path does not exist, or path is an empty string and
        /// AT_EMPTY_PATH was not specified in flags.
        FileNotFound,
        /// Out of memory (i.e., kernel memory).
        SystemResources,
        /// A component of the path prefix of path is not a directory or path
        /// is relative and fd is a file descriptor referring to a file other
        /// than a directory.
        NotDir,
    } || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.preadv.
        return switch (linux_err) {
            .ACCESS => error.AccessDenied,
            // fd is not a valid open file descriptor.
            .BADF => unreachable,
            // path or buf is NULL or points to a location outside the
            // process's accessible address space.
            .FAULT => unreachable,
            // Invalid flag specified in flags or reserved flag specified
            // in mask.
            .INVAL => unreachable,
            .LOOP => error.SymLinkLoop,
            .NAMETOOLONG => error.NameTooLong,
            .NOENT => error.FileNotFound,
            .NOMEM => error.SystemResources,
            .NOTDIR => error.NotDir,
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.statx(@ptrToInt(node), self.fd, self.path, self.flags, self.mask, self.buf);
    }
};

pub const Shutdown = struct {
    sockfd: os.socket_t,
    how: u32,

    const Error = std.os.ShutdownError || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.shutdown.
        return switch (linux_err) {
            .BADF => unreachable,
            .INVAL => unreachable,
            .NOTCONN => error.SocketNotConnected,
            .NOTSOCK => unreachable,
            .NOBUFS => error.SystemResources,
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.shutdown(@ptrToInt(node), self.sockfd, self.how);
    }
};

pub const RenameAt = struct {
    old_dir_fd: os.fd_t,
    old_path: [*:0]const u8,
    new_dir_fd: os.fd_t,
    new_path: [*:0]const u8,
    flags: u32,

    const Error = std.os.RenameError || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.renameatZ.
        return switch (linux_err) {
            .ACCES => error.AccessDenied,
            .PERM => error.AccessDenied,
            .BUSY => error.FileBusy,
            .DQUOT => error.DiskQuota,
            .FAULT => unreachable,
            .INVAL => unreachable,
            .ISDIR => error.IsDir,
            .LOOP => error.SymLinkLoop,
            .MLINK => error.LinkQuotaExceeded,
            .NAMETOOLONG => error.NameTooLong,
            .NOENT => error.FileNotFound,
            .NOTDIR => error.NotDir,
            .NOMEM => error.SystemResources,
            .NOSPC => error.NoSpaceLeft,
            .EXIST => error.PathAlreadyExists,
            .NOTEMPTY => error.PathAlreadyExists,
            .ROFS => error.ReadOnlyFileSystem,
            .XDEV => error.RenameAcrossMountPoints,
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.renameat(
            @ptrToInt(node),
            self.old_dir_fd,
            self.old_path,
            self.new_dir_fd,
            self.new_path,
            self.flags,
        );
    }
};

pub const UnlinkAt = struct {
    dir_fd: os.fd_t,
    path: [*:0]const u8,
    flags: u32,

    const Error = std.os.UnlinkError || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.unlinkZ.
        return switch (linux_err) {
            .ACCES => error.AccessDenied,
            .PERM => error.AccessDenied,
            .BUSY => error.FileBusy,
            .FAULT => unreachable,
            .INVAL => unreachable,
            .IO => error.FileSystem,
            .ISDIR => error.IsDir,
            .LOOP => error.SymLinkLoop,
            .NAMETOOLONG => error.NameTooLong,
            .NOENT => error.FileNotFound,
            .NOTDIR => error.NotDir,
            .NOMEM => error.SystemResources,
            .ROFS => error.ReadOnlyFileSystem,
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.unlinkat(@ptrToInt(node), self.dir_fd, self.path, self.flags);
    }
};

pub const MkdirAt = struct {
    dir_fd: os.fd_t,
    path: [*:0]const u8,
    mode: os.mode_t,

    const Error = std.os.MakeDirError || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.mkdiratZ.
        return switch (linux_err) {
            .ACCES => error.AccessDenied,
            .BADF => unreachable,
            .PERM => error.AccessDenied,
            .DQUOT => error.DiskQuota,
            .EXIST => error.PathAlreadyExists,
            .FAULT => unreachable,
            .LOOP => error.SymLinkLoop,
            .MLINK => error.LinkQuotaExceeded,
            .NAMETOOLONG => error.NameTooLong,
            .NOENT => error.FileNotFound,
            .NOMEM => error.SystemResources,
            .NOSPC => error.NoSpaceLeft,
            .NOTDIR => error.NotDir,
            .ROFS => error.ReadOnlyFileSystem,
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.mkdirat(@ptrToInt(node), self.dir_fd, self.path, self.mode);
    }
};

pub const SymlinkAt = struct {
    target: [*:0]const u8,
    new_dir_fd: os.fd_t,
    link_path: [*:0]const u8,

    const Error = std.os.SymLinkError || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.symlinkatZ.
        return switch (linux_err) {
            .FAULT => unreachable,
            .INVAL => unreachable,
            .ACCES => return error.AccessDenied,
            .PERM => return error.AccessDenied,
            .DQUOT => return error.DiskQuota,
            .EXIST => return error.PathAlreadyExists,
            .IO => return error.FileSystem,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .ROFS => return error.ReadOnlyFileSystem,
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.symlinkat(@ptrToInt(node), self.target, self.new_dir_fd, self.link_path);
    }
};

pub const LinkAt = struct {
    old_dir_fd: os.fd_t,
    old_path: [*:0]const u8,
    new_dir_fd: os.fd_t,
    new_path: [*:0]const u8,
    flags: u32,

    const Error = std.os.LinkatError || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.linkatZ.
        return switch (linux_err) {
            .ACCES => error.AccessDenied,
            .DQUOT => error.DiskQuota,
            .EXIST => error.PathAlreadyExists,
            .FAULT => unreachable,
            .IO => error.FileSystem,
            .LOOP => error.SymLinkLoop,
            .MLINK => error.LinkQuotaExceeded,
            .NAMETOOLONG => error.NameTooLong,
            .NOENT => error.FileNotFound,
            .NOMEM => error.SystemResources,
            .NOSPC => error.NoSpaceLeft,
            .NOTDIR => error.NotDir,
            .PERM => error.AccessDenied,
            .ROFS => error.ReadOnlyFileSystem,
            .XDEV => error.NotSameFileSystem,
            .INVAL => unreachable,
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.linkat(
            @ptrToInt(node),
            self.old_dir_fd,
            self.old_path,
            self.new_dir_fd,
            self.new_path,
            self.flags,
        );
    }
};

pub const Send = struct {
    fd: os.fd_t,
    buffer: []const u8,
    flags: u32,

    const Error = std.os.SendError || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.sendto + std.os.send.
        // TODO: Double-check some of these unreachables with send man pages.
        return switch (linux_err) {
            .ACCES => error.AccessDenied,
            .AGAIN => error.WouldBlock,
            .ALREADY => error.FastOpenAlreadyInProgress,
            .BADF => unreachable, // always a race condition
            .CONNRESET => error.ConnectionResetByPeer,
            .DESTADDRREQ => unreachable, // The socket is not connection-mode, and no peer address is set.
            .FAULT => unreachable, // An invalid user space address was specified for an argument.
            .INVAL => unreachable, // Invalid argument passed.
            .ISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
            .MSGSIZE => error.MessageTooBig,
            .NOBUFS => error.SystemResources,
            .NOMEM => error.SystemResources,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .OPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
            .PIPE => error.BrokenPipe,
            .AFNOSUPPORT => unreachable,
            .LOOP => unreachable,
            .NAMETOOLONG => unreachable,
            .NOENT => unreachable,
            .NOTDIR => unreachable,
            .HOSTUNREACH => unreachable,
            .NETUNREACH => unreachable,
            .NOTCONN => unreachable,
            .NETDOWN => error.NetworkSubsystemFailed,
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.send(@ptrToInt(node), op.fd, op.buffer, op.flags);
    }
};

pub const OpenAt = struct {
    fd: os.fd_t,
    path: [*:0]const u8,
    flags: u32,
    mode: os.mode_t,

    const Error = std.os.OpenError || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.openatZ.
        return switch (linux_err) {
            .FAULT => unreachable,
            .INVAL => unreachable,
            .BADF => unreachable,
            .ACCES => error.AccessDenied,
            .FBIG => error.FileTooBig,
            .OVERFLOW => error.FileTooBig,
            .ISDIR => error.IsDir,
            .LOOP => error.SymLinkLoop,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => error.NameTooLong,
            .NFILE => error.SystemFdQuotaExceeded,
            .NODEV => error.NoDevice,
            .NOENT => error.FileNotFound,
            .NOMEM => error.SystemResources,
            .NOSPC => error.NoSpaceLeft,
            .NOTDIR => error.NotDir,
            .PERM => error.AccessDenied,
            .EXIST => error.PathAlreadyExists,
            .BUSY => error.DeviceBusy,
            .OPNOTSUPP => error.FileLocksNotSupported,
            .AGAIN => error.WouldBlock,
            .TXTBSY => error.FileBusy,
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.openat(@ptrToInt(node), op.fd, op.path, op.flags, op.mode);
    }
};

pub const Close = struct {
    fd: os.fd_t,

    const Error = DefaultError;

    // TODO: The stdlib says that INTR on close is actually an indicator of
    // success - so we may need a way to convert that to success here. For now,
    // the caller can ignore error.Cancelled.
    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.close.
        return switch (linux_err) {
            .BADF => unreachable, // Always a race condition.
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.close(@ptrToInt(node), op.fd);
    }
};

pub const Cancel = struct {
    cancel_user_data: u64,
    flags: u32,

    pub fn convertError(linux_err: os.E) anyerror {
        return switch (linux_err) {
            .ALREADY => error.OperationAlreadyInProgress,
            .NOENT => error.OperationNotFound,
            else => |err| return defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.cancel(@ptrToInt(node), op.cancel_user_data, op.flags);
    }
};

pub const Nop = struct {
    const Error = DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        return defaultConvertError(linux_err);
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(_: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.nop(@ptrToInt(node));
    }
};

pub const EpollCtl = struct {
    epfd: os.fd_t,
    fd: os.fd_t,
    op: u32,
    ev: ?*linux.epoll_event,

    const Error = std.os.EpollCtlError || DefaultError;

    pub fn convertError(linux_err: os.E) Error {
        // Copied from std.os.epoll_ctl.
        return switch (linux_err) {
            .BADF => unreachable, // always a race condition if this happens
            .EXIST => error.FileDescriptorAlreadyPresentInSet,
            .INVAL => unreachable,
            .LOOP => error.OperationCausesCircularLoop,
            .NOENT => error.FileDescriptorNotRegistered,
            .NOMEM => error.SystemResources,
            .NOSPC => error.UserResourceLimitReached,
            .PERM => error.FileDescriptorIncompatibleWithEpoll,
            else => |err| defaultConvertError(err),
        };
    }

    pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
        return 1;
    }

    pub fn submit(this: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.epoll_ctl(@ptrToInt(node), this.epfd, this.fd, this.op, this.ev);
    }
};

fn testWrite(ring: *AsyncIOUring) !void {
    const path = "test_io_uring_write_read";
    const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
    defer file.close();
    defer std.fs.cwd().deleteFile(path) catch {};
    const fd = file.handle;

    const write_buffer = [_]u8{9} ** 20;
    const cqe_write = try ring.write(fd, write_buffer[0..], 0, null, null);
    try std.testing.expectEqual(cqe_write.res, write_buffer.len);

    var read_buffer = [_]u8{0} ** 20;
    // Do an ordinary blocking read to check that the bytes were written.
    const num_bytes_read = try file.readAll(read_buffer[0..]);
    try std.testing.expectEqualSlices(u8, read_buffer[0..num_bytes_read], write_buffer[0..]);
}

test "write" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(1, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var async_ring = AsyncIOUring{ .ring = &ring };

    var write_frame = async testWrite(&async_ring);

    try async_ring.run_event_loop();

    try nosuspend await write_frame;
}

test "write handles full submission queue" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(4, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var async_ring = AsyncIOUring{ .ring = &ring };

    // Random number to identify the no-ops.
    const nop_user_data = 9;
    var num_submitted: u32 = 0;
    // Fill up the submission queue.
    while (true) {
        var sqe = ring.nop(nop_user_data) catch |err| {
            switch (err) {
                error.SubmissionQueueFull => {
                    break;
                },
                else => {
                    return err;
                },
            }
        };
        num_submitted += 1;
        sqe.user_data = 9;
    }

    try std.testing.expect(num_submitted > 0);

    // Try to do a write - we expect this to submit the existing submission
    // queue entries to the kernel and then retry adding the write to the
    // submission queue and succeed.
    var write_frame = async testWrite(&async_ring);

    // A bit hacky - make sure the previous no-ops were submitted, but not the
    // write itself.
    var cqes: [256]linux.io_uring_cqe = undefined;
    const num_ready_cqes = try ring.copy_cqes(cqes[0..], num_submitted);
    async_ring.num_outstanding_events -= num_ready_cqes;

    try std.testing.expectEqual(num_ready_cqes, num_submitted);
    for (cqes[0..num_ready_cqes]) |cqe| {
        try std.testing.expectEqual(cqe.user_data, nop_user_data);
    }

    // Make sure the write itself hasn't been submitted.
    try std.testing.expectEqual(ring.sq_ready(), 1);
    // Inspect the last submission queue entry to check that it's actually a
    // write. There's no way to get this from IO_Uring without directly
    // inspecting its SubmissionQueue, AFAICT, so we do that for now.
    var sqe = &ring.sq.sqes[(ring.sq.sqe_tail - 1) & ring.sq.mask];
    try std.testing.expectEqual(sqe.opcode, .WRITE);

    // This should submit the write and wait for it to occur.
    try async_ring.run_event_loop();

    try nosuspend await write_frame;
}

fn testRead(ring: *AsyncIOUring) !void {
    const path = "test_io_uring_write_read";
    const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
    defer file.close();
    defer std.fs.cwd().deleteFile(path) catch {};
    const fd = file.handle;

    const write_buffer = [_]u8{9} ** 20;
    const cqe_write = try ring.write(fd, write_buffer[0..], 0, null, null);
    try std.testing.expectEqual(cqe_write.res, write_buffer.len);

    var read_buffer = [_]u8{0} ** 20;

    const read_cqe = try ring.read(fd, read_buffer[0..], 0, null, null);
    const num_bytes_read = @intCast(usize, read_cqe.res);
    try std.testing.expectEqualSlices(u8, read_buffer[0..num_bytes_read], write_buffer[0..]);
}

fn testReadThatTimesOut(ring: *AsyncIOUring) !void {
    var read_buffer = [_]u8{0} ** 20;

    const ts = os.linux.kernel_timespec{ .tv_sec = 0, .tv_nsec = 10000 };
    // Try to read from stdin - there won't be any input so this should
    // reliably time out.
    const read_cqe = ring.do(
        Read{ .fd = std.io.getStdIn().handle, .buffer = read_buffer[0..], .offset = 0 },
        Timeout{ .ts = &ts, .flags = 0 },
        null,
    );
    try std.testing.expectEqual(read_cqe, error.Cancelled);
}

test "read" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(2, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var async_ring = AsyncIOUring{ .ring = &ring };

    var read_frame = async testRead(&async_ring);

    try async_ring.run_event_loop();

    try nosuspend await read_frame;
}

fn testReadWithManualAPI(ring: *AsyncIOUring) !void {
    var read_buffer = [_]u8{0} ** 20;

    const ts = os.linux.kernel_timespec{ .tv_sec = 0, .tv_nsec = 10000 };
    // Try to read from stdin - there won't be any input so this should
    // reliably time out.
    const read_cqe = ring.do(Read{
        .fd = std.io.getStdIn().handle,
        .buffer = read_buffer[0..],
        .offset = 0,
    }, .{ .ts = &ts, .flags = 0 }, null);

    try std.testing.expectEqual(read_cqe, error.Cancelled);
}

fn testReadWithManualAPIAndOverridenSubmit(ring: *AsyncIOUring) !void {
    var read_buffer = [_]u8{0} ** 20;

    var ran_custom_submit: bool = false;

    // Make a special op based on read.
    const my_read: struct {
        read: Read,
        value_to_set: *bool,

        const convertError = Read.convertError;

        pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
            return 1;
        }

        pub fn submit(self: @This(), my_ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
            self.value_to_set.* = true;
            return try my_ring.read(@ptrToInt(node), self.read.fd, self.read.buffer, self.read.offset);
        }
    } = .{
        .read = .{
            .fd = std.io.getStdIn().handle,
            .buffer = read_buffer[0..],
            .offset = 0,
        },
        .value_to_set = &ran_custom_submit,
    };

    const ts = os.linux.kernel_timespec{ .tv_sec = 0, .tv_nsec = 10000 };
    // Try to read from stdin - there won't be any input so this should
    // reliably time out.
    const read_cqe = ring.do(my_read, Timeout{ .ts = &ts, .flags = 0 }, null);

    try std.testing.expectEqual(read_cqe, error.Cancelled);
    try std.testing.expectEqual(ran_custom_submit, true);
}

fn testOverridingNumberOfSQEs(ring: *AsyncIOUring) !void {
    var ran_custom_submit: bool = false;

    // Make a special op based on read.
    const double_nop: struct {
        value_to_set: *bool,

        const convertError = Read.convertError;

        pub fn getNumRequiredSubmissionQueueEntries(_: @This()) u32 {
            return 2;
        }

        pub fn submit(self: @This(), my_ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
            self.value_to_set.* = true;
            // TODO: Using this in practice will probably be a bit tricky since
            // the timeout only applies to whatever this function returns, not
            // to the first op. This interface maybe seems more generic than it
            // actually is, which sould be a problem
            _ = try my_ring.nop(0);
            return try my_ring.nop(@ptrToInt(node));
        }
    } = .{
        .value_to_set = &ran_custom_submit,
    };

    const nop_cqe = try ring.do(double_nop, null, null);

    try std.testing.expectEqual(nop_cqe.res, 0);
    try std.testing.expectEqual(ran_custom_submit, true);
}

test "overriding number of sqes in custom op submits pending entries when queue would be full" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(2, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var async_ring = AsyncIOUring{ .ring = &ring };

    // After this there will only be 1 slot left in the submission queue - if
    // getNumRequiredSubmissionQueueEntries is not implemented/used correctly,
    // this will cause a SubmissionQueueFull error when we try to submit our
    // custom op.
    _ = try ring.nop(0);

    var read_frame = async testOverridingNumberOfSQEs(&async_ring);

    try async_ring.run_event_loop();

    try nosuspend await read_frame;
}

test "read with manual API" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(2, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var async_ring = AsyncIOUring{ .ring = &ring };

    var read_frame = async testReadWithManualAPI(&async_ring);

    try async_ring.run_event_loop();

    try nosuspend await read_frame;
}

test "read with manual API and overriden submit" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(2, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var async_ring = AsyncIOUring{ .ring = &ring };

    var read_frame = async testReadWithManualAPIAndOverridenSubmit(&async_ring);

    try async_ring.run_event_loop();

    try nosuspend await read_frame;
}

test "read with timeout returns cancelled" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(2, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var async_ring = AsyncIOUring{ .ring = &ring };

    var read_frame = async testReadThatTimesOut(&async_ring);

    try async_ring.run_event_loop();

    try nosuspend await read_frame;
}

test "read with timeout returns cancelled with only 1 submission queue entry free" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(4, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var async_ring = AsyncIOUring{ .ring = &ring };

    _ = try ring.nop(0);
    _ = try ring.nop(0);
    _ = try ring.nop(0);

    // At this point there will only be one submission queue entry free. This
    // should submit the outstanding entries and wait for two slots to be free
    // before submitting the read and its linked timeout.
    var read_frame = async testReadThatTimesOut(&async_ring);

    try async_ring.run_event_loop();

    try nosuspend await read_frame;
}

fn testReadThatIsCancelled(ring: *AsyncIOUring) !void {
    var read_buffer = [_]u8{0} ** 20;

    var op_id: usize = undefined;

    // Try to read from stdin - there won't be any input so this operation should
    // reliably hang until cancellation.
    var read_frame = async ring.do(Read{ .fd = std.io.getStdIn().handle, .buffer = read_buffer[0..], .offset = 0 }, null, &op_id);

    const cancel_cqe = try ring.cancel(op_id, 0, null, null);
    // Expect that cancellation succeeded.
    try std.testing.expectEqual(cancel_cqe.res, 0);

    const read_cqe = await read_frame;
    try std.testing.expectEqual(read_cqe, error.Cancelled);
}

test "read that is cancelled returns cancelled" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(2, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var async_ring = AsyncIOUring{ .ring = &ring };

    var read_frame = async testReadThatIsCancelled(&async_ring);

    try async_ring.run_event_loop();

    try nosuspend await read_frame;
}

fn testCancellingNonExistentOperation(ring: *AsyncIOUring) !void {
    const op_id: u64 = 32;
    _ = ring.cancel(op_id, 0, null, null) catch |err| {
        try std.testing.expectEqual(err, error.OperationNotFound);
        return;
    };
    // Cancellation should not succeed so we should never reach this line.
    unreachable;
}

test "cancelling an operation that doesn't exist returns error.OperationNotFound" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(2, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var async_ring = AsyncIOUring{ .ring = &ring };

    var cancel_frame = async testCancellingNonExistentOperation(&async_ring);

    try async_ring.run_event_loop();

    try nosuspend await cancel_frame;
}
