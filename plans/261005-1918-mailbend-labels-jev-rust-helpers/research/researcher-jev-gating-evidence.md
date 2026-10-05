# Research: where Jev belongs in MailBend's tool calls

Date: 2026-10-05. Read-only research; vendor figures are self-reported.

## Conclusion adopted

Tiered Jev (user decision after this research): veto before
send/reply/forward (attachments included) and permanent delete, failing
closed; typed annotations on `mail_get` results; a headers-only pass on
search, new mail and threads; `mail_classify` and `mail_triage` as tools; no
Jev on reversible changes, folder operations or downloads. A separate
`mailbend-typesafe` helper makes the HTTPS call.

Why not before every call: a pre-call check on a read sees only arguments
(content arrives in the result) and reads are already proven read-only;
reversible actions are covered by deterministic checks.

## Evidence

| Claim | Figure | Source | Confidence |
| --- | --- | --- | --- |
| Price | $0.042 per million input tokens, output free | https://docs.typesafe.ai/models.md | High |
| Limits | 80 req/s, 100K tok/s, 64k per request, 32k state + longest question, text only, limits "can change without notice" | same | High |
| Latency, 14 Nouls ~1k tokens | 111 ms mean vs 1.1-13.9 s for LLMs | https://docs.typesafe.ai/cookbooks/consistency_noul_cookbook.md | High (one run) |
| Batching | 13 questions in one call: 0.27 s, $0.000497 vs 13 calls 2.71 s, $0.006090 | https://docs.typesafe.ai/cookbooks/parallel_questions.md | High |
| Consistency | mean per-question std dev 0.0102; one answer spanned 0.43-0.53 across repeats; "does not measure accuracy" | noul cookbook | High |
| Not a security boundary | "The injection question is a filter... Nothing here is a security boundary"; adversarial content "can move the answer" | https://docs.typesafe.ai/cookbooks/classifying_rag_passages.md, https://docs.typesafe.ai/model-jaggedness/jev-1.13.md | High |
| Version drift | `jev-latest` moves; pin the version when thresholds are tuned | models page | High |
| Agent benefit analogue | skill suggestion: wrong loads 16.8% to 7.3% (jev-1.12, vendor-run) | https://docs.typesafe.ai/cookbooks/skill_suggestion.md | Medium |
| Untrusted input must not trigger consequential actions | design patterns incl. LLM map-reduce with structured outputs, dual LLM | https://arxiv.org/abs/2506.08837 | High |
| Human approval for high-impact actions; authorization outside the LLM | OWASP LLM06:2025 | https://genai.owasp.org/llmrisk/llm062025-excessive-agency/ | High |
| Human in the loop able to deny tool calls; annotations untrusted | MCP spec 2025-06-18 | https://modelcontextprotocol.io/specification/2025-06-18/server/tools | High |
| Classifiers are bypassed by adaptive attacks | 12 defenses bypassed, mostly >90% success | https://arxiv.org/abs/2510.09023 | High |
| Layering helps but does not eliminate | Prompt Guard 2: AgentDojo ASR 17.6% to 7.5% | https://arxiv.org/abs/2505.03574 | High |
| Constrained outputs keep tainted text out of control flow | CaMeL 77% tasks with provable security vs 84% undefended | https://arxiv.org/abs/2503.18813 | High |
| Less context improves accuracy | "a single distractor reduces performance" | https://www.trychroma.com/research/context-rot | High |
| Email-triage annotations reduce agent effort | no study found | n/a | Unverified |

## Design rules taken from the evidence

- Jev answers are `derived_from_untrusted_content`; never presented as
  approval.
- Omit `suspected_injection` unless flagged (a `false` invites false
  confidence).
- `suggested_action` only takes non-sending, non-destructive values.
- Pin `jev-1.13.0`, not `jev-latest`.
- Send minimal fields; bodies only with the zero-retention attestation.
- A blocked send says the agent may save a draft instead; it never
  substitutes the operation (the veto law forbids substitution).

## Corrections to the research

- It counted 16 tools; `tools/gen-schema.py` defines 14 (verified by grep),
  so "14 tools" in README and ARCHITECTURE is currently accurate and becomes
  stale only when this plan adds tools.
