# Image-round reply parsing

A cached image round shares one IMAP reply across at most four slots. Before
this change, each slot called `part_bytes` and repeated the metadata parser
and the section tokenizer over the same reply.

`I.frame` already separates literal payloads from response syntax.
`I.tokens` traverses the syntax and attaches each literal as a value without
walking its bytes. The concern in [the #282 review](https://github.com/albertc71/MailBend/pull/282#discussion_r4475449979)
therefore applies to repeated syntax and metadata work. It does not imply
that every slot tokenizes every image byte.

The prepared reply retains both parsers. Their response-recognition rules
are different, so merging them would change malformed-input behavior. Each
parser runs once per round. Each slot still checks its UID, current section
metadata, exact section and partial origin, and complete transfer decoding.
The mailbox identity is checked once before preparing the round.

## Reproduce the local comparison

Use clean baseline and candidate worktrees and the pinned Bend compiler with
Clang available. The script builds each probe with `bend -o`, as the normal
installer builds the core. It does not build or time a full mail operation.

```sh
git worktree add --detach ../mailbend-before-image-cache edbcfb0d93ff990f77aa805a2fc8ac8fbaa80081
python3 tests/compare-image-replies.py \
  --baseline ../mailbend-before-image-cache \
  --output build/image-replies.json
```

The baseline calls its real `part_bytes` entry point for each of four slots.
The candidate prepares the reply once inside each round, then consumes all
four slots. Both compile the same fixture, loop and output consumer. The
script rejects tracked source changes and reports source, probe and binary
hashes. It alternates the leading side across five pairs and checks every
output byte count. A failed process or a wrong count aborts the comparison.

The fixtures contain four UIDs, either one leaf or a multipart structure
with 127 leaves per UID, and either 1 or 100,000 raw bytes per slot. The
multipart structure reaches the parser's 128-node budget including its root.
Payloads use 7bit transfer encoding so the measurement isolates selected-read
work rather than base64 or PNG validation. These are synthetic bytes, not
valid image files. UID and byte identity are covered separately by the unit
and fake-server tests.

Timed work includes process startup, fixture construction, repeated selected
reads and consumption of every returned byte. Compilation is outside the
interval. CPU accounting identifies CPU-bound samples. It does not attribute
time to a specific source line. The script does not measure TLS, IMAP framing,
image validation, quota admission, TypeSafe transport or a provider's latency.
A gap smaller than the sample ranges is inconclusive.

## End-to-end evidence

The paired scale workflow separately exercises compiled public calls with
fixed fake servers, including `classify-images-50`. Its reference is the
reviewed immutable scale anchor, not this change's parent. It checks the
candidate as a whole and cannot isolate this cache's contribution from other
changes since the anchor. The image-path source files now trigger that
workflow. Its baseline, workload, deadlines and acceptance bounds are unchanged.

The new selected-reply tests use fixed expected strings. Local negative
controls that substitute the wrong UID, choose the last section response,
or bypass metadata comparison each produce wrong output. Existing image-round
end-to-end cases retain exact assets, per-message sections, quotas, stale
identity, changed metadata, removed messages and cut-literal coverage.
