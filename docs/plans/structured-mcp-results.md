# Structured MCP results

Outcome: publish the existing Bend result through text and structured MCP content
with accurate output contracts for all tools. Preserve CLI, error semantics,
safety restrictions, body evidence and the supported protocol revisions.

Non-goals: new mail operations, a wire-size cap, or a newer MCP lifecycle.

- [x] Trace result constructors and preserve one shared JSON result.
- [x] Carry negotiated structured-content support across input chunks.
- [x] Describe read, change, interrupted, blocked, preview, compose and Jev results.
- [x] Validate schemas against the existing end-to-end scenario matrix on e0547cd CI.
- [x] Open isolated draft PR35; original contributor CI passed.
- [ ] Revalidate the expanded integration contracts and combined runtime.

Acceptance: older clients retain legacy fields; modern text decodes exactly to
structured content; actual results validate; malformed requests and hidden tools
remain refused; generated schema pins agree. Revert the commit to roll back.

Integration dependency: the output contracts also describe the accepted result
variants from SMTP outcomes (#20), projections (#22), MIME sections (#23),
pagination (#24), and refresh (#29). Each remains a closed record with required
evidence. Their operations and input options belong to their independent PRs;
these definitions do not enable them on this branch. Legacy result variants
remain accepted. Selected response projections preserve source completeness and
add response.content_complete for the representation actually returned.

Focused schema cases exercise valid and invalid combinations, including accepted
SMTP results whose Sent filing failed. Combined runtime testing remains necessary:
a schema fixture check is not a proof that every constructor always conforms.
