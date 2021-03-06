
# About the examples

Files:
* `src/client.zig`: Echo client. All I/O (including reading from stdin) is
  non-blocking except for the debug logging.
* `src/server.zig`: Echo server. Handles multiple concurrent connections. All I/O
  is non-blocking except for the debug logging.
* `src/benchmark.zig`: A silly benchmarking loop to check throughput from the
  perspective of a client sending "hello" over and over again.

# Running the echo client and server
```sh
$ cd examples
# Fetch async_io_uring as a dependency for the examples.
$ zigmod fetch 

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
```
