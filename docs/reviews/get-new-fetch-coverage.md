# Arrival checkpoint FETCH coverage

A polling client must not save a cursor past a selected message that was
not returned. The SEARCH and FETCH sessions can differ. A successful tagged
FETCH response alone does not prove that all selected header data arrived.

```mermaid
stateDiagram-v2
    [*] --> Search
    Search --> Reset: UIDVALIDITY changed
    Search --> Unchanged: no selected UIDs
    Search --> Fetch: bounded selected UIDs
    Fetch --> Error: transport or protocol failure
    Fetch --> Reset: UIDVALIDITY changed
    Fetch --> Error: any selected UID lacks header data or returns NIL
    Fetch --> Publish: every selected UID has header data, including empty strings
    Error --> Search: retry the original checkpoint
    Publish --> [*]
    Unchanged --> [*]
    Reset --> [*]
```

The new gate runs after the existing UIDVALIDITY check. It uses the existing
normalized FETCH list, which excludes unsolicited UIDs and headerless flag
updates, sorts by UID and deduplicates responses. Any missing selected UID
returns an error without messages or a new cursor. Explicit empty strings
are represented, but NIL remains absent data. It does not manufacture a
partial success. A retry performs SEARCH again. A message expunged between
sessions therefore no longer needs to be fetched on that retry.

Review the small gate in `src/tools.bend` first. The existing `msg_uids`
helper only moves earlier so the gate can use it. No plans, native helpers,
response byte budgets, limits, or command permissions change.

The focused Bend regression exercises missing middle and tail UIDs,
headerless updates, duplicate and reordered responses, unsolicited UIDs, and
UIDVALIDITY reset precedence. Before the fix the missing cases returned
`next_since_uid: 9`. The CLI and MCP scenario uses the existing fake server
to omit first, middle and last selected header data, then retries the same
cursor with complete data. It also checks read-only commands and state.


The follow-up keeps the normal nonempty response path intact. Its additive
empty-string parser requires a completed tokenizer state and an untagged FETCH with one positive
UID and one exact, unpartial requested HEADER.FIELDS item. Duplicate UID or
header items and unfinished strings or lists do not establish coverage. A nonempty
response wins over an empty duplicate for the same UID.

Persistent omission and NIL remain errors. This intentionally prevents a
cursor from skipping unrepresented messages. The caller-visible retry limits
are documented in README's polling section. The e2e regression retries the
same persistent omission and separately removes the missing UID before retry.
It also exercises explicit empty literal and quoted forms through CLI and MCP.
