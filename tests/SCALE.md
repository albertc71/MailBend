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

## Compare a recorded baseline

```sh
baseline=$(python3 tests/scale_baseline.py)
python3 tests/test-scale.py --baseline "$baseline" --output build/scale-results.json
```

The selector accepts only `AMD EPYC 9V45 96-Core Processor` and chooses
`scale-baseline.json`. Other CPU models fail selection. CI still collects a
bounded candidate using the unchanged full-profile comparison, then forces
a failed job even if that command unexpectedly exits successfully. This is
evidence capture, not a baseline or acceptance fallback. Selection is not
acceptance: the unchanged harness still requires the same full profile.
It never combines measurements or records a replacement automatically.
The scale job pins CPython 3.13.18, like ordinary CI. The new 9V45 snapshot
candidate below records the actual versioned dependency hashes. A matching
comparison is still required. The retained 7763 record is historical.
The 7763, Intel 8573C and EPYC 9V74 models take the explicit unreviewed-CPU
evidence-only path until fresh matching evidence is independently reviewed.
CPU selection alone never makes a stale or unknown profile acceptable.

The comparison requires the same runner, operating system, architecture,
CPU model, logical CPU count, Bend version, Python implementation/version,
limits and sample count. The profile also hashes the measurement harness,
fixture generator, image generator and both fake servers. A different
profile is incomparable and fails. Changing any versioned scale-support
file or the scale fixture generator requires re-recording every selected
baseline. Ordinary CI checks those source hashes with
`python3 tests/test-scale-baseline.py`. This check is separate from the
measurement job so a stale record blocks ordinary CI without preventing
collection of a replacement candidate. The measurement job still cannot
pass an incomparable profile. Wall-time, maximum-process RSS or IMAP
login medians more than 25% above the baseline fail. The fast contract tests
include a deliberate 26% slowdown and reject invalid or incomplete samples.
This threshold detects a budget breach; it does not by itself establish a
statistically significant regression. Inspect the ranges and host load.

`--record` never updates the committed baseline. Review a complete result,
including successful work checks and sample variation, before copying it to
the matching reviewed baseline file. Do not copy results between runner profiles.
An unmeasured baseline remains a failing gate, not a guessed budget.

The CI workflow runs scale tests on manual dispatch with `scale` enabled and
on Mondays at 04:17 UTC. The weekly job compares against the committed
hosted baseline; it does not replace it. The schedule starts only after this
workflow reaches the default branch. Scale runs have a separate concurrency
group from ordinary CI, so they cannot cancel a push check on the same branch.
Ordinary product pull requests run only the fast contract controls. A separate
`Scale comparison` workflow runs when a pull request changes the measurement
harness, scale fixture generator, versioned scale-support directory, either
baseline, the selector or either workflow. Changes to the shared CI workflow trigger comparison
because it also defines the scale environment. It reuses the
same bounded scale job in comparison mode, checks out the exact PR head, and
does not join the ordinary `checks` aggregate. Pull requests that change only documentation or unrelated
product files do not trigger it. No secrets or additional token permissions
are passed to the reused workflow.
`record_scale` saves a candidate result without comparing it. The workflow
logs the full JSON and its SHA-256 hash even when a scenario fails. The JSON
is between `SCALE_RESULT_JSON_BEGIN` and `SCALE_RESULT_JSON_END` markers.
Retrieve it from the job log and verify the hash before using it. This uses
no artifact or cache storage. A failed measurement still fails the job.
The GitHub-hosted runner needs
its own verified baseline; a local result cannot stand in for it.

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

## Previous hosted 9V45 candidate

[Run 41409341267](https://github.com/albertc71/MailBend/actions/runs/41409341267)
measured all 35 exact samples in 584.59 seconds on source
`2562db03ed6481c852398a3a4e4450ff4c384966`. The profile is EPYC 9V45,
CPython 3.13.18 and the candidate-SEARCH fixture hash introduced on main.
Independent review matched all 26,874 logged JSON bytes and SHA-256
`a1996859ada45410fec61c6f2770f2386dcfc43f4e63c9c300770bff3cc9a93c`.
The report is committed unchanged. That evidence-capture run correctly
failed while this CPU had no current selected baseline. A subsequent
matching-profile comparison is required; this candidate is not a pass.

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

The previous 7763 candidate is retained in Git history and its hosted log:

Standard public runners also assigned AMD EPYC 7763. Instead of replacing
one CPU's baseline with another's, the original `scale-baseline-epyc7763.json` retained
[run 41399173308](https://github.com/albertc71/MailBend/actions/runs/41399173308)
unchanged: source `b9b583cdc4f2128b30d55c14cfb086e60d2626a3`, all 35 successful
samples, 699.07 seconds. Independent review verified full JSON SHA-256
`a1b82bac473aefa91f1c5768039e4d2666d94754cc620fb8d7b1555f84eed5b4`.
Its profile differs from the 9V45 candidate only in CPU model. This run also
failed comparison correctly against the other CPU, not workload validation.
These earlier candidate runs were not successful regression comparisons;
the later passing run for the historical 7763 profile is linked above.
The active 9V45 profile has no passing comparison yet.

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
