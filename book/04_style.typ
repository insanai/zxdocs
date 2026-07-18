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

== Flattening the Happy Path

In nested code, the reader must keep track of multiple levels of indentation. This increases cognitive load. TigerStyle requires control flow to be flat: handle rejections and error checks early, and return immediately.

Consider a nested prepare message handler:

```zig
// AVOID this style
if (message.ballot.greaterThanOrEqual(self.durable.promised)) {
    self.durable.promised = message.ballot;
    // ... write to disk ...
    if (durable_success) {
        self.sendPromise(from, effects);
    }
} else {
    self.sendNack(from, self.durable.promised, effects);
}
```

Now look at the flat style used in our library:

```zig
// PREFER this style
if (message.ballot.lessThan(self.durable.promised)) {
    self.sendNack(from, self.durable.promised, effects);
    return;
}

// Happy path continues here, completely flat!
self.durable.promised = message.ballot;
effects.addWrite(.{ .promise = .{ .ballot = message.ballot } });
```

By returning early on rejection, the happy path stays at one level of indentation. The reader can trace the primary transition easily without keeping a mental stack of nested conditions.

== Errors vs Assertions: Knowing the Difference

We distinguish between two kinds of failures:

1. *Operating Errors*: These are expected events in an asynchronous network. A client sends a message to the wrong node, or proposes a command when the log is full. These are handled gracefully by returning an error or a network rejection (`nack`).
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

== Review Checklist: The Human Proof

Even with tests and formatters, human review is our final defense. When reviewing a change to the consensus core, ask these questions:

+ *What invariant does this change affect?* Trace the code back to Leslie Lamport's invariants `B1`, `B2`, or `B3`.
+ *Is the write synced before the send?* Ensure no network message leaves before the corresponding write is durable.
+ *What happens if this message is duplicated or delayed?* Verify that the handler is idempotent.
+ *Are all buffers bounded?* Make sure no loop or array mutation can run out of bounds.
+ *Is it readable?* Can a colleague review the code and understand the proof without reading this book?
