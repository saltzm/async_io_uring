
# About

In-progress async wrapper for IO\_Uring library and examples. The project isn't
structured super well and is missing some error handling. This is my first
actual Zig project and I love it so far. I would like to continue working on it
and then extract the event loop into its own library if it continues to seem
useful.

Files:
* `src/client.zig`: Echo client. 
* `src/server.zig`: Echo server. Handles multiple concurrent connections. All I/O
  is non-blocking except for the debug logging :) 
* `src/benchmark.zig`: A silly benchmarking loop to check throughput from the
  perspective of a client sending "hello" over and over again.
* `src/async\_io\_uring.zig`: Partially implemented wrapper for IO\_Uring that
  has versions of its functions that suspend until their results are ready, and
  an event loop that makes it work.  

# Running the echo client and server
```sh
# Run the server
zig build run_server

# In a separate shell
zig build run_client
```

# Running the benchmark
```sh
# Run the server
zig build run_server -Drelease-fast

# In a separate shell
zig build run_benchmark -Drelease-fast

# Or for multiple client processes at once (in this case 30):
for in {0..30}; do zig build run_benchmark -Drelease-fast & done;
```
