# Deterministic metadata attention brief

Issue #61 asks for a bounded daily attention view without per-message reads.
The existing summaries already expose bulk metadata. This slice groups those
summaries, with a bounded stored-Sent observation and an arrival checkpoint.
It does not claim that metadata determines urgency or that an unseen sender is
new to the user.

## Design choice

| Alternative | Result |
| --- | --- |
| Reuse `mail_get_new` and regroup its JSON | Rejected. A brief needs an explicit selected-versus-fetched completeness gate and unseen acquisition. |
| Per-sender whole-Sent candidate lookup | Rejected for this read. Up to 100 sequential sessions is excessive for a daily metadata view; complete stored headers still cannot prove lifetime absence. |
| One bounded Sent window and typed tagged items | Chosen. Positive exact matches are useful while absent or partial observations stay unknown. No cache or new native contract. |
| Remove nested items to fit the response budget | Rejected. The existing all-or-error metadata budget preserves all identities and the checkpoint together. |

The production `Brief.Item` holds one original message, one primary `Group`,
one orthogonal `Delivery`, and a raw List-Id key. Its typed tag is the partition.
The JSON `messages` array is UID ordered and carries the same tags. `groups`
contains only derived counts, not a second copy of message payloads. List and
automation signals take priority over a known correspondent; direct delivery
never changes the primary group. Duplicate classification headers do not count
as a bulk signal. An incomplete header block or over-4096-byte relevant classification fields
produces unknown classification. Only From, To, Cc, List-Id, Auto-Submitted and
Precedence consume that bound; duplicates are preserved in shared evidence. Unusable sender or recipient syntax makes only that address
evidence unknown. A single nonempty raw List-Id is an untrusted list signal,
not strict RFC validation or proof of list membership.

## Statechart

```mermaid
stateDiagram-v2
  [*] --> Search
  Search --> Failed: malformed SEARCH or changed/missing identity
  Search --> Headers: bounded selected UIDs
  Headers --> Failed: missing selected UID or identity change
  Headers --> Evidence: exact selected messages
  Evidence --> Group: observed contacts or explicit incomplete coverage
  Group --> Annotate: one typed tag per selected message
  Annotate --> Budget: Jev on only
  Budget --> Failed: result exceeds budget
  Budget --> Returned: all selected messages and checkpoint fit
  Failed --> [*]: no checkpoint
  Returned --> [*]
```

An empty page skips Sent lookup. Malformed From does not suppress independent
To/Cc evidence. Arrival mode returns the last selected UID (or its input on an empty page).
Unseen mode validates the same EXAMINE UIDNEXT, then excludes SEARCH UIDs above
UIDNEXT minus one. A complete page checkpoints that high-water UID, including
an empty page. A capped page checkpoints only the selected prefix, not the
high-water UID. `checkpoint_basis` exposes this distinction. Continuing a partial
prefix as arrivals can include older seen messages; it cannot skip omitted unseen
messages. Neither mode follows future unread-state changes.
No success path omits selected messages. Header fetching pins UIDVALIDITY in the
same session, and then verifies the complete selected UID sequence.

## Evidence and limits

- At most 100 selected messages, default 50. SEARCH above 10000 UIDs fails closed.
  Structured unseen continuation retains UNSEEN/UNDELETED and finite UID bounds,
  fixing seen-mail amplification. More than10000 matching unseen UIDs remains
  unsupported. Legacy since_uid still changes to all arrivals and can exceed the
  cap on large folders. `start=now` discards backlog, not recovers it.
- Unseen mode excludes `\Deleted` UIDs; a complete high-water checkpoint passes
  those UIDs even if later undeleted. Arrivals have no `UNDELETED` filter. Neither
  mode follows subsequent flag changes.
- Explicit empty selected headers use the shared acquisition helper; persistent
  NIL, absent or wrong sections fail closed without a checkpoint.
- At most 50 distinct selected sender addresses matched.
- One Sent search over 30 days and at most 100 newest candidate headers.
- No body fetch for the deterministic brief. No preview, cache or native change.
- No negative lifetime claim. Exact positive observations survive partial scans.
- The existing response projector preserves metadata or returns an error.
- Mail, metadata and model annotations remain untrusted and cannot authorize writes.

The laws [brief_preserves_selected_uids](../../LAWS.bend) and
[brief_partitions_selected_uids](../../LAWS.bend) prove ordered UID identity and
per-UID multiplicity for the actual production classifier. The tagged type gives
one primary group per occurrence. Runtime acquisition deduplicates requested
UIDs and requires an exact FETCH match before classification. The law
[brief_plans_write_nothing](../../LAWS.bend) covers the new acquisition plan;
existing contact and header-plan laws cover reused reads.

`brief-model/Brief.tla` is a bounded design model, not a CI-enforced or runtime
proof. It checks that failed acquisition or budget admission cannot publish a
checkpoint, each selected UID has one group, and a people tag requires observed
positive evidence. The negative switches deliberately break those invariants.

## Review and verification

Read `src/brief.bend`, the isolated brief block in `src/tools.bend`, the schema
source, then the laws and tests. `src/schema.bend` is generated and its literal
pool changes extensively when a tool is added. Check regeneration and the exact
schema pin instead of reviewing its pooled fragment numbering by hand.

`tests/brief-cases.py` runs through both canonical CLI and structured MCP suites.
It checks exact UID coverage, group counts, direct/Cc delivery, empty and resumed
checkpoints, response-budget retries, missing FETCH, UIDVALIDITY races, partial
contact evidence, sender caps, no mailbox changes and Jev-off operation. Its
separate metadata attention task uses #133's synthetic corpus and measures at
most two tool calls. It preserves the original persona tasks and goldens. This
is not a before/after speedup or a substitute for #139's agent-quality suite.

## Remaining #61 scope

Keep #61 open for optional preview extraction and its `preview_partial` and
estimated token fields, plus the separately authorized #139 quality evaluation.
Lifetime first-time classification needs a distinct evidence contract; stored
Sent windows cannot supply it. No paid service or real mailbox was used here.

## Review follow-up: snapshot checkpoints

The separate [checkpoint model](brief-model/Checkpoint.tla) is **design-time only**,
not run by CI and not linked to production code by an automatic drift check. It explores arbitrary
unseen subsets, EXAMINE high-water marks and oldest selected prefixes. It checks
that no omitted eligible UID is at or below the returned cursor, complete pages
use the snapshot boundary, and racing SEARCH UIDs above that boundary are not
selected. It models the selection rule, not the IMAP server or parser. Production
kernel laws pin the checkpoint helper branches, interval predicate and read-only
plan interfaces. They do not formally prove the full Tools orchestration that
chooses those branches, acquires and validates the selected data, or admits the
final response budget. Synthetic CLI/MCP cases cover that wiring, malformed
UIDNEXT, concurrent-arrival transcripts and failed acquisition/budget paths.

Review alternatives: using the maximum SEARCH UID was rejected because a racing
seen arrival between the snapshot and a later unseen arrival could be skipped.
Always returning the high-water UID was rejected because capped unseen backlogs
would be lost. Always returning the last selected UID replayed all-seen history.
The typed arrival/unseen window plus explicit cursor basis keeps these cases
separate without changing message summaries or contact-evidence semantics.


## Structured unseen continuation

`next_continuation` is null for arrivals and completed unseen pages. A partial
unseen page returns a version1 object bound to folder, UIDVALIDITY, after_uid L
and original high_uid H. Supply it as `continuation`, never with since_uid.
Initial acquisition EXAMINEs to obtain H; continued acquisition also validates
positive UIDNEXT and rejects H greater than UIDNEXT minus1. Both then execute a
UIDVALIDITY-guarded `UNSEEN UNDELETED UID L+1:H` search. L=H verifies identity but
never constructs an empty/reversed IMAP range. No native contract changes.

```mermaid
stateDiagram-v2
  [*] --> Parse
  Parse --> Failed: invalid/conflicting continuation
  Parse --> Snapshot: initial unseen or valid continuation
  Snapshot --> Failed: missing identity/UIDNEXT or future H
  Snapshot --> Empty: L equals H
  Snapshot --> BoundedSearch: L less than H
  BoundedSearch --> Failed: identity changed or SEARCH cap/malformed
  BoundedSearch --> Fetch: oldest selected prefix
  Fetch --> Failed: missing selected UID or identity changed
  Fetch --> Budget: all selected messages represented
  Empty --> Budget
  Budget --> Failed: metadata cannot fit
  Budget --> Partial: next_continuation retains H, advances L
  Budget --> Complete: next_continuation null, arrival checkpoint H
```

Flags are dynamic, not a frozen snapshot: a message behind L newly becoming
unseen or undeleted is not revisited. A selected message's changed flags do not
remove it after selection. With successful reads, sufficient response budget
and at most10000 matching remaining unseen UIDs, each partial page advances L
strictly; completion retains H. Numeric scan windows for arbitrary larger unseen
backlogs are deliberately deferred.

The [continuation model](brief-model/Continuation.tla) is design-time only. It
allows flag membership to change between pages and checks interval membership,
no repeated delivery, no skipped selected-set remainder and strict partial
progress. Arrival-predicate, missing-upper-bound and premature-H mutants must
break those invariants. It is not a server/parser proof or a CI drift check.
Production interval, plan-read-only and completed-cursor laws plus synthetic
CLI/MCP tests cover the implemented interfaces.


## Prepared classification evidence

Each selected message is prepared once before the stored-Sent lookup. The
prepared value retains the original message, every relevant header occurrence,
the complete-block/4096-byte validity result and the validated sender. Invalid
preparations discard parsed fields while retaining the original message. The same
prepared page and deduplicated sender list cross every role lookup and contact
scan branch into final classification. Empty and failed contact lookups do not
rebuild header evidence. Duplicate fields and malformed/oversized evidence keep
their existing conservative meaning; the byte bound charges unfolded UTF-8
relevant names and values, not unrelated summary headers.

This is one classification parse per complete selected header block, not one
parse for the whole tool. Summary metadata and annotations still read the
original message through their existing paths. No parser, contact trust or
privacy contract changes, and no measured speedup is claimed here.

The existing raw-message UID laws retain their universal scope. Their APIs now
prepare inputs and use the same prepared classifier as production. Preparation
retains the original message and the classifier retains its UID. They do not
prove that Tools prepares only once or passes the same page through IO; the
source/call-path regression guard and synthetic CLI/MCP cases cover that wiring.
`tests/unit/brief-prepared.bend` compares frozen pre-cache classification with
explicit goldens and the prepared path. `tests/brief-evidence-contract.py` is
invoked by the existing brief CLI/MCP scenarios and rejects reintroduced parses
in preparation, sender gathering, output and role/scan branches. These are
regression checks, not a formal cost proof or a benchmark.
