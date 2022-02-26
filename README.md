
# About

`AsyncIOUring` is an event loop that wraps the `IO_Uring` library with coroutines
support. It is currently relatively complete, but has a few remaining `TODO`s
in the source. It's not used in production anywhere currently.

See the `examples` directory for an echo client and server that use the event loop.

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

# How to use 

This library integrates with the [zigmod](https://github.com/nektro/zigmod)
package manager. If you've installed `zigmod`, you can add a line like the
following to your `root_dependencies` in the `zig.mod` file of your project 
and run `zigmod fetch`:
```
root_dependencies:
  - ...
  - src: git https://github.com/saltzm/async_io_uring.git
```

You'll then be able to include `async_io_uring.zig` by doing something like:
```
const io = @import("async_io_uring");
```

The examples directory is structured roughly as you might structure a project
that uses `async_io_uring`, with a working `zig.mod` file and `build.zig` that
can serve as examples.

# Example usage

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
        const recv_cqe = try ring.do(io.Recv{ .fd = server, .buffer = input_buffer[0..], .flags = 0 }, null, null);

        const num_bytes_received = @intCast(usize, recv_cqe.res);
        try writer.print("Received: {s}\n", .{input_buffer[0..num_bytes_received]});
    }
}
```
