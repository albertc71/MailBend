---
title: "MailBend core, TLS helper and MCP tools"
date: 2026-09-27
summary: "Implemented the Bend 2 core, OpenSSL helper and 14 MCP tools; fixed review findings; verified e2e against a local TLS server (PR #1)"
---

# MailBend core, TLS helper and MCP tools

## What happened
- HANDOFF.md lived only on `main`; the work branch started from `master`, so it was fast-forwarded to `main` first.
- The original tree did not build on Bend 2.0.29: constructors are namespaced per module and `Move` collided with Base's `Event.Move`.
- Built `native/mailbend-tls.c` (verified TLS, login from env, lock-step commands, literal framing) and the Bend core (JSON, codecs, IMAP, MIME, SMTP, ops plans, tools, MCP server).
- Bend constraints shaped the code: no mutual recursion, `match` only on parameters, defs before use, strict `Bool.pick`. Parsers became char-by-char state machines feeding explicit stacks.
- Big string literals overflow the compiler stack; the generated schema is emitted as short concatenated pieces.
- A hang on `mail_get` of a multipart/alternative message was exponential recursion: six functions called themselves in both branches of the strict `Bool.pick`. They were rewritten to recurse once.
- Security review: an attachment `path` could mail out `/proc/self/environ` (which holds the app password); a server answering a literal with tagged OK made the helper send literal bytes as commands. Both fixed.

## Decisions
- One helper process per IMAP/SMTP session via `Process.run`; the helper, not the core, reads the password.
- Tools build IMAP commands only through `src/ops.bend` plans; laws cover plans and the rendered wire form (EXAMINE, BODY.PEEK).
- Attachments only from `MAILBEND_ATTACH_DIR` (realpath, regular files); delete requires the confirmation word inside the proven plan plus the folder's UIDVALIDITY; no plain EXPUNGE ever.

## Outcome
Proofs pass (19 laws); unit 4/4; transport 17/17; e2e 84/84 (CLI and MCP). PR https://github.com/albertc71/MailBend/pull/1.

## Next steps
- Live iCloud run in the target Cursor Cloud Agent (docs/CLOUD_AGENT.md section 5).
- Monitoring watcher (milestone 7) on top of `mail_get_new`.
- Check whether iCloud files SMTP-sent mail in Sent Messages.

> Historical work record — not durable authority. Prefer docs/specs/ADRs for current decisions.
