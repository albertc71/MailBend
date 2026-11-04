# Maintain the safety claims

The [catalogue](LAWS.md) lists every law declared in `LAWS.bend`.
The [coverage report](PROOF-COVERAGE.md) connects README claims to source,
named tests and negative controls. These files are generated, not evidence
that a particular checkout has passed the proofs.

## Update a claim

1. Add or update a record in `safety-claims.json`. Describe the narrow guarantee
   and its limits. Use `proven` for a pure-function guarantee with a proof
   mutation, `tested` for runtime behavior, or `reviewed` for a code boundary.
2. Cite root laws by name. Cite imported laws as `path/to/file.bend#law_name`.
   Imported laws must be reachable from `PROOF.bend`. Every root law must appear
   in a claim or in `unclaimed` with a specific reason. The exclusion list does
   not automatically accept new laws.
3. Cite Python test functions as `tests/test-e2e.py#allowlist`, for example.
   The checker resolves function declarations with Python's AST without running
   the test module. This checks names, not whether a test proves the claim.
   Review that relationship and run the tests. Code references can name a file
   or a Bend definition as `src/ops.bend#plan_get`.
4. Put `<!-- claim:the-id -->` beside the README statement, within the section
   named by `anchor`. Put a marker on every line that uses the word `proven`.
   Repeated markers may cite the same claim elsewhere in the README. A tested
   or reviewed claim cannot support that word. Fenced examples do not supply
   claim markers or README heading anchors.
5. For a proven claim, add one mutation with a unique ID, a production Bend
   path, exact `before` and `after` text, and the expected failing definition
   as `path#definition`. The target must occur exactly once. Cite the target
   file in the claim's code. A named root law failure must be among its cited laws.
   A helper lemma or imported example can fail first; name that precise check
   and retain the public laws rather than pretending the example is universal.
6. Generate and check the reports.

```sh
python3 tools/gen-laws.py
python3 tools/check-claims.py
python3 tests/formal/test-claims.py
python3 tests/formal/check-law-mutations.py
bend PROOF.bend --verdict
```

Both generators accept `--check` to reject stale output without writing it.
The lightweight negative controls need only Python's standard library.
The proof mutation run needs the repository's pinned Bend toolchain. The
kernel verdict also needs its pinned Lean toolchain. Run the other
[contributor checks](../CONTRIBUTING.md#checks) before opening a pull request.

## Add a law summary

The generator reads section headings, declaration names and `# LAW:` summaries
from `LAWS.bend`, and computes the law count. A summary can span adjacent comment
lines. Some older declarations have no summary of their own. Their explicit
plain-English summaries live in `law-summaries.json` so this catalogue does not
change the law contract. Remove a supplement if its law gains a source summary.
Unknown supplements, missing summaries and duplicate declarations fail.

## Read a mutation failure

`tests/formal/mutation_runner.py` is shared source-copy and verdict machinery
for this manifest and future law-strength suites. It first checks the checkout
and a temporary copy. Each mutation changes one production module in the copy,
then runs `bend PROOF.bend --check-only`. A success verdict, timeout, parse error,
wrong failure location or missing expected/observed comparison fails the suite.
A semantic rejection at the expected definition passes that negative control.

The runner restores each changed file, checks the restored copy, and compares
source hashes with the checkout. It never writes to the checkout or edits laws
or proofs. A surviving mutant needs investigation or a stronger law in a
separately reviewed change. Do not weaken a law or accept an unrelated compiler
error to make the mutation pass.

One mutation per proven claim is a diagnostic control, not a mutation score for
all laws in that claim. These checks do not establish correctness of native IO,
cryptography, model answers, or the mail provider.

The README badge uses GitHub's own CI workflow status. That workflow runs the
kernel verdict and requires the proof and mutation lanes to pass. GitHub's
workflow badge is not a per-job badge; it also reflects unrelated CI failures.
