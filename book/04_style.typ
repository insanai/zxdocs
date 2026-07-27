#import "theme.typ": *

= Writing Reviewable Consensus Code

#objectives([
  By the end of this chapter you should be able to review a change in reasoning
  order, distinguish recoverable input errors from internal invariant checks,
  and connect a source transition to the proof obligation it preserves.
])

== Why Zero Allocation Matters

In typical application development, we allocate memory on the heap whenever we need a new buffer or object. If we run out of memory, the operating system might kill our process, or the program might crash. 

Dynamic allocation is not inherently a Paxos safety violation: a node that
fails cleanly on allocation failure can remain fail-stop. It does introduce
additional failure paths, latency variance, fragmentation, and ownership work.
A torn journal record is a storage-format and recovery problem whether or not a
heap was involved. This library chooses fixed bounds so its core never needs to
solve those problems at runtime.

Our library follows the *TigerStyle* coding guidelines:
+ *Zero runtime allocation*: All memory needed by the consensus core is allocated statically at startup or on the call stack. The library does not import or use a heap allocator.
+ *Static bounds*: Cluster size, slot log capacity, and message buffers are defined at compile time.
+ *Fail-fast checks*: Recoverable boundaries return errors; safe builds also
  assert internal invariants close to their mutation sites.

It also follows a Knuth-inspired literate rule: organize an explanation around
the human proof, not the compiler's file order. That does not mean comments
should narrate syntax. A useful source comment names the invariant, the reason
for a write, or the ownership boundary that a reviewer could otherwise miss.

Lamport's hierarchical-proof practice adds another rule: a long argument needs
levels. First state the transition's claim; then split it into obligations such
as membership validation, durable monotonicity, quorum evidence, and emitted
effects. A reviewer should not have to remember an unstructured page of prose
while inspecting one branch.

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

Internal impossible states use assertions in builds where runtime safety is
enabled. Untrusted bytes, wrong recipients, stale ballots, capacity limits, and
storage failures must use validation, errors, or protocol replies instead;
correctness must not depend on a debug assertion that an optimized build may
omit.

A third category sits between them: a *host-facing safety boundary*, where the
caller's code, not the library's, can break a load-bearing rule. The effect
ordering contract is the canonical example. Boundary checks like this must be
always-on, in every optimize mode, and stop the process with a stable
diagnostic; an invalid option value at a type factory must fail compilation
outright. A boundary is not an internal invariant, so `std.debug.assert` is
the wrong tool for it, and it is not an operating error, so returning an
error a caller could ignore is wrong too.

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

== Review Checklist: A Human Proof Outline

Human review complements executable tests; this repository does not yet ship a
machine-checked specification that refines to the Zig code. When reviewing a
change to the consensus core, ask these questions in order:

+ *What invariant does this change affect?* Trace the code back to Leslie Lamport's invariants `B1`, `B2`, or `B3`.
+ *Is the write synced before the send?* Ensure no network message leaves before the corresponding write is durable.
+ *What happens if this message is duplicated or delayed?* Verify that the handler is idempotent.
+ *Are all buffers bounded?* Make sure no loop or array mutation can run out of bounds.
+ *Is it readable?* Can a colleague review the code and understand the proof without reading this book?

#teach_back([
  Choose `Node.onAccept` or `DurableState.apply`. Explain it in reasoning order:
  precondition, state protected, durable change, emitted evidence, duplicate
  behavior, and failure behavior. Only then read the function and list any line
  your explanation failed to predict.
])
