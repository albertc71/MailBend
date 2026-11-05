# Tool-layer laws: proofs about the orchestration in src/tools.bend, kept
# apart from PROOF.bend so the policy proofs never import tool
# orchestration. CI kernel-checks this file with `--verdict`.

import Base
import ../../src/tools.bend as Tools
import ../../src/policy.bend as Policy
import ../../src/json.bend as J
import ../../src/ops.bend as Ops
import ../../src/jev.bend as Jev

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

# Unknown time refuses composition regardless of either random result.
law unknown_clock_refuses_stamp:
  for a: Result<&1, &1, U32 & String, U32>
  for b: Result<&1, &1, U32 & String, U32>
  {Tools.stamp_checked(0, a, b) ==
    Fail{"system clock is unavailable or invalid"} : Result<&2, &2, String, Tools.Stamp>}

def unknown_clock_refuses_stamp(a, b):
  {==}

# The reservation-time refusal is pure IO, with no counter or SMTP effect,
# including when the daily limit is zero.
law unknown_clock_refuses_reservation:
  for envelope: String
  for limit: U32
  for dir: String
  for s: Tools.Sent
  {Tools.send_allowed.clock(Tools.clock_checked(0), envelope, limit, dir, s) ==
    Tools.pure_out(Tools.send_not_attempted(
      Policy.Err{"system clock is unavailable or invalid; nothing was sent"})) : IO(Policy.Out)}

def unknown_clock_refuses_reservation(envelope, limit, dir, s):
  {==}

# Offline posture
# ---------------

# Offline posture uses the same refusal gate; it cannot grant sending.
law posture_send_matches_gate:
  for ro: Bool
  for drafts: Bool
  for jev: Bool
  {Tools.posture_send_allowed(ro, drafts, jev) ==
    String.is_empty(Policy.refusal(Ops.OSend{}, J.obj([]), ro, drafts, jev)) : Bool}

def posture_send_matches_gate(ro, drafts, jev):
  {==}

law posture_body_matches_switch:
  for content: Jev.Content
  ({Tools.posture_body(Jev.On{content}) == Jev.is_body(content) : Bool} &
   {Tools.posture_body(Jev.Off{}) == False{} : Bool})

def posture_body_matches_switch(content):
  match content:
    case Jev.Headers{}:
      ({==}, {==})
    case Jev.Body{}:
      ({==}, {==})

law posture_images_match_permission:
  ({Tools.posture_images(Jev.ImagesOn{}) == True{} : Bool} &
   {Tools.posture_images(Jev.ImagesOff{}) == False{} : Bool})

def posture_images_match_permission():
  ({==}, {==})

law posture_read_only_changes_nothing:
  {Tools.posture_state_change(True{}) == False{} : Bool}

def posture_read_only_changes_nothing():
  {==}

law posture_send_label_matches_gate:
  for ro: Bool
  for drafts: Bool
  for jev: Bool
  for restricted: Bool
  {String.eq(Tools.posture_send_kind(Tools.posture_send_allowed(ro, drafts, jev), restricted),
    "none") == Bool.not(String.is_empty(
      Policy.refusal(Ops.OSend{}, J.obj([]), ro, drafts, jev))) : Bool}

def posture_send_label_matches_gate(ro, drafts, jev, restricted):
  match ro drafts jev restricted:
    case True{} _ _ _:
      {==}
    case False{} True{} _ _:
      {==}
    case False{} False{} True{} True{}:
      {==}
    case False{} False{} True{} False{}:
      {==}
    case False{} False{} False{} True{}:
      {==}
    case False{} False{} False{} False{}:
      {==}

law posture_text_list_matches_switch:
  for s: Jev.Switch
  {List.is_empty(&2, String, Tools.posture_text_tools(s)) == Bool.not(Tools.posture_body(s)) : Bool}

def posture_text_list_matches_switch(s):
  match s:
    case Jev.Off{}:
      {==}
    case Jev.On{Jev.Headers{}}:
      {==}
    case Jev.On{Jev.Body{}}:
      {==}

law posture_image_list_matches_permission:
  for m: Jev.ImageMode
  {List.is_empty(&2, String, Tools.posture_image_tools(m)) ==
    Bool.not(Tools.posture_images(m)) : Bool}

def posture_image_list_matches_permission(m):
  match m:
    case Jev.ImagesOn{}:
      {==}
    case Jev.ImagesOff{}:
      {==}

law posture_mailbend_trust_precedes_ssl:
  for file: Bool
  for dirs: Bool
  {Tools.posture_trust_source(True{}, file, dirs) == Tools.PostureMailbendCaFile{} :
    Tools.PostureTrustSource}

def posture_mailbend_trust_precedes_ssl(file, dirs):
  {==}

law posture_ssl_file_presence_selects_override:
  for dirs: Bool
  {Tools.posture_trust_source(False{}, True{}, dirs) == Tools.PostureSslCertEnv{} :
    Tools.PostureTrustSource}

def posture_ssl_file_presence_selects_override(dirs):
  {==}

law posture_trust_without_overrides_is_system:
  {Tools.posture_trust_source(False{}, False{}, False{}) == Tools.PostureSystemTrust{} :
    Tools.PostureTrustSource}

def posture_trust_without_overrides_is_system():
  {==}
