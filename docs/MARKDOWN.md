# Markdown composition core

This private source packet is an intermediate part of [issue #106](https://github.com/albertc71/MailBend/issues/106).
It does not enable Markdown on any tool. No compiler, proof checker, parser,
test, or workflow has run against these files.

## Implemented source API

`src/markdown.bend` contains pure functions and data types. It performs no IO.

`SourceBody` has two constructors.

- `TextBody{plain}` retains the legacy combined string.
- `MarkdownBody{caller, suffix}` retains the original caller and the exact
  generated reply or forward suffix as separate strings.

`plain(body)` returns the text string unchanged or `caller ++ suffix`.
It performs no stripping, Unicode filtering, line conversion, or Markdown
interpretation. Source provenance comes from these separate fields, never
from offsets inferred after concatenation.

The future composition preparation step must compute this projection once
and retain it for existing checks and plain MIME serialization. This packet
does not introduce a second independently mutable plain copy.

`escape_data(source, room)` returns
`Result<&2, &2, Error, Fragment>`. A successful
`Fragment{html, remaining}` contains the complete escaped data and the
unused UTF-8 byte budget. The starting budget is
`min(room, 4194304)`. `room` is an internal pure-function argument, not a
tool argument, setting, or environment variable.

The escaper maps exactly these characters.

- `&` becomes `&amp;`.
- `<` becomes `&lt;`.
- `>` becomes `&gt;`.
- Double quote becomes `&quot;`.
- Single quote becomes `&#39;`.

Every other character is retained. Existing entity spelling is ordinary
data, so `&lt;` becomes `&amp;lt;`. CR, LF, TAB, and Unicode are not
normalized here. Source-byte and control admission belong before rendering
and are not implemented by this low-level escaper.

Each escaped scalar forms one bounded chunk. The code measures that chunk
through the existing UTF-8 encoder before adding it to the reversed output
list. It uses `Nat` arithmetic and subtracts only after the comparison.
One reversal and join produce the complete fragment. A refusal returns
`Fail{OutputLimit{}}` with no prefix or alternate result.

`render_suffix(suffix, room)` uses the same result type and budget.
An empty suffix produces an empty fragment. A nonempty suffix produces
`<blockquote><pre>`, escaped data, and `</pre></blockquote>`.
The fixed tags cost 36 UTF-8 bytes, reserved before escaping. The suffix
never enters a Markdown scanner. The API returns its unused budget so the
future caller renderer and suffix can share one total HTML allowance.

Neither successful helper result is an admitted Markdown message.
The `Fragment` type is not an authorization or safety-policy token.
These helpers are intentionally not connected to a transport.

## Single-line caller API

Revision 3 adds `render_inline_line(source, room, events)`. It accepts one
complete caller line and returns `Result<&2, &2, Error, Inline>`.
`Inline{html, remaining, events_left, anchors}` contains no paragraph or
other block wrapper. This is an internal inline interface, not a partial
implementation of a public Markdown composition tool.

The entry checks at most 262,144 UTF-8 bytes before parsing. It rejects
NUL, disallowed C0 controls, C1 controls, invalid Unicode scalar values,
and CR or LF in this single-line interface. Input-limit refusal precedes
control, scalar, or multiline refusal. TAB remains valid. DEL is not
part of the additional C0/C1 rule. Existing hidden-Unicode checks still
belong to the later tool and whole-body admission path.

Empty input or a line containing only ASCII spaces and TAB emits nothing
and consumes no structure event. Every other line consumes one event.
Each opening maximal star run, backtick run, bracket candidate, or image
candidate consumes one further event before token processing.
The supplied event allowance is capped at 65,536. Exhaustion returns
`StructureLimit` with no partial HTML.

Supported inline forms are single-backtick code, single-star emphasis,
double-star strong text, and explicit links. Code and label content are
escaped without nested scanning. The first subsequent maximal matching
delimiter run ends a code or emphasis candidate, even when its width or
interior makes the candidate invalid. An invalid candidate is emitted
literally as one consumed span. Runs too long to open a candidate are
consumed as one literal run.

Bracket candidates stop at the first closing bracket and, only when it is
immediately followed by an opening parenthesis, the first closing
parenthesis. A missing label close, immediate opening parenthesis, or
closing parenthesis consumes the rest of the line literally. A complete
candidate with an invalid label ends at its first closing parenthesis.
Images always remain literal.
An overlong URL does not shorten the candidate. Backslash and its next
scalar are retained as one literal pair.

`valid_destination(source)` implements the reviewed URL subset described
below. It performs no lookup or normalization. The 2,048-byte
printable-ASCII gate precedes scheme parsing. Host-label, host-total, local-part,
port-digit, port-value, and tail checks remain independent conditions.
The port accumulator uses `Nat` and stops after five digits.

Each `Anchor{source_start, source_end, html_start, html_end}` records
half-open scalar ranges. Source coordinates index the exact complete line
passed to this API. HTML coordinates index the actual returned string's
escaped href value, excluding its surrounding quotes. They are not UTF-8
byte offsets, wire offsets, or offsets into a normalized source.
The serializer constructs the href and its recorded range from the same
escaped destination. Unicode before a link and entity expansion inside
its href are covered by a literal coordinate fixture.

The scanner buffers at most one pending candidate. It never reintroduces
a consumed span into its remaining input. An outer fuel counter starts
at the admitted source's scalar count. Each successful iteration consumes
at least one scalar. Exhausted fuel with remaining source returns
`ParserInvariant`, not partial output or a fallback. That refusal is
intended to be unreachable and has an open proof obligation.

Escaping and trusted inline tags use one decreasing HTML allowance.
Code reserves 13 bytes, emphasis 9, strong text 17, and an anchor 15
before escaping their variable content. Chunks and anchor records are
stored in reverse and joined or reversed once. Growing HTML is not
repeatedly concatenated. Scalar-length counters add each new chunk's
length to the existing count, with the smaller chunk operand first.

### Proposed whitespace clarification

The reviewed design did not define "non-whitespace scalar" at emphasis
endpoints. For this packet, the coordinator authorized a proposed
clarification for independent review, not a retroactive claim about
design revision 2.

The set is Unicode 17.0.0 `White_Space` from
[PropList.txt](https://github.com/unicode-org/unicodetools/blob/48afe632bf194a20bcd27c3488b49dc23274b684/unicodetools/data/ucd/17.0.0/PropList.txt),
blob `e64b4224d7271c8463b4c5f80fd6e9dbb5865fbb`.
It contains U+0009 through U+000D, U+0020, U+0085, U+00A0, U+1680,
U+2000 through U+200A, U+2028, U+2029, U+202F, U+205F, and U+3000.
The implementation enumerates these scalars directly.

Whitespace at either emphasis endpoint makes the complete candidate
literal. It does not introduce a new refusal. Existing caller admission
still rejects disallowed controls, including U+0085. This clarification
changes neither ASCII blank-line rules nor the printable-ASCII URL grammar.
Its acceptance remains part of the retained review's next verdict.

### Remaining renderer boundary

The block parser, multiline view, and whole-source provenance adapter
remain absent. The single-line API never receives a suffix.
Full block integration must retain original caller coordinates while
removing only the recognized block prefixes from the inline view.
It must charge each source line once, preserve fence event rules, translate
href coordinates into the complete HTML, and share one HTML/event budget.
Calling this entry separately on each line and resetting its allowances
would violate that contract.

The inline helpers do not certify a complete source body. In particular,
the combined caller/suffix cap, suffix control admission, existing hidden
checks, and tool construction of caller/suffix provenance remain pending.


## Source fixtures and candidate laws

`tests/unit/markdown.bend` uses literal expected strings through the pure
projection, escaping, suffix, URL, and inline interfaces. The initial fixture
groups were written before their corresponding implementation. Later
boundary fixtures and observer controls extend that coverage. The tests have not run,
so no red-to-green execution or passed behavior is claimed.

The fixtures cover exact line endings and Unicode, all five escapes,
entity-shaped source, empty input, complete rejection after a partial
internal prefix, UTF-8 rather than character budgets, the fixed suffix
wrapper, and a suffix containing link or hostile HTML syntax.

`tests/formal/markdown-core-observers.bend` recognizes the escaped-fragment
language independently. It accepts safe literal characters and exactly the
five complete entities. It rejects raw markup punctuation, bare ampersands,
unknown entities, and unfinished entities. It does not call the production
escaper to generate an expected result.

The projection equalities and finite observer examples contain proposed
computation proofs. They have not been kernel checked. These universal laws
are declared and deliberately left open.

- `escape_language` states that every successful escaped output belongs
  to the independent fragment language.
- `escape_byte_accounting` and `suffix_byte_accounting` state that the
  actual UTF-8 output size plus remaining budget equals the initial capped
  budget.
- `suffix_no_anchor` observes actual returned HTML for generated anchor
  syntax.
- `suffix_language` requires an empty result or the exact fixed wrapper
  around a fragment accepted by the independent data-language observer.
- `fragment_concatenation` states closure of the independent language.

The failure branch makes these admission laws conditional on success.
Nonempty accepted fixtures separately exclude a useless always-refuse
implementation. Those finite fixtures do not prove any universal law.

Universal proof feasibility is untested on Bend 2.0.35. The open laws are
evidence work, not waived obligations. No shared law catalogue or aggregate
proof file has changed.

Revision 3 retains all six open core laws and adds eight open obligations.
They cover actual href provenance, inline byte accounting, admitted URL
shape and the complete independent URL grammar, contiguous token progress,
sufficient scanner fuel, exact source-event counts, and single-line source
admission. None has been kernel checked.

The independent HTML observer accepts only escaped data and the fixed
inline tags in their permitted nonnested positions. It decodes href data
once, records actual output ranges, and requires a one-to-one match with
all reported source ranges. An anchor with missing metadata, extra
attributes, a wrong source slice, or a nested tag fails that observer.
It shares neither the production tokenizer nor its HTML serializer.

The event observer consumes delimiter and bracket endpoints without
producing markup or calling the production tokenizer. The URL observer
uses split labels, endpoint checks, and a separate port interpretation,
rather than the production host-state counters. Observers remain code
that requires its own source review and negative controls.

There are 71 unexecuted unit assertions. They include exact caller and
event limits, UTF-8 boundaries, 2,048/2,049-byte URLs, host and local-part
length bounds, the reviewed malformed-token examples, and actual href
coordinates. The full-size fixtures are proposed resource observations,
not evidence that those sizes run within a particular time or memory bound.

## Required integrated contract

The rest of this section records the integrated contract. The inline and
URL subset above exists only at its pure single-line interface. Tool,
block-parser, MIME, and delivery integration are not enabled by this packet.

The four tools are `mail_send`, `mail_save_draft`, `mail_reply`, and
`mail_forward`. Optional `format` accepts exactly `text` or `markdown`.
Missing format means text. Null, other types, padding, empty values, and
other casing fail. Format validation precedes attachment reads and original
fetch, while existing outer policy refusal keeps its precedence.

Missing format and explicit text must select the unchanged legacy
`M.compose` path with byte-identical results at fixed inputs and stamp.
The existing plain projection remains the sole body input to hidden-Unicode
checks, local scanning, Jev's current bounded text selection, and plain
serialization. Jev headers mode gains no body. No rendered HTML is disclosed
to TypeSafe.

Reply and forward construction must preserve the existing stripped suffix,
including separators, attribution, truncation markers, and read bounds.
A forwarded original remains an attachment. No suffix or attachment enters
the caller Markdown scanner.

### Block grammar remains pending

The reviewed subset has column-zero headings of levels one through six,
flat `- ` and `1. ` lists, one-level `> ` quotes, ordinary paragraphs,
and fences consisting of exactly three backticks. Fence content is escaped
code. An unclosed fence and all following content form one literal
`pre` block. Logical CR, LF, and CRLF become LF only in the caller's HTML
presentation. The retained plain source is unchanged.

Inline productions are single-backtick code, restricted single-star
emphasis, restricted double-star strong text, and explicit links.
No production rescans its interior. Maximal delimiter runs and first-close
bracket endpoints determine complete consumed spans, including failed
candidates. Images remain literal and cannot expose an inner anchor.
Incomplete brackets consume the remainder of their logical line.
Backslash and the next scalar remain one literal pair.

The structure limit counts source events, not allocated records.
Every nonblank non-fence line costs one. A whole recognized or unclosed
fenced region costs one. Every inline opening star run, backtick run,
bracket candidate, or image candidate costs one, including failures.
Consumed interiors and closing runs cost nothing extra. Blank lines,
ordinary text, backslash pairs, and all suffix content cost no structure
units. The 65,537th event refuses the request.

Links admit only exact lowercase `http://`, `https://`, or `mailto:`
and printable ASCII destinations of at most 2,048 UTF-8 bytes.
HTTP hosts use nonempty 1-to-63-byte letter/digit/hyphen labels, with
letter/digit endpoints and total length at most 253 bytes. A single label
is allowed. All-numeric dotted hosts are rejected, but other numeric
spellings can remain admitted. This is not an IP or public-address policy.
Ports have 1 to 5 decimal digits and numeric value 1 through 65535.

An HTTP tail begins with slash, question mark, or hash and permits ASCII
letters, digits, and `-._~:/?&=+#,@!$`.
Mailto permits exactly one restricted dot-atom address, a local part of at
most 64 bytes, and the same host grammar. It rejects headers and query
strings. Percent signs, backslashes, Unicode destinations, whitespace,
controls, and userinfo are rejected. Destinations are not decoded or
normalized. Each actual href must decode once to its exact caller span.
These restrictions do not establish destination trust or prevent client
previews after delivery.

### Admission and delivery remain pending

The complete implementation must enforce these reviewed bounds.

- Caller UTF-8 source is at most 262,144 bytes.
- Escaped-only suffix UTF-8 source is at most 262,144 bytes.
- Combined plain projection is at most 524,288 UTF-8 bytes.
- Structure events are at most 65,536.
- Complete HTML, including all tags, is at most 4,194,304 UTF-8 bytes.
- The encoded MIME body and each complete message variant are each at
  most 67,108,864 bytes.
- Actual SMTP helper input and selected APPEND script are each strictly
  smaller than 67,108,864 UTF-8 bytes.
- Boundary selection examines at most 16 candidate pairs.

Markdown admission rejects NUL, disallowed C0 controls, and C1 controls in
both caller and suffix, while preserving existing hidden-Unicode checks.
The low-level helper's ability to escape arbitrary input does not replace
these checks. All limits refuse rather than truncate or fall back to text.

Markdown MIME contains plain first and HTML second in one alternative.
Attachments produce mixed with that alternative first, followed by the
unchanged attachments. The plain child uses the existing text encoder.
The prepared MIME body is retained and reused for SMTP, drafts, and Sent
copy, with the existing Bcc header differences.

Candidate boundaries use the reviewed `mb106-a-` and `mb106-m-` roles
and indices 00 through 0f. Collision checks inspect actual encoded child
headers and physical lines, including lines created by quoted-printable
soft wrapping. The existing raw-message attachment fallback remains.
Exhaustion reports size failure if any collision-free pair was oversized.
It reports boundary failure if every pair collided. Transport refusal is
terminal and does not restart the candidate search.

Only `Jev.outbound_checked` can produce the SMTP envelope.
Markdown-only transport preflight measures that exact envelope, including
dot stuffing, before reservation. When Sent saving is enabled, earlier
read-only role discovery retains the selected folder and admitted APPEND
plan. Discovery failure retains optional-copy failure semantics rather
than vetoing a send. Drafts preflight the selected draft APPEND plan.
Text-mode discovery timing stays unchanged.

The fresh reservation clock and one daily reservation remain after
applicable admission and existing gates. Dry runs do not reserve, send,
APPEND, or mark. SMTP acceptance remains acceptance even if Sent copy
fails. Reply marking remains post-acceptance. No new helper, setting,
gate policy, mailbox creation, send authority, or recipient policy is added.

## Proposed feasibility campaign

This is a proposal for a later, separately authorized campaign. It grants
no compiler, test, scanner, kernel, process, workflow, or network execution
now. The frozen source packet and the retained source review are not
runtime admission.

The first syntax attempt uses the pinned Bend 2.0.35 source and the
current repository contracts in one isolated, credential-free copy.
The four packet files are overlaid only after their hashes match the
reviewed manifest. Existing compiler, codec, and test-runner inputs stay
pinned. No current shared checkout or old process is reused.

The proposed order is:

1. Check the production module, then compile the pure unit module once.
   Record syntax, name resolution, affine-use, and termination failures
   separately. A proposed ceiling is 120 seconds for each initial syntax
   attempt and five minutes for the unit compilation, with no automatic
   retry or increase. These ceilings are proposals, not observed timings.
2. Resolve one kernel goal at a time before an aggregate verdict.
   The six core obligations remain first. Prove scalar escaping and
   concatenation, reversed-chunk preservation, UTF-8 length addition, and
   fixed-wrapper accounting. The formal file deliberately has open laws.
   Their absence is not a parser failure, and removing them is not a pass.
3. Prove every candidate helper consumes a contiguous prefix and preserves
   its returned suffix and scalar position. Relate those facts to the
   decreasing outer fuel. Prove exact independent event counts for maximal
   runs, failed candidates, images, and backslash pairs.
4. Relate the URL counter state to the independent split-label grammar.
   Cover host endpoints, empty labels, total and per-label caps, numeric
   dotted hosts, bounded decimal ports, and mailto local/domain separation.
   The simpler forbidden-scheme/percent/backslash law does not replace
   this full-grammar goal.
5. Prove token emission against the independent HTML mode observer.
   Establish one-pass entity decoding and the actual href/source-slice
   equality, including a one-to-one match of all emitted anchors.
   Prove byte conservation over each trusted wrapper and reverse chunk
   accumulation. Then address source admission and parser-fuel sufficiency.
6. Run the 71 literal assertions only after syntax and source disposition
   permit it. Run the observer controls and targeted mutants separately.
   A timeout, missing import, unrelated type error, or missing proof is
   inconclusive, not a successful negative control.
7. Repeat the accepted focused campaign on native x86-64 and ARM64.
   Record exact source/toolchain identities, queue, build, check, and
   runtime durations separately. Preserve failed and incomplete evidence.

The proposed focused runtime ceiling remains 30 seconds per invocation
and ten minutes per architecture after build, with a 1 GiB runtime-process
target from the reviewed design. A later kernel feasibility campaign has
a proposed ten-minute total ceiling per architecture and a two-minute
ceiling per selected goal. Existing owned-descendant cleanup must apply.
No uncertain process is inspected or killed under this source assignment.
A ceiling failure requires a new disposition, never an automatic increase.

Initial negative controls should independently alter ampersand escaping,
the whole closing-run consumption, image endpoint consumption, an href
source offset, an href output offset, URL percent acceptance, numeric
dotted-host acceptance, the first line charge, and the fixed anchor-byte
overhead. Each control must fail its intended assertion or named law.

### Resource questions remain open

The source algorithms use forward cursors and bounded candidate buffers.
That is not an observed CPU or memory bound. A long literal line creates
one top-level chunk per scalar. Pending candidates can retain raw and
component buffers at once. Escaping, chunk reversal, output joining,
source copies, and proof normalization have different allocation costs.

The proposed maximum-size observations include 262,144 UTF-8 bytes of
multibyte text, the one-byte-over-limit input, 65,536 total source events,
and the 65,537th event refusal. The exact-event fixture has 65,535
`*x* ` tokens and one nonblank-line event. Its literal expected output
size is 720,885 bytes. The next-token fixture reaches the source cap
without exceeding it, so a structure failure cannot be explained by an
earlier input-size rejection.

For output-size behavior, small internal allowances exercise reachable
exact-fit and one-byte-short cases. The 4,194,304-byte global allowance
clamp is also checked with empty input. This does not claim a single-line
caller can reach every full HTML-cap boundary under the smaller source
cap. That reachability needs a separate bound before a full-limit fixture
is claimed. No memory or throughput result is inferred from these counts.

Proof practicality also remains open. The new independent observers are
larger than the renderer's first packet. Their finite examples must be
checked before they can support the universal goals. The observer uses
the existing UTF-8 encoder for byte lengths and the production URL
validator only to tie actual hrefs to admission. The separate URL grammar
law must justify that validator. Neither shared component is silently
treated as an independent implementation.


## Next gate

Retained independent source, security, data-integrity, resource, and test
review of this frozen packet precedes further expansion. It must assess
the proposed Unicode whitespace clarification explicitly.
Shared-file handoff precedes MIME and
tool integration. Kernel proofs, bounded hosted fixtures on both
architectures, mutation controls, independent MIME checks, and complete
CLI and MCP coverage remain required before release readiness.

This packet is not a renderer-only completion of issue #106, a runnable
validation result, a PR, or merge approval.

