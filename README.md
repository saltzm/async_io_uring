
In-progress async wrapper for IO\_Uring library and examples. The project isn't
structured super well and is missing some error handling. This is my first
actual Zig project and I love it so far. 

Files:
* src/client.zig: Echo client. It also has a silly benchmarking loop that you can
  enable by commenting out the client\_loop in main and enabling the benchmark.
* src/server.zig: Echo server. Handles multiple concurrent connections. All I/O
  is non-blocking except for the debug logging :) 
* src/async\_io\_uring.zig: Partially implemented wrapper for IO\_Uring that
  has versions of its functions that suspend until their results are ready, and
  an event loop that makes it work.  

To run:
```sh
# Run the server
zig build run_server

# In a separate shell
zig build run_client
```
