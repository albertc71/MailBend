# Tool-layer laws: proofs about the orchestration in src/tools.bend, kept
# apart from PROOF.bend so the policy proofs never import tool
# orchestration. CI kernel-checks this file with `--verdict`.

import Base
import ../../src/tools.bend as Tools
import ../../src/policy.bend as Policy

# Outgoing checks
# ---------------

# LAW: a refused outgoing check returns only an error. It never reaches the
# stamp, SMTP envelope builder or Drafts APPEND, for either delivery mode.
law hidden_tags_refuse_send_and_draft:
  for first: Char
  for rest: String
  for w: Tools.Want
  for from: String
  {Tools.with_atts.if(SCon{first, rest}, w, from) ==
    Tools.pure_out(Policy.Err{SCon{first, rest}}) : IO(Policy.Out)}

def hidden_tags_refuse_send_and_draft(first, rest, w, from):
  {==}
