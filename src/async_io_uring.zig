const std = @import("std");
const builtin = @import("builtin");
const IO_Uring = std.os.linux.IO_Uring;
const os = std.os;
const linux = os.linux;

// Used as user data for submission queue entries, so that the event loop can
// have resume the callers frame.
const ResumeNode = struct { frame: anyframe = undefined, result: linux.io_uring_cqe = undefined };

// TODO: Use existing codes and make them more semantically meaningful. This is
// just a bandaid so that callers don't have to check the 'res' field on CQEs
// after calling functions on AsyncIOUring.
pub const AsyncIOUringError = error{UnknownError};

/// Wrapper for IO_Uring that turns its functions into async functions that
/// suspend after enqueuing entries to the submission queue and resume and
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
/// TODO: Turn linux errors on the resulting CQEs into zig errors.
/// TODO: Consider making AsyncIOUring own the ring and add init()/deinit()
///       functions.
/// TODO: Consider making another class that's higher level with sensible defaults for everything.
pub const AsyncIOUring = struct {
    ring: *IO_Uring = undefined,

    // Number of events submitted minus number of events completed. We can
    // exit when this is 0.
    //
    // TODO: See if there's a way to do this with builtin IO_Uring methods.
    //       Didn't see how at first glance. Specifically I don't know how
    //       to find if there are previously submitted events that aren't
    //       complete yet.
    num_outstanding_events: u64 = 0,

    // Runs a loop to submit tasks on the underlying IO_Uring and block waiting
    // for completion events. When a completion queue event (cqe) is available, it
    // will resume the coroutine that submitted the request corresponding to that cqe.
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        // TODO: Allow user to pass a callback to modify the fsync SQE for
        // advanced cases.
        _ = try self.ring.fsync(@ptrToInt(&node), fd, flags);
        suspend {}

        // TODO
        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a no-op.
    /// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
    /// A no-op is more useful than may appear at first glance.
    /// For example, you could call `drain_previous_sqes()` on the returned SQE, to use the no-op to
    /// know when the ring is idle before acting on a kill signal.
    pub fn nop(self: *AsyncIOUring) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.nop(@ptrToInt(&node));
        suspend {}

        // TODO
        if (node.result.res < 0) {
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };

        while (true) {
            _ = self.ring.read(@ptrToInt(&node), fd, buffer, offset) catch |err| {
                switch (err) {
                    error.SubmissionQueueFull => {
                        const num_submitted = try self.ring.submit_and_wait(1);
                        self.num_outstanding_events += num_submitted;
                        // Try again - we should have enough space now.
                        continue;
                    },
                    else => {
                        // Return all other errors to the caller.
                        return err;
                    },
                }
            };

            // Submission was successful. Suspend to wait for event completion.
            suspend {}

            if (node.result.res >= 0) {
                // Success.
                return node.result;
            } else {
                // Retry on certain errors, return error on others.
                //
                // More or less copied from https://github.com/lithdew/rheia/blob/5ff018cf05ab0bf118e5cdcc35cf1c787150b87c/runtime.zig#L801-L814
                return switch (@intToEnum(os.E, -node.result.res)) {
                    .BADF => unreachable,
                    .FAULT => unreachable,
                    .INVAL => unreachable,
                    .NOTCONN => error.SocketNotConnected,
                    .NOTSOCK => unreachable,
                    .INTR => continue,
                    .AGAIN => error.WouldBlock,
                    .NOMEM => error.SystemResources,
                    .CONNREFUSED => error.ConnectionRefused,
                    .CONNRESET => error.ConnectionResetByPeer,
                    .CANCELED => error.Cancelled,
                    else => |err| os.unexpectedErrno(err),
                };
            }
        }
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        while (true) {
            _ = self.ring.write(@ptrToInt(&node), fd, buffer, offset) catch |err| {
                switch (err) {
                    error.SubmissionQueueFull => {
                        // Submit the current queue to clear it.
                        const num_submitted = try self.ring.submit_and_wait(1);
                        self.num_outstanding_events += num_submitted;
                        // Try again and hope we have enough space now.
                        continue;
                    },
                    else => {
                        // Return all other errors to the caller.
                        return err;
                    },
                }
            };

            suspend {}

            if (node.result.res >= 0) {
                // Success.
                return node.result;
            } else {
                // Retry on certain errors, return error on others.
                return switch (@intToEnum(os.E, -node.result.res)) {
                    .INTR => continue,
                    // TODO
                    else => |err| os.unexpectedErrno(err),
                };
            }
        }
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.readv(@ptrToInt(&node), fd, iovecs, offset);
        suspend {}

        // TODO
        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.read_fixed(@ptrToInt(&node), fd, buffer, offset, buffer_index);
        suspend {}

        // TODO
        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.writev(@ptrToInt(&node), fd, iovecs, offset);
        suspend {}

        // TODO
        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.write_fixed(@ptrToInt(&node), fd, buffer, offset, buffer_index);
        suspend {}

        // TODO
        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        while (true) {
            _ = self.ring.accept(@ptrToInt(&node), fd, addr, addrlen, flags) catch |err| {
                switch (err) {
                    error.SubmissionQueueFull => {
                        const num_submitted = try self.ring.submit_and_wait(1);
                        self.num_outstanding_events += num_submitted;
                        // Try again - we should have enough space now.
                        continue;
                    },
                    else => {
                        // Return all other errors to the caller.
                        return err;
                    },
                }
            };

            suspend {}

            if (node.result.res >= 0) {
                return node.result;
            } else {
                // More or less copied from
                // https://github.com/lithdew/rheia/blob/5ff018cf05ab0bf118e5cdcc35cf1c787150b87c/runtime.zig#L480-L497.
                return switch (@intToEnum(os.E, -node.result.res)) {
                    .INTR => continue,
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
        }
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        while (true) {
            _ = self.ring.connect(@ptrToInt(&node), fd, addr, addrlen) catch |err| {
                switch (err) {
                    error.SubmissionQueueFull => {
                        const num_submitted = try self.ring.submit_and_wait(1);
                        self.num_outstanding_events += num_submitted;
                        // Try again - we should have enough space now.
                        continue;
                    },
                    else => {
                        // Return all other errors to the caller.
                        return err;
                    },
                }
            };

            suspend {}

            if (node.result.res >= 0) {
                return node.result;
            } else {
                // More or less copied from
                // https://github.com/lithdew/rheia/blob/5ff018cf05ab0bf118e5cdcc35cf1c787150b87c/runtime.zig#L682-L704.
                return switch (@intToEnum(os.E, -node.result.res)) {
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
                    .INTR => continue,
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
        }
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.epoll_ctl(@ptrToInt(&node), epfd, fd, op, ev);
        suspend {}

        // TODO
        if (node.result.res < 0) {
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        while (true) {
            _ = self.ring.recv(@ptrToInt(&node), fd, buffer, flags) catch |err| {
                switch (err) {
                    error.SubmissionQueueFull => {
                        const num_submitted = try self.ring.submit_and_wait(1);
                        self.num_outstanding_events += num_submitted;
                        // Try again - we should have enough space now.
                        continue;
                    },
                    else => {
                        // Return all other errors to the caller.
                        return err;
                    },
                }
            };

            suspend {}

            if (node.result.res >= 0) {
                return node.result;
            } else {
                // More or less copied from
                // https://github.com/lithdew/rheia/blob/5ff018cf05ab0bf118e5cdcc35cf1c787150b87c/runtime.zig#L546-L559.
                return switch (@intToEnum(os.E, -node.result.res)) {
                    .BADF => unreachable,
                    .FAULT => unreachable,
                    .INVAL => unreachable,
                    .NOTCONN => error.SocketNotConnected,
                    .NOTSOCK => unreachable,
                    .INTR => continue,
                    .AGAIN => error.WouldBlock,
                    .NOMEM => error.SystemResources,
                    .CONNREFUSED => error.ConnectionRefused,
                    .CONNRESET => error.ConnectionResetByPeer,
                    .CANCELED => error.Cancelled,
                    else => |err| os.unexpectedErrno(err),
                };
            }
        }
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        while (true) {
            _ = self.ring.send(@ptrToInt(&node), fd, buffer, flags) catch |err| {
                switch (err) {
                    error.SubmissionQueueFull => {
                        const num_submitted = try self.ring.submit_and_wait(1);
                        self.num_outstanding_events += num_submitted;
                        // Try again - we should have enough space now.
                        continue;
                    },
                    else => {
                        // Return all other errors to the caller.
                        return err;
                    },
                }
            };

            suspend {}

            if (node.result.res >= 0) {
                // Success.
                return node.result;
            } else {
                // More or less copied from https://github.com/lithdew/rheia/blob/5ff018cf05ab0bf118e5cdcc35cf1c787150b87c/runtime.zig#L604-L632.
                return switch (@intToEnum(os.E, -node.result.res)) {
                    .ACCES => error.AccessDenied,
                    .AGAIN => error.WouldBlock,
                    .ALREADY => error.FastOpenAlreadyInProgress,
                    .BADF => unreachable,
                    .CONNRESET => error.ConnectionResetByPeer,
                    .DESTADDRREQ => unreachable,
                    .FAULT => unreachable,
                    .INTR => continue,
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
        }
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.openat(@ptrToInt(&node), fd, path, flags, mode);
        suspend {}

        // TODO
        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a `close(2)`.
    /// Returns a pointer to the SQE.
    pub fn close(self: *AsyncIOUring, fd: os.fd_t) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        while (true) {
            _ = self.ring.close(@ptrToInt(&node), fd) catch |err| {
                switch (err) {
                    error.SubmissionQueueFull => {
                        const num_submitted = try self.ring.submit_and_wait(1);
                        self.num_outstanding_events += num_submitted;
                        // Try again - we should have enough space now.
                        continue;
                    },
                    else => {
                        // Return all other errors to the caller.
                        return err;
                    },
                }
            };

            suspend {}

            if (node.result.res >= 0) {
                return node.result;
            } else {
                // TODO
                return AsyncIOUringError.UnknownError;
            }
        }
    }

    /// Queues (but does not submit) an SQE to register a timeout operation.
    /// Returns a pointer to the SQE.
    ///
    /// The timeout will complete when either the timeout expires, or after the specified number of
    /// events complete (if `count` is greater than `0`).
    ///
    /// `flags` may be `0` for a relative timeout, or `IORING_TIMEOUT_ABS` for an absolute timeout.
    ///
    /// The completion event result will be `-ETIME` if the timeout completed through expiration,
    /// `0` if the timeout completed after the specified number of events, or `-ECANCELED` if the
    /// timeout was removed before it expired.
    ///
    /// io_uring timeouts use the `CLOCK.MONOTONIC` clock source.
    pub fn timeout(
        self: *AsyncIOUring,
        ts: *const os.linux.kernel_timespec,
        count: u32,
        flags: u32,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.timeout(@ptrToInt(&node), ts, count, flags);
        suspend {}

        // TODO But actually, this is totally wrong.
        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
    }

    // TODO timeout_remove - which identifies timeout by user_data

    // TODO link_timeout - which should probably be included in all other ops
    // as an optional timeout parameter

    /// Queues (but does not submit) an SQE to perform a `poll(2)`.
    /// Returns a pointer to the SQE.
    pub fn poll_add(
        self: *AsyncIOUring,
        fd: os.fd_t,
        poll_mask: u32,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        while (true) {
            _ = try self.ring.poll_add(@ptrToInt(&node), fd, poll_mask);
            suspend {}

            if (node.result.res >= 0) {
                return node.result;
            } else {
                // More or less copied from
                // https://github.com/lithdew/rheia/blob/5ff018cf05ab0bf118e5cdcc35cf1c787150b87c/runtime.zig#L748-L756
                return switch (@intToEnum(os.E, -node.result.res)) {
                    .BADF => unreachable,
                    .FAULT => unreachable,
                    .INVAL => unreachable,
                    .INTR => continue,
                    .NOMEM => error.SystemResources,
                    .CANCELED => error.Cancelled,
                    else => |err| os.unexpectedErrno(err),
                };
            }
        }
    }

    // TODO poll_remove, poll_update, which require user_data from poll_add

    /// Queues (but does not submit) an SQE to perform an `fallocate(2)`.
    /// Returns a pointer to the SQE.
    pub fn fallocate(
        self: *AsyncIOUring,
        fd: os.fd_t,
        mode: i32,
        offset: u64,
        len: u64,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.fallocate(@ptrToInt(&node), fd, mode, offset, len);
        suspend {}

        // TODO
        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.statx(@ptrToInt(&node), fd, path, flags, mask, buf);
        suspend {}

        // TODO
        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
    }

    // TODO cancel, which uses target user_data to cancel ops

    /// Queues (but does not submit) an SQE to perform a `shutdown(2)`.
    /// Returns a pointer to the SQE.
    ///
    /// The operation is identified by its `user_data`.
    pub fn shutdown(
        self: *AsyncIOUring,
        sockfd: os.socket_t,
        how: u32,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.shutdown(@ptrToInt(&node), sockfd, how);
        suspend {}

        // TODO
        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.renameat(@ptrToInt(&node), old_dir_fd, old_path, new_dir_fd, new_path, flags);
        suspend {}

        // TODO
        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a `unlinkat(2)`.
    /// Returns a pointer to the SQE.
    pub fn unlinkat(
        self: *AsyncIOUring,
        dir_fd: os.fd_t,
        path: [*:0]const u8,
        flags: u32,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.unlinkat(@ptrToInt(&node), dir_fd, path, flags);
        suspend {}

        // TODO
        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a `mkdirat(2)`.
    /// Returns a pointer to the SQE.
    pub fn mkdirat(
        self: *AsyncIOUring,
        dir_fd: os.fd_t,
        path: [*:0]const u8,
        mode: os.mode_t,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.mkdirat(@ptrToInt(&node), dir_fd, path, mode);
        suspend {}

        // TODO
        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
    }

    /// Queues (but does not submit) an SQE to perform a `symlinkat(2)`.
    /// Returns a pointer to the SQE.
    pub fn symlinkat(
        self: *AsyncIOUring,
        target: [*:0]const u8,
        new_dir_fd: os.fd_t,
        link_path: [*:0]const u8,
    ) !linux.io_uring_cqe {
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.symlinkat(@ptrToInt(&node), target, new_dir_fd, link_path);
        suspend {}

        // TODO
        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }

        return node.result;
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
        var node = ResumeNode{ .frame = @frame(), .result = undefined };
        _ = try self.ring.linkat(@ptrToInt(&node), old_dir_fd, old_path, new_dir_fd, new_path, flags);
        suspend {}

        // TODO
        if (node.result.res < 0) {
            return AsyncIOUringError.UnknownError;
        }
        return node.result;
    }

    // TODO Re-expose register_* functions, or just have people call into the
    // underlying ring?

};

// const WriteTest = struct {
//     path: []u8 = "test_io_uring_write",
//     file: std.fs.File,
//     fd: os.fd_t,
//
//     const Self = @This();
//
//     pub fn init(path: []u8) Self {
//         var self = Self { path, try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true }), file.handle };
//         return .{};
//     }
// };

fn doWrite(ring: *AsyncIOUring) !void {
    const path = "test_io_uring_write_read";
    const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
    defer file.close();
    defer std.fs.cwd().deleteFile(path) catch {};
    const fd = file.handle;

    const write_buffer = [_]u8{9} ** 20;
    const sqe_write = try ring.write(fd, write_buffer[0..], 0);

    try std.testing.expectEqual(sqe_write.res, write_buffer.len);

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

    var write_frame = async doWrite(&async_ring);

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

    // Try to do a write - we expect this to submit the existing submissions to
    // the kernel and then retry and succeed.
    var write_frame = async doWrite(&async_ring);

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
    // VERY hacky - inspect the last submission queue entry to check that it's
    // actually a write.
    var sqe = &ring.sq.sqes[(ring.sq.sqe_tail - 1) & ring.sq.mask];
    try std.testing.expectEqual(sqe.opcode, .WRITE);

    // This should submit the write and wait for it to occur.
    try async_ring.run_event_loop();

    try nosuspend await write_frame;
}
