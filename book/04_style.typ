#import "theme.typ": *

= TigerStyle Coding Standard

== Why Zero Allocation Matters

In typical application development, we allocate memory on the heap whenever we need a new buffer or object. If we run out of memory, the operating system might kill our process, or the program might crash. 

For a consensus protocol, *dynamic allocation is a safety risk*. 

If a database node runs out of memory while writing a vote to disk, the process might panic midway, leaving the journal in a half-written state. Furthermore, heap allocation introduces non-determinism (memory fragmentation, variable allocator latency) that makes performance profiling and testing difficult.

Our library follows the *TigerStyle* coding guidelines:
+ *Zero runtime allocation*: All memory needed by the consensus core is allocated statically at startup or on the call stack. The library does not import or use a heap allocator.
+ *Static bounds*: Cluster size, slot log capacity, and message buffers are defined at compile time.
+ *Fail-fast assertions*: We protect internal invariants using standard assertions. If an invariant is violated, the node halts immediately.

== Control Flow Rules

Consensus transitions should be obvious. We enforce the following control flow guidelines:
- Keep control flow explicit and shallow. Do not hide protocol transitions in callbacks, reflection, or generic magic.
- Return early when a precondition fails to keep the happy path flat.
- Split compound conditions when their parts protect different invariants.
- Do not use recursion in protocol or storage paths.
- Bound every loop with a compile-time capacity or a validated input length.
- Use one explicit, flat switch statement for message dispatch.

== Memory and Type Guidelines

- The consensus library does not allocate after initialization.
- Capacities are compile-time options and are validated at startup.
- Initialize large values through destination pointers to avoid stack copy overhead.
- Do not return a large node struct by value.
- Use fixed-width integers (`u8`, `u32`, `u64`, `u128`) for protocol identities, rounds, slots, and counts.
- Use the native `usize` type *only* for Zig array and slice indexing.
- Values stored in messages must own their data or contain durable identifiers.

== State and Invariant Safety

- State the invariant in code comments before implementing its state transition.
- Assert important preconditions and postconditions in safe builds.
- Pair an assertion before and after a buffer count mutation.
- Durable state (promised ballot, accepted ballot, committed slot) never moves backward.
- One ballot and slot must never carry two conflicting values.
- A committed slot must never change its value.
- A later leader preserves the highest accepted value reported by the phase one quorum.
- Quorum configuration is valid only when read and write quorums intersect.
- Every message that depends on a write is sent *only* after that write is durably synced to disk.

== Functions and Names

- A function should do exactly one protocol action.
- Keep functions at or below 70 lines (exempting generic factories, though their nested functions are checked).
- Keep source lines at or below 100 columns.
- Use names directly from the protocol: `promised`, `accepted`, `committed`, and `ballot`.
- Include units or domains in names when confusion is possible.
- Avoid abbreviations except for established protocol terms.
- Place helper functions immediately after the public operation that motivates them.

== Errors vs Assertions: Knowing the Difference

We distinguish between two kinds of failures:

1. *Operating Errors*: These are expected events in an asynchronous network. A client sends a message to the wrong node, or proposes a command when the log is full. These are handled gracefully by returning an error or a network rejection (`nack`).
   - We explain all operating errors using a human-friendly diagnostics format, inspired by the Elm language compiler's diagnostic design (Compiler Errors for Humans).
   - Each error returns a structured explanation with a clear top boundary header (e.g. `-- NOT LEADER --`), a simple English description of what failed in the state machine, and a `Hint:` suggesting a resolution path.
2. *Invariant Violations*: These are bugs. An acceptor votes for a ballot lower than its promise, or the write count exceeds the size of the array. These represent impossible state transitions. 

If we detect an invariant violation, *we assert and crash*. 

In consensus engineering, a dead node is safe, but a corrupt node that continues running and sends corrupt messages can break safety for the entire cluster. We use `std.debug.assert` to protect all internal boundaries:

```zig
// Verify the array index is within bounds before mutating
std.debug.assert(self.messages_count < self.messages.len);
self.messages[self.messages_count] = envelope;
self.messages_count += 1;
std.debug.assert(self.messages_count <= self.messages.len);
```

== Comments and Documentation

- Comments explain *why* a rule exists, not what the next statement says.
- Public methods document ordering, durability, bounds, and memory ownership.
- Examples must show the write-before-send sequence explicitly.
- Documentation must distinguish safety from liveness.
- Unsupported behavior must be stated directly in documentation, not hidden behind broad claims.

== Tests and Measurements

- Every protocol bug receives a deterministic failure schedule test to prevent regressions.
- Test duplicates, packet loss, reordering, restarts, stale ballots, and bounded capacity.
- Test one voter, the smallest quorum, and the configured maximum.
- A benchmark validates its checksum and protocol message count.
- Cross-language measurements must pin dependency versions and disclose differences.
- Performance claims use observed numbers and never infer language superiority.

== Review Checklist: The Human Proof

Even with tests and formatters, human review is our final defense. When reviewing a change to the consensus core, ask these questions:

+ *What invariant does this change affect?* Trace the code back to Leslie Lamport's invariants `B1`, `B2`, or `B3`.
+ *Is the write synced before the send?* Ensure no network message leaves before the corresponding write is durable.
+ *What happens if this message is duplicated or delayed?* Verify that the handler is idempotent.
+ *Are all buffers bounded?* Make sure no loop or array mutation can run out of bounds.
+ *Is it readable?* Can a colleague review the code and understand the proof without reading this book?
