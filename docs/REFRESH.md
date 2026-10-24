# Bounded refresh experiment

## Outcome and scope

A polling caller keeps arrival cursors with `mail_get_new`, then refreshes a
bounded cache with `mail_refresh`. Bend owns input checks, the read plan,
interpretation and output. The TLS helper is unchanged. There is no database,
watcher, IDLE, QRESYNC, full mailbox mirror or automatic action.

The accepted prototype bounds are 100 supplied UIDs per call (duplicates count),
positive 32-bit UID and UIDVALIDITY values, one session, three planned commands,
256 KiB helper output and serialized tool result, 1024 UTF-8 bytes per folder
name and a 30-second helper deadline. The process output cap is
enforced before the core materializes parsed responses. Normal work scales with
the bounded caller set, not the size of the entire mailbox; a server's own search
implementation and TLS/login overhead remain outside the client's control.

The public result and cache reconciliation rules are in
[README.md](../README.md#polling-known-messages). Evidence distinguishes a UID
absent from this mailbox at SEARCH from incomplete observations and from global
deletion. Flags precede the presence check; this is not a snapshot. A UIDVALIDITY
reset stops the plan before either UID operation and invalidates the old cache.

## Validation and measurements

`refresh_known` in [the e2e suite](../tests/test-e2e.py) exercises a caller cache:
get arrivals, change flags and move one message elsewhere, refresh known UIDs,
then obtain later arrivals with the original cursor. It also covers empty,
duplicate, invalid, maximum and excessive UIDs, stale UIDVALIDITY, concurrent
removal after FETCH, omitted flags, missing/malformed/duplicate SEARCH, rejected
commands, connection loss and output overflow. The synthetic server records
response byte counts without logging mail content for the cost cases.

[Unit evidence tests](../tests/unit/refresh.bend) cover incomplete and malformed
transcripts independently of the server. [Transport tests](../tests/test-transport.sh)
verify the guarded sequence and refusal before stale UID operations.

The formal `refresh_plan` law in [LAWS.bend](../LAWS.bend) pins the exact read-only
EXAMINE/expectation/metadata FETCH/UID SEARCH plan for all arguments. The updated
tool-list laws include refresh in every appropriate configuration. These proofs
cover the command plan; protocol evidence and output interpretation are tested,
not represented as a proof of server correctness.

Measured synthetic results will be recorded after the full test run.

## Decision

Retain the bounded stateless prototype if the synthetic tests pass. The cost
experiment measures client command count and response size, not provider latency,
rate limits or a claim that polling an entire large mailbox is cheap. There is
no automatic polling schedule. Larger-scale or event-driven synchronization
requires a separate product decision supported by actual polling costs.
