#import "theme.typ": *

= TigerStyle Coding Standard

== The coding standard

A consensus library is read under pressure. A reviewer may be tracing a safety
failure at three in the morning. A future maintainer may know Zig but not Paxos.
The code must help both readers.

This project begins with seven sentences.

#book_quote([
  Beautiful is better than ugly. Explicit is better than implicit. Simple is
  better than complex. Complex is better than complicated. Flat is better than
  nested. Sparse is better than dense. Readability counts.
], [Project design principles])

These sentences are not permission to prefer pretty code over correct code.
They tell us how correct code should be presented. TigerStyle supplies the hard
bounds. Paxos supplies the invariants. Zig supplies explicit values and errors.

The order of concern is:

1. safety,
2. performance,
3. developer experience.

An attractive abstraction that hides a disk ordering rule fails the first item.
A fast loop without a bound fails the first item as well. A safe and bounded
function with poor names fails the third item and will eventually threaten the
first two.

=== Readability is a safety property

Consider a promise check written as one dense expression.

```zig
if (done[i] and received[i] == expected[i] and ballot.eql(active)) count += 1;
```

The expression is short. It is not simple. Three facts have been compressed into
one line. A reviewer must separate them mentally.

The library uses the flat form.

```zig
if (!promise_done[member]) continue;
if (promise_received[member] != promise_expected[member]) continue;
complete += 1;
```

Each line answers one question. Did the completion marker arrive? Did every
promised entry arrive? If both answers are yes, this member is complete. Message
reordering is now visible in the shape of the code.

#callout([The test for a readable line], [
  Ask whether a reviewer can name the invariant protected by the line without
  expanding a hidden abstraction or evaluating a compound expression.
], kind: "idea")

== Control flow

Protocol control flow is deliberately ordinary.

+ Public methods validate, reset effects, perform one transition, and validate.
+ Message dispatch uses one explicit switch.
+ Invalid input returns early.
+ Loops have visible bounds.
+ Recursion is not used.
+ A helper has one protocol purpose.

This is preferred:

```zig
if (message.ballot.lessThan(self.durable.promised)) {
    self.sendNack(from, message.ballot, effects);
    return;
}
```

The rejection is a complete branch. The normal path remains flat. A nested
version would make the common transition harder to see.

=== Function size

Functions are limited to 70 lines. Source lines are limited to 100 columns.
These are not aesthetic guesses. A short function can usually be held in one
view and reviewed as one transition. A short line leaves room for an editor,
line numbers, and a debugging pane.

The generic `Protocol` and `ReplicatedLog` type factories are namespaces written
as Zig functions. They are exempt from the outer function limit. Every function
inside them is still checked.

If a function grows, split it by protocol responsibility. Do not split it at an
arbitrary line count. `sendAccept`, `recordCommit`, and `emitContiguous` are
separate because acceptance, durable choice, and application delivery are
different facts.

== Bounds and memory

The consensus path allocates no memory after initialization. Members, retained
entries, batches, messages, writes, and delivery buffers have compile time
bounds.

#table(
  columns: (1.2fr, 1fr, 1.5fr),
  table.header([*Quantity*], [*Type*], [*Reason*]),
  [Node identity], [`u32`], [Stable protocol identity.],
  [Ballot round], [`u64`], [Explicit exhaustion boundary.],
  [Slot], [`u32`], [Wire and durable log position.],
  [Array index], [`usize`], [Required by Zig slices.],
  [Member count], [`u16`], [Bounded by the configured maximum.],
)

`usize` does not cross the protocol boundary. It is used for array indexes and
slice lengths. A node ID is not an index. A slot is not an index. Converting one
to the other happens in a small checked function.

Large structures are initialized through destination pointers.

```zig
var membership: P.Membership = undefined;
try membership.init(&.{ 1, 2, 3 });

var node: P.Node = undefined;
try node.init(1, &membership);
```

Returning a large node by value would make an accidental copy easy to miss.
The destination pointer makes ownership and storage visible.

=== Batches remain bounded

Batching is useful only when it does not turn latency into an unbounded queue.
`max_batch` is a compile time limit. `appendBatch` rejects a larger slice before
it mutates the log. The caller supplies the slot output buffer.

Preflight checks happen before the first proposal. A rejected batch therefore
has no partial prefix.

== Assertions and errors

Operating errors are returned. Examples are invalid membership, wrong recipient,
not leader, and slot exhaustion. Programmer and invariant errors are assertions.

#table(
  columns: (1fr, 1.5fr, 1.5fr),
  table.header([*Situation*], [*Mechanism*], [*Example*]),
  [Invalid caller input], [Return an error.], [`error.InvalidSlot`],
  [Capacity reached], [Return an error.], [`error.SlotLimitReached`],
  [Stale network ballot], [Return a protocol message.], [`nack`],
  [Impossible buffer count], [Assert.], [`count <= buffer.len`],
  [Durable storage failure], [Stop the node.], [Restore from durable state.],
)

Buffer mutations use paired assertions.

```zig
std.debug.assert(self.messages_count < self.messages.len);
self.messages[self.messages_count] = envelope;
self.messages_count += 1;
std.debug.assert(self.messages_count <= self.messages.len);
```

The first assertion protects the write. The second records the new invariant.
ReleaseFast removes full state validation from the hot path. Debug and
ReleaseSafe retain it.

The library does not use `catch unreachable` for ordinary errors. It does not
panic because a peer sent an old ballot. It does not continue after a journal
sync fails.

== Names carry the proof

Names come from the domain.

+ `promised` is the ballot below which an acceptor will not vote.
+ `accepted` is a durable vote for one slot and value.
+ `committed` is a learned chosen value.
+ `delivered_through` is the contiguous prefix released to the application.
+ `readQuorum` is the phase one quorum.
+ `writeQuorum` is the phase two quorum.

Names such as `state2`, `tmp`, and `data` force the reader to rediscover facts
that the program already knows. Short loop names such as `index` and `member`
are acceptable when their domain is immediate.

Units belong in names when two units could be confused. Use `timeout_ticks`,
`metadata_count`, and `from_slot`. Do not make the reader guess whether a number
is bytes, entries, ticks, or nodes.

== Comments explain why

This comment is weak.

```zig
// Increment the count.
count += 1;
```

The statement already says that. A useful comment preserves a reason.

```zig
// A completion marker may overtake entries on a reordering network.
// Count this member only after every announced entry has arrived.
```

Comments should mention crash boundaries, quorum arguments, ownership, or a
surprising performance decision. They should not translate Zig into English.

== Formatting is executable

The repository makes the standard part of the build.

```sh
zig build fmt
```

This command runs `zig fmt --check`. It also runs `tools/check-style.sh`, which
checks every project Zig file for:

+ tabs,
+ lines over 100 columns,
+ functions over 70 lines.

Formatting is necessary but not sufficient. `zig fmt` cannot prove that a name
is precise or that a comment explains the correct invariant. Human review uses
the checklist below.

== Review checklist

Review a protocol change in this order.

1. State the invariant affected by the change.
2. Identify the durable write that preserves it across restart.
3. Confirm that no dependent message can leave before that write is synced.
4. Check duplicates, reordering, message loss, and a stale ballot.
5. Check one voter, a minimum quorum, and the configured maximum.
6. Confirm that all loops, buffers, and retries are bounded.
7. Read names and branches without relying on the author explanation.
8. Add a deterministic failure schedule test.
9. Run formatting, tests, examples, benchmarks, and the book build.
10. Make only the performance claim supported by the recorded measurement.

#warning([A formatter cannot grant clarity], [
  A file can be perfectly formatted and still be difficult to understand.
  Readability counts only when the state transition and its reason are visible.
])
