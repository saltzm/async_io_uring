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
///
/// Note on abbreviations:
///      SQE == submission queue entry
///      CQE == completion queue entry
///
/// TODO: 
///     * Implement or demonstrate how to mimic the behavior of timeout and
///       timeout_remove
///     * Implement poll_add, poll_remove, poll_update - the latter two require
///       user_data from poll_add
///     * Convert anyerror in operation structs to be an error set specific to
///       each operation
///     * Make cancel handle its expected errors properly
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
        // TODO Make this a comptime parameter
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
    ///
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
            // TODO: Allow op to define the number of SQEs it requires -
            // for cases where e.g. a custom op needs to do write + fsync
            const num_required_sqes: u32 = if (timeout) |_| 2 else 1;

            if (self.ring.sq.sqes.len - self.ring.sq_ready() < num_required_sqes) {
                const num_submitted = try self.ring.submit_and_wait(num_required_sqes);
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
            const Op = @TypeOf(op);
            return Op.convertError(@intToEnum(os.E, -node.result.res));
        }
    }

    /// Submits an SQE to remove an existing operation and suspends until the
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
    ) !linux.io_uring_cqe {
        return self.do(Cancel{ .cancel_user_data = operation_id, .flags = flags }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform an `fsync(2)`.
    /// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
    /// For example, for `fdatasync()` you can set `IORING_FSYNC_DATASYNC` in the SQE's `rw_flags`.
    /// N.B. While SQEs are initiated in the order in which they appear in the submission queue,
    /// operations execute in parallel and completions are unordered. Therefore, an application that
    /// submits a write followed by an fsync in the submission queue cannot expect the fsync to
    /// apply to the write, since the fsync may complete before the write is issued to the disk.
    /// You should preferably use `link_with_next_sqe()` on a write's SQE to link it with an fsync,
    /// or else insert a full write barrier using `drain_previous_sqes()` when queueing an fsync.
    pub fn fsync(self: *AsyncIOUring, fd: os.fd_t, flags: u32) !linux.io_uring_cqe {
        return self.do(Fsync{ .fd = fd, .flags = flags }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform a no-op.
    /// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
    /// A no-op is more useful than may appear at first glance.
    /// For example, you could call `drain_previous_sqes()` on the returned SQE, to use the no-op to
    /// know when the ring is idle before acting on a kill signal.
    pub fn nop(self: *AsyncIOUring) !linux.io_uring_cqe {
        return self.do(Nop{});
    }

    /// Queues (but does not submit) an SQE to perform a `read(2)`.
    /// Suspends execution until the resulting CQE is available and returns
    /// that CQE.
    pub fn read(self: *AsyncIOUring, fd: os.fd_t, buffer: []u8, offset: u64) !linux.io_uring_cqe {
        return self.do(Read{ .fd = fd, .buffer = buffer, .offset = offset }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform a `write(2)`.
    /// Suspends execution until the resulting CQE is available and returns
    /// that CQE.
    pub fn write(
        self: *AsyncIOUring,
        fd: os.fd_t,
        buffer: []const u8,
        offset: u64,
    ) !linux.io_uring_cqe {
        return self.do(Write{ .fd = fd, .buffer = buffer, .offset = offset }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform a `preadv()`.
    /// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
    /// For example, if you want to do a `preadv2()` then set `rw_flags` on the returned SQE.
    /// See https://linux.die.net/man/2/preadv.
    pub fn readv(
        self: *AsyncIOUring,
        fd: os.fd_t,
        iovecs: []const os.iovec,
        offset: u64,
    ) !linux.io_uring_cqe {
        return self.do(ReadV{ .fd = fd, .iovecs = iovecs, .offset = offset }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform a IORING_OP_READ_FIXED.
    /// The `buffer` provided must be registered with the kernel by calling `register_buffers` first.
    /// The `buffer_index` must be the same as its index in the array provided to `register_buffers`.
    ///
    /// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
    pub fn read_fixed(
        self: *AsyncIOUring,
        fd: os.fd_t,
        buffer: *os.iovec,
        offset: u64,
        buffer_index: u16,
    ) !linux.io_uring_cqe {
        return self.do(ReadFixed{ .fd = fd, .buffer = buffer, .offset = offset, .buffer_index = buffer_index }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform a `pwritev()`.
    /// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
    /// For example, if you want to do a `pwritev2()` then set `rw_flags` on the returned SQE.
    /// See https://linux.die.net/man/2/pwritev.
    pub fn writev(
        self: *AsyncIOUring,
        fd: os.fd_t,
        iovecs: []const os.iovec_const,
        offset: u64,
    ) !linux.io_uring_cqe {
        return self.do(WriteV{ .fd = fd, .iovecs = iovecs, .offset = offset }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform a IORING_OP_WRITE_FIXED.
    /// The `buffer` provided must be registered with the kernel by calling `register_buffers` first.
    /// The `buffer_index` must be the same as its index in the array provided to `register_buffers`.
    ///
    /// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
    pub fn write_fixed(
        self: *AsyncIOUring,
        fd: os.fd_t,
        buffer: *os.iovec,
        offset: u64,
        buffer_index: u16,
    ) !linux.io_uring_cqe {
        return self.do(WriteFixed{ .fd = fd, .buffer = buffer, .offset = offset, .buffer_index = buffer_index }, null, null);
    }

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
        return self.do(Accept{ .fd = fd, .addr = addr, .addrlen = addrlen, .flags = flags }, null, null);
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
        return self.do(Connect{ .fd = fd, .addr = addr, .addrlen = addrlen }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform a `epoll_ctl(2)`.
    /// Returns a pointer to the SQE.
    pub fn epoll_ctl(
        self: *AsyncIOUring,
        epfd: os.fd_t,
        fd: os.fd_t,
        op: u32,
        ev: ?*linux.epoll_event,
    ) !linux.io_uring_cqe {
        return self.do(EpollCtl{ .epfd = epfd, .fd = fd, .op = op, .ev = ev }, null, null);
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
        return self.do(Recv{ .fd = fd, .buffer = buffer, .flags = flags }, null, null);
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
        return self.do(Send{ .fd = fd, .buffer = buffer, .flags = flags }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform an `openat(2)`.
    /// Returns a pointer to the SQE.
    pub fn openat(
        self: *AsyncIOUring,
        fd: os.fd_t,
        path: [*:0]const u8,
        flags: u32,
        mode: os.mode_t,
    ) !linux.io_uring_cqe {
        return self.do(OpenAt{ .fd = fd, .path = path, .flags = flags, .mode = mode }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform a `close(2)`.
    /// Returns a pointer to the SQE.
    pub fn close(self: *AsyncIOUring, fd: os.fd_t) !linux.io_uring_cqe {
        return self.do(Close{ .fd = fd }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform an `fallocate(2)`.
    /// Returns a pointer to the SQE.
    pub fn fallocate(
        self: *AsyncIOUring,
        fd: os.fd_t,
        mode: i32,
        offset: u64,
        len: u64,
    ) !linux.io_uring_cqe {
        return self.do(Fallocate{ .fd = fd, .mode = mode, .offset = offset, .len = len }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform an `statx(2)`.
    /// Returns a pointer to the SQE.
    pub fn statx(
        self: *AsyncIOUring,
        fd: os.fd_t,
        path: [:0]const u8,
        flags: u32,
        mask: u32,
        buf: *linux.Statx,
    ) !linux.io_uring_cqe {
        return self.do(Statx{ .fd = fd, .path = path, .flags = flags, .mask = mask, .buf = buf }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform a `shutdown(2)`.
    /// Returns a pointer to the SQE.
    ///
    /// The operation is identified by its `user_data`.
    pub fn shutdown(
        self: *AsyncIOUring,
        sockfd: os.socket_t,
        how: u32,
    ) !linux.io_uring_cqe {
        return self.do(Shutdown{ .sockfd = sockfd, .how = how }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform a `renameat2(2)`.
    /// Returns a pointer to the SQE.
    pub fn renameat(
        self: *AsyncIOUring,
        old_dir_fd: os.fd_t,
        old_path: [*:0]const u8,
        new_dir_fd: os.fd_t,
        new_path: [*:0]const u8,
        flags: u32,
    ) !linux.io_uring_cqe {
        return self.do(RenameAt{
            .old_dir_fd = old_dir_fd,
            .old_path = old_path,
            .new_dir_fd = new_dir_fd,
            .new_path = new_path,
            .flags = flags,
        }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform a `unlinkat(2)`.
    /// Returns a pointer to the SQE.
    pub fn unlinkat(
        self: *AsyncIOUring,
        dir_fd: os.fd_t,
        path: [*:0]const u8,
        flags: u32,
    ) !linux.io_uring_cqe {
        return self.do(UnlinkAt{ .dir_fd = dir_fd, .path = path, .flags = flags }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform a `mkdirat(2)`.
    /// Returns a pointer to the SQE.
    pub fn mkdirat(
        self: *AsyncIOUring,
        dir_fd: os.fd_t,
        path: [*:0]const u8,
        mode: os.mode_t,
    ) !linux.io_uring_cqe {
        return self.do(MkdirAt{ .dir_fd = dir_fd, .path = path, .mode = mode }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform a `symlinkat(2)`.
    /// Returns a pointer to the SQE.
    pub fn symlinkat(
        self: *AsyncIOUring,
        target: [*:0]const u8,
        new_dir_fd: os.fd_t,
        link_path: [*:0]const u8,
    ) !linux.io_uring_cqe {
        return self.do(SymlinkAt{ .target = target, .new_dir_fd = new_dir_fd, .link_path = link_path }, null, null);
    }

    /// Queues (but does not submit) an SQE to perform a `linkat(2)`.
    /// Returns a pointer to the SQE.
    pub fn linkat(
        self: *AsyncIOUring,
        old_dir_fd: os.fd_t,
        old_path: [*:0]const u8,
        new_dir_fd: os.fd_t,
        new_path: [*:0]const u8,
        flags: u32,
    ) !linux.io_uring_cqe {
        return self.do(LinkAt{
            .old_dir_fd = old_dir_fd,
            .old_path = old_path,
            .new_dir_fd = new_dir_fd,
            .new_path = new_path,
            .flags = flags,
        }, null, null);
    }
};

// Used as user data for submission queue entries, so that the event loop can
// have resume the callers frame.
const ResumeNode = struct {
    frame: anyframe = undefined,
    result: linux.io_uring_cqe = undefined,
};

pub const Timeout = struct {
    ts: *const os.linux.kernel_timespec,
    flags: u32,
};

// TODO: Convert all usages of this to properly handle errors according to the
// use case.
fn defaultConvertError(linux_err: os.E) anyerror {
    return switch (linux_err) {
        .INTR, .CANCELED => error.Cancelled,
        else => |err| os.unexpectedErrno(err),
    };
}

pub const Read = struct {
    fd: os.fd_t,
    buffer: []u8,
    offset: u64,

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return try ring.read(@ptrToInt(node), op.fd, op.buffer, op.offset);
    }

    pub fn convertError(linux_err: os.E) anyerror {
        // More or less copied from
        // https://github.com/lithdew/rheia/blob/5ff018cf05ab0bf118e5cdcc35cf1c787150b87c/runtime.zig#L801-L814
        return switch (linux_err) {
            .NOTCONN => error.SocketNotConnected,
            .AGAIN => error.WouldBlock,
            .NOMEM => error.SystemResources,
            .CONNREFUSED => error.ConnectionRefused,
            .CONNRESET => error.ConnectionResetByPeer,
            .INTR, .CANCELED => error.Cancelled,
            .BADF, .FAULT, .INVAL, .NOTSOCK => unreachable,
            else => |err| os.unexpectedErrno(err),
        };
    }
};

pub const Write = struct {
    fd: os.fd_t,
    buffer: []const u8,
    offset: u64,
    const convertError = defaultConvertError;

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.write(@ptrToInt(node), op.fd, op.buffer, op.offset);
    }
};

pub const ReadV = struct {
    fd: os.fd_t,
    iovecs: []const os.iovec,
    offset: u64,
    const convertError = defaultConvertError;

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.readv(@ptrToInt(node), op.fd, op.iovecs, op.offset);
    }
};

pub const ReadFixed = struct {
    fd: os.fd_t,
    buffer: *os.iovec,
    offset: u64,
    buffer_index: u16,
    const convertError = defaultConvertError;
    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.read_fixed(@ptrToInt(node), op.fd, op.buffer, op.offset, op.buffer_index);
    }
};

pub const WriteV = struct {
    fd: os.fd_t,
    iovecs: []const os.iovec_const,
    offset: u64,

    const convertError = defaultConvertError;

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.writev(@ptrToInt(node), op.fd, op.iovecs, op.offset);
    }
};

pub const WriteFixed = struct {
    fd: os.fd_t,
    buffer: *os.iovec,
    offset: u64,
    buffer_index: u16,
    const convertError = defaultConvertError;

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.write_fixed(@ptrToInt(node), op.fd, op.buffer, op.offset, op.buffer_index);
    }
};

pub const Accept = struct {
    fd: os.fd_t,
    addr: *os.sockaddr,
    addrlen: *os.socklen_t,
    flags: u32,

    pub fn convertError(linux_err: os.E) anyerror {
        return switch (linux_err) {
            .AGAIN => error.WouldBlock,
            .BADF => unreachable,
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
            .CANCELED => error.Cancelled,
            else => |err| return os.unexpectedErrno(err),
        };
    }

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.accept(@ptrToInt(node), op.fd, op.addr, op.addrlen, op.flags);
    }
};

pub const Connect = struct {
    fd: os.fd_t,
    addr: *const os.sockaddr,
    addrlen: os.socklen_t,
    pub fn convertError(linux_err: os.E) anyerror {
        // More or less copied from
        // https://github.com/lithdew/rheia/blob/5ff018cf05ab0bf118e5cdcc35cf1c787150b87c/runtime.zig#L682-L704.
        return switch (linux_err) {
            .ACCES => error.PermissionDenied,
            .PERM => error.PermissionDenied,
            .ADDRINUSE => error.AddressInUse,
            .ADDRNOTAVAIL => error.AddressNotAvailable,
            .AFNOSUPPORT => error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => error.WouldBlock,
            .ALREADY => error.ConnectionPending,
            .BADF => unreachable,
            .CONNREFUSED => error.ConnectionRefused,
            .CONNRESET => error.ConnectionResetByPeer,
            .FAULT => unreachable,
            .ISCONN => unreachable,
            .NETUNREACH => error.NetworkUnreachable,
            .NOTSOCK => unreachable,
            .PROTOTYPE => unreachable,
            .TIMEDOUT => error.ConnectionTimedOut,
            .NOENT => error.FileNotFound,
            .CANCELED => error.Cancelled,
            else => |err| os.unexpectedErrno(err),
        };
    }

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.connect(@ptrToInt(node), op.fd, op.addr, op.addrlen);
    }
};

pub const Recv = struct {
    fd: os.fd_t,
    buffer: []u8,
    flags: u32,

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.recv(@ptrToInt(node), op.fd, op.buffer, op.flags);
    }

    pub fn convertError(linux_err: os.E) anyerror {
        // More or less copied from
        // https://github.com/lithdew/rheia/blob/5ff018cf05ab0bf118e5cdcc35cf1c787150b87c/runtime.zig#L546-L559.
        return switch (linux_err) {
            .NOTCONN => error.SocketNotConnected,
            .AGAIN => error.WouldBlock,
            .NOMEM => error.SystemResources,
            .CONNREFUSED => error.ConnectionRefused,
            .CONNRESET => error.ConnectionResetByPeer,
            .CANCELED => error.Cancelled,
            .BADF, .FAULT, .INVAL, .NOTSOCK => unreachable,
            else => |err| os.unexpectedErrno(err),
        };
    }
};

pub const Fsync = struct {
    fd: os.fd_t,
    flags: u32,

    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.fsync(@ptrToInt(node), self.fd, self.flags);
    }

    const convertError = defaultConvertError;
};

pub const Fallocate = struct {
    fd: os.fd_t,
    mode: i32,
    offset: u64,
    len: u64,

    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.fallocate(@ptrToInt(node), self.fd, self.mode, self.offset, self.len);
    }

    const convertError = defaultConvertError;
};

pub const Statx = struct {
    fd: os.fd_t,
    path: [:0]const u8,
    flags: u32,
    mask: u32,
    buf: *linux.Statx,

    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.statx(@ptrToInt(node), self.fd, self.path, self.flags, self.mask, self.buf);
    }

    const convertError = defaultConvertError;
};

pub const Shutdown = struct {
    sockfd: os.socket_t,
    how: u32,

    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.shutdown(@ptrToInt(node), self.sockfd, self.how);
    }

    const convertError = defaultConvertError;
};

pub const RenameAt = struct {
    old_dir_fd: os.fd_t,
    old_path: [*:0]const u8,
    new_dir_fd: os.fd_t,
    new_path: [*:0]const u8,
    flags: u32,

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

    const convertError = defaultConvertError;
};

pub const UnlinkAt = struct {
    dir_fd: os.fd_t,
    path: [*:0]const u8,
    flags: u32,

    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.unlinkat(@ptrToInt(node), self.dir_fd, self.path, self.flags);
    }

    const convertError = defaultConvertError;
};

pub const MkdirAt = struct {
    dir_fd: os.fd_t,
    path: [*:0]const u8,
    mode: os.mode_t,
    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.mkdirat(@ptrToInt(node), self.dir_fd, self.path, self.mode);
    }

    const convertError = defaultConvertError;
};

pub const SymlinkAt = struct {
    target: [*:0]const u8,
    new_dir_fd: os.fd_t,
    link_path: [*:0]const u8,

    pub fn submit(self: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.symlinkat(@ptrToInt(node), self.target, self.new_dir_fd, self.link_path);
    }

    const convertError = defaultConvertError;
};

pub const LinkAt = struct {
    old_dir_fd: os.fd_t,
    old_path: [*:0]const u8,
    new_dir_fd: os.fd_t,
    new_path: [*:0]const u8,
    flags: u32,

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

    const convertError = defaultConvertError;
};

pub const Send = struct {
    fd: os.fd_t,
    buffer: []const u8,
    flags: u32,

    pub fn convertError(linux_err: os.E) anyerror {
        // More or less copied from https://github.com/lithdew/rheia/blob/5ff018cf05ab0bf118e5cdcc35cf1c787150b87c/runtime.zig#L604-L632.
        return switch (linux_err) {
            .ACCES => error.AccessDenied,
            .AGAIN => error.WouldBlock,
            .ALREADY => error.FastOpenAlreadyInProgress,
            .BADF => unreachable,
            .CONNRESET => error.ConnectionResetByPeer,
            .DESTADDRREQ => unreachable,
            .FAULT => unreachable,
            .INVAL => unreachable,
            .ISCONN => unreachable,
            .MSGSIZE => error.MessageTooBig,
            .NOBUFS => error.SystemResources,
            .NOMEM => error.SystemResources,
            .NOTSOCK => unreachable,
            .OPNOTSUPP => unreachable,
            .PIPE => error.BrokenPipe,
            .AFNOSUPPORT => error.AddressFamilyNotSupported,
            .LOOP => error.SymLinkLoop,
            .NAMETOOLONG => error.NameTooLong,
            .NOENT => error.FileNotFound,
            .NOTDIR => error.NotDir,
            .HOSTUNREACH => error.NetworkUnreachable,
            .NETUNREACH => error.NetworkUnreachable,
            .NOTCONN => error.SocketNotConnected,
            .NETDOWN => error.NetworkSubsystemFailed,
            .CANCELED => error.Cancelled,
            else => |err| os.unexpectedErrno(err),
        };
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

    const convertError = defaultConvertError;

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.openat(@ptrToInt(node), op.fd, op.path, op.flags, op.mode);
    }
};

pub const Close = struct {
    fd: os.fd_t,

    const convertError = defaultConvertError;
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

    pub fn submit(op: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.cancel(@ptrToInt(node), op.cancel_user_data, op.flags);
    }
};

pub const Nop = struct {
    const convertError = defaultConvertError;
    pub fn submit(_: @This(), ring: *IO_Uring, node: *ResumeNode) !*linux.io_uring_sqe {
        return ring.nop(@ptrToInt(node));
    }
};

pub const EpollCtl = struct {
    epfd: os.fd_t,
    fd: os.fd_t,
    op: u32,
    ev: ?*linux.epoll_event,

    const convertError = defaultConvertError;

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
    const cqe_write = try ring.write(fd, write_buffer[0..], 0);
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
    const cqe_write = try ring.write(fd, write_buffer[0..], 0);
    try std.testing.expectEqual(cqe_write.res, write_buffer.len);

    var read_buffer = [_]u8{0} ** 20;

    const read_cqe = try ring.read(fd, read_buffer[0..], 0);
    const num_bytes_read = @intCast(usize, read_cqe.res);
    try std.testing.expectEqualSlices(u8, read_buffer[0..num_bytes_read], write_buffer[0..]);
}

fn testReadThatTimesOut(ring: *AsyncIOUring) !void {
    var read_buffer = [_]u8{0} ** 20;

    const ts = os.linux.kernel_timespec{ .tv_sec = 0, .tv_nsec = 10000 };
    // Try to read from stdin - there won't be any input so this should
    // reliably time out.
    const read_cqe = ring.do(Read{ .fd = std.io.getStdIn().handle, .buffer = read_buffer[0..], .offset = 0 }, Timeout{ .ts = &ts, .flags = 0 }, null);
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

    const cancel_cqe = try ring.cancel(op_id, 0);
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
    _ = ring.cancel(op_id, 0) catch |err| {
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
