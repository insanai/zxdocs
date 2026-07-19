#import "theme.typ": *

= Embedding APIs

== The Zig library

Add the package and import `zaxonlite`; the parent `paxos` library and
the pinned SQLite amalgamation come with it.

```zig
const zaxonlite = @import("zaxonlite");

var node = try zaxonlite.Node.open(gpa, io, .{ .directory = "./data" });
defer node.close();

_ = try node.exec("create table items(id integer primary key, v text)");

const session = try node.openSession();
_ = try node.execIdempotent(session, 1,
    "insert into items(v) values ('tea')");

var rows = try node.query(gpa, "select id, v from items order by id");
defer rows.deinit();

try node.snapshot();                       // seal the epoch online
const report = try node.integrityCheck();  // sqlite + chain + payloads
```

Key surface on `Node`:

#table(
  columns: (auto, 1fr),
  table.header([*Function*], [*Contract*]),
  [`open` / `close`], [Owns the directory; `OpenOptions` selects
    one-member or cluster membership, election priority, and a fixed
    database identity for clusters.],
  [`exec`], [One replicated write transaction. In a one-member
    configuration the result is committed and applied on return.],
  [`openSession` / `execIdempotent` / `expireSessions`], [Exactly-once
    retry sessions (chapter 6).],
  [`query`], [Read-only, arena-backed result set; uses the live
    connection on the leader, a short-lived one elsewhere.],
  [`snapshot`], [Online checkpoint + epoch seal + rollover
    (one-member); cluster hosts use `prepareCheckpoint` and complete on
    decision.],
  [`backup` / `contentHash` / `integrityCheck` / `status`],
    [Operations surface, identical to the CLI's.],
  [`stepEnvelope` / `tickProtocol` / `peerReconnected` /
   `requestCatchUp` / outbox], [The transport-host surface `server.zig`
    is built on — available to embedders who bring their own
    transport.],
)

== The C ABI

`libzaxonlite.a` plus `zaxonlite.h` export the embedded surface with
CLI-aligned return codes (0 ok, 1 SQL/session, 2 misuse, 3 integrity,
4 unavailable):

```c
#include <zaxonlite.h>

zaxonlite *db = NULL;
if (zaxonlite_open("./data", &db) != 0) return 1;

int64_t changes;
zaxonlite_exec(db, "create table t(a integer primary key, b text)",
               &changes);

uint64_t session;
zaxonlite_session_open(db, &session);
bool replayed;
zaxonlite_exec_idempotent(db, session, 1,
    "insert into t(b) values ('x')", &changes, &replayed);

char *json;
if (zaxonlite_query_json(db, "select * from t", &json) == 0) {
    puts(json);              /* {"columns":[...],"rows":[[...]]} */
    zaxonlite_free(json);
}

zaxonlite_snapshot(db);
zaxonlite_integrity_check(db);
zaxonlite_close(db);
```

Each handle owns an internal event-loop instance; use a handle from one
thread at a time (SQLite connection discipline). `zaxonlite_last_error`
returns the most recent message for the handle.

== The client RPC protocol

Anything that can frame bytes over TCP can be a client: one `hello`
frame (`kind = client`), then one JSON request per `rpc_request` frame
and one JSON response per `rpc_response`. Requests are objects with an
`op` — `exec`, `query`, `session`, `wait`, `status`, `leader`,
`snapshot`, `integrity`, `expire-sessions`, `stop` — mirroring the CLI
exactly; error responses carry `{"ok":false,"error":code,` and, for
`not_leader`, the leader's endpoint for redirect-following.
