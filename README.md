
# About

In-progress async wrapper for the `IO_Uring` library and an echo client and
server as examples. The project is very much not finished and isn't properly
structured as a library for use yet. I would like to continue working on it and
then extract the event loop into its own library if it continues to seem
useful. This is my first actual Zig project and I love it so far. 

Files:
* `src/client.zig`: Echo client. All I/O (including reading from stdin) is
  non-blocking except for the debug logging.
* `src/server.zig`: Echo server. Handles multiple concurrent connections. All I/O
  is non-blocking except for the debug logging.
* `src/benchmark.zig`: A silly benchmarking loop to check throughput from the
  perspective of a client sending "hello" over and over again.
* `src/async_io_uring.zig`: Partially implemented wrapper for `IO_Uring` that
  has versions of its functions that suspend until their results are ready, and
  an event loop that makes it work.  

# Running the echo client and server
```sh
# Run the server
$ zig build run_server

# Example output when server.zig has max_connections set to 2
Accepting
Spawning new connection with index: 0
Accepting
Spawning new connection with index: 1
Accepting
Reached connection limit, refusing connection.
Accepting
Closing connection with index 1
Closing connection with index 0

# In a separate shell
$ zig build run_client
#Example output
Input: hello
Received: hello

Input: world
Received: world
```

# Running the benchmark
```sh
# Run the server
$ zig build run_server -Drelease-fast

# In a separate shell
$ zig build run_benchmark -Drelease-fast

# Or for multiple client processes at once (in this case 30):
$ for in {0..30}; do zig build run_benchmark -Drelease-fast & done;
```
