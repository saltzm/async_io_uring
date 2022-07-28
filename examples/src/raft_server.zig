const std = @import("std");

const io = @import("async_io_uring");

const builtin = @import("builtin");
const IO_Uring = std.os.linux.IO_Uring;
const assert = std.debug.assert;
const mem = std.mem;
const net = std.net;
const os = std.os;
const linux = os.linux;
const time = std.time;

const AsyncIOUring = io.AsyncIOUring;
const AsyncWriter = io.AsyncWriter;
const AsyncMutex = @import("async_mutex.zig").AsyncMutex;

const server_util = @import("server.zig");

pub fn main() !void {
    const num_threads = 1;
    const max_num_connections = 10000;
    try server_util.runServer(
        num_threads,
        max_num_connections,
        handleClientConnection,
        server_util.ServerConfig{
            .address = try net.Address.parseIp4("127.0.0.1", 3131),
        },
    );
}

pub const RaftServer = union(enum) { leader: struct {}, follower: struct {}, candidate: struct {} };

// TODO make not a global
const server = RaftServer{ .follower = .{} };

pub const ProtocolVersion = struct {}; // TODO

pub const RPCHeader = struct {
    protocol_version: u64,
    // ServerID of the ndoe sending RPC request
    id: []u8,
    // ServerAddr of node sending request
    addr: []u8,
};
pub const RaftMessage = struct {
    term: u64,
    contents: RaftMessageContents,
};

pub const RaftMessageContents = union(enum) {
    // Doubles as heartbeat when entries is empty for some reason... Maybe
    // change that?
    append_entries_request: struct {
        rpc_header: RPCHeader,
        term: u64,
        // For integrity checking.
        prev_log_entry: u64,
        prev_log_term: u64,
        entries: []u8, // TODO
    },
    append_entries_response: struct {
        rpc_header: RPCHeader,
        term: u64,
        // Hint to accelerate rebuilding slow nodes.
        // last_log: u64
        // May not succeed if there's a conflicting entry.
        success: bool,
        // Indicates didn't succeed but don't need to retry or backoff for next
        // request.
        no_retry_backoff: bool,
    },
    request_vote_request: struct {
        rpc_header: RPCHeader,
        term: u64,
        // Used to ensure safety
        // last_log_index: u64,
        // last_log_term: u64,
        // TODO: Paraphrase
        // Used to indicate to peers if this vote was triggered by a leadership
        // transfer. It is required for leadership transfer to work, because
        // servers wouldn't vote otherwise if they are aware of an existing
        // leader.
        leadership_transfer: bool,
    },
    request_vote_response: struct {
        rpc_header: RPCHeader,
        term: u64,
        vote_granted: bool,
    },
    install_snapshot_request: struct {
        // TODO
    },
    install_snapshot_response: struct {
        // TODO
    },
    // Used by leader to tell another server to start an election.
    timeout_now_request: struct { rpc_header: RPCHeader },
    timeout_now_response: struct { rpc_header: RPCHeader },
};

fn handleClientConnection(serverCtx: server_util.ServerContext, client: server_util.TcpConnection) !void {
    try serverCtx.logger.print(
        "Accepted new connection on thread {}\n",
        .{serverCtx.thread_id},
    );

    var num_msgs_received: u64 = 0;

    defer {
        serverCtx.logger.print(
            "\nFinished with connection on thread {}, received {} messages\n",
            .{ serverCtx.thread_id, num_msgs_received },
        ) catch |err| {
            std.debug.print("Error logging connection closure: {}\n", .{err});
            std.os.exit(1);
        };
    }

    // Used to send and receive.
    // TODO
    var buffer: [@sizeOf(RaftMessage)]u8 = undefined;

    // Loop until the connection is closed, receiving input and sending back
    // that input as output.
    while (true) {
        switch (server) {
            .leader => {
                try serverCtx.logger.print("Leader waiting for message\n", .{});
            },
            .follower => {
                // TODO possibly unsafe cast
                var last_heartbeat = @intCast(u64, time.nanoTimestamp());
                while (true) {
                    // TODO make random
                    const next_heartbeat_deadline = last_heartbeat + 500000;

                    const now_ns = @intCast(u64, time.nanoTimestamp());
                    const heartbeat_timeout_ts = os.linux.kernel_timespec{
                        .tv_sec = 0,
                        .tv_nsec = @intCast(isize, next_heartbeat_deadline - now_ns),
                    };

                    try serverCtx.logger.print("Follower waiting for message\n", .{});
                    // TODO: BLEH this has to listen from ALL connections
                    const num_bytes_received = client.recv(
                        buffer[0..],
                        io.Timeout{ .ts = &heartbeat_timeout_ts, .flags = 0 },
                        null,
                    ) catch |err| {
                        switch (err) {
                            error.Cancelled => {
                                // Timed out waiting for heartbeat.
                                // Start election.
                                try serverCtx.logger.print("Starting election\n", .{});
                            },
                            else => {},
                        }
                        return err;
                    };
                    if (num_bytes_received == 0) {
                        // 0 bytes received indicates orderly connection closure.
                        break;
                    }
                    const msg = std.mem.bytesAsValue(RaftMessage, buffer[0..@sizeOf(RaftMessage)]);

                    switch (msg.*) {
                        .append_entries_request => |append_entries| {
                            if (append_entries.entries.len == 0) {
                                // Is heartbeat.
                                last_heartbeat = @intCast(u64, time.nanoTimestamp());
                            }
                        },
                        else => {},
                    }
                }

                //const num_bytes_received = try client.recv(buffer[0..], null, null);
            },
            .candidate => {
                try serverCtx.logger.print("Candidate waiting for message\n", .{});
            },
        }

        num_msgs_received += 1;
    }
}

pub const MemberType = enum {
    follower,
    candidate,
    leader,
};

const LeadershipStatus = struct { current_term: u64, member_type: MemberType };

fn runConsensusModule(
    comptime MessageQueue: type,
    comptime Clock: type,
    comptime RandomNumberGenerator: type,
    comptime ClusterConfiguration: type,
    msg_queue: MessageQueue,
    clock: Clock,
    rng: RandomNumberGenerator,
    leadership_status: *LeadershipStatus,
    cluster_config: ClusterConfiguration,
) void {
    // We should start as a follower.
    std.debug.assert(leadership_status.member_type == RaftServer.follower);

    const CM = ConsensusModule(MessageQueue, Clock, RandomNumberGenerator, ClusterConfiguration);

    while (true) {
        // Run as a follower until we don't hear from the leader within the election timeout.
        CM.runAsFollower(msg_queue, clock, rng, leadership_status);

        // At this point, we've timed out waiting for an AppendEntriesRequest from the leader. We
        // become a candidate and start an election.
        leadership_status = LeadershipStatus{
            .member_type = MemberType.candidate,
            .current_term = leadership_status.current_term + 1,
        };

        // Run for election until there's a determinate result.
        while (leadership_status == MemberType.candidate) {
            leadership_status = CM.runAsCandidate(
                msg_queue,
                clock,
                rng,
                leadership_status,
                cluster_config,
            );
        }

        // If we won the election, hang out sending heartbeats until we receive a message from a
        // server with a higher term and need to transition into the follower state.
        if (leadership_status == MemberType.leader) {
            CM.runAsLeader(msg_queue, clock, leadership_status, cluster_config);
        }
    }
}

fn ConsensusModule(
    comptime MessageQueue: type,
    comptime Clock: type,
    comptime RandomNumberGenerator: type,
    comptime ClusterConfiguration: type,
) type {
    return struct {
        fn runAsFollower(
            msg_queue: MessageQueue,
            clock: Clock,
            rng: RandomNumberGenerator,
            leadership_status: *LeadershipStatus,
        ) void {
            var election_deadline = clock.now() + rng.getRandomIntInRange(150, 300);

            // Loop as a follower as long as we receive a message from the leader before the election
            // deadline.
            while (msg_queue.waitForNextWithDeadline(election_deadline)) |msg| {
                // Check whether we've recevied an AppendEntriesRequest from the leader and should
                // update our election deadline.
                switch (msg.contents) {
                    // TODO: Hashicorp implementation also updates election timer on an install
                    // snapshot request, but it's not mentioned in the raft paper
                    .append_entries_request => |append_entries_request| {
                        if (append_entries_request.term < leadership_status.current_term) {
                            // Reject this request, it's from a stale leader.
                            // TODO: Send response with !success
                            continue;
                        }

                        // Received an AppendEntriesRequest from the leader - update election
                        // deadline.
                        election_deadline = clock.now() + rng.getRandomIntInRange(150, 300);
                    },
                    .request_vote_request => |request_vote_request| {
                        if (request_vote_request.term < leadership_status.current_term) {
                            // Reply false.
                        } else {
                            // TODO If votedFor is null or candidateId, and candidate’s log is at
                            // least as up-to-date as receiver’s log, grant vote (§5.2, §5.4)
                        }
                    },
                    else => {
                        std.debug.print("Ignoring message\n", .{});
                    },
                }
            }
        }

        fn runAsCandidate(
            msg_queue: MessageQueue,
            clock: Clock,
            rng: RandomNumberGenerator,
            leadership_status: LeadershipStatus,
            cluster_config: ClusterConfiguration,
        ) LeadershipStatus {
            // From Raft paper
            // • Increment currentTerm
            // • Vote for self
            // • Reset election timer
            // • Send RequestVote RPCs to all other servers
            var election_deadline = clock.now() + rng.getRandomIntInRange(150, 300);

            for (cluster_config.getCurrentPeers()) |peer| {
                peer.requestVote();
            }

            // set of peer ids who voted for us.
            var votes = std.AutoHashMap(u64, void).init(std.testing.allocator);
            defer votes.deinit();

            // TODO Vote for self

            // Loop as a candidate, looking for RequestVoteResponses from peers or an
            // AppendEntriesRequest from a new leader.
            while (msg_queue.waitForNextWithDeadline(election_deadline)) |msg| {
                // TODO make sure we do this for every message
                if (msg.term > leadership_status.current_term) {
                    // Received a request from a server with a higher term, which may be the new
                    // leader - become a follower.
                    return LeadershipStatus{
                        .member_type = MemberType.follower,
                        .current_term = msg.term,
                    };
                }

                // Check whether we've recevied an AppendEntriesRequest from the leader and should
                // update our election deadline.
                switch (msg.contents) {
                    // TODO: Hashicorp implementation also updates election timer on an install
                    // snapshot request, but it's not mentioned in the raft paper
                    .append_entries_request => |append_entries_request| {
                        if (append_entries_request.term < leadership_status.current_term) {
                            // Ignore this message, it's from a stale leader.
                            // TODO: respond with "NO NO BAD"
                            continue;
                        }
                        // Received an AppendEntriesRequest from the leader - become a follower.
                        return LeadershipStatus{
                            .member_type = MemberType.follower,
                            .current_term = msg.term,
                        };
                    },
                    .request_vote_request => {
                        // TODO
                    },
                    .request_vote_response => |request_vote_response| {
                        if (request_vote_response.vote_granted) {
                            // TODO: Add vote to tally
                            // If have enough votes, become leader.
                            // TODO >= ?
                            if (votes.count() > cluster_config.getCurrentPeers().len / 2) {
                                return LeadershipStatus{
                                    .member_type = MemberType.leader,
                                    .current_term = leadership_status.current_term,
                                };
                            }
                        } else {
                            // TODO: how can we get here?
                        }
                    },
                    else => {
                        std.debug.print("Ignoring message\n", .{});
                    },
                }
            }
            // We haven't become elected or heard about a new leader within the deadline - restart
            // the election.
            return LeadershipStatus{
                .member_type = MemberType.candidate,
                .current_term = leadership_status.current_term + 1,
            };
        }

        fn runAsLeader(
            msg_queue: MessageQueue,
            clock: Clock,
            leadership_status: *LeadershipStatus,
            cluster_config: ClusterConfiguration,
        ) void {
            const heartbeat_interval_ms = 50;
            var next_heartbeat_time = clock.now() + heartbeat_interval_ms;

            // Scan messages one at a time to see if there's a new leader, and send heartbeats when
            // needed.
            while (true) {
                // Send heartbeats to all peers if enough time has elapsed.
                if (clock.now() > next_heartbeat_time) {
                    for (cluster_config.getCurrentPeers()) |peer| {
                        peer.sendHeartbeat();
                    }
                    next_heartbeat_time = clock.now() + heartbeat_interval_ms;
                }

                // Check the next message to make sure it didn't come from a server with a higher
                // term, in which case we'd need to step down.
                const maybe_msg = msg_queue.waitForNextWithDeadline(next_heartbeat_time);
                if (maybe_msg) |msg| {
                    if (msg.term > leadership_status.current_term) {
                        // Received a request from a server with a higher term, which may be the new
                        // leader - become a follower.
                        leadership_status.member_type = MemberType.follower;
                        leadership_status.current_term = msg.term;
                        break;
                    }
                }
            }
        }
    };
}

test "runAsFollower returns when no messages arrive within election timeout" {
    const MessageQueue = struct {
        pub fn waitForNextWithDeadline(_: @This(), _: u64) ?RaftMessage {
            return null;
        }
    };

    const Clock = struct {
        pub fn now(_: @This()) u64 {
            return 0;
        }
    };

    const RandomNumberGenerator = struct {
        pub fn getRandomIntInRange(_: @This(), min: u64, _: u64) u64 {
            return min;
        }
    };
    const ClusterConfiguration = struct {};

    var ls = LeadershipStatus{ .member_type = MemberType.follower, .current_term = 0 };
    const msg_queue = MessageQueue{};
    const clock = Clock{};
    const rng = RandomNumberGenerator{};

    const CM = ConsensusModule(MessageQueue, Clock, RandomNumberGenerator, ClusterConfiguration);
    CM.runAsFollower(msg_queue, clock, rng, &ls);
}
