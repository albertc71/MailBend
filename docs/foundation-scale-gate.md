# Foundation paired validation

PR #242 keeps its product and frozen fixture code separate from PR #253's
paired implementation. Its existing Scale comparison caller now invokes
`foundation-scale.yml` instead of the legacy per-CPU comparison job. All
previous caller path filters remain, and the new workflow is also covered.
This replaces the PR gate; it is not an extra green check hiding a failed
legacy comparison. Ordinary CI and existing manual/scheduled coverage in
`ci.yml` remain unchanged. PR #253 later updates those manual/scheduled jobs.

## Exact roles and trust

Three disjoint checkouts have different roles:

- Control: immutable `bca8aa63067c7d302d07567dd0dd1ee00fde876f`, from the
  separately reviewed and not-yet-merged PR #253. This script and its controls
  run, but its product binaries are never built or measured here.
- Reference product: immutable `8ae04b1b3c773d14dea78e167e0047adab1e7cb5`.
  `scale-reference-v1` must resolve to this exact SHA.
- Candidate product: the calling PR's exact head SHA, not the control commit,
  a tag, or a moving branch. It is independently built in its own tree.

The workflow verifies the control checkout SHA and script hash before running
it. The verifier checks both product source SHAs, clean trees, frozen
apparatus, fixed launcher/installers, and distinct regular core/helper paths.
Source and executable identities are rechecked after measurement. The
reference harness and snapshot serve both products; only the validated
public launcher path changes between them.

The control commit passed real paired run 41499602224 attempt 2 on its own
head, with independent full-evidence review. That prior result is provenance
for the control, not validation of PR #242. This foundation requires a fresh
run with its own exact candidate head and report identities.

## Acceptance and evidence

Five adjacent reference/candidate pairs per seven scenarios alternate their
leaders, with a remaining 3:2 imbalance. All 70 samples must pass. All 21
median candidate/reference ratios must be at most 1.25. The 16 MiB read,
25 MiB forward, 90-second calls, 3 GiB RSS bounds, explicit per-sample login
ceilings and 900-second active budget per side remain. Shared setup and full
sample cleanup count toward side budgets; a combined 1800-second watchdog
fits a 31-minute paired step inside a 60-minute separate job. Reference
failures fail closed. No samples are discarded or replaced.

Historical 9V45 timings are informational only. Full reports, identities and
hashes are logged even on failure; no committed baseline is promoted. No
paid runner, artifact storage, secrets or additional token permissions are
introduced. Explicit manual evidence-record mode cannot satisfy a PR gate.

## Pin maintenance

This is an explicit dependency on an immutable **unmerged** implementation
commit, not a Git ancestry cycle or a PR merge. The control pin never follows
the candidate automatically. After PR #253 merges, later candidate edits to
`scale_pair.py` are not exercised by this pinned gate until a separately
reviewed control-pin migration. Preserve ordinary source tests for such
changes; do not claim their new code was measured by an older control pin.
Changes to the control SHA or script hash require review and a fresh run.
