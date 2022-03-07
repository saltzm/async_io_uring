
# Overview

`AsyncIOUring` is an event loop that wraps the `IO_Uring` library with coroutines
support. It supports all `IO_Uring` operations (with the intentional exception
of `poll_update`\*). 

In addition, it allows:
* Adding timeouts to operations
* Manual cancellation of operations
* Writing custom operations for advanced use cases

It is currently functionally complete, though there are a few `TODO`s marked in
the source related to polishing the API. It's not used in production anywhere currently.

See `src/async_io_uring.zig` for full API documentation.

See the `examples` directory for an echo client and server that use the event loop.

\* If you need this for some reason, please create an issue.

## Table of contents
* [Background](#background)
* [Goals](#goals)
* [Installation](#installation)
* [Example usage](#example-usage)
    * [Echo client](#echo-client)
    * [Operation cancellation](#operation-cancellation)

---
# Background

As an overview for the unfamiliar, `io_uring` is a new-ish Linux kernel feature 
that allows users to enqueue requests to perform syscalls into a submission
queue (e.g. a request to read from a socket) and then submit the submission
queue to the kernel for processing.

When requests from the submission queue have been satisfied, the result is
placed onto completion queue by the kernel. The user is able to either poll
the kernel for completion queue results or block until results are
available.

Zig's `IO_Uring` library provides a convenient interface to the kernel's
`io_uring` functionality. The user of `IO_Uring`, however, still has to manually
deal with submitting requests to the kernel and retrieving events from the
completion queue, which can be tedious.

This library wraps the `IO_Uring` library by adding an event loop that handles
request submission and completion, and provides an interface for each syscall
that uses zig's `async` functionality to suspend execution of the calling code
until the syscall has been completed. This lets the user write code that looks
like blocking code, while still allowing for concurrency even within a single
thread.

# Goals

* **Minimal**: Wraps the `IO_Uring` library in the most lightweight way
  possible. This means it still uses the `IO_Uring` data structures in many
  places, like for completion queue entries. There are no additional internal
  data structures other than the submission queue and completion queue used by
  the `IO_Uring` library. This means there's no heap allocation. It also relies
  entirely on kernel functionality for timeouts and cancellation.
* **Complete**: You should be able to do anything with this that you could do
  with `IO_Uring`. (Right now there are a few missing operations - these are
  noted in `TODO`s in the source.)
* **Easy to use**: Because of the use of coroutines, code written with this
  library looks almost identical to blocking code. In addition, operation
  timeouts and cancellation support is integrated into the API for all operations.
* **Performant**: The library does no heap allocation and there's minimal
  additional logic on top of `suspend`/`resume`.

# Installation 

This library integrates with the [zigmod](https://github.com/nektro/zigmod)
package manager. If you've installed `zigmod`, you can add a line like the
following to your `root_dependencies` in the `zig.mod` file of your project 
and run `zigmod fetch`:
```yml
root_dependencies:
  - ...
  - src: git https://github.com/saltzm/async_io_uring.git
```

You'll then be able to include `async_io_uring.zig` by doing something like:
```zig
const io = @import("async_io_uring");
```

The examples directory is structured roughly as you might structure a project
that uses `async_io_uring`, with a working `zig.mod` file and `build.zig` that
can serve as examples.

You'll also need a Linux kernel version that supports all of the `io_uring`
features you'd like to use. (All testing was done on version 5.13.0.)

# Example usage

## Echo client

The following is a snippet of code from the echo client in the examples
directory.

```zig
const io = @import("async_io_uring");

pub fn run_client(ring: *AsyncIOUring) !void {
    // Make a data structure that lets us do async file I/O with the same
    // syntax as `std.debug.print`.
    var writer = AsyncWriter{ .ring = ring };
    try writer.init(std.io.getStdErr().handle);

    // Address of the echo server.
    const address = try net.Address.parseIp4("127.0.0.1", 3131);

    // Open a socket for connecting to the server.
    const server = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    defer {
        _ = ring.close(server, null, null) catch {
            std.os.exit(1);
        };
    }

    // Connect to the server.
    _ = try ring.connect(server, &address.any, address.getOsSockLen(), null, null);

    const stdin_file = std.io.getStdIn();
    const stdin_fd = stdin_file.handle;
    var input_buffer: [256]u8 = undefined;

    while (true) {
        // Prompt the user for input.
        try writer.print("Input: ", .{});

        const read_timeout = os.linux.kernel_timespec{ .tv_sec = 10, .tv_nsec = 0 };
        // Read a line from stdin with a 10 second timeout.
        // This is the more verbose API - you can also do `ring.read`.
        const read_cqe = ring.do(
            io.Read{ .fd = stdin_fd, .buffer = input_buffer[0..], .offset = input_buffer.len },
            io.Timeout{ .ts = &read_timeout, .flags = 0 },
            null,
        ) catch |err| {
            if (err == error.Cancelled) {
                try writer.print("\nTimed out waiting for input, exiting...\n", .{});
                return;
            } else return err;
        };

        const num_bytes_read = @intCast(usize, read_cqe.res);

        // Send it to the server.
        _ = try ring.send(server, input_buffer[0..num_bytes_read], 0, null, null);

        // Receive response.
        const recv_cqe = try ring.recv(server, input_buffer[0..], 0, null, null);

        const num_bytes_received = @intCast(usize, recv_cqe.res);
        try writer.print("Received: {s}\n", .{input_buffer[0..num_bytes_received]});
    }
}
```

## Operation cancellation

`AsyncIOUring` supports cancellation for all operations. Each operation is 
identified by an `id` that is set via a `maybe_id` "output parameter" in all
operation submission functions (e.g. `read`, `send`, etc.). This `id` can then
be passed to `AsyncIOUring.cancel` to cancel that operation.

An example from the unit tests:

```zig
fn testReadThatIsCancelled(ring: *AsyncIOUring) !void {
    var read_buffer = [_]u8{0} ** 20;

    var op_id: u64 = undefined;

    // Try to read from stdin - there won't be any input so this operation should
    // reliably hang until cancellation.
    var read_frame = async ring.do(
        Read{ .fd = std.io.getStdIn().handle, .buffer = read_buffer[0..], .offset = 0 },
        null,
        &op_id,
    );

    const cancel_cqe = try ring.cancel(op_id, 0, null, null);
    // Expect that cancellation succeeded.
    try std.testing.expectEqual(cancel_cqe.res, 0);

    const read_cqe = await read_frame;
    try std.testing.expectEqual(read_cqe, error.Cancelled);
}
```
