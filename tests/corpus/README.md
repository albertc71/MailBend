# MIME corpus

These are original synthetic messages under the repository's [MIT license](../../LICENSE).
No fixture was exported from a mailbox or copied from a third-party corpus.
Addresses use reserved example domains. Client names describe synthetic MIME layouts,
not messages emitted or verified by those clients. Stalwart's samples are not vendored;
their provenance and license were not established for this change.

Each `.eml` has a same-named JSON file with its provenance, primary references and
literal expected `mail_get` projection. The expected values were written from the
input and documented contracts, not recorded from MailBend output. There is no
record-or-update mode. Review every expected-value change with the fixture bytes.

## Outcomes

- `conformant` checks a valid message against the stated reading contract,
  which can include an explicit interoperability mapping rather than an RFC rule.
- `recovery` checks deliberate behavior for malformed input. It does not certify
  that the input is valid or that other parsers must recover identically.
- `known_unsupported` checks a current regression pin and retains the desired
  result separately. The runner prints an explicit diagnostic, never a conformance
  pass. A drift, including newly correct behavior, fails until the pin is reviewed.

`latin1-windows1252` pins the WHATWG label mapping: `iso-8859-1` is read as
windows-1252, so byte 0x92 becomes U+2019. Strict ISO-8859-1 instead maps it to
U+0092. This expectation does not claim RFC charset conformance.

The legacy charset diagnostics link to [#135](https://github.com/albertc71/MailBend/issues/135).
They are test metadata. They do not claim that MailBend currently reports a charset
status. Flowed text is unsupported rendering, not an automatic RFC violation;
[RFC 3676 section 4](https://www.rfc-editor.org/rfc/rfc3676#section-4) permits a receiver
not to interpret it. The implicit `multipart/digest` default is a separate known
reading gap under [RFC 2046 section 5.1.5](https://www.rfc-editor.org/rfc/rfc2046#section-5.1.5).
A terminal quoted-printable `=` is malformed under [RFC 2045 §6.7](https://www.rfc-editor.org/rfc/rfc2045#section-6.7). The one-CRLF
`qp-final-soft-break` fixture pins recovery because [RFC 2046 §5.1.1](https://www.rfc-editor.org/rfc/rfc2046#section-5.1.1) assigns that CRLF to
the boundary; the `-complete` companion supplies a separate soft-break CRLF and
checks valid input. Selected-part acceptance does not certify wire validity.
Encoded words split mid-character or placed inside quotes are malformed under
[RFC 2047 section 5](https://www.rfc-editor.org/rfc/rfc2047#section-5).

`encoded-word-oversized-recovery` preserves the existing recovery for an encoded
word longer than RFC 2047 permits. It is a compatibility case, not a length-policy
change or a stack-depth test. `tests/unit/header-depth.bend` exercises the large
inputs with tail-safe fixtures and observers.

`html` is untrusted source content, not sanitized browser markup. The corpus reads
never render it or fetch any referenced resource. Decoded headers may also retain
untrusted controls in `mail_get`; reply scenarios separately check safe quoting.

## Run the checks

After `scripts/install.sh`, run `python3 tests/test-mime-corpus.py`. It checks every
fixture through the CLI and structured MCP against the local fake server. It also
exports every named unit composition to Python's independent
[`email` parser](https://docs.python.org/3/library/email.parser.html) with `policy.default`.
The ordinary CLI and MCP end-to-end suites audit every complete SMTP DATA and APPEND
message they receive, including rejected messages. A refusal before the server
receives a complete message produces no wire message to parse. Internally composed
messages discarded by a dry-run or later gate are not observable in this server capture;
only the named unit registry checks composition without transmission.

Headers, root media type and parameters, MIME leaf types, dispositions, charsets, decoded text, filenames and decoded
payload bytes must agree. An attached `message/rfc822` remains one attachment;
Python returns a nested object rather than decoded bytes, so nested raw header fields
and decoded payloads are compared without reserializing it as a byte oracle. Raw header
comparison preserves a hostile original's encoded controls: Python's structured address
constructor rejects decoded CR/LF, but forwarding must not rewrite the attached original.
A hostile-original positive control and two header/body mutations pin this boundary. This compares root and leaf semantics, not
every intermediate container inside arbitrary attached messages. Named composition inputs separately require
that the original attached-message bytes remain in the outer wire unchanged.

The unit composition registry retains the input Draft. Its headers, text, filenames
and attachment bytes are checked independently of MailBend's own readback. Existing
unit cases with synthetic dates such as `D` test byte preservation, not date validity.
Twelve deliberately broken observations verify that the comparator rejects disagreements.
Fifteen independently corrupted wire messages verify that the Draft comparison rejects
shared parser agreement on the wrong output. Three literal-filename mutations
separately reject a wrong fallback, changed filename bytes, or quoted encoded-word-looking
output instead of the extended form.

MailBend emits RFC 2231 filename continuations before the unchanged ASCII fallback.
This order lets Python `policy.default` retain the original Unicode or long ASCII
filename. Short plain ASCII names keep their existing quoted output unless they
look like encoded words. Encoded-word-looking names use literal RFC 2231 pieces
and the neutral `attachment` fallback, so tolerant readers cannot decode hidden
text from the fallback. The `LiteralFilename` registry case checks this branch. Both
`Content-Type` names and `Content-Disposition` filenames must match the original
Draft, as must the UTF-8 filename bytes, fallback, continuation order and bounds.
The strict comparisons have no filename whitelist.

Extended-first output is an interoperability convention, not an RFC precedence
requirement. [RFC 2231 section 3](https://www.rfc-editor.org/rfc/rfc2231#section-3)
says MIME parameters are not order-sensitive, and
[section 4.1](https://www.rfc-editor.org/rfc/rfc2231#section-4.1) defines combined
encoding and continuations without specifying basic-versus-extended precedence.
The related [Python issue](https://github.com/python/cpython/issues/87113) discusses
HTTP precedence, not a MIME precedence rule. Python still reports duplicate-parameter
defects for dual-form names. It can also report `UndecodableBytesDefect` when a
continuation splits a UTF-8 character, despite reconstructing the correct name.
These tests do not certify defect-free MIME or compatibility with every legacy client.
The valid `rfc2231-extended-filename` read fixture uses extended-only parameters.
The complete composition registry separately checks MailBend's dual-form output
against the interoperability contract, without classifying that output as malformed
or assigning an RFC-defined winner to duplicate logical names.

`--validate-only` checks metadata, registry completeness and negative controls without
Bend or a server. `--reads-only` and `--compositions-only` isolate a diagnosis; neither
replaces the full contributor check.

## Add a regression

1. Create a synthetic `.eml` containing the smallest realistic message that reproduces
   the bug. Preserve its raw octets. Do not use real personal mail or secrets.
2. Write the expected JSON by hand. Include the issue, source, license and primary
   reference. Classify valid input separately from malformed-input recovery.
3. For an unfixed bug, include a diagnostic, the desired result and a separate
   `known_wrong` pin. Do not turn the wrong output into the desired contract.
4. Add new composition inputs to `tests/composition-cases.bend`. Export every typed
   case in `all()`. Do not call `M.compose` directly elsewhere in tests.
5. Run the full corpus and contributor checks. Every later MIME or charset fix
   must add or update its fixture deliberately.

The files are also raw seed inputs for [#84](https://github.com/albertc71/MailBend/issues/84).
Point a message parser fuzzer at `tests/corpus/*.eml`, or copy those bytes into its
seed directory. No JSON interpretation, newline conversion or network access is needed.
The JSON files are expected results, not message seeds.

## Independent parser runtime

CI pins Python 3.13.18 and probes adjacent encoded-word display names before comparison.
Older Python 3.12.14 and 3.13.5 insert spaces in this case, contrary to RFC 2047 §6.2;
[CPython #128110](https://github.com/python/cpython/issues/128110) is fixed in
[3.13.14 and later](https://docs.python.org/3.13/whatsnew/changelog.html#python-3-13-14-final).
An affected runtime fails with a specific diagnostic; no parser outputs are normalized
to conceal that disagreement. The Bend oracle is compiled to a temporary executable
once per test process, matching the product's compiled execution path; the interpreter
cannot handle the >64 KiB stream control with its default machine stack.
