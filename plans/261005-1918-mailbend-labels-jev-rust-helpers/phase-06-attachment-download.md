---
phase: 6
title: "Phase 6: Attachment download"
status: todo
priority: P2
effort: "1.5d"
dependencies: [1]
---

# Phase 6: Attachment download

## Goal

Add `mail_get_attachment`: save one attachment of a message into
`MAILBEND_DOWNLOAD_DIR` through the credential-free `mailbend-attach`,
atomically, outside `MAILBEND_ATTACH_DIR`, and never in read-only mode.

## Evidence

- Attachment download is in 10+ competitors (mcp-email-server opt-in,
  codefuturist 5 MB cap, Nylas 10 MiB, JulienRabault saves to disk).
- Today `mail_get` lists attachments (`M.Att{name, ctype, size}`,
  `src/mime.bend:16-17`); no part bytes are exposed.
- Binary crosses the boundary one character per byte (0x80-0xFF as UTF-8 of
  U+0080-U+00FF, `native/mailbend-attach.c:30-32`); `Process.run` passes
  stdin with an explicit length (`~/.bend/bend2/effs/process_run.c:343`), so
  0x00 survives; the e2e round trip proves it.
- `Process.run` SIGKILLs a helper on timeout
  (`~/.bend/bend2/effs/process_run.c:283`), so in-helper cleanup cannot be
  relied on.
- The existing directory refusals were built to stop reading secrets
  (`native/mailbend-attach.c:27-29`), not to stop writing executables.
- Symlinked attach directories are supported (`tests/test-e2e.py:422-428`),
  so string comparison in Bend cannot prove two directories are distinct.
- User decision: refused under `MAILBEND_READ_ONLY`.

## Design

- Not a read tool: `is_read_only(OGetAttachment) = False`, hidden and
  refused in read-only mode, MCP `readOnlyHint: false`.
- Read path: `plan_get` (EXAMINE, BODY.PEEK); refuse when the fetch was
  truncated by `max`; `M.part_bytes(msg, index)` decodes base64,
  quoted-printable or 7/8bit.
- File name policy (Bend): default the attachment name; take the last path
  component; remove NUL, control and Unicode format (Cf) characters; strip
  every leading dot; at most 255 bytes; `filename` may be passed.
- `mailbend-attach save <attach-dir> <download-dir> <name> <max-bytes> <path-list>`
  (6 arguments; mode chosen by argument count, phase 1). The helper
  re-executes with an empty environment (`native/mailbend-attach.c:96-101`),
  so the caller's `PATH` is passed explicitly as `<path-list>`, a
  non-secret value; no other environment value is passed:
  - canonicalises both directories and refuses when they are the same inode
    or either contains the other (dev/inode ancestry walk);
  - download-dir refusals: everything the read mode refuses, plus any
    directory under `~/.config`, `~/.local/bin`, `~/.local/share/applications`,
    any `autostart` or `systemd` directory, and any directory in
    `<path-list>`, each entry canonicalised and compared by device and
    inode, so a symlink alias of a PATH directory is refused too;
  - `name` must be one component;
  - writes with `O_TMPFILE` in the download directory, then `linkat` to
    the final name (fails with EEXIST rather than overwrite), so a killed
    helper never leaves a partial file under the real name; mode 0600.
- `MAILBEND_DOWNLOAD_DIR` unset means downloads are off.

## Files

- Modify: `src/mime.bend`, `src/tools.bend`, `src/ops.bend`, `LAWS.bend`,
  `PROOF.bend` (read-only list law), `tools/gen-schema.py`,
  `native/mailbend-attach/src/*.rs` (save mode), `tests/test-e2e.py`,
  `tests/unit/mime.bend`, `.env.example`.

## Steps

1. `part_bytes` with unit tests (base64, quoted-printable, 7bit, nested
   multipart, RFC 2231 names).
2. Save mode in Rust with unit tests for every refusal and the
   `O_TMPFILE`/`linkat` path.
3. Tool, schema (not read-only), switch parsing.
4. e2e: byte-for-byte round trip of a file holding every byte 0x00-0xFF;
   EEXIST refused; `..`, `/`, U+202E and leading dots handled; download dir
   equal to, inside, or a symlink alias of the attach dir refused;
   `~/.config/autostart` refused; a temporary directory added to `PATH`, and
   a symlink alias of it, refused after the re-exec while
   `/proc/<pid>/environ` of the helper holds no `MAILBEND_APP_PASSWORD`;
   truncated fetch refused; read-only mode
   refuses and hides the tool; a helper killed mid-write leaves no file.

## Verification

- `cargo test --locked`; `sh tests/run-unit.sh`; `python3 tests/test-e2e.py`.

## Risks

- Large attachments use one value per character in Bend (README known
  limits); keep the 25 MB cap shared with sending.
