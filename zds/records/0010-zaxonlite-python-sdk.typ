#let zds-number = "0010"
#let zds-title = "zxlite: A Native Python SDK for zaxonlite"
#let zds-state = "discussion"
#let zds-created = "2026-07-29"
#let zds-discussion = "CPython Stable ABI, Python DB-API, PyPI wheels, and SQLAlchemy compatibility"
#let zds-labels = ("zaxonlite", "zxlite", "python", "db-api", "sqlalchemy", "pypi", "sdk",)
#let zds-authors = ("paxos-zig project",)
#let zds-category = "Engineering Discussion"
#let zds-status = "Open for Discussion"
#let zds-last-updated = "2026-07-29"

#import "../../shared/zds.typ": zds-document
#import "@preview/fletcher:0.5.8" as fletcher: diagram, edge, node

#let ink = rgb("334155")
#let blue = (fill: rgb("dbeafe"), stroke: rgb("2563eb"))
#let green = (fill: rgb("dcfce7"), stroke: rgb("16a34a"))
#let amber = (fill: rgb("fef3c7"), stroke: rgb("d97706"))
#let violet = (fill: rgb("ede9fe"), stroke: rgb("7c3aed"))
#let slate = (fill: rgb("f1f5f9"), stroke: rgb("64748b"))
#let red = (fill: rgb("fee2e2"), stroke: rgb("dc2626"))

#let flow-node(pos, title, detail, palette, width: auto) = node(
  pos,
  align(center)[
    #text(9pt, weight: "bold", fill: palette.stroke.darken(20%))[#title]
    #linebreak()
    #text(7.2pt, fill: ink)[#detail]
  ],
  fill: palette.fill,
  stroke: 0.9pt + palette.stroke,
  shape: fletcher.shapes.rect,
  corner-radius: 5pt,
  inset: 7pt,
  width: width,
)

#let actor-node(pos, title, palette) = node(
  pos,
  align(center)[#text(8pt, weight: "bold", fill: palette.stroke.darken(20%))[#title]],
  fill: palette.fill,
  stroke: 0.9pt + palette.stroke,
  shape: fletcher.shapes.rect,
  corner-radius: 4pt,
  inset: 6pt,
  width: 25mm,
)

#let edge-label(body) = text(6.8pt, fill: ink)[#body]

#let zds-figure(body) = context {
  if target() == "html" {
    html.frame(align(center, body))
  } else {
    align(center, body)
  }
}

#show: doc => zds-document(
  zds-number,
  zds-title,
  doc,
  authors: zds-authors,
  state: zds-state,
  created: zds-created,
  discussion: zds-discussion,
  labels: zds-labels,
  category: zds-category,
  status: zds-status,
  last-updated: zds-last-updated,
)

= Abstract

zaxonlite exposes a small C ABI, but Python applications cannot install or
use it as a normal Python database driver. The current query ABI serializes
every non-null cell as text, write results omit generated row IDs, and the
explicit transaction builder does not behave like a live SQLite transaction.
Wrapping that surface with `ctypes` would produce a Python-shaped interface,
but it would not produce faithful Python DB-API or SQLAlchemy behavior.

This record proposes a Python language SDK under `languages/python`, a PyPI
distribution and import namespace named `zxlite`, and a native `_zxlite`
extension linked statically to Zig-built zaxonlite. The extension targets
CPython 3.12's Limited API and Stable ABI, so one `cp312-abi3` wheel per
operating-system and architecture pair can serve supported later CPython
releases.

Delivery has two compatibility gates. The first release provides a useful,
typed, sqlite-shaped DB-API subset in replicated autocommit mode. The second
adds a local embedded transaction surface with rollback, read-your-writes,
savepoints, `lastrowid`, and `RETURNING`, then publishes a dedicated
SQLAlchemy dialect. The project does not claim that API resemblance alone
makes arbitrary `sqlite3` applications portable.

= Introduction

Python's standard `sqlite3` module is a DB-API 2.0 driver with a broad
behavioral contract. Programs rely not only on `connect()` and `execute()`,
but also on transaction timing, cursor metadata, native value types,
generated keys, exception classes, row factories, savepoints, and cleanup.
SQLAlchemy relies on an overlapping but distinct set of driver hooks for
reflection, pooling, isolation, generated identifiers, and nested
transactions.

zaxonlite deliberately differs from a direct SQLite connection. Application
writes execute inside a zaxonlite-owned outer transaction. On commit,
zaxonlite captures SQLite WAL pages and replicates those page images through
Paxos. Public SQL may not end that outer transaction, change capture-critical
pragmas, attach another database, or access the reserved `__zaxon_`
namespace.

The existing C ABI reflects those rules:

- `zaxonlite_exec_prepared` commits one prepared write as one replicated
  transaction and returns only its change count;
- `zaxonlite_query_prepared_json` executes a read-only statement and returns
  a materialized JSON object;
- the JSON query path converts every non-null SQLite value to text;
- `zaxonlite_transaction_*` accumulates copied statements and executes them
  only at commit;
- one native handle is single-threaded unless its caller provides a lock.

These are sound embedding primitives. They are not yet sufficient to
implement the standard-library cursor contract or SQLAlchemy's unit-of-work
behavior. The Python SDK therefore starts at the native boundary rather than
papering over missing semantics in Python.

= Terminology and Scope

- *distribution*: the installable PyPI project, named `zxlite`
- *import package*: the Python package imported with `import zxlite`
- *native extension*: the private `_zxlite` CPython extension module
- *DB-API*: PEP 249's Python Database API 2.0 contract
- *sqlite-shaped*: names and ordinary usage resemble Python's `sqlite3`
  module without claiming complete substitutability
- *Limited API*: the subset of the CPython C API selected with
  `Py_LIMITED_API`
- *Stable ABI*: the cross-minor CPython binary ABI used by `abi3` wheels
- *local embedded connection*: one in-process zaxonlite node owning one data
  directory
- *autocommit operation*: one statement or explicit batch that becomes one
  complete replicated zaxonlite transaction before returning
- *live transaction*: a connection-scoped SQLite transaction in which later
  calls observe earlier uncommitted writes
- *DB-API transaction mode*: live transaction behavior exposed through
  `commit()`, `rollback()`, context managers, and savepoints
- *cluster client*: a network or transport-owning handle that may redirect
  operations to a leader
- *materialized cursor*: a cursor whose complete result is copied into
  extension-owned or Python-owned memory before `execute()` returns

This record covers the local embedded driver, additive C ABI work, Python
interfaces, packaging, binary wheels, SQLAlchemy integration, and release
verification. It does not define a general Python cluster protocol, an async
driver, arbitrary Python SQLite callbacks, or substitution of the
standard-library `sqlite3` module.

= Problem Statement

Five gaps must be closed before zaxonlite can be a credible Python database
package.

First, the C query ABI destroys SQLite type information. Python's default
mapping is `NULL` to `None`, INTEGER to `int`, REAL to `float`, TEXT to `str`,
and BLOB to `bytes`. JSON strings cannot distinguish integer `1`, text
`"1"`, or the byte sequence containing `1`.

Second, write results do not expose `sqlite3_last_insert_rowid`, result-column
metadata, or rows from `RETURNING`. ORMs commonly need a generated primary
key immediately after an insert.

Third, the existing transaction builder is intentionally deferred. It copies
statements without touching SQLite until commit. A query between two queued
writes cannot observe those writes; a failed transaction cannot provide
statement-local result rows; and a caller cannot use savepoints. Relabeling
that builder as a DB-API transaction would be incorrect.

Fourth, the build installs only a static C library and header. PyPI needs
self-contained, platform-tagged wheels, reproducible native builds, binary
dependency inspection, and tests run against the installed wheel.

Fifth, SQLAlchemy does not support a new driver merely because that driver
has methods named like `sqlite3`. Its SQLite dialect has pysqlite-specific
connection behavior. zaxonlite needs its own dialect and acceptance suite.

= Goals and Non-Goals

== Goals

- Create an independent Python SDK project at `languages/python`.
- Support CPython 3.12 and later through the CPython Stable ABI.
- Ship self-contained wheels that need neither Zig nor a system zaxonlite
  installation at runtime.
- Preserve all five SQLite storage classes across the native boundary.
- Expose ZDS 0009's validated lexical, vector, and hybrid search operation as
  a first-class `zxlite` API.
- Provide PEP 249 module globals, exceptions, connections, cursors, and fetch
  behavior for the supported surface.
- Keep zaxonlite replication and WAL-capture invariants authoritative.
- Release the GIL around blocking native operations.
- Enforce one-call-at-a-time access to a native handle.
- Make autocommit semantics explicit in the first release.
- Add genuine rollback and read-your-writes before enabling DB-API transaction
  mode.
- Provide a dedicated SQLAlchemy URL and dialect only after its behavioral
  release gates pass.
- Test installed wheels on every supported operating system and CPython
  minor.
- Keep the public Python layer type-annotated and documented.
- Preserve the existing C ABI by making all native changes additive.

== Non-Goals

- No top-level module that shadows or replaces Python's `sqlite3`.
- No claim that every SQLite database file is a zaxonlite data directory.
- No direct access to zaxonlite's `current.db`.
- No `ATTACH`, runtime extension loading, or capture-changing pragmas.
- No arbitrary Python `create_function`, `create_aggregate`, or
  `create_window_function` in the first two releases.
- No Python callback executed from a Zig or SQLite worker thread.
- No faithful distributed transaction spanning separate Python calls across
  leader changes.
- No asyncio API in the first release.
- No embedding model, NumPy dependency, media decoder, or model inference in
  the Python package.
- No PyPy, GraalPy, 32-bit, musllinux, mobile, or WebAssembly wheel initially.
- No source-distribution promise until the monorepo source-staging design is
  reproducible and tested.

= Invariants

1. A successful acknowledged write remains a committed zaxonlite operation,
   not merely a successful call to SQLite.
2. Python never obtains or modifies the materialized SQLite file directly.
3. The native layer preserves NULL, integer, real, text, and blob values
   without routing them through JSON.
4. Every owned native result, connection, transaction, and buffer has one
   explicit release path.
5. The Python extension does not expose a pointer whose lifetime can outlive
   its native owner.
6. One connection serializes native calls even when the GIL is released.
7. `check_same_thread=True` is the default; disabling it removes the
   creator-thread check but not the per-connection lock.
8. The first release never pretends that a no-op `rollback()` can undo an
   already replicated write.
9. A live transaction is enabled only for a local embedded, single-member
   handle whose ownership and failure semantics are defined by this record.
10. Cluster handles remain autocommit-only until a separate design defines
    leases, leader loss, abandoned transactions, and retry identity.
11. The extension is compiled against `Py_LIMITED_API=0x030C0000` and may use
    only symbols documented in the CPython 3.12 Limited API.
12. The wheel contains the exact zaxonlite, paxos, SQLite, and sqlite-vec
    versions named by its build provenance.
13. The import package and native library versions agree at import time or
    import fails.
14. SQLAlchemy compatibility is a tested dialect contract, never an inference
    from DB-API method names.
15. Python's typed search API delegates validation and SQL-plan construction
    to zaxonlite's ZDS 0009 implementation; it never reconstructs the
    canonical hybrid SQL with Python string interpolation.

= Design Overview

== Package architecture

#figure(
  zds-figure(
    diagram(
      spacing: (13mm, 10mm),
      node-outset: 2pt,
      edge-stroke: 0.8pt + rgb("64748b"),
      flow-node(
        (0, 0),
        [Application],
        [`zxlite.connect` #linebreak() cursor / rows],
        blue,
        width: 29mm,
      ),
      flow-node(
        (1, -0.7),
        [DB-API layer],
        [policy + exceptions #linebreak() row factories],
        green,
        width: 29mm,
      ),
      flow-node(
        (1, 0.7),
        [SQLAlchemy dialect],
        [URL + reflection #linebreak() transaction hooks],
        violet,
        width: 29mm,
      ),
      flow-node(
        (2, 0),
        [`_zxlite`],
        [CPython 3.12 ABI3 #linebreak() GIL boundary],
        amber,
        width: 30mm,
      ),
      flow-node(
        (3, 0),
        [C ABI],
        [opaque handles #linebreak() typed results],
        slate,
        width: 29mm,
      ),
      flow-node(
        (4, 0),
        [Zig node],
        [SQLite + WAL capture #linebreak() Paxos commit],
        blue,
        width: 30mm,
      ),
      edge((0, 0), (1, -0.7), "-|>", bend: 14deg),
      edge((0, 0), (1, 0.7), "-|>", bend: -14deg),
      edge((1, -0.7), (2, 0), "-|>", bend: -14deg),
      edge((1, 0.7), (2, 0), "-|>", bend: 14deg),
      edge((2, 0), (3, 0), "-|>"),
      edge((3, 0), (4, 0), "-|>"),
    ),
  ),
  caption: [The public Python layers contain policy. The private extension is
  a narrow ownership, conversion, locking, and GIL boundary over the C ABI.],
)

The distribution uses a `src` layout:

```text
languages/python/
  pyproject.toml
  README.md
  LICENSE
  src/
    zxlite/
      __init__.py
      dbapi.py
      rows.py
      sqlalchemy.py
      py.typed
    native/
      module.c
      connection.c
      result.c
      conversion.c
  tests/
    dbapi/
    sqlalchemy/
    packaging/
  examples/
```

`zxlite.__init__` re-exports the stable DB-API surface. `_zxlite` stays
private and may change between SDK releases. `zxlite.sqlalchemy` imports
SQLAlchemy only when the optional dialect is used; the base driver has no
runtime dependency outside the Python standard library and its bundled
native extension.

== Two compatibility gates

#table(
  columns: (1.05fr, 1.55fr, 2.2fr),
  stroke: 0.5pt + rgb("d7dee8"),
  inset: 5pt,
  table.header([*Gate*], [*User promise*], [*Required native behavior*]),
  [Gate A: typed autocommit],
  [A useful sqlite-shaped DB-API subset for one-operation replicated writes
  and materialized reads.],
  [Typed result handles, prepared positional parameters, changes, generated
  row ID, reliable exception mapping, and explicit autocommit-only policy.],
  [Gate B: local transactions],
  [Rollback, read-your-writes, savepoints, generated keys, `RETURNING`, and
  supported SQLAlchemy Core/ORM operation.],
  [Connection-scoped local transaction, writer-connection reads, result rows
  before commit, safe WAL capture at commit, rollback without replication,
  and host-managed savepoints.],
)

Gate A is independently useful for scripts, services that already use
one-statement transactions, migrations expressed as one atomic batch, and
direct zaxonlite maintenance. It includes typed search because search uses
the existing bounded read path and does not require a live transaction. Gate
A is not marketed as general SQLAlchemy support.

Gate B is intentionally local. It extends the embedded node so Python can
hold a live transaction between calls without inventing distributed
transaction semantics. A future cluster DB-API design requires its own ZDS.

= Detailed Design

== Additive typed C result ABI

The existing JSON query API remains supported. New functions return opaque
materialized result handles:

```c
typedef void zaxonlite_result;

typedef struct zaxonlite_exec_result {
    int64_t changes;
    int64_t last_insert_rowid;
    bool has_last_insert_rowid;
    bool replayed;
} zaxonlite_exec_result;

int zaxonlite_query_prepared_result(
    zaxonlite *handle,
    const char *sql,
    const zaxonlite_value *values,
    size_t value_count,
    zaxonlite_result **out_result);

int zaxonlite_exec_prepared_result(
    zaxonlite *handle,
    const char *sql,
    const zaxonlite_value *values,
    size_t value_count,
    zaxonlite_exec_result *out_result,
    zaxonlite_result **out_returning);

size_t zaxonlite_result_column_count(const zaxonlite_result *result);
size_t zaxonlite_result_row_count(const zaxonlite_result *result);
const char *zaxonlite_result_column_name(
    const zaxonlite_result *result,
    size_t column);
int zaxonlite_result_value(
    const zaxonlite_result *result,
    size_t row,
    size_t column,
    zaxonlite_value *out_value);
void zaxonlite_result_close(zaxonlite_result *result);
```

The exact C spelling may follow repository naming conventions, but the
contract is fixed:

- a result owns copied column names and cell bytes;
- `zaxonlite_result_value` borrows text/blob bytes until result close;
- integer and real values preserve SQLite's runtime storage class;
- a zero-length text or blob is distinct from NULL;
- all count and index operations are bounds-checked;
- fallible functions clear output values before work;
- result close accepts null;
- `last_insert_rowid` is present only for a successful INSERT or REPLACE
  whose SQLite statement semantics update it;
- a DML statement with `RETURNING` returns typed rows and completes before
  the write is acknowledged.

The internal Zig `QueryResult` changes from nullable byte strings to a tagged
value union. JSON encoding remains a presentation adapter over that typed
form. Existing JSON consumers continue to receive strings and null unless a
separate format-version decision changes their contract.

== Native CPython extension

The C extension uses multi-phase module initialization and heap types created
through Limited-API type specifications. It does not read CPython object
layouts or use private `_Py` symbols.

The private extension owns four kinds of objects:

- a native connection wrapping a zaxonlite handle, creator thread ID, state,
  and mutex;
- a native result wrapping one `zaxonlite_result`;
- a native transaction for Gate B;
- module state containing exception and type references.

Each potentially blocking open, close, execute, query, snapshot, backup,
integrity, transaction commit, and transaction rollback call follows this
sequence:

1. validate and convert Python arguments while holding the GIL;
2. acquire the connection mutex while holding a strong reference to the
   owner;
3. release the GIL;
4. call the C ABI;
5. reacquire the GIL;
6. release the mutex;
7. convert the result or raise the mapped Python exception.

The close path marks the connection closing before releasing the GIL.
Concurrent new operations then fail with `ProgrammingError`. Finalization
never calls into a handle already detached by explicit `close()`.

Python-to-SQLite binding is:

#table(
  columns: (1.1fr, 1.15fr, 2.1fr),
  stroke: 0.5pt + rgb("d7dee8"),
  inset: 5pt,
  table.header([*Python input*], [*SQLite value*], [*Rule*]),
  [`None`],
  [NULL],
  [No bytes pointer and zero length.],
  [`bool`, `int`],
  [INTEGER],
  [Reject values outside signed 64-bit range with `OverflowError`.],
  [`float`],
  [REAL],
  [Pass IEEE-754 binary64; SQLite decides subsequent SQL behavior.],
  [`str`],
  [TEXT],
  [Encode UTF-8 once; embedded NUL is preserved by explicit length.],
  [`bytes`, `bytearray`, contiguous `memoryview`],
  [BLOB],
  [Borrow a pinned contiguous buffer for the duration of the call.],
  [other],
  [none],
  [Raise `ProgrammingError` until an explicit adapter API is added.],
)

SQLite-to-Python conversion creates `None`, arbitrary-precision Python
integers from signed 64-bit values, Python floats, UTF-8 strings, and bytes.
Invalid UTF-8 returned as SQLite TEXT raises `OperationalError`; it is not
silently reclassified as BLOB. A later `text_factory` extension may offer
different policy.

== Public DB-API module

The base module exports:

```python
apilevel = "2.0"
threadsafety = 1
paramstyle = "qmark"

def connect(
    database,
    *,
    timeout=5.0,
    isolation_level=None,
    check_same_thread=True,
    autocommit=True,
): ...
```

`database` is a path-like zaxonlite data directory, not an SQLite filename.
Gate A accepts only `isolation_level=None` and `autocommit=True`. Any other
combination raises `NotSupportedError` at connect time. Gate B adds
`isolation_level="DEFERRED"` as the default compatibility mode while
retaining explicit autocommit.

The exception hierarchy is:

```text
Exception
  Warning
  Error
    InterfaceError
    DatabaseError
      DataError
      OperationalError
      IntegrityError
      InternalError
      ProgrammingError
      NotSupportedError
```

Native return codes provide the first classification:

#table(
  columns: (0.65fr, 1.35fr, 2.25fr),
  stroke: 0.5pt + rgb("d7dee8"),
  inset: 5pt,
  table.header([*Code*], [*Python exception*], [*Examples*]),
  [`1`],
  [`DatabaseError` subclass],
  [SQLite constraint maps to `IntegrityError`; syntax, parameter, and
  statement errors map to `ProgrammingError`; busy and interrupt map to
  `OperationalError`.],
  [`2`],
  [`ProgrammingError`],
  [Closed object, bad argument, write on read path, unsupported transaction
  control, or parameter mismatch.],
  [`3`],
  [`DatabaseError`],
  [Integrity verification failed; maintenance API may expose a structured
  report later.],
  [`4`],
  [`OperationalError`],
  [Locked directory, storage failure, corrupt state, or unavailable node.],
)

The native ABI must expose stable extended error categories rather than
requiring Python to parse human-readable error strings. The existing integer
codes remain; an additive error-category accessor supplies SQL constraint,
busy, interrupt, misuse, storage, integrity, and availability classification.

`Connection` provides:

- `cursor(factory=Cursor)`;
- shortcut `execute`, `executemany`, and `executescript`;
- `commit`, `rollback`, `close`, and context-manager methods;
- `row_factory`, `total_changes`, and `in_transaction`;
- zaxonlite-specific `snapshot`, `backup`, `integrity_check`,
  `open_session`, `execute_idempotent`, `expire_sessions`, and `search`;
- read-only `zaxonlite_version` and `sqlite_version`.

`Cursor` provides:

- `execute(sql, parameters=())`;
- `executemany(sql, iterable_of_parameters)`;
- `executescript(sql_script)`;
- `fetchone`, `fetchmany`, `fetchall`, and iteration;
- `close`, `setinputsizes`, and `setoutputsize`;
- `description`, `rowcount`, `lastrowid`, `arraysize`, `connection`, and
  `row_factory`.

`description` is one seven-tuple per result column with the name followed by
six `None` values. Cursors are materialized in both gates: native execution
finishes before `execute()` returns, and fetch methods traverse copied rows.
This makes ownership simple and matches the current node query architecture.
Query row, byte, and VM-step budgets must be configurable before untrusted
network inputs are routed through the local SDK.

Gate A supports positional qmark parameters. `execute()` rejects more than
one SQL statement; `executescript()` is the explicit multi-statement path.
The implementation uses SQLite preparation metadata to detect a trailing
statement rather than parsing SQL in Python.

Gate B adds named dict binding. The C ABI exposes each prepared parameter's
SQLite name and index so `:name`, `@name`, and `$name` are resolved by SQLite
itself. Python never rewrites SQL with a regular expression.

== Typed search API

Raw search SQL works through ordinary `execute()` from Gate A onward. The
bundled SQLite build registers FTS5, sqlite-vec, `rrf`, `dbsf`,
`stddev_samp`, and `zaxon_vec_distance_cosine` on every connection. Python
TEXT and BLOB parameters preserve the query text and embedding bytes, and the
typed result ABI preserves item IDs, scores, and metadata values.

Raw SQL alone is not sufficient for the enforced search contract from
`ZDS 0009`. In particular, a host cannot reliably inspect the vec0 `k`
constraint inside arbitrary SQL. The native Python package therefore also
exposes the existing typed `Node.search` path through an additive C request:

```c
typedef enum zaxonlite_search_fusion {
    ZAXONLITE_SEARCH_RRF = 0,
    ZAXONLITE_SEARCH_DBSF = 1
} zaxonlite_search_fusion;

typedef struct zaxonlite_search_options {
    const char *fts_table;
    const char *vec_table;
    const void *text;
    size_t text_length;
    const void *embedding;
    size_t embedding_length;
    uint32_t k;
    uint32_t candidate_count;
    bool has_candidate_count;
    zaxonlite_search_fusion fusion;
    double text_weight;
    double vector_weight;
    const char *metadata_table;
    const char *metadata_id_column;
    const char *const *metadata_columns;
    size_t metadata_column_count;
} zaxonlite_search_options;

int zaxonlite_search(
    zaxonlite *handle,
    const zaxonlite_search_options *options,
    zaxonlite_result **out_result);
```

Optional strings use null pointers. Text uses a pointer and explicit length
so an FTS query is not constrained by C-string termination. Embeddings are
raw little-endian float32 bytes. All pointer/count pairs follow the C ABI's
existing safe-empty-output and early-validation rules.

The C adapter borrows request memory for the call, converts the request to
`search_api.Request`, and calls `Node.search`. The Zig implementation remains
the single authority for:

- table and column identifier validation;
- rejection of `__zaxon_` and `sqlite_` namespaces;
- lexical-only, vector-only, and hybrid branch selection;
- `k` and `candidate_count` validation in `1..=4096`;
- the default `min(max(8k, 64), 4096)` candidate rule;
- nonnegative finite fusion weights;
- nonempty little-endian float32 embeddings whose dimension is divisible by
  eight;
- RRF or DBSF canonical SQL planning;
- a maximum of 16 selected metadata columns;
- omission of implicit embedding BLOBs from results.

The public Python method is:

```python
cursor = connection.search(
    *,
    fts_table=None,
    vec_table=None,
    text=None,
    embedding=None,
    k=10,
    candidate_count=None,
    fusion="rrf",
    text_weight=1.0,
    vector_weight=1.0,
    metadata_table=None,
    metadata_id_column=None,
    metadata_columns=(),
)
```

It returns a normal materialized `Cursor`, so `description`, row factories,
iteration, and all fetch methods behave exactly as for `execute()`.
Lexical-only search requires `fts_table` and `text`. Vector-only search
requires `vec_table` and `embedding`. Hybrid search supplies both branches.

`embedding` accepts `bytes`, `bytearray`, or a contiguous `memoryview`.
Bytes-like input is interpreted as raw little-endian float32. The base
package does not depend on NumPy; NumPy callers pass
`numpy.asarray(vector, dtype="<f4").tobytes()`. A typed memoryview with native
float format is accepted only on little-endian hosts and is borrowed for the
duration of the native call. Big-endian hosts fail closed, matching ZDS
0009's first vector-format contract.

Invalid Python option types raise `ProgrammingError`. Validly typed requests
rejected by zaxonlite's search validator map to `ProgrammingError` with a
stable native search error category. SQLite execution failures map through
the normal database exception hierarchy.

SQLAlchemy applications have two supported paths:

- compose the documented search SQL with SQLAlchemy `text()` and bound
  parameters when the query must participate in a larger SQL expression;
- obtain the dialect's DB-API driver connection and call its typed
  `search()` method when the enforced candidate cap and canonical planner are
  required.

The first SQLAlchemy release does not invent a custom ORM query language.
A future SQLAlchemy executable search construct may be added only if it can
retain native validation rather than duplicating the ZDS 0009 planner.

== Gate A autocommit behavior

Every write `execute()` invokes one complete zaxonlite write transaction.
Every `executemany()` builds one bounded native transaction batch and commits
the batch atomically. `executescript()` uses the native SQL-batch write path
and inherits its size and statement limits.

`Connection.commit()` is a no-op only because the connection was explicitly
opened with `autocommit=True`. `Connection.rollback()` is also a no-op in
that mode, matching the fact that no transaction is open. The SDK never
accepts a non-autocommit configuration and then silently performs these
no-ops.

`Cursor.rowcount` is the change count for completed DML and `-1` for reads or
statements whose category is not known to the driver. `lastrowid` changes
only after a qualifying successful `execute()`; `executemany()` and
`executescript()` leave it unchanged. A read cursor has `description` even
when it has zero rows.

SQL text containing application `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`,
or `RELEASE` continues to be rejected by the zaxonlite guard. Transaction
control is a connection operation, never an escape hatch around WAL capture.

== Gate B local live transactions

Gate B introduces a native local-transaction handle. It is restricted to a
single embedded node because that node cannot lose leadership to another
voter while a Python caller holds a transaction.

#figure(
  zds-figure(
    diagram(
      spacing: (11mm, 9mm),
      node-outset: 2pt,
      edge-stroke: 0.8pt + rgb("64748b"),
      actor-node((0, 0), [Python], blue),
      actor-node((1, 0), [DB-API], green),
      actor-node((2, 0), [Node writer], amber),
      actor-node((3, 0), [WAL capture], violet),
      actor-node((4, 0), [Paxos], slate),
      edge((0, 0.4), (0, 7.2), "--"),
      edge((1, 0.4), (1, 7.2), "--"),
      edge((2, 0.4), (2, 7.2), "--"),
      edge((3, 0.4), (3, 7.2), "--"),
      edge((4, 0.4), (4, 7.2), "--"),
      edge((0, 1), (1, 1), edge-label[first write], "-|>"),
      edge((1, 1.8), (2, 1.8), edge-label[begin immediate], "-|>"),
      edge((0, 2.7), (1, 2.7), edge-label[insert + RETURNING], "-|>"),
      edge((1, 3.4), (2, 3.4), edge-label[execute on writer], "-|>"),
      edge((2, 4.1), (0, 4.1), edge-label[typed row + lastrowid], "-|>"),
      edge((0, 4.9), (1, 4.9), edge-label[select], "-|>"),
      edge((1, 5.5), (2, 5.5), edge-label[read uncommitted writes], "-|>"),
      edge((0, 6.3), (1, 6.3), edge-label[commit], "-|>"),
      edge((1, 6.8), (3, 6.8), edge-label[capture committed frames], "-|>"),
      edge((3, 7.2), (4, 7.2), edge-label[durable decision], "-|>"),
    ),
  ),
  caption: [A local live transaction returns statement results immediately,
  but acknowledges commit only after the captured transition is decided.],
)

The native implementation refactors the current write path into these states:

```text
idle -> sqlite-open -> executing -> committing -> idle
                       |    |
                       |    +-> rolling-back -> idle
                       +-> failed -> rolling-back -> idle
```

On first transactional write, the node:

1. verifies the single-member capability and epoch capacity;
2. opens or reuses the guarded writer connection;
3. verifies no other captured write is in flight;
4. records the current WAL frame and total-change baselines;
5. executes `BEGIN IMMEDIATE` in internal guard scope;
6. returns a transaction handle bound to the node and connection.

Application statements execute under application guard scope. Read statements
prepare and step on the same writer connection so they observe uncommitted
writes. Their rows are copied before returning. Write statements may return
rows. The host records changes and last row ID after each completed statement.

Savepoints are host operations. SQLAlchemy dialect hooks and DB-API transaction
control call native savepoint functions that execute the necessary SQL under
internal scope after validating an SDK-generated name. Arbitrary application
transaction-control SQL remains denied.

Commit:

1. performs the batch marker and internal metadata work;
2. commits SQLite;
3. verifies the WAL hook and capture contract;
4. reads the frames since the recorded baseline;
5. builds one bounded payload and appends its descriptor through Paxos;
6. acknowledges only when the local single-member slot is committed and
   applied;
7. marks the node for resync if SQLite committed but durable logging failed.

Rollback executes SQLite rollback, discards the frame baseline, clears
transaction state, and publishes no payload. Closing a connection with an
open transaction attempts rollback. A rollback failure makes the handle
unavailable and prevents reuse.

While a live transaction exists, no other operation may use that node handle.
The Python mutex serializes calls from the owning connection; native state
also rejects misuse so non-Python embedders cannot violate the rule.

== SQLAlchemy dialect

Gate B registers:

```text
sqlalchemy.dialects
  zxlite = zxlite.sqlalchemy:ZxLiteDialect
```

The connection URL is:

```python
create_engine("zxlite:///absolute/or/relative/data-directory")
```

The dialect reuses SQLAlchemy's SQLite SQL compiler, type compiler, identifier
preparer, and schema reflection queries. It overrides:

- DB-API module loading and connect argument translation;
- database path interpretation;
- begin, commit, rollback, savepoint, rollback-to, and release hooks;
- supported isolation and autocommit values;
- server and SQLite version discovery;
- `RETURNING`, generated-key, and sane-rowcount capability flags;
- connection-pool defaults appropriate to a directory-locked embedded node;
- pysqlite-specific `on_connect` handlers, including automatic Python UDF
  registration.

The default pool is `NullPool`: one checked-out DB-API connection owns the
zaxonlite directory lock, and closing it releases that ownership. A
`QueuePool` is allowed only when configured so the process maintains one
underlying connection per data directory. The dialect detects a second open
as `OperationalError`, not as a separate SQLite connection to the same file.

An optional dependency extra installs the tested SQLAlchemy range:

```text
zxlite[sqlalchemy]
```

Importing the base DB-API package never imports SQLAlchemy. The first dialect
release supports the maintained SQLAlchemy 2.0 and 2.1 lines. SQLAlchemy 1.x
is out of scope.

== Unsupported sqlite3 facilities

#block(breakable: false)[
  #set text(size: 8pt)
  #table(
    columns: (1.5fr, 1.2fr, 2.1fr),
    stroke: 0.5pt + rgb("d7dee8"),
    inset: 5pt,
    table.header([*sqlite3 facility*], [*SDK status*], [*Reason*]),
    [`create_function`, aggregates, collations],
    [unsupported],
    [zaxonlite opens multiple internal SQLite connections; Python callbacks
    would need registration, lifetime, GIL, and replication rules on every
    connection.],
    [`enable_load_extension`, `load_extension`],
    [unsupported],
    [Runtime extensions are compiled out as a product security boundary.],
    [`ATTACH` and `DETACH`],
    [unsupported],
    [Attached database WAL pages are outside the replicated image.],
    [`backup` to another connection],
    [replaced],
    [`Connection.backup(path)` calls zaxonlite's consistent logical backup
    API; it does not accept another DB-API connection.],
    [`serialize`, `deserialize`, `blobopen`],
    [unsupported],
    [They expose or mutate materialized SQLite state outside the replicated
    transaction path.],
    [`set_authorizer`, progress/trace callbacks],
    [unsupported],
    [zaxonlite owns the authorizer and query-budget policy.],
    [`interrupt`],
    [deferred],
    [Needs a safe cross-thread native interrupt handle and lifecycle design.],
    [`text_factory`, adapters, converters],
    [deferred],
    [The first contract uses SQLite's five native types without implicit
    conversion registries.],
  )
]

The package README contains a compatibility matrix organized by API and
behavior, not a blanket percentage. Unsupported methods exist only where the
DB-API requires them; otherwise attribute absence is preferred to a method
that fails late.

== Build and wheel production

`languages/python/pyproject.toml` uses setuptools as its PEP 517 backend with
a focused `build_ext` subclass:

1. locate the monorepo root when building from a checkout;
2. invoke the pinned Zig 0.16.0 build for the static zaxonlite C library with
   `-Doptimize=ReleaseSafe -Dtls=false`;
3. compile the CPython shim with `Py_LIMITED_API=0x030C0000`;
4. link the shim, zaxonlite, pinned SQLite, sqlite-vec, the platform C runtime,
   and required platform system libraries into `_zxlite`;
5. mark the extension `py_limited_api=True`;
6. copy it under `src/zxlite` with the platform's `abi3` extension suffix.

TLS is disabled because this SDK record covers local embedded connections.
It avoids bundling OpenSSL into every wheel and prevents a local driver from
accidentally exposing an unaudited cluster surface. A future cluster SDK may
ship a separate native artifact or define an OpenSSL packaging contract.

The initial release matrix is:

#table(
  columns: (1fr, 1.35fr, 1.35fr, 1.35fr),
  stroke: 0.5pt + rgb("d7dee8"),
  inset: 5pt,
  table.header([*System*], [*Architecture*], [*Wheel platform*], [*Runtime floor*]),
  [Linux],
  [x86_64, AArch64],
  [`manylinux2014`],
  [glibc 2.17],
  [macOS],
  [x86_64],
  [`macosx_10_15_x86_64`],
  [macOS 10.15],
  [macOS],
  [AArch64],
  [`macosx_11_0_arm64`],
  [macOS 11],
  [Windows],
  [AMD64],
  [`win_amd64`],
  [Windows 10 1809 / Server 2019],
)

Each artifact is tagged `cp312-abi3`. CI imports and exercises the same wheel
on CPython 3.12, 3.13, and 3.14. A later CPython minor is added to the test
matrix before the project claims it, even though the Stable ABI should permit
loading the artifact.

`cibuildwheel` drives platform builds, wheel repair, and tests in fresh
environments. Linux uses `auditwheel`, macOS uses `delocate`, and Windows uses
`delvewheel` inspection. The release fails if the wheel depends on an
unexpected zaxonlite, SQLite, sqlite-vec, OpenSSL, Zig, or non-platform shared
library.

The initial PyPI release is wheel-only. A source distribution is added only
after a release staging tool can copy the exact `paxos`, `zaxonlite`, Python
SDK, manifests, dependency pins, and licenses into an isolated source tree.
The sdist must build without reaching outside its unpacked directory. Symlinks
to monorepo parents and build-time downloads of mutable branches are rejected.

== Versioning and provenance

The Python SDK version follows the zaxonlite product version while the native
ABI reports its own version. Import checks both:

```text
Python distribution version == Python package version
native zaxonlite major/minor  == SDK expected native major/minor
```

Patch differences are allowed only when the C ABI compatibility policy says
they are compatible. Wheels record:

- Git commit and clean/dirty state;
- Zig version;
- zaxonlite and paxos versions;
- SQLite numeric version;
- sqlite-vec version and source pin;
- target triple, optimization mode, and TLS-disabled flag;
- CPython Limited API floor;
- wheel repair tool and version.

Release builds require a clean tagged commit. PyPI upload uses trusted
publishing from a protected GitHub environment. The build job cannot upload;
the publish job downloads immutable wheel artifacts, verifies hashes and
provenance, and then publishes first to TestPyPI or PyPI as selected.

= Failure Semantics

#table(
  columns: (1.35fr, 1.35fr, 2.15fr),
  stroke: 0.5pt + rgb("d7dee8"),
  inset: 5pt,
  table.header([*Condition*], [*Python result*], [*Native consequence*]),
  [data directory already open],
  [`OperationalError`],
  [No second connection is returned; the first owner is unchanged.],
  [closed connection or cursor],
  [`ProgrammingError`],
  [No native call occurs.],
  [wrong creator thread],
  [`ProgrammingError`],
  [No native call occurs unless `check_same_thread=False`.],
  [unsupported parameter type],
  [`ProgrammingError`],
  [Statement does not execute.],
  [integer outside signed 64-bit],
  [`OverflowError`],
  [Statement does not execute.],
  [SQL constraint],
  [`IntegrityError`],
  [Current statement or transaction rolls back according to its gate.],
  [busy, interrupt, or I/O error],
  [`OperationalError`],
  [Handle remains usable only when native error state permits it.],
  [invalid UTF-8 TEXT result],
  [`OperationalError`],
  [Result is closed; no partially converted cursor is returned.],
  [Gate A rollback request],
  [no-op only in explicit autocommit],
  [Every prior write is already replicated and remains committed.],
  [Gate B close with open transaction],
  [rollback then close],
  [No payload is proposed; rollback failure poisons the handle.],
  [SQLite commit succeeds, logging fails],
  [`OperationalError`],
  [Node marks image for resync and rejects unsafe reuse.],
  [Python exception during row factory],
  [propagate exception],
  [Cursor retains or discards its materialized row according to documented
  fetch semantics; native result ownership remains balanced.],
)

= Security Considerations

The native extension runs inside the Python process and has the same
filesystem authority as that process. A wheel is executable code; release
provenance, pinned inputs, protected publishing, and artifact inspection are
part of the security boundary.

The package statically links the existing guarded SQLite build. Runtime
extension loading stays omitted. Python cannot replace zaxonlite's authorizer,
register an arbitrary callback, attach a database, or obtain `current.db`.

All Python lengths, row/column indexes, parameter counts, and buffer sizes are
validated before casting to C types. Contiguous buffers are pinned for the
entire GIL-released native call. Text and blob output is copied before its
native result closes.

The extension never parses native error messages to make a security decision.
Stable native error categories drive exception mapping; the message is
diagnostic text only.

The GIL is not the connection lock. Native calls release the GIL, so explicit
per-connection synchronization and close-state transitions prevent
use-after-close, concurrent handle use, and result-owner races.

TestPyPI and PyPI publication use separate environments. The publishing job
has no arbitrary pull-request execution and no long-lived API token. Every
wheel includes the MIT license plus required notices for bundled third-party
code.

= Replication and Compatibility

The typed result ABI changes no journal, WAL payload, snapshot, or wire
format. It exposes information SQLite and zaxonlite already compute.

Gate B changes the duration of the writer transaction, not the committed
artifact. A completed local transaction still produces one captured WAL
transition and one transaction payload. Its protocol payload remains subject
to the existing statement, input-byte, and maximum-payload bounds.

Holding a writer transaction longer can delay other work and rollover. The
local Python connection owns the node handle, so this is a process-local
availability tradeoff rather than a cross-node consistency change. Cluster
transactions remain out of scope.

The Python API follows semantic versioning:

- removing a supported method, changing a default, or changing exception
  classification is a breaking change;
- adding an optional method or accepted input type is additive;
- expanding the wheel matrix is additive;
- changing a native dependency without changing the Python API is still
  release-noted because SQLite behavior may change.

`sqlite3` compatibility is stated feature by feature. A program can usually
port by changing `import sqlite3 as db` to `import zxlite as db` only when
every used feature is marked supported and its database argument is changed
from an SQLite file to a zaxonlite data directory.

= Operational Considerations

Opening a connection initializes a zaxonlite node and can perform recovery.
It is heavier than opening a routine cursor and should be pooled at the
application level only within the one-directory/one-owner rule.

Materialized query results bound native lifetimes but can consume memory
proportional to total result bytes. The SDK documents query budgets and
encourages pagination. A streaming cursor requires a different read-lease
lifetime and cancellation design and is deferred.

The package logs nothing by default. Native errors become exceptions.
Applications opt into standard Python logging for SDK diagnostics. Secrets,
SQL parameter values, TLS material, and full SQL text are not included in
default error logs or build provenance.

Release telemetry is artifact-level only: build duration, wheel size,
dependency inspection, and test results. The installed package performs no
network telemetry.

The first wheels are expected to be substantially larger than a pure-Python
driver because they contain SQLite, sqlite-vec, Paxos, and zaxonlite. CI
records stripped wheel and loaded-library sizes; size is reported, not hidden
by downloading a native library after installation.

= Verification and Acceptance

== Native ABI tests

- Preserve NULL, signed integer limits, real values, UTF-8 text, embedded NUL,
  empty text, blobs, and empty blobs.
- Return column metadata for zero-row queries.
- Bounds-check every row and column accessor.
- Close results before and after partial inspection without leaks.
- Return changes, optional last row ID, replay state, and `RETURNING` rows.
- Convert typed lexical, vector, and hybrid search requests to
  `search_api.Request` without copying or reimplementing the SQL planner.
- Validate null pointer/length pairs, metadata column counts, fusion values,
  embedding lengths, and safe empty search outputs.
- Keep existing JSON query output and C smoke tests compatible.
- Exercise allocation failure and safe empty outputs.
- Verify stable error categories independently of message text.
- Run address, undefined-behavior, and leak sanitizers where the target
  toolchain supports them.

== DB-API tests

- Import metadata, module globals, exception hierarchy, and version checks.
- Connection and cursor close idempotence, finalization, context managers,
  creator-thread checks, and serialized cross-thread use.
- Qmark binding for every supported Python type and parameter-count mismatch.
- Reject multi-statement `execute()` and direct transaction-control SQL.
- `description` on populated and empty results.
- `fetchone`, `fetchmany`, `fetchall`, iteration, arraysize, and exhaustion.
- Default tuple rows, `Row`, connection row factory, and cursor row factory.
- `rowcount`, `lastrowid`, total changes, and no stale metadata after errors.
- Atomic bounded `executemany` and `executescript`.
- Snapshot, backup, integrity, sessions, idempotent replay, and recovery.
- Raw FTS5, sqlite-vec, RRF, and DBSF SQL with text and embedding bindings.
- Typed lexical-only, vector-only, RRF hybrid, and DBSF hybrid search.
- Default and explicit candidate counts, the 4,096 hard ceiling, invalid
  identifiers, invalid weights, malformed embeddings, and metadata projection.
- Search cursors with tuple rows, `Row`, custom row factories, zero results,
  stable item-ID ordering, and no implicit embedding BLOB.
- Compare each supported behavior against CPython 3.12 `sqlite3` using a
  table-driven compatibility oracle.

== Gate B transaction tests

- Implicit begin on the first write and explicit autocommit.
- Read-your-writes across insert, update, delete, and DDL.
- Generated row ID and `RETURNING` before commit.
- Commit durability across close and reopen.
- Rollback publishes no payload and restores prior query results.
- Savepoint, rollback-to-savepoint, release, and nested SQLAlchemy transaction.
- Failed statement followed by rollback.
- Connection close, object finalization, and interpreter shutdown with an
  open transaction.
- Payload-limit failure before commit.
- Crash at SQLite commit, payload sync, journal append, decision, and apply
  failpoints.
- Compile-time and runtime rejection on multi-member or cluster handles.

== SQLAlchemy acceptance

Run SQLAlchemy 2.0 and 2.1 tests against the installed wheel:

- engine construction and disposal;
- metadata `create_all`, `drop_all`, and reflection;
- Core insert, update, delete, select, bound parameters, and compiled cache;
- integer primary-key autoincrement and `RETURNING`;
- ORM add, flush, refresh, commit, rollback, and identity-map refresh;
- unique and foreign-key integrity exception mapping;
- nested transactions and savepoints;
- transactional DDL behavior documented by the dialect;
- `NullPool` reconnect and invalid multi-open configuration;
- Alembic create/upgrade/downgrade smoke tests through an optional test
  dependency;
- explicit rejection of unsupported Python UDF and attachment features.
- raw search SQL through SQLAlchemy `text()` and typed search through the
  underlying `zxlite` DB-API connection.

The documentation may say "SQLAlchemy supported" only after this suite passes
on every release platform.

== Wheel and release tests

- Build each `cp312-abi3` wheel from a clean tagged checkout.
- Install with no Zig compiler and no system zaxonlite.
- Test the same artifact on CPython 3.12, 3.13, and 3.14.
- Inspect imported symbols to confirm Stable-ABI-only CPython references.
- Inspect shared-library dependencies after wheel repair.
- Run open, write, query, rollback where available, close, reopen, and
  integrity checks from outside the source tree.
- Verify package/native version agreement and provenance.
- Verify licenses and third-party notices inside the wheel.
- Upload to TestPyPI, install by version from TestPyPI, rerun smoke tests,
  then permit the protected PyPI publication job.

= Performance Gates

The native driver is not accepted solely because it is functionally correct.
Benchmarks record:

- connection open and recovery time;
- prepared insert and select latency through Python versus the C ABI;
- conversion throughput for integers, reals, text, and blobs;
- materialized result memory per row and per byte;
- GIL release by demonstrating progress on another Python thread during a
  deliberately slow native operation;
- `executemany` throughput and payload size;
- Gate B commit and rollback latency;
- import time and loaded native image size.

The first release sets no claim that Python overhead is zero. It must show no
per-row native ownership leak, no allocation proportional to query history,
and no unexpected serialization beyond the documented one-handle rule.
Results are stored as raw benchmark artifacts with machine, Python, Zig, and
native dependency versions.

= Delivery Plan

== Phase 1: typed boundary

1. Change the internal query result to tagged SQLite values.
2. Add opaque typed result and structured write-result C APIs.
3. Add the typed search request C API over the existing `Node.search`.
4. Add stable native error categories and statement metadata.
5. Preserve and extend the C smoke suite and C ABI documentation.

== Phase 2: Python autocommit SDK

1. Create `languages/python` with packaging, native extension, DB-API layer,
   typing, examples, and compatibility matrix.
2. Implement Limited-API connection and result types, GIL release, locking,
   conversion, and exception mapping.
3. Implement Gate A connections, cursors, fetch behavior, atomic
   `executemany`, typed search, maintenance, and exactly-once helpers.
4. Add wheel CI for Linux x86_64 first, then Linux AArch64, macOS x86_64 and
   AArch64, and Windows AMD64.
5. Publish a Gate A prerelease to TestPyPI and retain the explicit
   autocommit-only label.

== Phase 3: local transaction core

1. Refactor node write capture into begin, statement, query, savepoint,
   commit, and rollback states without weakening the application guard.
2. Expose the local transaction through an additive C ABI.
3. Add typed `RETURNING`, generated-key, named-parameter metadata, and
   multi-statement-tail detection.
4. Complete crash, resync, payload-limit, finalization, and one-member
   capability tests.
5. Enable Gate B DB-API transaction mode only after the native suite passes.

== Phase 4: SQLAlchemy and PyPI release

1. Implement the `zxlite://` SQLAlchemy dialect and `NullPool` default.
2. Run the SQLAlchemy 2.0/2.1 and Alembic acceptance suites on installed
   wheels.
3. Publish documentation that distinguishes supported sqlite3, DB-API,
   SQLAlchemy, and zaxonlite-specific behavior.
4. Produce signed provenance, TestPyPI verification, and protected PyPI
   publication.
5. Add an sdist only after isolated source staging passes its release gates.

= Alternatives Considered

== Pure Python `ctypes`

Rejected as the release architecture. It avoids CPython headers but performs
conversion and ownership through a dynamic FFI layer, cannot use the Stable
ABI wheel tag to describe the bundled native module, and makes GIL release
and rich native types awkward. It remains useful as a development spike.

== CFFI ABI mode

Rejected for the base package. It adds a runtime dependency and still needs a
bundled shared library with platform-specific loading and repair. The narrow
CPython extension has a smaller runtime surface.

== Write the complete extension in Zig

Rejected for the first release. Zig can call the CPython Stable ABI, but a
small C shim uses the Limited API headers as their primary supported form and
keeps Python reference-counting conventions reviewable. Product logic remains
in Zig.

== One wheel per CPython minor

Rejected. The extension does not require CPython object-layout access.
Targeting the 3.12 Limited API permits one `abi3` artifact per platform and
reduces release and security-patching fan-out.

== Shadow the standard-library `sqlite3`

Rejected. Installing a competing top-level `sqlite3` package creates import
ambiguity, surprises transitive dependencies, and overstates compatibility.
Applications import `zxlite` explicitly.

== Use SQLAlchemy's stock pysqlite dialect

Rejected. That dialect applies pysqlite connection and transaction behavior,
including optional Python UDF registration. A dedicated dialect can reuse SQL
compilation while declaring zaxonlite's actual capabilities.

== Claim transactions by buffering statements in Python

Rejected. Deferred statements cannot provide read-your-writes, immediate
constraints, generated keys, `RETURNING`, or correct savepoints. The existing
native transaction builder remains useful for atomic batches but is not a
live DB-API transaction.

== Autocommit forever

Rejected as the final SQLAlchemy path. It is a useful first gate, but ORM
rollback and unit-of-work semantics require a real transaction boundary.

== Distributed live DB-API transactions

Deferred to a separate design. A leader can change while a Python application
thinks between calls. Correct behavior needs leases, retry identity,
abandoned-client cleanup, conflict policy, and availability tradeoffs that
are not implied by local transaction support.

= Resolved Design Decisions

#block(breakable: false)[
  #set text(size: 8pt)
  #table(
    columns: (1.2fr, 2fr, 2.05fr),
    stroke: 0.5pt + rgb("d7dee8"),
    inset: 5pt,
    table.header([*Question*], [*Resolved answer*], [*Constraint or gate*]),
    [Q1: import name],
    [`import zxlite`; never shadow `sqlite3`.],
    [The PyPI distribution is `zxlite`; ownership is verified
    before publication.],
    [Q2: Python floor],
    [CPython 3.12 Limited API and `cp312-abi3`.],
    [Test every claimed later CPython minor with the installed wheel.],
    [Q3: first semantics],
    [Typed, replicated autocommit DB-API subset.],
    [Only `autocommit=True` and `isolation_level=None`; no general SQLAlchemy
    claim.],
    [Q4: transaction scope],
    [Live DB-API transactions are local embedded and single-member only.],
    [Cluster transaction semantics require a separate ZDS.],
    [Q5: SQLAlchemy],
    [A dedicated `zxlite://` dialect after Gate B.],
    [SQLAlchemy 2.0 and 2.1 Core/ORM acceptance on every release platform.],
    [Q6: packaging],
    [Static native extension, Zig TLS disabled, wheel-only first release.],
    [manylinux2014 x86_64/AArch64, macOS x86_64/AArch64, Windows AMD64.],
    [Q7: result model],
    [Opaque materialized typed results in the C ABI and Python cursors.],
    [Streaming is deferred; query memory is bounded through documented
    budgets and pagination.],
    [Q8: Python callbacks],
    [No arbitrary UDF, aggregate, collation, authorizer, or trace callbacks.],
    [Registration across internal connections and GIL/thread lifetime need a
    separate design.],
    [Q9: search API],
    [`Connection.search(...)` returns a normal materialized cursor and calls
    zaxonlite's typed planner; raw search SQL remains available.],
    [The native validator owns identifiers, embedding shape, fusion weights,
    metadata projection, and the `candidate_count <= 4096` gate. The Python
    package adds no NumPy or model-runtime dependency.],
  )
]

These decisions close the implementation choices for the first two release
gates. PyPI project-name ownership for `zxlite` is an external administrative
prerequisite. The distribution name, import namespace, SQLAlchemy dialect
name, and connection URL remain aligned as `zxlite`; a different fallback
name requires this record to be updated before publication.

#context {
  if target() != "html" {
    pagebreak(weak: true)
  }
}

= References

- #link("https://peps.python.org/pep-0249/")[PEP 249: Python Database API
  Specification v2.0]
- #link("https://docs.python.org/3.12/library/sqlite3.html")[
  Python 3.12 `sqlite3` documentation]
- #link("https://docs.python.org/3.12/c-api/stable.html")[
  CPython Limited API and Stable ABI]
- #link("https://packaging.python.org/en/latest/guides/packaging-binary-extensions/")[
  Python Packaging User Guide: Packaging binary extensions]
- #link("https://packaging.python.org/en/latest/specifications/platform-compatibility-tags/")[
  Python platform compatibility tags]
- #link("https://cibuildwheel.pypa.io/")[cibuildwheel documentation]
- #link("https://docs.sqlalchemy.org/en/20/dialects/sqlite.html")[
  SQLAlchemy 2.0 SQLite dialect]
- #link("https://docs.sqlalchemy.org/en/21/dialects/sqlite.html")[
  SQLAlchemy 2.1 SQLite dialect]
- #link("https://www.sqlite.org/c3ref/last_insert_rowid.html")[
  SQLite last inserted row ID]
- #link("https://www.sqlite.org/lang_returning.html")[SQLite `RETURNING`]
- #link("https://www.sqlite.org/c3ref/bind_parameter_name.html")[
  SQLite prepared-parameter metadata]
- ZDS 0002, _Zaxonlite: Product and Delivery Plan_
- ZDS 0003, _Zaxonlite Security and Trust Plan_
- ZDS 0004, _Zaxonlite Format and Compatibility Contract_
- ZDS 0006, _Windows Durability and the Supported Platform Floor_
- ZDS 0009, _Multimodal Search in zaxonlite_
