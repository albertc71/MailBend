# Structured MCP results

Outcome: publish the existing Bend result through text and structured MCP content
with accurate output contracts for all tools. Preserve CLI, error semantics,
safety restrictions, body evidence and the supported protocol revisions.

Non-goals: new mail operations, a wire-size cap, or a newer MCP lifecycle.

- [x] Trace result constructors and preserve one shared JSON result.
- [x] Carry negotiated structured-content support across input chunks.
- [x] Describe read, change, interrupted, blocked, preview, compose and Jev results.
- [ ] Validate schemas against the existing end-to-end scenario matrix.
- [ ] Run contributor checks, review, commit and open the isolated draft PR.

Acceptance: older clients retain legacy fields; modern text decodes exactly to
structured content; actual results validate; malformed requests and hidden tools
remain refused; generated schema pins agree. Revert the commit to roll back.
