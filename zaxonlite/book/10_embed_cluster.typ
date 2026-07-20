#import "theme.typ": *
#import "figures.typ": *

= Embedding a cluster in Zig

#objectives([
  By the end of this chapter you should be able to start a cluster
  member inside your own process with `Embedded.open`, say which parts
  of the stack the facade owns and which parts your host owns, route
  writes to the leader without knowing who the leader is, and state
  plainly what the facade does not do for you.
])

#checkpoint([the embedded node], [
  Everything here wraps chapter 9's `Node`. You should know what `exec`
  syncs before it returns, and who owns a `QueryResult`, before we add
  a network to the picture.
])

Chapter 9's `Node` leaves networking to you. The `Embedded` facade,
exported as `zaxonlite.Embedded`, is the batteries-included member.
Each facade owns one node, its TCP listener, its peer senders, its tick
loop, and client routing. An application creates one facade per
process. The same API serves one through nine voters, plus any number
of non-voting replicas and gateways.

== The member registry and `open`

#api_anchor(`Embedded.open(gpa, io, options) !*Embedded`,
  [Starts a full cluster member, server thread included, and returns
   once its listener answers, or fails within the startup timeout.],
  source: [`zaxonlite/src/embedded.zig`])

Every member passes the same registry: a slice of
`zaxonlite.EmbeddedMember` values. Each entry carries an `id`, an
`address` in `host:port` text, and a `role` that defaults to
`.data_voter`. `OpenOptions` adds `directory` and `node_id`, which say
which member this process is. It also takes an optional `cluster_id`,
an optional `auth_secret`, and `startup_timeout_ms` with a default of
10,000.

There is no `database_id` field here. The database identity is derived
from the member registry plus `cluster_id`. Agreeing on the registry is
agreeing on the database. Changing either later names a different
database.

Validation happens before any thread starts, and the error names are
the contract:

#table(
  columns: (auto, 1fr),
  table.header([*Open-time error*], [*When `open` returns it*]),
  [`error.InvalidMemberCount`], [The registry is empty.],
  [`error.InvalidNodeId`], [A member id is zero.],
  [`error.DuplicateNodeId`], [Two registry entries share an id.],
  [`error.InvalidVoterCount`], [The registry has zero voters, or more
    than nine. Witnesses count as voters; learners do not.],
  [`error.CampaignerRequired`], [No voter can campaign. Such a cluster
    would be leaderless forever, by construction, so `open` refuses
    it.],
  [`error.NotMember`], [Your `node_id` does not appear in the
    registry.],
)

After validation the facade copies every string into its own arena. You
may free your registry and address buffers the moment `open` returns.
`open` then spawns the server thread and polls its own endpoint until a
status call answers. A server that dies first surfaces as
`error.ServerStartupFailed`. Silence past the timeout surfaces as
`error.ServerStartupTimeout`.

== Who owns what

#table(
  columns: (1fr, 1fr),
  table.header([*The facade owns*], [*Your host owns*]),
  [The TCP listener and the server thread behind it.],
    [The allocator and the `Io` you pass in. Both must outlive the
     facade.],
  [The peer senders and the protocol tick loop.],
    [The data directory chosen for each member.],
  [The node, with its journal, payloads, snapshots, and image.],
    [The retry policy around ambiguous write outcomes (chapter 8).],
  [Client routing, including leader redirects.],
    [Freeing every response body returned by `call`.],
)

== `exec`, `query`, and `call`

The facade speaks to its own cluster through the client RPC protocol.
That is what makes leader routing uniform: your process is a client of
itself.

+ `exec(sql) !ExecResult` runs one replicated write, routed to the
  leader. The result is the decided outcome. Acknowledged means
  committed by a voter quorum and applied.
+ `query(gpa, sql) !QueryResult` runs a `linearizable` read, using the
  quorum fence from chapter 8, routed to the leader. The result owns
  its memory through an arena on the `gpa` you pass. Call `deinit()`
  exactly once.
+ `call(request, leader) ![]u8` sends any raw JSON request from the
  RPC vocabulary: `session`, `wait`, `status`, `members`, `snapshot`,
  `backup`, `integrity`, `expire-sessions`, and the rest. With
  `leader = true` the request routes to the leader. With `false` the
  first reachable member answers. You own the returned body. Free it
  with the `gpa` the facade was opened with.

Routing tries endpoints in rotation and follows the `not_leader`
redirect hint each declining member returns. It retries for up to
twelve attempts with 150 ms pauses, which is enough to ride out an
election. After that it gives up with `error.NoLeaderReachable`.

#transcript((
  [1], [You], [Call `exec` on member 2's facade. Member 2 is not the
    leader, but you do not need to know that.],
  [2], [Facade], [Sends the RPC to the first endpoint in its
    rotation.],
  [3], [Member], [Declines with `not_leader` and names the leader in
    the redirect hint.],
  [4], [Facade], [Retries against the hinted leader.],
  [5], [Leader], [Runs the replicated write and answers with the
    decided result once the slot is committed and applied.],
))

`exec` and `query` flatten any other error response to
`error.RemoteOperationFailed`. Sometimes you need more than that. The
structured error code (`sql`, `ambiguous`, `stale`, `forbidden`, and
the rest) and the `replayed` marker of a session retry only appear in
the JSON body. For those, use `call` and parse the response yourself.
Idempotent sessions in particular are reached through `call`. The
facade adds no session helper.

When `auth_secret` is set, every connection the facade makes or
accepts runs the pre-shared-key transport authentication. That covers
peer and client connections alike. All members must carry the same
secret. The secret provides integrity and authentication, not secrecy.

== Walkthrough: three voters in one process

This is the shape of `zaxonlite/src/role_cluster_test.zig`, reduced to
three data voters. In production these are three processes on three
machines. The API is identical. First we write the registry. Every
member will pass this same slice:

```zig
const zaxonlite = @import("zaxonlite");

const members = [_]zaxonlite.EmbeddedMember{
    .{ .id = 1, .address = "127.0.0.1:9701" },
    .{ .id = 2, .address = "127.0.0.1:9702" },
    .{ .id = 3, .address = "127.0.0.1:9703" },
};
```

Next we open the three members. Each gets its own directory and its own
`node_id`. Everything else is shared:

```zig
var nodes: [3]*zaxonlite.Embedded = undefined;
for (&nodes, 0..) |*node, index| {
    node.* = try zaxonlite.Embedded.open(gpa, io, .{
        .directory = directories[index], // one directory per member
        .node_id = @intCast(index + 1),
        .members = &members,
        .cluster_id = "example",
        .auth_secret = "example-cluster-secret-32-bytes!",
    });
}
defer for (nodes) |node| node.close();
```

The cluster is now electing its first leader. A write issued before
that election finishes fails cleanly, so the first write retries until
a leader wins:

```zig
var elapsed: u64 = 0;
while (elapsed < 20_000) : (elapsed += 100) {
    if (nodes[0].exec("create table t(v text)")) |_| break else |_| {}
    io.sleep(.fromMilliseconds(100), .awake) catch {};
}
```

From here, any member's facade accepts any operation. Routing finds the
leader for us:

```zig
_ = try nodes[1].exec("insert into t values ('chosen')"); // any member
var rows = try nodes[2].query(gpa, "select v from t");
defer rows.deinit();
```

Mixed roles use the same registry. The six-member test adds a
`.witness`, a `.standby`, and a `.read_replica`. A member whose own
role is `.gateway` runs the stateless gateway loop instead of a node.
It keeps no data directory contents and no Paxos state. It routes
bytes, unmodified, to the members whose roles serve reads or writes,
behind the same `auth_secret` gate.

#book_figure([
  One registry can describe every role at once. Voters replicate, the
  gateway routes without storing anything, and learners receive
  certified commits.
], cluster_topology())

== Shutdown ordering in `close`

`close` is deliberate about order. A normal member first asks its own
server to stop through a client `stop` RPC. A gateway instead flips its
shutdown flag and pokes the listener awake. `close` then joins the
server thread. The listener, peer senders, and node therefore close on
the server's own path, with the journal already durable. Only then does
`close` free the arena-held registry and the facade itself.

Close members in any order. Once fewer than a quorum of voters remain,
the survivors keep serving `any`-level reads. Writes and linearizable
reads block until a quorum returns. A request still in flight when
`close` runs may or may not have committed. Its caller must treat the
outcome as ambiguous, exactly as in chapter 8. `close` never returns
an error, and it is safe to call after the server has already exited on
its own.

== What the facade does not provide

Stated directly, per the release limits in `docs/zaxonlite-format.typ`:

+ *No automatic membership change.* The voter set is fixed at open.
  Replacing a failed voter is an operator procedure, not an API call.
+ *No dynamic registry.* Adding even a read replica means restarting
  members with the new registry, keeping the same voters and the same
  `cluster_id`.
+ *No secrecy on the wire.* `auth_secret` authenticates; it does not
  encrypt. Run untrusted networks through your own tunnel.
+ *No session sugar and no read-level knob.* `exec` is leader-routed
  and `query` is linearizable. Every other combination goes through
  `call`.
+ *No multi-database support.* One facade serves one replicated
  database. There are no cross-database transactions.

#exercise(1, hint: [
  Count campaigners, then reread the `open` validation order in
  `zaxonlite/src/embedded.zig` and the read-level table in chapter 8.
])[
  Extend the three-voter example with a fourth member of role
  `.read_replica`. Predict, before running: which validation error
  changes if you instead give all four members role `.witness`? Then
  use `call` with a `{"op":"query", ..., "level":"any"}` request
  against the replica's endpoint. Explain why that response may be
  labeled stale when the same query through `query` never is.
]

#teach_back([
  Explain to a colleague which failures of a three-voter embedded
  cluster your application code must still handle itself. Use the words
  ambiguous, quorum, and registry at least once each.
])
