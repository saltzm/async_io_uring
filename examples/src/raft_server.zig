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

const expect = std.testing.expect;

const AsyncIOUring = io.AsyncIOUring;
const AsyncWriter = io.AsyncWriter;
const AsyncMutex = @import("async_mutex.zig").AsyncMutex;

const server_util = @import("server.zig");

// TODO why does this cause tests to be run...
const rb = @import("./ring_buffer.zig");
const RingBuffer = rb.RingBuffer;

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
    id: []const u8,
    // ServerAddr of node sending request
    addr: []const u8,
};

pub const RaftMessage = struct {
    rpc_header: RPCHeader,
    term: u64,
    contents: RaftMessageContents,
};

const AppendEntriesResponse = struct {
    // Hint to accelerate rebuilding slow nodes.
    // last_log: u64
    // May not succeed if there's a conflicting entry.
    success: bool,
    // Indicates didn't succeed but don't need to retry or backoff for next
    // request.
    no_retry_backoff: bool,
};

pub const RaftMessageContents = union(enum) {
    // Doubles as heartbeat when entries is empty for some reason... Maybe
    // change that?
    append_entries_request: struct {
        // For integrity checking.
        prev_log_index: u64,
        prev_log_term: u64,
        entries: []u8, // TODO
    },
    append_entries_response: AppendEntriesResponse,
    request_vote_request: struct {
        // Used to ensure safety
        last_log_index: u64,
        last_log_term: u64,
        // TODO: Paraphrase
        // Used to indicate to peers if this vote was triggered by a leadership
        // transfer. It is required for leadership transfer to work, because
        // servers wouldn't vote otherwise if they are aware of an existing
        // leader.
        leadership_transfer: bool,
    },
    request_vote_response: struct {
        vote_granted: bool,
    },
    install_snapshot_request: struct {
        // TODO
    },
    install_snapshot_response: struct {
        // TODO
    },
    // Used by leader to tell another server to start an election.
    timeout_now_request: struct {},
    timeout_now_response: struct {},
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

//                         RaftMessage{
//                                .rpc_header = .{
//                                    .id = cluster_config.getMyId(),
//                                    .addr = cluster_config.getMyAddr(),
//                                },
//                                .term = leadership_status.current_term,
//                                .contents = .{
//                                    .append_entries_response = .{
//                                        .success = false,
//                                        .no_retry_backoff = true, // TODO
//                                    },
//                                },
//                            }
//
//
//
//                         const logOk = m.prev_log_index == 0 or
//                            (m.prev_log_index <= log.getLastIndex() and
//                            m.prev_log_term == log.getTermOfEntryAt(m.prev_log_index));
//
//                        // Reject this request, if it's from a stale leader or logs don't match.
//                        if (msg.term < leadership_status.current_term or !logOk) {
//                            var sender = cluster_config.getPeer(msg.rpc_header.id);
//                            sender.sendAppendEntriesResponse(
//                                leadership_status.current_term,
//                                AppendEntriesResponse{
//                                    .success = false,
//                                    .no_retry_backoff = true, // TODO - double check
//                                },
//                            );

//
// TODO persistence of persistent state
fn ConsensusModule(
    comptime MessageQueue: type,
    comptime Clock: type,
    comptime ElectionTimer: type,
    comptime ClusterConfiguration: type,
) type {
    return struct {
        msg_queue: *MessageQueue,
        clock: Clock,
        election_timer: ElectionTimer,
        cluster_config: ClusterConfiguration,
        leadership_status: LeadershipStatus,

        pub fn run(self: *@This()) !void {
            // We should start as a follower.
            std.debug.assert(self.leadership_status.member_type == MemberType.follower);

            const CM = @This();

            while (true) {
                std.debug.print("Transitioning to follower\n", .{});
                // Run as a follower until we don't hear from the leader within the election timeout.
                CM.runAsFollower(
                    self.msg_queue,
                    self.election_timer,
                    &self.leadership_status,
                    &self.cluster_config,
                );

                // At this point, we've timed out waiting for an AppendEntriesRequest from the leader. We
                // become a candidate and start an election.
                self.leadership_status = LeadershipStatus{
                    .member_type = MemberType.candidate,
                    .current_term = self.leadership_status.current_term + 1,
                };
                std.debug.print("Transitioning to candidate\n", .{});

                // Run for election until there's a determinate result.
                while (self.leadership_status.member_type == MemberType.candidate) {
                    self.leadership_status = try CM.runAsCandidate(
                        self.msg_queue,
                        self.election_timer,
                        self.leadership_status,
                        &self.cluster_config,
                    );
                }

                // If we won the election, hang out sending heartbeats until we receive a message
                // from a server with a higher term and need to transition into the follower state.
                if (self.leadership_status.member_type == MemberType.leader) {
                    std.debug.print("Transitioning to leader\n", .{});
                    CM.runAsLeader(
                        self.msg_queue,
                        self.clock,
                        &self.leadership_status,
                        &self.cluster_config,
                    );
                }
            }
        }

        fn runAsFollower(
            msg_queue: *MessageQueue,
            election_timer: ElectionTimer,
            leadership_status: *LeadershipStatus,
            cluster_config: *ClusterConfiguration,
        ) void {
            var votedFor: ?[]const u8 = null;

            // Loop as a follower as long as we receive a message from the leader before the election
            // deadline.
            while (msg_queue.waitForNextWithDeadline(election_timer.getElectionDeadline())) |msg| {
                if (msg.term > leadership_status.current_term) {
                    leadership_status.current_term = msg.term;
                }
                // Check whether we've received an AppendEntriesRequest from the leader and should
                // update our election deadline.
                switch (msg.contents) {
                    // TODO: Hashicorp implementation also updates election timer on an install
                    // snapshot request, but it's not mentioned in the raft paper
                    .append_entries_request => {
                        // Reject this request, if it's from a stale leader or logs don't match.
                        if (msg.term == leadership_status.current_term) {
                            // Received an AppendEntriesRequest from the leader - update election
                            // deadline.
                            election_timer.reset();
                        }
                    },
                    .request_vote_request => {
                        var sender = cluster_config.getPeer(msg.rpc_header.id);
                        // TODO Maybe have a separate thread/process-y thing handling this stuff?
                        if (msg.term < leadership_status.current_term) {
                            // Reply false.
                        } else {
                            // TODO If votedFor is null or candidateId, and candidate’s log is at
                            // least as up-to-date as receiver’s log, grant vote (§5.2, §5.4)
                            if (votedFor) |_| {
                                // std.debug.print("Already voted for {s}", .{v});
                                sender.sendRejectingVote(
                                    cluster_config.my_id,
                                    leadership_status.current_term,
                                );
                            } else {
                                sender.sendAffirmativeVote(
                                    cluster_config.my_id,
                                    leadership_status.current_term,
                                );
                                votedFor = msg.rpc_header.id;
                            }
                        }
                    },
                    else => {
                        //std.debug.print("Ignoring message\n", .{});
                    },
                }
            }
        }

        fn runAsCandidate(
            msg_queue: *MessageQueue,
            election_timer: ElectionTimer,
            leadership_status: LeadershipStatus,
            cluster_config: *ClusterConfiguration,
        ) !LeadershipStatus {
            std.debug.assert(leadership_status.member_type == MemberType.candidate);
            // From Raft paper
            // • Increment currentTerm
            // • Vote for self
            // • Reset election timer
            // • Send RequestVote RPCs to all other servers
            for (cluster_config.getCurrentPeers()) |*peer| {
                peer.*.requestVote(cluster_config.my_id, leadership_status.current_term);
            }

            // set of peer ids who voted for us.
            var votes = std.StringHashMap(void).init(std.testing.allocator);
            defer votes.deinit();

            // Vote for self.
            try votes.put(cluster_config.my_id, {});

            // Loop as a candidate, looking for RequestVoteResponses from peers or an
            // AppendEntriesRequest from a new leader.
            while (msg_queue.waitForNextWithDeadline(election_timer.getElectionDeadline())) |msg| {
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
                    .append_entries_request => {
                        if (msg.term == leadership_status.current_term) {
                            // Received an AppendEntriesRequest from the leader - become a follower.
                            // TODO: This should not consume the message, as we should still apply
                            // it as a follower....
                            return LeadershipStatus{
                                .member_type = MemberType.follower,
                                .current_term = msg.term,
                            };
                        }
                    },
                    .request_vote_request => {
                        // TODO
                    },
                    .request_vote_response => |request_vote_response| {
                        if (request_vote_response.vote_granted) {
                            try votes.put(msg.rpc_header.id, {});
                            std.debug.print("{s} received vote from {s}\n", .{ cluster_config.my_id, msg.rpc_header.id });
                            // TODO: Add vote to tally
                            // If have enough votes, become leader.
                            // TODO: Make this always right
                            var quorum = cluster_config.getCurrentPeers().len / 2 + 1;
                            if (votes.count() > quorum) {
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
            msg_queue: *MessageQueue,
            clock: Clock,
            leadership_status: *LeadershipStatus,
            cluster_config: *ClusterConfiguration,
        ) void {
            const heartbeat_interval_ms = 50;
            var next_heartbeat_time = clock.now() + heartbeat_interval_ms;

            // Scan messages one at a time to see if there's a new leader, and send heartbeats when
            // needed.
            while (true) {
                // Send heartbeats to all peers if enough time has elapsed.
                if (clock.now() > next_heartbeat_time) {
                    for (cluster_config.getCurrentPeers()) |*peer| {
                        peer.*.sendHeartbeat();
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

const Test = struct {
    const DummyMessageQueue = struct {
        pub fn waitForNextWithDeadline(_: @This(), _: u64) ?RaftMessage {
            return null;
        }
    };
    const DummyClock = struct {
        pub fn now(_: @This()) u64 {
            return 0;
        }
    };

    const DummyElectionTimer = struct {
        pub fn getElectionDeadline(_: @This()) u64 {
            return 0;
        }
        pub fn reset(_: @This()) void {}
    };
};

test "runAsFollower returns when no messages arrive within election timeout" {
    const ClusterConfiguration = struct {
        my_id: []const u8 = "",
        const Peer = struct {
            pub fn sendAppendEntriesResponse(_: @This(), _: u64, _: RaftMessageContents) void {}
            pub fn sendAffirmativeVote(_: *@This(), _: []const u8, _: u64) void {}
            pub fn sendRejectingVote(_: *@This(), _: []const u8, _: u64) void {}
        };

        pub fn getPeer(_: @This(), _: []const u8) Peer {
            return .{};
        }
    };

    var ls = LeadershipStatus{ .member_type = MemberType.follower, .current_term = 0 };

    const CM = ConsensusModule(
        Test.DummyMessageQueue,
        Test.DummyClock,
        Test.DummyElectionTimer,
        ClusterConfiguration,
    );
    var msg_queue = Test.DummyMessageQueue{};
    var cluster_config = ClusterConfiguration{};
    CM.runAsFollower(&msg_queue, Test.DummyElectionTimer{}, &ls, &cluster_config);
}

test "runAsCandidate sends request vote to all peers" {
    var ls = LeadershipStatus{ .member_type = MemberType.candidate, .current_term = 0 };

    const ClusterConfiguration = struct {
        my_id: []const u8 = "",
        peers: [3]Peer = [_]Peer{ Peer{}, Peer{}, Peer{} },

        const Peer = struct {
            received_request_vote: bool = false,

            pub fn requestVote(self: *@This(), _: []const u8, _: u64) void {
                self.received_request_vote = true;
            }
        };

        pub fn getPeer(_: @This(), _: []const u8) Peer {
            return .{};
        }

        pub fn getCurrentPeers(self: *@This()) []Peer {
            return self.peers[0..];
        }
    };

    const CM = ConsensusModule(
        Test.DummyMessageQueue,
        Test.DummyClock,
        Test.DummyElectionTimer,
        ClusterConfiguration,
    );

    var cluster_config = ClusterConfiguration{};

    var msg_queue = Test.DummyMessageQueue{};
    _ = try CM.runAsCandidate(msg_queue, Test.DummyElectionTimer{}, ls, &cluster_config);

    for (cluster_config.getCurrentPeers()) |peer| {
        try std.testing.expectEqual(peer.received_request_vote, true);
    }
}

test "three node cluster" {
    const MessageQueue = struct {
        //TODO maybe try something fancy with asyncmutex
        mtx: std.Thread.Mutex = .{},
        messages: RingBuffer(RaftMessage, 1024) = .{},

        //messages: UnbufferedChannel(RaftMessage) = .{},

        pub fn waitForNextWithDeadline(self: *@This(), _: u64) ?RaftMessage {
            self.mtx.lock();
            defer self.mtx.unlock();
            const msg = self.messages.dequeue() catch |err| {
                if (err == error.RingBufferEmpty) {
                    return null;
                } else return err;
            };

            return msg;
            //return self.messages.recv();
        }

        pub fn enqueue(self: *@This(), msg: RaftMessage) void {
            //self.messages.send(msg);
            self.mtx.lock();
            defer self.mtx.unlock();
            self.messages.enqueue(msg) catch {
                //std.debug.print("RingBuffer enqueue error: .{} \n", .{err});
                //std.os.exit(1);
            };
        }
    };

    const Peer = struct {
        msg_queue: MessageQueue = MessageQueue{},
        id: []const u8,
        // TODO
        addr: *const [5:0]u8 = "addr1",

        pub fn requestVote(self: *@This(), local_id: []const u8, local_term: u64) void {
            self.msg_queue.enqueue(RaftMessage{
                .rpc_header = .{
                    .protocol_version = 0,
                    .id = local_id,
                    .addr = @as([]const u8, self.addr[0..]),
                },
                .term = local_term,
                .contents = RaftMessageContents{
                    .request_vote_request = .{
                        .last_log_index = 0,
                        .last_log_term = 0,
                        .leadership_transfer = false,
                    },
                },
            });
        }

        pub fn sendHeartbeat(self: *@This()) void {
            self.msg_queue.enqueue(RaftMessage{
                .rpc_header = .{
                    .protocol_version = 0,
                    .id = self.id,
                    .addr = @as([]const u8, self.addr[0..]),
                },
                .term = 0,
                .contents = RaftMessageContents{
                    .append_entries_request = .{
                        .prev_log_index = 0,
                        .prev_log_term = 0,
                        .entries = "", // TODO make entries optional?
                    },
                },
            });
        }

        fn sendVote(self: *@This(), local_id: []const u8, local_term: u64, vote: bool) void {
            self.msg_queue.enqueue(RaftMessage{
                .rpc_header = .{
                    .protocol_version = 0,
                    .id = local_id,
                    .addr = @as([]const u8, self.addr[0..]),
                },
                .term = local_term,
                .contents = RaftMessageContents{
                    .request_vote_response = .{
                        .vote_granted = vote,
                    },
                },
            });
        }

        pub fn sendAffirmativeVote(self: *@This(), local_id: []const u8, term: u64) void {
            self.sendVote(local_id, term, true);
        }

        pub fn sendRejectingVote(self: *@This(), local_id: []const u8, term: u64) void {
            self.sendVote(local_id, term, false);
        }
    };

    const ClusterConfiguration = struct {
        const Self = @This();

        my_id: []const u8,
        peers: []*Peer,
        peers_by_id: std.StringHashMap(*Peer),

        pub fn init(my_id_: []const u8, starting_peers: []*Peer) Self {
            var self = Self{
                .my_id = my_id_,
                .peers = starting_peers,
                .peers_by_id = std.StringHashMap(*Peer).init(std.testing.allocator),
            };

            for (self.peers) |p| {
                // TODO: Assuming capacity
                self.peers_by_id.put(p.id, p) catch |err| {
                    std.debug.print("err putting {}\n", .{err});
                    std.os.exit(1);
                };
            }

            var keys = self.peers_by_id.keyIterator();
            while (keys.next()) |key| {
                std.debug.print("init Key: {s}\n", .{key.*});
            }

            return self;
        }

        pub fn deinit(self: *@This()) void {
            self.peers_by_id.deinit();
        }

        pub fn getCurrentPeers(self: *@This()) []*Peer {
            return self.peers;
        }

        pub fn getPeer(self: *@This(), id: []const u8) *Peer {
            var maybe_peer = self.peers_by_id.get(id);
            if (maybe_peer) |peer| {
                return peer;
            } else {
                // TODO
                std.debug.print("Peer not found: {s}\n", .{id});
                var keys = self.peers_by_id.keyIterator();
                while (keys.next()) |key| {
                    std.debug.print("Key: {s}\n", .{key.*});
                }

                std.os.exit(1);
            }
        }
    };

    const CM = ConsensusModule(
        MessageQueue,
        Test.DummyClock,
        Test.DummyElectionTimer,
        ClusterConfiguration,
    );

    var threads: [3]std.Thread = undefined;
    var cms: [3]CM = undefined;
    const ids = [_][]const u8{ "0", "1", "2" };
    var peers: [3]Peer = [_]Peer{
        Peer{ .id = ids[0][0..] },
        Peer{ .id = ids[1][0..] },
        Peer{ .id = ids[2][0..] },
    };

    var p0 = [_]*Peer{ &peers[1], &peers[2] };
    var p1 = [_]*Peer{ &peers[0], &peers[2] };
    var p2 = [_]*Peer{ &peers[0], &peers[1] };

    cms[0] = CM{
        .msg_queue = &peers[0].msg_queue,
        .clock = Test.DummyClock{},
        .election_timer = Test.DummyElectionTimer{},
        .cluster_config = ClusterConfiguration.init(ids[0], p0[0..]),
        .leadership_status = LeadershipStatus{
            .member_type = MemberType.follower,
            .current_term = 0,
        },
    };
    cms[1] = CM{
        .msg_queue = &peers[1].msg_queue,
        .clock = Test.DummyClock{},
        .election_timer = Test.DummyElectionTimer{},
        .cluster_config = ClusterConfiguration.init(ids[1], p1[0..]),
        .leadership_status = LeadershipStatus{
            .member_type = MemberType.follower,
            .current_term = 0,
        },
    };
    cms[2] = CM{
        .msg_queue = &peers[2].msg_queue,
        .clock = Test.DummyClock{},
        .election_timer = Test.DummyElectionTimer{},
        .cluster_config = ClusterConfiguration.init(ids[2], p2[0..]),
        .leadership_status = LeadershipStatus{
            .member_type = MemberType.follower,
            .current_term = 0,
        },
    };

    for (threads) |*t, i| {
        std.debug.print("Spawning: {}\n", .{i});
        t.* = try std.Thread.spawn(.{}, CM.run, .{&cms[i]});
    }

    for (threads) |*t| {
        t.join();
    }

    //for (cluster_config.getCurrentPeers()) |*peer| {
    //    const msg_in_peer = peer.msg_queue.waitForNextWithDeadline(0);
    //    if (msg_in_peer) |msg| {
    //        try std.testing.expectEqual(msg.contents, RaftMessageContents{
    //            .request_vote_request = .{
    //                .last_log_index = 0,
    //                .last_log_term = 0,
    //                .leadership_transfer = false,
    //            },
    //        });
    //    } else {
    //        try std.testing.expectEqual(true, false); // TODO
    //    }
    //}
}

fn UnbufferedChannel(comptime T: type) type {
    return struct {
        const Self = @This();
        value: ?T = null,
        waiting_recv: ?anyframe = null,
        waiting_send: ?anyframe = null,

        // Sends a value to the channel.
        //
        // Suspends until the value is fetched by a call to recv.
        pub fn send(self: *Self, t: T) void {
            assert(self.value == null);
            self.value = t;
            if (self.waiting_recv) |recv_op| {
                resume recv_op;
            } else {
                suspend {
                    self.waiting_send = @frame();
                }
                self.waiting_send = null;
            }
        }

        // Returns the value in the channel, or if there is no value present,
        // suspends until a value is sent into the channel.
        pub fn recv(self: *Self) T {
            if (self.value) |val| {
                self.value = null;
                assert(self.waiting_send != null);
                resume self.waiting_send.?;
                return val;
            } else {
                suspend {
                    self.waiting_recv = @frame();
                }
                self.waiting_recv = null;

                assert(self.waiting_send == null);
                assert(self.value != null);
                const val = self.value.?;
                self.value = null;
                return val;
            }
        }
    };
}

fn test_unbuffered_channel_send_before_receive(finished_test: *bool) !void {
    var channel = UnbufferedChannel(i32){};
    const val = 1;
    var send_frame = async channel.send(val);
    var recv_frame = async channel.recv();
    await send_frame;
    var received = await recv_frame;
    try expect(val == received);
    finished_test.* = true;
}

fn test_unbuffered_channel_send_after_receive(finished_test: *bool) !void {
    var channel = UnbufferedChannel(i32){};
    const val = 1;
    var recv_frame = async channel.recv();
    var send_frame = async channel.send(val);
    await send_frame;
    var received = await recv_frame;
    try expect(val == received);
    finished_test.* = true;
}

test "unbuffered channel send before receive" {
    var finished_test = false;
    _ = async test_unbuffered_channel_send_before_receive(&finished_test);
    try expect(finished_test);
}

test "unbuffered channel send after receive" {
    var finished_test = false;
    _ = async test_unbuffered_channel_send_after_receive(&finished_test);
    try expect(finished_test);
}

fn fibonacci_w_channel(channel: *UnbufferedChannel(i64)) void {
    var a: i64 = 0;
    var b: i64 = 1;
    while (true) {
        channel.send(b);
        const next = a + b;
        a = b;
        b = next;
    }
}

fn test_fibonacci_w_channel(finished_test: *bool) !void {
    var channel = UnbufferedChannel(i64){};
    _ = async fibonacci_w_channel(&channel);
    try expect(channel.recv() == @intCast(i64, 1));
    try expect(channel.recv() == @intCast(i64, 1));
    try expect(channel.recv() == @intCast(i64, 2));
    try expect(channel.recv() == @intCast(i64, 3));
    try expect(channel.recv() == @intCast(i64, 5));
    try expect(channel.recv() == @intCast(i64, 8));
    try expect(channel.recv() == @intCast(i64, 13));
    finished_test.* = true;
}

test "fibonacci w channel" {
    var finished_test = false;
    _ = async test_fibonacci_w_channel(&finished_test);
    try expect(finished_test);
}
var test_frame: anyframe = undefined;
fn fibonacci_w_channel_and_suspend(channel: *UnbufferedChannel(i64)) void {
    var a: i64 = 0;
    var b: i64 = 1;
    while (true) {
        suspend {
            test_frame = @frame();
        }
        channel.send(b);
        const next = a + b;
        a = b;
        b = next;
    }
}

fn test_fibonacci_w_channel_and_suspend(finished_test: *bool) void {
    var channel = UnbufferedChannel(i64){};
    _ = async fibonacci_w_channel_and_suspend(&channel);
    resume test_frame;
    try expect(channel.recv() == @intCast(i64, 1));
    resume test_frame;
    try expect(channel.recv() == @intCast(i64, 1));
    resume test_frame;
    try expect(channel.recv() == @intCast(i64, 2));
    resume test_frame;
    try expect(channel.recv() == @intCast(i64, 3));
    resume test_frame;
    try expect(channel.recv() == @intCast(i64, 5));
    resume test_frame;
    try expect(channel.recv() == @intCast(i64, 8));
    resume test_frame;
    try expect(channel.recv() == @intCast(i64, 13));
    finished_test.* = true;
}

test "Channel" {
    var finished_test = false;
    _ = async test_fibonacci_w_channel(&finished_test);
    try expect(finished_test);
}
