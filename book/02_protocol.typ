#import "theme.typ": *
#import "figures.typ": *

#part_page("II", [The complete ballot], [
  We execute one ballot. We stop at every write, every reply, and every failure.
  At the end we can recover after a crash without guessing.
])

= The Single-Decree Protocol

== The four roles

To build a consensus system, we divide the work into four distinct roles: *Proposers*, *Acceptors*, *Learners*, and *Clients*. Although a production server (like a node in our library) usually performs all of these roles at the same time to save resources, they are conceptually completely separate.

#book_figure(
  [A client supplies the intent (what we want to do). Paxos orders that intent.
  The state machine executes the ordered commands, turning them into meaningful results.],
  role_map(),
)

Let us break down what each role is thinking and what it must remember:

+ *Clients*: The clients want to get work done. A client submits a command (e.g., `set x = 10`) and expects a response. If the network drops a message, the client must retry. To prevent executing the same command twice, the client attaches a unique `client_id` and `request_id` to its request.
+ *Proposers (Candidates/Leaders)*: Proposers are the active orchestrators. They run campaigns to become the leader, choose values, and drive consensus. A proposer does not need stable storage to ensure safety after a crash; if it restarts, it can simply start a new campaign with a higher ballot.
+ *Acceptors (The Parliament)*: Acceptors are the passive voters. They act as the stable memory of the system. They receive queries, make promises, write votes to disk, and reply to proposers. *Acceptors must never forget what they have written to disk.*
+ *Learners*: Learners are the observers. They do not vote. They listen for chosen decisions and apply them to the local application state machine (such as a key-value store or database).

#table(
  columns: (auto, 1fr, 1.2fr),
  table.header([*Role*], [*Key Question*], [*Durable State on Disk*]),
  [Proposer], [Which value am I allowed to propose?], [None (volatile). Re-campaigning on reboot is safe.],
  [Acceptor], [Am I allowed to vote, and what did I vote for?], [Highest promised ballot, and highest accepted vote.],
  [Learner], [Which values have been chosen?], [Delivered slot prefix (applied index).],
  [Client], [Did my request succeed?], [Stable transaction record.],
)

== Phase one: The Election and Query

Phase one is the leader election and recovery phase. A candidate cannot propose a value out of thin air. First, it must ask the acceptors what they have already done.

=== Step 1: Prepare

A candidate chooses a ballot number higher than any it has seen so far (say, `(round = 1, node = 1)`). It sends a `prepare` message to all acceptors:

```text
prepare { ballot }
```

Notice that this message contains no value! The candidate is not yet proposing `olive = 7`. It is simply querying the acceptors.

=== Step 2: Promise

When an acceptor receives a `prepare` message with ballot $B$, it compares $B$ with the highest ballot it has ever promised ($P_("max")$).

*   *If $B < P_("max")$*: The acceptor ignores or rejects the prepare by sending a `nack` (negative acknowledgement).
*   *If $B >= P_("max")$*: The acceptor makes a solemn promise. It writes $B$ to its durable storage as its new promise ($P_("max") = B$). Once this write is synced to disk, the acceptor replies with a `promise` message:

```text
promise {
    ballot = B,
    accepted_ballot = B_last,
    accepted_value = V_last
}
```

The promise has a powerful meaning: *"I promise never to accept any future proposal that has a ballot number lower than $B$. Also, here is the highest ballot I have accepted so far ($B_("last")$), along with the value I voted for ($V_("last")$)."*

#warning([Sync before you speak], [
  An acceptor must never send a `promise` reply until the promise is written to durable disk. If it replies first, and then crashes before the disk write completes, it might reboot and vote for a lower ballot, breaking the quorum intersection guarantee!
])

=== Step 3: Value Selection

The candidate waits for a quorum of complete promise replies. Once it has a quorum, it examines the replies:

+   *If no acceptor has ever accepted a value*: The candidate is free to propose its own client value (e.g., `olive = 7`).
+   *If any acceptor has accepted a value*: The candidate is *forced* to select the value associated with the highest accepted ballot number reported in the replies.

The candidate is now the prepared leader. It can proceed to Phase Two.

== Phase two: Proposing and Voting

Now that the leader knows what was chosen in the past, it can safely write the future.

=== Step 4: Accept

The leader broadcasts its proposal to all acceptors:

```text
accept { ballot, slot, value }
```

=== Step 5: Accepted

When an acceptor receives the `accept` message with ballot $B$ and value $V$, it checks its promise one more time. Why? Because another candidate might have campaigned in the split second between Phase One and Phase Two!

*   *If $B < P_("max")$*: The acceptor rejects the vote and replies with a `nack`.
*   *If $B >= P_("max")$*: The acceptor accepts the vote. It writes the accepted ballot and value to disk durably:
    $ "accepted_ballot" = B, quad "accepted_value" = V $
    Once the write is synced, it replies to the leader:
    ```text
    accepted { ballot, slot }
    ```

=== Step 6: Commit

When the leader collects a quorum of `accepted` votes for its ballot and slot, the value is *chosen*. The leader writes the commit to its local ledger and broadcasts a `commit` message to all nodes (who act as learners):

```text
commit { slot, value }
```

Upon receiving `commit`, the learners safely apply the value to their state machines.

== Local acceptance optimization

A leader node is also an acceptor. In our Zig library, we optimize this by writing the leader's own vote directly to its local disk without sending a network loopback packet to itself:

```zig
self.durable.promised = self.ballot;
self.durable.accepted[index] = .{
    .ballot = self.ballot,
    .value = value,
};
effects.addWrite(.{ .accept = .{
    .ballot = self.ballot,
    .slot = slot,
    .value = value,
} });
```

This local write count as the first vote in our quorum, meaning a three-node leader only needs one remote peer to respond to reach a majority of two!

== A complete trace

Let us watch this dance in action. Nodes 1, 2, and 3 start empty. Node 1 tries to propose `tea` using ballot `(1, 1)`.

#transcript((
  [1], [N1], [Chooses ballot `(1, 1)` and sends `prepare` to all nodes.],
  [2], [N1], [Writes promise `(1, 1)` to its own disk before replying locally.],
  [3], [N2], [Receives `prepare`, writes promise `(1, 1)` to disk, and replies with no past votes.],
  [4], [N1], [Collects promises from N1 and N2 (a quorum). No old value was reported.],
  [5], [N1], [Proposes `tea`. Writes acceptance of `tea` locally to disk.],
  [6], [N1], [Sends `accept` for `tea` to N2 and N3.],
  [7], [N2], [Checks promise, writes acceptance of `tea` to disk, and replies `accepted`.],
  [8], [N1], [Sees two acceptances (N1, N2). `tea` is officially chosen!],
  [9], [N1], [Writes `commit` to disk and broadcasts `commit` to N2 and N3.],
  [10], [All], [Learn the commit and feed `tea` to their state machines.],
))

== Rejection and competing campaigns

What happens if Node 2 tries to campaign with ballot `(2, 2)` while Node 1 is leading?

When Node 2 sends `prepare` with ballot `(2, 2)` to Node 1, Node 1 compares it with its own active ballot `(1, 1)`. Since `(2, 2) > (1, 1)`, Node 1 yields! It accepts the promise, updates its local `highest_observed_round` to round 2, and steps down to become a follower.

If Node 1 later tries to propose a value, the acceptors will reply with `nack`:

```text
nack { rejected = (1, 1), promised = (2, 2) }
```

This tells Node 1: *"Your ballot was rejected because I have already promised a higher ballot."* Node 1 updates its round and waits for its election timeout before trying again.

== Liveness and the dueling leaders

What if two nodes campaign back and forth endlessly?
- N1 prepares ballot `(1, 1)`. Acceptors promise `(1, 1)`.
- N2 prepares ballot `(2, 2)`. Acceptors promise `(2, 2)`.
- N1 tries to send `accept` for `(1, 1)` → Rejected (promised `(2, 2)`).
- N1 prepares ballot `(3, 1)`. Acceptors promise `(3, 1)`.
- N2 tries to send `accept` for `(2, 2)` → Rejected (promised `(3, 1)`).

This is a *liveness hazard* (dueling leaders). To resolve this, our library contains no internal timers or randomized election protocols; instead, it exposes the control of campaigns to the host application via ticks. The host can use randomized timeouts (like Raft) or a distinguished leader election lease to ensure only one proposer campaigns at a time.

== Crash points and recovery

Let us inspect what happens if a node crashes at any point in the trace.

#table(
  columns: (1.2fr, 1.2fr, 1.6fr),
  table.header([*Crash Point*], [*Disk State*], [*Recovery Behavior*]),
  [Before promise write completes], [Old promise.], [The prepare request is lost. The leader will retry.],
  [After promise write, before reply], [New promise.], [Leader prepares again. Acceptor replies with its saved promise.],
  [Before accept write completes], [No vote.], [The proposal is lost. The leader will retry.],
  [After accept write, before reply], [Vote is saved.], [A future leader's prepare phase will discover this vote.],
  [After quorum, before commit], [Votes are saved on quorum.], [A future leader is forced to recover and commit this value.],
)

This table shows the elegance of Paxos safety: *no matter where the power cord is pulled, the system recovers to a safe, consistent state.*

#exercise([8.1], [
  Look at Step 8 in the complete trace. If Node 1 crashes right after writing `commit` locally but before sending `commit` to Node 2 and Node 3, has `tea` been chosen? Can a future leader change the value in slot 1 to `coffee`?
])
