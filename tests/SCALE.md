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
state persistence, remains in wall time. These are local fake-server costs,
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
15-minute alarm covering setup, validation and all samples. Cleanup can add
a short delay. A timeout, refusal, incomplete read, wrong result, or missing
sample fails the run. The report retains failures rather than treating them
as fast measurements. These safety limits can reject workloads that would
succeed on a larger machine.

## Compare a recorded baseline

```sh
python3 tests/test-scale.py --baseline tests/scale-baseline.json --output build/scale-results.json
```

The comparison requires the same runner, operating system, architecture,
CPU model, logical CPU count, Bend version, limits and sample count. A different
profile is incomparable and fails. Wall-time, maximum-process RSS or IMAP
login medians more than 25% above the baseline fail. The fast contract tests
include a deliberate 26% slowdown and reject invalid or incomplete samples.
This threshold detects a budget breach; it does not by itself establish a
statistically significant regression. Inspect the ranges and host load.

`--record` never updates the committed baseline. Review a complete result,
including successful work checks and sample variation, before copying it to
`tests/scale-baseline.json`. Do not copy results between runner profiles.
An unmeasured baseline remains a failing gate, not a guessed budget.

The CI workflow runs scale tests weekly and on manual dispatch with `scale`
enabled. Ordinary pull requests run only the fast contract controls.
`record_scale` saves a candidate result without comparing it. The workflow
uploads the JSON even when a scenario fails. The GitHub-hosted runner needs
its own verified baseline; a local result cannot stand in for it.

No Raspberry Pi or other ARM board measurements are implied. A future ARM
baseline needs that board, a supported build, and the same work checks.

GNU time runs as a fresh, small supervisor before it starts the launcher.
This excludes the Python fixture parent from the measured high-water mark.
A dirty-parent regression control verifies this separation. Missing or invalid
resource output cannot pass; a group killed by the safety stop may have no
GNU time output. The report then keeps only the sampled diagnostic peak.
The timer binary hash and version are part of the comparable runner profile.

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
