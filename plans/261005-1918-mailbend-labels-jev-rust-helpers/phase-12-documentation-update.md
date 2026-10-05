---
phase: 12
title: "Phase 12: Documentation update"
status: todo
priority: P1
effort: "1d"
dependencies: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
---

# Phase 12: Documentation update

## Goal

Bring every document in the repository, including the tool descriptions
agents read, in line with the tiered Jev decisions, the new tools and the Rust
helpers, with wording checked against the code, and stop counts from
drifting again.

## Evidence

- User asked for a dedicated phase so all wording is correct now that Jev is
  part of MailBend's tool calls (tiered: vetoes before outbound and
  irreversible actions, annotations on mail content).
- Documentation has already drifted: `docs/ARCHITECTURE.md:39` says "27 laws
  proven over the plans" while `LAWS.bend` has 42 laws;
  `README.md:228` and `docs/ARCHITECTURE.md:37,176` say "14 tools", which
  this plan changes.
- Tool descriptions in `tools/gen-schema.py` are what agents read; they must
  describe the `jev` result object, vetoes and dry runs accurately.
- `.github/CODEOWNERS` lists safety-critical paths (`/native/`, `LAWS.bend`,
  `PROOF.bend`, `src/ops.bend`, ...); `src/jev.bend` decides vetoes and joins
  that list.

## Documents and what changes

| File | Changes |
| --- | --- |
| `README.md` | A "Why MailBend" section near the top that states MailBend's own strengths without comparing it to other projects or naming them, each point backed by a source in this repo (laws proven for every input; same-session UIDVALIDITY pinning; agent-facing core never reads the password; sandboxed attachment reader with tests for `/proc/self/environ` and symlinks; fail-closed switches that hide tools; iCloud live-tested; no daemon or database), plus honest limits (Linux only, password login only, iCloud-only live testing); then the tools table (all new tools, which change mail, which Jev checks); Configure (every new variable); a "Jev decisions" section: when it runs, what leaves the machine, the `jev` result object, veto-only guarantee, failure policy, cost and latency, zero retention is the operator's claim; Safety (labels copy only, folder deletion rules, allowlist law, Rust helpers, which laws exist); Install (Rust toolchain); Development (cargo checks); "Not yet" pruned; Known limits updated; mermaid diagram labels |
| `AGENTS.md` | Native boundaries for the Rust helpers: `mailbend-attach` becomes credential-free sandboxed local file access (attachments, downloads, the send counter) with no mail policy; the new `mailbend-typesafe` (key file only, allow-listed environment, fixed host, returns typed answers, never decides); reworded mailbox-creation rule (line 42); Jev may only veto or annotate, never widen a plan, and never resolves folder roles; TypeSafe key read only by `mailbend-typesafe` from `MAILBEND_TYPESAFE_KEY_FILE`; the core never sees it; checks before committing gain cargo commands |
| `docs/ARCHITECTURE.md` | Component and sequence diagrams with Jev and Rust helpers; per-call Jev flow; enforcement table rows for every new law; file map with `src/jev.bend`, `src/thread.bend`, `native/` workspace |
| `native/README.md` | Rust workspace layout, build, modes (`imap`, `smtp`, `--check`; attach read form, `save` and `count`; `mailbend-typesafe`), exit codes, environment variables, security properties |
| `docs/CLOUD_AGENT.md` | Rust install in setup and rebuild recovery; Jev secrets for cloud agents; live iCloud checklist for the new features (from phase 13) |
| `CONTRIBUTING.md` | Rust toolchain, cargo checks, how to add a tool with its Jev question set and laws |
| `SECURITY.md` | Scope adds the TypeSafe key and data sent to TypeSafe |
| `.env.example` | Every new variable with fail-closed notes |
| `.github/PULL_REQUEST_TEMPLATE.md` | Checklist items for cargo checks and laws if it lists checks |
| `.github/CODEOWNERS` | `/src/jev.bend`, `/native/` stays |
| `tools/gen-schema.py` | Every tool description mentions the `jev` field, `dry_run`, and vetoes where they apply; regenerate `src/schema.bend` |
| `LAWS.bend` header comments | Name what the laws cover now (Jev policy, labels, allowlist) and what they do not (Rust helpers, TypeSafe accuracy) |

## Discoverability (user's open-source goal)

- README first screen: one sentence on what MailBend is and its main
  strength ("safety rules proven by the compiler for every input"), then
  install in three commands. No comparison with, or naming of, other
  connectors (user decision).
- GitHub topics and description: `mcp`, `mcp-server`, `imap`, `smtp`,
  `icloud`, `email`, `ai-agents`, `bend` (set by the user in repo settings).
- Directory listings (official MCP Registry, awesome-mcp-servers) publish
  under the user's name: listed as steps for the user; a registry
  `server.json` is prepared only if the user confirms.

## Design

- Remove hard-coded counts ("14 tools", "27 laws") in favour of wording
  that cannot drift ("the tools listed below", "the laws in `LAWS.bend`").
- Wording rules: say "Jev can block or annotate; it never approves an action
  on its own"; never call the confirmation word or a Jev answer "approval";
  say "unverified" for anything the live check has not confirmed.

## Steps

1. Grep for stale terms: `C helper`, `OpenSSL`, `libcurl`, `mailbend-tls.c`,
   `mailbend-attach.c`, `14 tools`, `27 laws`, `never creates a mailbox`,
   `Not yet`; fix each hit. Keep `build-essential`/clang: ring's build and
   the core still need a C compiler.
2. Rewrite each document per the table, verifying every claim against the
   source line it describes.
3. Regenerate the schema (CI already checks it is current,
   `.github/workflows/ci.yml:43-46`).
4. Render-check mermaid blocks (GitHub preview on the PR).

## Verification

- `python3 tools/gen-schema.py && git diff --exit-code -- src/schema.bend`.
- Every tool in `tools/gen-schema.py` appears in the README tools table and
  every `MAILBEND_*` variable read by the code appears in `.env.example`
  (checked by hand in this phase).
- `grep -rn "27 laws\|14 tools\|mailbend-tls.c" --include=*.md .` finds
  nothing outside `plans/`.

## Risks

- Docs describing unverified iCloud behaviour: every such sentence links to
  the live checklist and says "unverified" until the user's run.
