# Feature map

This file compares Paxos Zig 0.1 with OmniPaxos 0.2.2. It is a design map, not
a claim that two implementations with different APIs have identical internals.

## Consensus and log features

| Capability | Paxos Zig | Notes |
|---|---|---|
| Multi-Paxos replicated log | Implemented | Stable leader phase skips repeated phase one. |
| Automatic leader election | Implemented | `tick` starts ballot elections after bounded logical timeouts. |
| Leader priority | Implemented | Priority is ordered inside ballots before node ID. |
| Heartbeats | Implemented | Leaders emit bounded heartbeat traffic from `tick`. |
| Message retransmission | Implemented | `tick` resends outstanding accepts and commits. |
| Reconnect repair | Implemented | `reconnected` repairs one peer without allocation. |
| Flexible quorums | Implemented | Read and write quorums are validated to intersect. |
| Batched append | Implemented | One call returns one write and message effect batch. |
| Reads | Implemented | Point reads, decided prefix, and caller-buffer suffix reads. |
| Catch-up | Implemented | A lagging member requests decided entries from a slot. |
| Reconfiguration | Implemented | An accepted stop seals local appends; a decided stop starts the next configuration. |
| Snapshot compaction | Implemented as epochs | `checkpoint` seals an epoch with snapshot metadata. |
| Start next epoch | Implemented | `initFromStop` validates and starts the decided membership. |
| Fixed memory | Implemented | All protocol buffers have compile-time bounds. |
| Reusable effects | Implemented | `Effects.init` avoids clearing large inactive backing arrays. |

Snapshot epochs are intentionally stronger and more explicit than local in-place
trimming. The application writes a snapshot, proposes a checkpoint stop sign,
waits for it to become decided, and starts the next configuration from that
snapshot. Old protocol memory can then be discarded as one unit. Paxos Zig does
not currently offer OmniPaxos's local `trim` operation inside a live epoch.

## Zig-native integration boundaries

Some OmniPaxos crate features solve Rust ecosystem concerns. Paxos Zig keeps
these concerns at explicit host boundaries.

| OmniPaxos facility | Paxos Zig boundary |
|---|---|
| Storage trait | Ordered `Effects.write` records and `DurableState.apply`. |
| Memory storage | `DurableState` is the reference in-memory replay target. |
| Persistent storage | The host journals and syncs `Write` records. |
| Network abstraction | The host sends owned `Envelope` values after syncing. |
| Serde | The host selects a wire codec for its fixed command type. |
| TOML configuration | The host parses configuration into explicit Zig values. |
| Logging feature | The host records effects and state transitions. |
| Derive macros | Compile-time generic types replace Rust derive machinery. |
| Dashboard state | Public role, ballot, leader, and decided-prefix accessors. |

The runtime library has no third-party dependencies. Fletcher and CeTZ are book
build dependencies only. OmniPaxos remains a benchmark development dependency.

## Deliberate differences

Paxos Zig does not claim byte-for-byte or algorithm-for-algorithm equivalence.

- OmniPaxos BLE has a published partial-connectivity progress argument. Paxos
  Zig uses bounded ballot timeouts, priority, heartbeats, and ordinary Paxos
  competition. Safety is preserved under competing candidates, but an equally
  strong partial-connectivity liveness proof is not claimed.
- OmniPaxos can trim or snapshot a live log. Paxos Zig compacts at an explicit
  sealed epoch boundary.
- OmniPaxos `batch_accept` combines entries in its internal wire message. Paxos
  Zig returns one bounded effect batch, which lets the host journal and packetize
  messages together, but each Paxos accept remains an explicit envelope.
- OmniPaxos UniCache performs synchronized dictionary encoding for skewed fields.
  Paxos Zig currently recommends fixed commands and content-addressed values. It
  does not claim a synchronized UniCache implementation.

These differences must remain visible until equivalent implementations and tests
exist. Readability counts, and unsupported behavior must not be hidden by a broad
compatibility statement.
