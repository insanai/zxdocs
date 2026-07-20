#import "theme.typ": *

= Operations

== Running one durable node

```sh
zaxon serve --data /var/lib/app --node 1 --listen 127.0.0.1:9901
```

or skip the server entirely and embed: every CLI command with `--data`
opens the node in-process, exactly as a linking application would. The
directory `flock` guarantees one host process at a time (a locked
directory is exit code 4, never a corruption risk).

== Running three voters

Give every member the *same* membership, its own id, directory, and
endpoint:

```sh
zaxon serve --data /d/n1 --node 1 --listen 10.0.0.1:9901 \
    --peer 2@10.0.0.2:9901/data-voter \
    --peer 3@10.0.0.3:9901/data-voter
zaxon serve --data /d/n2 --node 2 --listen 10.0.0.2:9901 \
    --peer 1@10.0.0.1:9901/data-voter \
    --peer 3@10.0.0.3:9901/data-voter
zaxon serve --data /d/n3 --node 3 --listen 10.0.0.3:9901 \
    --peer 1@10.0.0.1:9901/data-voter \
    --peer 2@10.0.0.2:9901/data-voter
```

The shared database identity derives from the member ids (add
`--cluster-id <text>` to separate otherwise-identical clusters). Wait
for the cluster:

```sh
zaxon wait --connect 10.0.0.1:9901 --leader --timeout-ms 10000
zaxon leader --connect 10.0.0.1:9901
```

== Non-voting and routing nodes

Every storage node receives the same bootstrap registry. A read replica uses
`--role read-replica`, and each voter lists it as
`--peer 4@10.0.0.4:9901/read-replica`. Use `standby` for a
promotion-eligible copy, `witness` for a voting non-SQL failure domain, and
`gateway` for a stateless client endpoint. An existing data directory pins its
role; changing the CLI role without a controlled migration is rejected.

== The command surface

#table(
  columns: (auto, 1fr),
  table.header([*Command*], [*Purpose*]),
  [`sql`], [Interactive shell (embedded or connected); read statements
    route to query, everything else to exec.],
  [`exec`], [One replicated write transaction; `--session`/`--sequence`
    makes it idempotent.],
  [`query`], [Read-only; `--level any|leader|linearizable`; defaults to
    `linearizable`; local learners accept `--freshness-ms`; `--json`.],
  [`session`], [Open a replicated retry session.],
  [`expire-sessions`], [Delete sessions idle beyond `--retain` recent
    session writes.],
  [`status`], [Node id, node type, Paxos role, leader, ballot, decided/applied slots,
    configuration, chain, snapshot.],
  [`wait`], [Block until `--applied <slot>` and/or `--leader`.],
  [`snapshot`], [Materialize, seal the epoch, roll to the next one.],
  [`backup`], [`VACUUM INTO` a consistent logical copy — works on
    leader and follower alike.],
  [`integrity-check`], [SQLite `integrity_check` + descriptor chain +
    payload availability. Exit 3 on failure.],
  [`stop`], [Graceful server shutdown (client mode).],
)

Exit codes: 0 ok · 1 SQL/session error · 2 usage · 3 integrity failure
· 4 unavailable (locked, corrupt, no reachable leader).

Client mode accepts a comma-separated endpoint list and follows
`not_leader` redirects automatically; scripts can point at all three
members and ignore leadership entirely.

== Failure playbook

#table(
  columns: (1fr, 1.6fr),
  table.header([*Symptom*], [*What happens / what to do*]),
  [One member down], [Writes and linearizable reads continue on the
    remaining two. Restart the member; it catches up automatically
    (journal suffix, or snapshot transfer across a sealed epoch).],
  [Two members down], [No quorum: writes and fenced reads refuse;
    `--level any` reads still serve locally. Add `--freshness-ms` to reject a
    disconnected or lagging learner instead. Restore a member.],
  [`current.db` lost or restored from an old copy], [Delete it (or
    leave the stale copy); the node rebuilds from snapshot plus journal
    and validates the batch marker. No operator action beyond restart.],
  [Journal tail torn by power loss], [Truncated automatically on open;
    the lost suffix was never acknowledged.],
  [Journal corrupt in the middle], [The node refuses to open. Recover
    by reimaging from a healthy member: empty the directory and
    restart — snapshot transfer plus catch-up rebuild everything.],
  [Disaster recovery of last resort], [`zaxon backup --to app.db` on
    any surviving member yields a plain SQLite file usable anywhere.],
)

== Monitoring

`status --json` is the machine surface: `node_type`, Paxos `role`, current leader, ballot,
`decided_slot` versus `applied_slot` (lag), journal record count, epoch
capacity, chain hash (compare across members: equality means identical
applied history), and the installed snapshot generation.
`members --json` returns the runtime registry with role, voter/campaign/read/
write/promotion capabilities, self identity, and the current leader hint.
