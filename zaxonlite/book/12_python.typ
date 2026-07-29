#import "theme.typ": *

= The Python SDK: zxlite

#objectives([
  - Install and build `zxlite` from a source checkout with uv, and say
    what the build actually links.
  - Open a local node through the sqlite3-shaped DB-API and explain, in
    replication terms, what a returned `execute()` means.
  - Explain why concurrent writes queue in arrival order instead of
    failing with "database is locked", and what the `timeout` argument
    actually bounds.
  - Host a single-node backend from Python over a Unix-domain socket and
    connect a second process to it.
  - Open a redundant remote connection with explicit read levels and
    exactly-once writes, and resolve a pending write after a failure.
  - Decide when a live transaction or the SQLAlchemy dialect applies and
    when it is refused.
])

Python applications reach zaxonlite through `zxlite`, a package that
lives in this repository at `zaxonlite/languages/python`. It is a thin
policy layer over chapter 11: a small CPython extension links
`libzaxonlite.a` statically and exposes the C ABI, and everything you
learned there — return codes, ownership, one replicated write per
acknowledgement — still governs what your Python program observes. We
walk the surface in the order you will use it: install, connect, write,
read, search, host a backend, go remote, hold a transaction, and map an
ORM.

== Install and build

The package is uv-managed. From a checkout:

```console
$ cd zaxonlite/languages/python
$ uv sync
$ uv pip install -e .
$ uv run pytest -q
```

The editable install runs `zig build -Doptimize=ReleaseSafe` in
`zaxonlite/` and compiles `src/native/module.c` against CPython's
Limited API for 3.12, so one built artifact serves CPython 3.12 and
later (the wheel tag is `cp312-abi3`). The extension is private: you
import `zxlite`, never `zxlite._zxlite`. Formatting and linting are
`ruff format` and `ruff check`, and both gate CI; the public layer is
fully type-annotated and follows the standard library's conventions so
a `sqlite3` user reads it without relearning style.

#callout(title: [The database argument is a directory], tone: "note")[
  Everywhere `sqlite3` takes a file path, `zxlite` takes a zaxonlite
  data directory — journal, payload store, snapshots, and the
  materialized image from chapter 6. The SDK never opens `current.db`
  directly, and a second `connect()` to the same directory fails with
  `OperationalError` because the directory lock has one owner.
]

== A first session

#api_anchor(
  [`zxlite.connect`],
  [Open a local embedded node, a served Unix socket, or a remote
  cluster, returning a DB-API 2.0 connection.],
  source: [`dbapi.py`],
)

```python
import zxlite

with zxlite.connect("/var/lib/example") as db:
    db.execute("create table item(id integer primary key, note text)")
    cursor = db.execute(
        "insert into item(note) values (?1) returning id", ("tea",)
    )
    print(cursor.lastrowid, cursor.fetchone())
    for row in db.execute("select id, note from item order by id"):
        print(row["id"], row["note"])
```

When `execute()` returns for a write, the statement has run inside one
zaxonlite transaction, its WAL frames were captured and proposed, and
the decided slot was applied. The row is durable and replicated, not
merely buffered. Reads are materialized: the full result is copied
before `execute()` returns, so a cursor never holds a native statement
open while your program thinks.

The module globals are exactly what PEP 249 asks for: `apilevel` is
`"2.0"`, `paramstyle` is `"qmark"`, and `threadsafety` is 2 — threads
may share the module and connections, but never one cursor. Local
connections default to `check_same_thread=True` like `sqlite3`; pass
`False` to share one connection between threads, in which case every
call still serializes through the connection's single native handle.

== Errors carry categories, not string matching

Native failures map onto the standard DB-API hierarchy — `Warning`,
`Error`, `InterfaceError`, `DatabaseError`, `DataError`,
`OperationalError`, `IntegrityError`, `InternalError`,
`ProgrammingError`, `NotSupportedError`. The mapping is driven by the
stable category codes from `zaxonlite_last_error_category`, never by
parsing message text:

#table(
  columns: (auto, auto, 1fr),
  table.header([*Category*], [*Exception*], [*Typical cause*]),
  [constraint], [`IntegrityError`], [UNIQUE or foreign-key violation.],
  [busy, interrupt], [`OperationalError`],
  [A genuine SQLite engine condition; see the next section for what
  never causes one.],
  [misuse], [`ProgrammingError`],
  [Closed handle, parameter mismatch, write on the read path,
  multi-statement `execute()`.],
  [session], [`OperationalError`],
  [Unknown session, sequence gap, expired replay window.],
  [validation], [`ProgrammingError`],
  [A typed search request the native validator rejected.],
  [storage, availability], [`OperationalError`],
  [Locked directory, storage failure, no leader or quorum.],
)

Exceptions expose the category as `exception.category`, so a program
that must branch on a cause has a stable token to branch on.

== Writes queue; they do not fail

Python's `sqlite3` exposes file-lock contention directly: a second
writer gets `SQLITE_BUSY` and the driver raises "database is locked".
zaxonlite removed that failure mode before this SDK existed — the
server owns SQLite's single writer and admits one replicated write at
a time behind a first-in-first-out gate (chapter 8) — and `zxlite`
completes the contract on the client side.

Every connection has one write lane. A thread that submits a write
while the lane is busy waits on an ordered ticket, strictly in arrival
order, so a sustained stream of writers cannot starve one caller. The
`timeout` argument to `connect()` keeps `sqlite3`'s name but bounds
this queue wait, not a lock spin: expiry raises `OperationalError`
with category `write_queue_timeout`, the statement provably never
executed, no session sequence was consumed, and an immediate retry is
safe.

#callout(title: [Ordered admission, single writer], tone: "decision")[
  Queueing is admission control, not parallelism. The database still
  commits one replicated write at a time, so under sustained write
  pressure latency grows with queue depth until waits surface as typed
  timeouts. What you gain is the server-database contract: no zxlite
  writer ever sees "database is locked" because another zxlite writer
  was ahead of it. A genuine `SQLITE_BUSY` from a different engine
  path still surfaces as a real `OperationalError` — contention is
  queued, engine faults are not hidden.
]

The 32-thread contention test in `tests/dbapi/test_threads.py` is the
executable form of this promise: every write applies exactly once and
no raised error mentions a locked database.

== Types cross the boundary intact

The extension binds and returns SQLite's five storage classes without
a text or JSON detour:

#table(
  columns: (auto, auto, 1fr),
  table.header([*Python*], [*SQLite*], [*Rule*]),
  [`None`], [NULL], [Distinct from empty text and empty blob.],
  [`bool`, `int`], [INTEGER],
  [Outside signed 64-bit raises `OverflowError` before execution.],
  [`float`], [REAL], [IEEE-754 binary64, passed bit-exact.],
  [`str`], [TEXT],
  [UTF-8; embedded NUL bytes survive because lengths are explicit.],
  [`bytes`, `bytearray`, `memoryview`], [BLOB],
  [Contiguous buffers are pinned for the duration of the call.],
)

Invalid UTF-8 coming back as TEXT raises `OperationalError` rather
than being silently reclassified. Anything else you pass as a
parameter raises `ProgrammingError`; there is no implicit adapter
registry in the first release.

== Statements are described, never parsed

`Cursor.execute()` accepts exactly one statement. The SDK asks the
native layer to prepare and describe the SQL — parameter count,
result shape, read-only classification, and whether a second statement
trails — so routing decisions come from SQLite's own preparation
metadata, not from a Python regular expression. A trailing statement
raises `ProgrammingError` and points you at `executescript()`, the
explicit multi-statement path. `executemany()` builds one bounded
native transaction batch and commits it atomically: one replicated
transition for the whole batch, `lastrowid` untouched.

== Sessions: exactly-once from Python

The replicated sessions of chapter 8 are first-class:

```python
session = db.open_session()
changes, replayed = db.execute_idempotent(
    session, 1, "insert into item(note) values ('once')"
)
```

Retrying sequence 1 after an ambiguous failure returns the recorded
result with `replayed` set instead of inserting twice. `snapshot()`,
`backup(path)`, `integrity_check()`, and `expire_sessions(retain)`
round out the maintenance surface with the same semantics as their C
counterparts.

== Search

#api_anchor(
  [`Connection.search`],
  [Typed lexical, vector, or hybrid search through the validated
  native planner (chapter 15's hybrid example, as an API).],
  source: [`dbapi.py`],
)

```python
cursor = db.search(fts_table="docs", text="paxos", k=5)
for item_id, score in cursor:
    print(item_id, score)
```

The Python layer forwards the request; identifier validation, the
candidate cap of 4096, fusion weights, and embedding shape are all
enforced by the Zig planner, never rebuilt with string interpolation.
Embeddings are raw little-endian float32 bytes — NumPy callers pass
`numpy.asarray(v, dtype="<f4").tobytes()`; the base package depends on
nothing outside the standard library. Raw FTS5 and vec0 SQL through
ordinary `execute()` remains fully supported, and is currently the
search path for remote connections.

== Hosting a backend from Python

#api_anchor(
  [`zxlite.start_server` / `Server` / `Member`],
  [Start a transport-owning cluster member on a background native
  thread and manage its lifetime.],
  source: [`server.py`],
)

Connection ownership and server ownership stay separate: `connect()`
never starts a listener, and `start_server()` never hands you SQL.

```python
from zxlite import Member, start_server
import zxlite

with start_server(
    directory="/tmp/example-node",
    node_id=1,
    members=[Member(1, "unix:/tmp/example.sock")],
) as server:
    with zxlite.connect(server.endpoint) as db:
        db.execute("create table item(id integer primary key)")
```

A single member with a `unix:` address serves one local node over an
owner-only socket (mode 600), exactly as `zaxon serve --listen unix:`
does in chapter 14: the filesystem is the authorization boundary, a
pre-existing socket path is refused rather than deleted, and the path
is removed on orderly shutdown. Windows refuses the mode until an
equivalent owner-only DACL exists.

For a development cluster, three fresh Python processes each call
`start_server(..., allow_psk_only_loopback=True)` with the same three
`Member` records, cluster ID, and a 0600 PSK provider file of at least
32 bytes; every endpoint must be numeric loopback (`127.0.0.1` or
`::1`). The SDK validates the registry shape before native startup —
unique non-zero IDs, one to 36 members, identical lists per process —
while zaxonlite stays authoritative for roles, quorum, identity
derivation, and transport policy.

#callout(title: [Not a process supervisor], tone: "warning")[
  The SDK does not allocate ports, spawn children, remove stale socket
  paths, or mint certificates, and handles must not be carried across
  `fork()` — test harnesses use `subprocess` or the `spawn` start
  method. Development PSK gives authentication and frame integrity but
  no confidentiality and no per-node identity; it is never a
  production transport, and privileged membership operations remain
  unreachable over it (chapter 7).
]

== Remote connections

A remote target is a multi-seed DSN, and the same `connect()` opens
it:

```python
db = zxlite.connect(
    "zxlite://db1.example:9901,db2.example:9901,db3.example:9901/"
    "?read_level=linearizable&pool_size=8",
    tls_ca="/run/secrets/cluster-ca.pem",
    tls_cert="/run/secrets/client.pem",
    tls_key="/run/secrets/client-key.pem",
)
```

One logical connection owns a bounded pool (1 to 64 slots, default
`min(32, max(4, 2 * seeds))`) of independent native client
connections. The first authenticated seed pins the database identity;
every later slot must report the same identity before it serves your
SQL, and a server that does not speak the typed value format is
refused outright, so remote cells keep their storage classes just like
local ones. `read_level` defaults to `linearizable` and is never
downgraded by retry or load balancing; only explicit `level="any"`
reads distribute across read-serving members, with `freshness_ms`
available to bound staleness.

#predict([
  You raise `pool_size` from 8 to 32 on a write-heavy workload. What
  happens to write throughput?
])

Nothing. Writes travel one serialized lane that owns a replicated
session and numbers every write; the pool scales reads only, and the
server admits one replicated write at a time regardless of how many
sockets you open. What the lane buys is exactly-once retry: after an
ambiguous failure the same session and sequence are resent, and if the
deadline passes the connection enters a pending state that refuses new
writes until `resolve_pending()` reaches a definitive outcome. Remote
connections are autocommit-only — requesting a transaction raises
`NotSupportedError` before any SQL leaves the process — and remote
`RETURNING` is refused until its result can be retained for replay.

== Live transactions

On a local, single-member directory, Gate C applies:

```python
db = zxlite.connect(
    "/var/lib/example", isolation_level="DEFERRED", autocommit=False
)
with db:
    db.execute("insert into item(note) values ('draft')")
    row = db.execute("select count(*) from item").fetchone()
```

The first write opens a real SQLite transaction on the writer
connection, so later reads on the same connection observe uncommitted
writes, `RETURNING` and `lastrowid` work before commit, and
`rollback()` publishes nothing. `commit()` captures the whole
transaction as one WAL transition and acknowledges only after the
decided slot is applied — the same durability meaning as autocommit,
held open across your calls. While the transaction is open, one-shot
writes, snapshots, and membership operations on that node are refused;
closing a connection with an open transaction rolls it back. A
multi-member handle refuses the mode: a leader can change while Python
thinks, and this SDK does not pretend otherwise.

== SQLAlchemy

The dialect registers as `zxlite` through the standard entry point:

```python
from sqlalchemy import create_engine

local = create_engine("zxlite:////var/lib/example")
remote = create_engine(
    "zxlite:///?seed=db1.example%3A9901&seed=db2.example%3A9901",
    connect_args={"tls_ca": "...", "tls_cert": "...", "tls_key": "..."},
    isolation_level="AUTOCOMMIT",
)
```

Local engines default to `NullPool` — one checked-out connection owns
the directory lock — and run Gate C transactions, so ORM unit-of-work
commit, rollback, and nested savepoint transactions behave as
SQLAlchemy expects. Remote engines default to `StaticPool` (the native
pool already exists; a second pool would only multiply sockets) and
require `AUTOCOMMIT`. SQL compilation, reflection, and type handling
reuse SQLAlchemy's SQLite dialect; install with the extra
`zxlite[sqlalchemy]` against the maintained 2.x lines.

== What zxlite does not do

The compatibility promise is stated feature by feature, never as a
percentage. The load-bearing exclusions:

#table(
  columns: (auto, 1fr),
  table.header([*Facility*], [*Status and reason*]),
  [`create_function`, aggregates, collations, `set_authorizer`],
  [Unsupported: zaxonlite owns the authorizer, and Python callbacks
  would need lifetime and replication rules on every internal
  connection.],
  [`ATTACH`, `load_extension`, `serialize`, `blobopen`],
  [Unsupported: they reach around the replicated image (chapter 5).],
  [`backup` to another connection],
  [Replaced by `Connection.backup(path)`, the consistent logical
  backup.],
  [Remote `executescript()`, remote typed `search()`],
  [`NotSupportedError` today; the wire carries one statement per
  write, and the typed search RPC is local-only so far.],
  [`text_factory`, adapters, converters, `asyncio`],
  [Deferred; the first contract is the five native types,
  synchronously.],
)

Everything else follows chapter 11's discipline: inputs are borrowed
for the call, results are owned copies, and one connection is one
native handle used by one call at a time.

#exercise(
  [12.1],
  [Start two threads that both run 100 single-row inserts through one
  shared local connection (`check_same_thread=False`). Predict the
  final row count and whether any call raises. Then set
  `timeout=0.001` and hold the write lane from a third thread — which
  exception category appears, and why is an immediate retry safe?],
  hint: [Re-read "Writes queue; they do not fail": the timeout bounds
  admission, and a write refused at admission provably never
  executed.],
)

#teach_back([
  Explain to a Flask developer why `zxlite` never raises "database is
  locked" for two of their own request handlers writing at once, what
  `timeout` bounds instead, and why raising `pool_size` will not make
  their write endpoint faster. Use the words write lane, arrival
  order, and one replicated write at a time.
])
