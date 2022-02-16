
# About the examples

Files:
* `client.zig`: Echo client. All I/O (including reading from stdin) is
  non-blocking except for the debug logging.
* `server.zig`: Echo server. Handles multiple concurrent connections. All I/O
  is non-blocking except for the debug logging.
* `benchmark.zig`: A silly benchmarking loop to check throughput from the
  perspective of a client sending "hello" over and over again.
* `async_writer.zig`: A demo of making a utility so that you can conveniently
  print to a file asynchronously.

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
