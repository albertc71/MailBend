# Measure synthetic large inputs

Build the pinned compiled core with `scripts/install.sh`. Then run:

```sh
python3 tests/test-scale-contract.py
python3 tests/test-scale.py --record --output build/scale-results.json
```

Install GNU `time` (for example, `sudo apt-get install time` on Debian/Ubuntu).
The suite uses Linux, GNU `time`, and local fake IMAP, SMTP and TypeSafe servers.
It does not use an account, a real service key, or an external service.
Build dependency downloads happen before measurement, not inside the suite.
Set `MAILBEND_TEST_TMPDIR` to an existing directory with enough free space if
the default temporary filesystem is small or unsuitable.
The child environment omits inherited mail settings and proxies. The fake
TypeSafe proxy is the only enabled route for classification.

Seven fixed scenarios cover 100,000 UIDs, 1,000 and 5,000 folders, a 16 MiB
read, a 25 MiB forward with a Sent copy, a 1,000-message star-shaped thread
with long shared ID prefixes, and 50 image-bearing classification inputs.
The classification checks keep the existing per-request image quota. They do
not claim that all 50 images are sent to the model.

Each scenario needs five successful, independently verified calls. A fresh
launcher and fresh fake server serve each call. The OS cache is not cleared.
Fixture generation, TLS certificate setup and result validation are outside
the measured interval. Fake-server work during the request, including Sent
state persistence, remains in wall time. Every measured process group is swept after its leader exits, including
normal and nonzero exits, before the next sample starts. Forward calls also
reject SELECT, EXPUNGE, non-PEEK body reads and mutations other than the
explicit Sent APPEND. These are local fake-server costs,
not provider latency or a comparison between implementations.

`peak_rss_kib` is GNU time’s Linux maximum RSS of an individual process in the
launcher and its waited descendants. It is not the sum of simultaneously
resident processes. It excludes the fixture server, the supervisor and result
validation, so it does not establish a minimum machine RAM requirement.
The report also records child CPU time, login counts, work counts, sample
ranges, load averages, the compiled binary hash and the source revision.
The supervisor scans visible process metadata to enforce its memory threshold.
Its CPU time and the maximum count of scanned processes are recorded. This
monitor adds work and up to one polling interval to wall time; the measurement
is not intrinsic core latency independent of the monitor.

Calls have a 90-second deadline. The supervisor samples process-group RSS
every 10 ms and stops a call above 3 GiB, or when the primary process is not
observable. This is an abort threshold, not a hard allocation limit. Memory
can grow between samples, and summed RSS can count shared pages more than
once. Bend reserves over 8 GiB of virtual address space, so a small address
limit would reject even small workloads without measuring resident memory.
Fake servers have a 1.5 GiB per-process address-space limit. The suite has a
15-minute cooperative deadline covering setup, validation and all samples.
Deadline and cancellation checks run between synchronous setup/validation
phases, every call poll, and at most 100 ms apart while waiting for server
readiness. Certificate commands have a maximum 15-second timeout. A phase
already doing synchronous fixture or result work can delay cancellation; this
is not a hard wall-clock limit. SIGINT, SIGTERM and SIGHUP request cancellation
without interrupting child registration or cleanup. Cleanup can add a delay. A timeout, refusal, incomplete read, wrong result, or missing
sample fails the run. The report retains failures rather than treating them
as fast measurements. These safety limits can reject workloads that would
succeed on a larger machine.

## Versioned scale apparatus

Scale uses the fixed files in `tests/scale_support/v1/`, not the evolving
general E2E fake servers. The first snapshot copies all three fixture files
byte-for-byte from commit `9b50f9d3c4aadad9f213c01f7b576d2e124394cc`.
`ORIGIN.json` records their original paths and SHA-256 hashes. This deliberate
~100 KiB duplication keeps unrelated E2E fault-injection additions out of
measured code; ordinary E2E tests continue to use the general fixtures.

Both server commands use explicit snapshot paths. Image generation imports
only the snapshot module. The profile hashes the actual bytes of all three
snapshot dependencies, the generator and the measurement harness. The
manifest is provenance, not an exemption from these checks. Editing any
executed snapshot dependency invalidates the profile and requires fresh,
independently reviewed hosted measurements. General-fixture-only changes
neither alter scale's imported code nor trigger its comparison workflow.

Protocol, security or correctness fixes that apply to these measured
workloads must be ported explicitly to the snapshot and remeasured. Do not
silently sync unrelated fault features. Review the imported dependency set
when adding a module; every executed local dependency must be hashed.
Version names alone never permit comparison. The initial byte identity and
contract checks do not substitute for the complete 35-sample hosted run.

The path and import migration changes the harness and generator hashes.
Earlier records remain historical evidence and fail against this new
apparatus. The current candidate below was measured on the new paths and
independently reviewed. No metadata was copied onto old measurements.

## Paired comparison on one runner

The automated regression gate compares a fixed reviewed product reference
against the exact candidate on the **same** standard Ubuntu runner. The
immutable reference is `8ae04b1b3c773d14dea78e167e0047adab1e7cb5`; it is not
a moving main revision or a value chosen by the candidate. The descriptive
`scale-reference-v1` tag must resolve to that exact SHA; a moved tag fails.
The reference is
a performance anchor, not a claim that every product feature at that revision
was complete. Changing it requires explicit review, never automatic promotion.

Both checkouts are clean, separate directories with independent in-tree
builds. `tests/scale_pair.py` verifies the source identities and immutable
apparatus before any measurement. The harness, generator and three snapshot
files must match the reviewed hashes in both trees. The launcher must match
the fixed reference, whose helper defaults point inside its own tree; the
harness removes inherited helper overrides. Core, launcher and all four
native helper paths must be regular, executable, tree-local files, not
symlinked or shared outputs. Their hashes are recorded and checked again
before acceptance. Both reports must name the expected source and core hash.

One frozen reference harness and snapshot serve **both** builds. A narrow
adapter substitutes only the validated public launcher path for the selected
side; it preserves the command arguments, environment, work directory,
timeout, control object and all measurement/verification functions. The
adapter/orchestrator has its own recorded hash: the old harness digest alone
does not describe the new paired orchestration.

The adapter and acceptance gate are candidate-side code, reviewed in this
PR, not hash-pinned against an older trusted copy. Their recorded hash is
provenance, not independent enforcement. Like the candidate-owned workflow,
changes to this gate require review; the path filter makes them visible to
the paired check. Only the measurement harness and apparatus are frozen.
The verifier starts with Python isolated mode (`-I`) before its own imports;
its boundary checks remain necessary for the frozen subprocess servers.
Paired preflight runs before the shared Bend toolchain is installed, then
installation uses the verified reference script. Explicit manual evidence
mode still uses its candidate installer and does not claim a paired pass.

For each scenario the order is A1,B1,B2,A2,A3,B3,B4,A4,A5,B5, where A is
reference and B is candidate. Pair leaders alternate deterministically; five
pairs leave a 3:2 leader imbalance, so this reduces but does not eliminate
order bias. Each side gets fresh fixture state and fake servers.
All 35 pairs (70 samples) must pass, with no discarded or replacement pairs.
For each metric and scenario compute all five B/A ratios, then gate their
median at 1.25. This is deliberately **not** the ratio of two medians.
Adjacent pairing and alternating leaders reduce time-varying noise but do
not eliminate host load or warm-up bias. If insufficiently stable, review more pairs
within the time budget rather than raising the regression threshold.

Missing or failed reference samples, altered apparatus, changed build
identities, incomplete pairs, wrong source IDs or unequal profiles fail
closed. Neither product is its own baseline. No committed record is replaced.
Apparatus or launcher changes require a separately reviewed migration;
copying a new hash into an old result is not permitted.

Full profile equality remains mandatory, including CPU, operating system,
Bend, Python, GNU time and all apparatus hashes. An unfamiliar CPU can pass
only because both real measurements ran on that same host with equal full
profiles, not because its model was normalized or ignored. All 21 median-of-pair-ratio
checks retain the 25% budget. The 16 MiB read, 25 MiB forward, 90-second call
limit, 3 GiB sampled stop and 15-minute deadline **per suite** are unchanged.

New explicit per-sample login ceilings strengthen the former median-only
login guard. They apply to both sides, independently of the paired login
ratio, and use floor(reference count * 1.25) from reviewed snapshot evidence:

| Scenario | Reference logins | Per-sample maximum |
| --- | ---: | ---: |
| search-100000 | 2 | 2 |
| folders-1000 | 2 | 2 |
| folders-5000 | 2 | 2 |
| read-16mib | 1 | 1 |
| forward-25mib | 5 | 6 |
| thread-1000 | 6 | 7 |
| classify-images-50 | 14 | 17 |

This is 70 real samples, not 35, and two fresh builds. Each side retains
its own 900-second cumulative active budget, including fixture generation,
startup, validation, cleanup and failed samples. Shared profile/certificate
setup is charged to both sides. Time spent waiting while the other side
runs does not consume its active budget; a separate 1800-second combined
watchdog bounds the whole sequence. Budget checks also occur after cleanup
before accepting a sample. Cancellation/cleanup semantics are unchanged.
The paired workflow step allows 31 minutes for this bounded sequence and
cleanup; the separate job allows 60 minutes including both builds.

Recent single-suite times were about 9–11 minutes, but no duration is
promised. No reference-build cache is used initially. Ordinary CI retains
its separate lanes and limits, with only fast paired-contract checks added.
The report retains its cold-launcher/warm-OS-cache definition and load data.
A 25% threshold is a budget rule, not proof of statistical significance.

On a matching 9V45 profile, reference-only results are also compared against
the committed historical snapshot timings and published as an informational
cross-check. Other profiles are explicitly incomparable. That result never
passes or fails the paired gate and cannot excuse a paired regression.

### Workflow and evidence

Manual dispatch with `scale` enabled, the Monday 04:17 UTC schedule and the
narrow `Scale comparison` PR workflow use the paired gate. The scale
concurrency group is separate from ordinary CI. The PR path filter covers
actual apparatus, the paired verifier and its tests, historical baseline
files/selector and both workflows. General E2E fixture additions are not
measurement inputs. Normal product-only changes are covered by the weekly
scale run rather than forcing a long scale job on every PR.

Explicit manual `record_scale` remains available for historical evidence
collection only. It cannot be selected by a PR or scheduled paired gate,
does not establish a comparison pass and never replaces a committed record.
No paid runner tier, additional permissions, secrets or artifact storage is
used. These are standard public runners; more computation is still consumed.

The job logs complete `reference-results.json`, `candidate-results.json`,
`paired-identities.json` and `paired-result.json` when available, including
failures. Each file has a SHA-256 line and named `SCALE_<name>_JSON_BEGIN` /
`SCALE_<name>_JSON_END` delimiters. Verify exact bytes and hashes when reading
logs. Oversized output fails rather than being silently truncated; an
always-run evidence step does not clear a failed measurement exit.

### Historical per-CPU comparison

The older direct command remains useful only for a matching recorded profile:

```sh
baseline=$(python3 tests/scale_baseline.py)
python3 tests/test-scale.py --baseline "$baseline" --output build/scale-results.json
```

That selector accepts the reviewed 9V45 record; other CPUs still fail it.
It is not used to choose hardware or to bypass the paired gate. Historical
7763 records remain unselected. `tests/test-scale-baseline.py` checks every
selected historical record against the actual current apparatus hashes.
Changing apparatus therefore still requires deliberate record maintenance,
not silent relabeling. Earlier hosted results below describe their actual
strategy and source; they are not evidence of a completed paired run.

No Raspberry Pi or other ARM board measurements are implied. A future ARM
baseline needs that board, a supported build, and the same work checks.

GNU time runs as a fresh, small supervisor before it starts the launcher.
This excludes the Python fixture parent from the measured high-water mark.
A dirty-parent regression control verifies this separation. Missing or invalid
resource output cannot pass; a group killed by the safety stop may have no
GNU time output. The report then keeps only the sampled diagnostic peak.
The timer binary hash and version are part of the comparable runner profile.

## Current snapshot candidate

[Run 41414114062](https://github.com/albertc71/MailBend/actions/runs/41414114062)
completed all 35 exact samples in 547.06 seconds on source
`8ae04b1b3c773d14dea78e167e0047adab1e7cb5`, using EPYC 9V45 and CPython
3.13.18. Independent review matched all 26,941 logged JSON bytes and SHA-256
`92832bc6e9b864dfc2665d5b191b15bb3852c2ddd4b79660d342801f3887e746`.
This exact report is the selected baseline. The run correctly failed
comparison against the old apparatus profile; it is not a regression pass.
A subsequent matching-profile comparison must pass the unchanged gates.
[Run 41416193899](https://github.com/albertc71/MailBend/actions/runs/41416193899)
completed all 35 samples but failed because its Intel 6973P-C CPU was not
reviewed. That report is retained as evidence, not promoted or a comparison
pass. Snapshot isolation does not solve arbitrary runner hardware allocation.

## Previous hosted 9V45 candidate

[Run 41409341267](https://github.com/albertc71/MailBend/actions/runs/41409341267)
measured all 35 exact samples in 584.59 seconds on source
`2562db03ed6481c852398a3a4e4450ff4c384966`. The profile is EPYC 9V45,
CPython 3.13.18 and the candidate-SEARCH fixture hash introduced on main.
Independent review matched all 26,874 logged JSON bytes and SHA-256
`a1996859ada45410fec61c6f2770f2386dcfc43f4e63c9c300770bff3cc9a93c`.
That evidence-capture run correctly failed while this CPU had no current
selected baseline. Its later matching-profile
[comparison 41415510407](https://github.com/albertc71/MailBend/actions/runs/41415510407)
passed on `1fb8fe5dd04a12119ef805cf6c817d790acfb87c`: all 35 samples,
identical full profile, and all 21 median checks within the unchanged 25%
budget. This is historical evidence for the pre-snapshot apparatus, not
acceptance of the current snapshot profile.

## Previous 7763 baseline and passing comparison

The previous 7763 baseline comes from
[run 41402595457](https://github.com/albertc71/MailBend/actions/runs/41402595457),
source `9e591fc86bfac81e61b9568d3463a34756955cf4`. All 35 exact samples passed
in 706.85 seconds with CPython 3.13.18 and the main-integrated fixture hashes.
Independent review verified all 26,864 bytes and JSON SHA-256
`eafd9e0710bd713f45e9d4b954b6091ac8b4ad4ec3b8009cdf59b03a4076c2d8`.
That candidate run correctly failed against its old profile. The subsequent
[comparison 41404768369](https://github.com/albertc71/MailBend/actions/runs/41404768369)
passed on source `79ae6bfc13a1441ca635ca4a7c919508aa222aa6`: all 35 samples,
697.28 seconds, identical full profile, and all 21 median checks within the
unchanged 25% budget. The largest median increase was 1.24%. Independent
review verified JSON SHA-256
`dbf67ea5157c7c3e046e45fde1c6f838cd99bd125cfd5d7a2ab5f121839c8237`.
This is evidence for that historical 7763 profile, not the newer fixture
hash or all hosted CPU models.

## Previous 9V45 measurement

[Run 41397060015](https://github.com/albertc71/MailBend/actions/runs/41397060015)
measured all 35 samples on source `e0494f20a891b59bb96fc4426be32233e1ee0968`
in 526.76 seconds. Its comparison correctly failed against the old profile;
the complete candidate was independently reviewed before being committed
unchanged as an earlier baseline. It is no longer selected. Its verified
JSON SHA-256 is
`e06ec29924bcd8e27b86f26e69a4c972eb9ca29fc455e5e347c8be8442b6ef2f`.
This candidate run was not a comparison pass.

The expanded profile records GitHub-hosted Ubuntu 24.04.5 LTS, x86-64,
AMD EPYC 9V45, four logical CPUs, Bend 2.0.35 and CPython 3.12.3, plus the
actual harness, fixture dependencies and timer hashes. Workloads, sample
counts and limits are unchanged. No metadata was guessed onto old samples.

| Workload | Median seconds | Seconds range | Median max-process RSS (KiB) | Median IMAP logins |
| --- | ---: | ---: | ---: | ---: |
| search-100000 | 0.23 | 0.23–0.24 | 53,032 | 2 |
| folders-1000 | 1.78 | 1.77–1.79 | 39,220 | 2 |
| folders-5000 | 39.81 | 39.77–39.99 | 42,180 | 2 |
| read-16mib | 2.57 | 2.55–2.62 | 1,076,656 | 1 |
| forward-25mib | 11.09 | 10.99–11.39 | 2,479,428 | 5 |
| thread-1000 | 47.14 | 47.04–47.30 | 86,388 | 6 |
| classify-images-50 | 0.26 | 0.25–0.27 | 39,216 | 14 |

The older CPU was different, so timing differences do not prove a speedup.
RSS and IMAP-login medians are close, but only matching complete profiles
can pass the regression gate.

## Earlier 7763 measurement

The previous 7763 candidate is retained in Git history and its hosted log.

Standard public runners also assigned AMD EPYC 7763. Instead of replacing
one CPU's baseline with another's, the original `scale-baseline-epyc7763.json` retained
[run 41399173308](https://github.com/albertc71/MailBend/actions/runs/41399173308)
unchanged: source `b9b583cdc4f2128b30d55c14cfb086e60d2626a3`, all 35 successful
samples, 699.07 seconds. Independent review verified full JSON SHA-256
`a1b82bac473aefa91f1c5768039e4d2666d94754cc620fb8d7b1555f84eed5b4`.
Its profile differs from the earlier `e0494f2` 9V45 candidate only in CPU model. This run also
failed comparison correctly against the other CPU, not workload validation.
These earlier candidate runs were not successful regression comparisons;
the later passing run for the historical 7763 profile is linked above.
These historical runs do not establish a pass for the new paired strategy.

### Previous hosted baseline

The original report remains in Git history and the linked hosted log. It is
historical evidence, not the current expanded-profile comparison baseline.

[Run 41379240425](https://github.com/albertc71/MailBend/actions/runs/41379240425)
recorded all seven exact workloads with five verified samples each on source
`a13504b703175f5b9ae9c1bdb9fcbcf3aca496f2`. The suite completed in 661.03
seconds, inside the unchanged cooperative 900-second limit. The 90-second
call limit and sampled 3 GiB process-group RSS stop remain unchanged.

Profile: GitHub-hosted Ubuntu 24.04.5 LTS, x86-64, AMD EPYC 7763, four visible
logical CPUs, Bend 2.0.35. The full report records exact timer, fixture and
measurement hashes. Its JSON SHA-256, verified against the job log, is
`69eb0a9ca61e195848cdfbec39ea1561389a3d17e5b33ad151ee9e70591842ea`.

| Workload | Median seconds | Seconds range | Median max-process RSS (KiB) | Median IMAP logins |
| --- | ---: | ---: | ---: | ---: |
| search-100000 | 0.33 | 0.32–0.37 | 53,068 | 2 |
| folders-1000 | 2.39 | 2.37–2.42 | 39,280 | 2 |
| folders-5000 | 52.82 | 52.36–52.95 | 42,164 | 2 |
| read-16mib | 3.59 | 3.58–3.60 | 1,076,724 | 1 |
| forward-25mib | 12.95 | 12.84–13.03 | 2,479,384 | 5 |
| thread-1000 | 55.90 | 55.64–56.22 | 86,480 | 6 |
| classify-images-50 | 0.38 | 0.37–0.38 | 39,272 | 14 |

These are cold-launcher, warm-cache observations on local synthetic servers,
not provider latency or minimum machine RAM. Peak RSS excludes the fixtures
and validation process. The exact 16 MiB read and 25 MiB forward (including
a matching Sent copy) now complete; the earlier failed observation below is
retained, not treated as a baseline. A record run is not a comparison pass.
Only matching runner profiles are comparable; changed hosts or toolchains
need separately reviewed measurements, not relaxed comparison gates.

## Local observation, not a baseline

[`scale-observation.json`](scale-observation.json) preserves a 658.15-second
run on Debian 13 x86-64, AMD EPYC 9V74, nine visible logical CPUs, Bend 2.0.35.
The report contains the exact core, fixture and measurement hashes. Its source
commit is the unchanged product baseline; the harness was a working-tree
addition. GNU time reports its version as `UNKNOWN` in this Debian package;
the binary hash identifies the timer precisely.

| Synthetic workload | Median wall seconds | Median maximum-process RSS, MiB | IMAP logins |
| --- | ---: | ---: | ---: |
| 100,000 UIDs | 0.488 | 46.73 | 2 |
| 1,000 folders | 2.178 | 23.15 | 2 |
| 5,000 folders | 47.086 | 32.88 | 2 |
| 1,000-message thread | 76.027 | 75.84 | 6 |
| 50 image-bearing classification inputs | 2.194 | 23.95 | 14 |

Each row has five successful, verified samples; ranges are in the JSON.
Two required workloads failed on their first attempt and were not repeated:

- The 16 MiB read exited 1 with `bend: memory fault (machine stack overflow?)`.
  GNU time recorded 2,889,652 KiB maximum-process RSS (about 2.76 GiB).
  This is a failed-operation observation, not the RAM required to read 16 MiB.
- The 25 MiB forward was killed at 3,165,964 KiB sampled process-group RSS,
  above the 3 GiB safety threshold. No completed GNU time measurement exists.
  This does not prove that the operation would fail without that safety stop.

The overall result is **incomplete**. It cannot be promoted to the committed
baseline, cannot pass the comparison gate, and does not close issue #140.
No successful 16/25 MiB capacity claim or ARM extrapolation follows from it.
