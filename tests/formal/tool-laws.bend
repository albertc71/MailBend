# Tool-layer laws: proofs about the orchestration in src/tools.bend, kept
# apart from PROOF.bend so the policy proofs never import tool
# orchestration. CI kernel-checks this file with `--verdict`.

import Base
import ../../src/tools.bend as Tools
import ../../src/policy.bend as Policy
import ../../src/json.bend as J
import ../../src/imap.bend as I
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

# Accepted-reply marking is a separate follow-up, never a send retry.
law original_mark_no_request_skips:
  for out: Policy.Out
  {Tools.original_mark.after(out, None{}) == Tools.pure_out(out) : IO(Policy.Out)}

def original_mark_no_request_skips(out):
  match out:
    case Policy.Ok{j}:
      {==}
    case Policy.Err{m}:
      {==}
    case Policy.Partial{j}:
      {==}

law original_mark_errors_skip:
  for msg: String
  for j: J.Json
  for original: Tools.Original
  ({Tools.original_mark.after(Policy.Err{msg}, Some{original}) ==
    Tools.pure_out(Policy.Err{msg}) : IO(Policy.Out)} &
   {Tools.original_mark.after(Policy.Partial{j}, Some{original}) ==
    Tools.pure_out(Policy.Partial{j}) : IO(Policy.Out)})

def original_mark_errors_skip(msg, j, original):
  ({==}, {==})

# Example: empty JSON only; not a universal theorem about absent fields.
law original_mark_defaults_off:
  {Tools.original_request(J.obj([]), True{}) == None{} : Maybe<&2, Tools.Original>}

def original_mark_defaults_off():
  {==}

# Example: the displayed draft JSON only; runtime covers the public gate.
law original_mark_drafts_skip:
  {Tools.original_request(J.obj([
    J.kv("mark_answered", J.bool(True{})), J.kv("as_draft", J.bool(True{}))]), True{}) ==
    None{} : Maybe<&2, Tools.Original>}

def original_mark_drafts_skip():
  {==}

# Example: the displayed preview JSON only; runtime covers the public gate.
law original_mark_dry_runs_skip:
  {Tools.original_request(J.obj([
    J.kv("mark_answered", J.bool(True{})), J.kv("dry_run", J.bool(True{}))]), True{}) ==
    None{} : Maybe<&2, Tools.Original>}

def original_mark_dry_runs_skip():
  {==}

law original_mark_forwards_skip:
  for args: J.Json
  {Tools.original_request(args, False{}) == None{} : Maybe<&2, Tools.Original>}

def original_mark_forwards_skip(args):
  {==}

# Example: Original/7/91 only; the plan laws quantify all identities.
law original_mark_keeps_identity:
  {Tools.original_request(J.obj([J.kv("folder", J.str("Original")), J.kv("uid", J.num(7)),
    J.kv("uidvalidity", J.num(91)), J.kv("mark_answered", J.bool(True{}))]), True{}) ==
    Some{Tools.Original{"Original", 7, 91}} : Maybe<&2, Tools.Original>}

def original_mark_keeps_identity():
  {==}

def reply_evidence(outcome: String) -> Policy.Out:
  Policy.Ok{J.obj([J.kv("sent", J.bool(True{})), J.kv("smtp_outcome", J.str(outcome))])}

# Mixed scope: any original, but only these three concrete evidence objects.
law original_mark_unaccepted_skips:
  for original: Tools.Original
  ({Tools.original_mark.after(reply_evidence("not_sent"), Some{original}) ==
    Tools.pure_out(reply_evidence("not_sent")) : IO(Policy.Out)} &
   {Tools.original_mark.after(reply_evidence("unknown"), Some{original}) ==
    Tools.pure_out(reply_evidence("unknown")) : IO(Policy.Out)} &
   {Tools.original_mark.after(reply_evidence(""), Some{original}) ==
    Tools.pure_out(reply_evidence("")) : IO(Policy.Out)})

def original_mark_unaccepted_skips(original):
  ({==}, {==}, {==})

# Mixed scope: all original identities, with the fixed accepted/sent=true evidence.
# Orchestration shape only: both sides reuse result/fields. Their returned
# values are independently observed by the fixed result examples below.
law original_mark_accepted_runs:
  for folder: String
  for uid: U32
  for uidv: U32
  {Tools.original_mark.after(reply_evidence("accepted"),
    Some{Tools.Original{folder, uid, uidv}}) ==
    do IO<Policy.Out>:
      p : Policy.Proc <- Tools.imap_proc(Ops.plan_answered(folder, uid, uidv))
      return Tools.with_fields(reply_evidence("accepted"),
        Tools.original_mark.fields(Tools.original_mark.result(p,
          Tools.Original{folder, uid, uidv})))
    : IO(Policy.Out)}

def original_mark_accepted_runs(folder, uid, uidv):
  {==}

# Result-evidence observers
# -------------------------
# These laws inspect production result interpretation, not native execution.
# I.has_attr and U32.is_eq are explicit premises, not claims that the server
# is honest or that flags persist. The concrete witnesses below are separate.

# Mixed scope: every original, with deliberately inconsistent accepted/false
# evidence. This pins the independent sent conjunct without sending mail.
law original_mark_sent_false_skips:
  for original: Tools.Original
  {Tools.original_mark.after(Policy.Ok{J.obj([
    J.kv("sent", J.bool(False{})), J.kv("smtp_outcome", J.str("accepted"))])},
    Some{original}) == Tools.pure_out(Policy.Ok{J.obj([
      J.kv("sent", J.bool(False{})), J.kv("smtp_outcome", J.str("accepted"))])}) : IO(Policy.Out)}

def original_mark_sent_false_skips(original):
  {==}

# Keep literal witnesses first so mutants fail on results, not rewrite motives.
# Concrete positive and negative witnesses, not universal parser proofs.
# The Answered witness rules out a classifier that always says unverified.
law original_mark_flag_examples:
  ({Tools.original_mark.flags(Some{[]}) ==
    Tools.OriginalNotMarked{"answered_absent"} : Tools.OriginalMark} &
   {Tools.original_mark.flags(Some{["\\Answered"]}) ==
    Tools.OriginalMarked{} : Tools.OriginalMark} &
   {Tools.original_mark.identity(Some{92}, 91) == "identity_changed" : String})

def original_mark_flag_examples():
  ({==}, {==}, {==})

# Universal conditional promise: a valid observed list lacking Answered
# cannot be reported marked, regardless of any other flags or list length.
law original_mark_absent_flags_not_marked:
  for flags: List<&2, String>
  for absent: {I.has_attr(flags, "\\Answered") == False{} : Bool}
  {Tools.original_mark.flags(Some{flags}) ==
    Tools.OriginalNotMarked{"answered_absent"} : Tools.OriginalMark}

def original_mark_absent_flags_not_marked(flags, absent):
  %Equal.sym(Bool, I.has_attr(flags, "\\Answered"), False{}, absent) :
    {Bool.pick(Tools.OriginalMark, _, Tools.OriginalMarked{},
      Tools.OriginalNotMarked{"answered_absent"}) ==
      Tools.OriginalNotMarked{"answered_absent"} : Tools.OriginalMark}
  {==}

law original_mark_present_flags_marked:
  for flags: List<&2, String>
  for present: {I.has_attr(flags, "\\Answered") == True{} : Bool}
  {Tools.original_mark.flags(Some{flags}) == Tools.OriginalMarked{} : Tools.OriginalMark}

def original_mark_present_flags_marked(flags, present):
  %Equal.sym(Bool, I.has_attr(flags, "\\Answered"), True{}, present) :
    {Bool.pick(Tools.OriginalMark, _, Tools.OriginalMarked{},
      Tools.OriginalNotMarked{"answered_absent"}) == Tools.OriginalMarked{} : Tools.OriginalMark}
  {==}

# Missing evidence is not a valid empty list. This is one concrete constructor.
law original_mark_missing_flags_unverified:
  {Tools.original_mark.flags(None{}) ==
    Tools.OriginalUnverified{"original_not_observed"} : Tools.OriginalMark}

def original_mark_missing_flags_unverified():
  {==}

law original_mark_changed_identity_refuses:
  for now: U32
  for want: U32
  for changed: {U32.is_eq(now, want) == False{} : Bool}
  {Tools.original_mark.identity(Some{now}, want) == "identity_changed" : String}

def original_mark_changed_identity_refuses(now, want, changed):
  %Equal.sym(Bool, U32.is_eq(now, want), False{}, changed) :
    {Bool.pick(String, _, "", "identity_changed") == "identity_changed" : String}
  {==}

law original_mark_incomplete_readback_unverified:
  for lines: List<&2, I.RLine>
  for uid: U32
  {Tools.original_mark.readback(False{}, lines, uid) ==
    Tools.OriginalUnverified{"mark_unverified"} : Tools.OriginalMark}

def original_mark_incomplete_readback_unverified(lines, uid):
  {==}

# Nonempty typed/framed refusal evidence always wins over any flag transcript.
law original_mark_refused_transcript_not_marked:
  for first: Char
  for rest: String
  for lines: List<&2, I.RLine>
  for uid: U32
  for uidv: U32
  {Tools.original_mark.transcript(SCon{first, rest}, lines, uid, uidv) ==
    Tools.OriginalNotMarked{SCon{first, rest}} : Tools.OriginalMark}

def original_mark_refused_transcript_not_marked(first, rest, lines, uid, uidv):
  {==}

# Universal at the parsed-evidence boundary. Parsing and the truth of a
# provider's replies remain distinct runtime/native concerns.
law original_mark_incomplete_transcript_unverified:
  for lines: List<&2, I.RLine>
  for uid: U32
  for uidv: U32
  for incomplete: {(Tools.ok_at(lines, 1) && Tools.ok_at(lines, 2) &&
    Tools.ok_at(lines, 3) && Tools.ok_at(lines, 4) &&
    Tools.uidv_is(I.ok_code(I.replies(lines, 1), "UIDVALIDITY"), uidv)) == False{} : Bool}
  {Tools.original_mark.transcript("", lines, uid, uidv) ==
    Tools.OriginalUnverified{"mark_unverified"} : Tools.OriginalMark}

def original_mark_incomplete_transcript_unverified(lines, uid, uidv, incomplete):
  %Equal.sym(Bool, Tools.ok_at(lines, 1) && Tools.ok_at(lines, 2) &&
    Tools.ok_at(lines, 3) && Tools.ok_at(lines, 4) &&
    Tools.uidv_is(I.ok_code(I.replies(lines, 1), "UIDVALIDITY"), uidv), False{}, incomplete) :
    {Tools.original_mark.readback(_, lines, uid) ==
      Tools.OriginalUnverified{"mark_unverified"} : Tools.OriginalMark}
  {==}

# An accepted, exact-command and exact-UID transcript is a non-vacuous witness.
law original_mark_complete_transcript_example:
  {Tools.original_mark.transcript("", I.frame(
    "* OK [UIDVALIDITY 91] stable\r\na1 OK selected\r\n" ++
    "* SEARCH 7\r\na2 OK searched\r\na3 OK stored\r\n" ++
    "* 1 FETCH (UID 7 FLAGS (\\Answered))\r\na4 OK fetched\r\n"), 7, 91) ==
    Tools.OriginalMarked{} : Tools.OriginalMark}

def original_mark_complete_transcript_example():
  {==}

# Fixed wire examples connect UIDVALIDITY comparison to the actual refusal
# caller. They are not universal parsing or refusal-precedence theorems.
def reply_mark_good_transcript() -> String:
  "* OK [UIDVALIDITY 91] stable\r\na1 OK selected\r\n" ++
  "* SEARCH 7\r\na2 OK searched\r\na3 OK stored\r\n" ++
  "* 1 FETCH (UID 7 FLAGS (\\Answered))\r\na4 OK fetched\r\n"

def reply_mark_changed_transcript() -> String:
  "* OK [UIDVALIDITY 92] changed\r\na1 OK selected\r\n" ++
  "* SEARCH 7\r\na2 OK searched\r\na3 OK stored\r\n" ++
  "* 1 FETCH (UID 7 FLAGS (\\Answered))\r\na4 OK fetched\r\n"

law original_mark_refusal_identity_examples:
  ({Tools.original_mark.refusal(I.frame(reply_mark_good_transcript()), 91) == "" : String} &
   {Tools.original_mark.refusal(I.frame(reply_mark_changed_transcript()), 91) ==
     "identity_changed" : String})

def original_mark_refusal_identity_examples():
  ({==}, {==})

# A fixed accepted reply includes a failed Sent-copy result. Expectations
# below are literal output objects, never derived by the helpers under test.
def reply_mark_accepted_with_failed_copy() -> Policy.Out:
  Policy.Ok{J.obj([J.kv("sent", J.bool(True{})),
    J.kv("smtp_outcome", J.str("accepted")),
    J.kv("sent_copy", J.str("failed or unconfirmed (check Sent before saving again): refused"))])}

# Four concrete returned-output examples cover the result wrapper, refusal
# wiring and all three original_marked encodings together. This is not a
# theorem for arbitrary JSON/transcripts or native/storage/SMTP execution.
law original_mark_result_fields_examples:
  ({Tools.with_fields(reply_mark_accepted_with_failed_copy(),
      Tools.original_mark.fields(Tools.original_mark.result(
        Policy.ProcOk{0, reply_mark_good_transcript(), ""}, Tools.Original{"Original", 7, 91}))) ==
    Policy.Ok{J.obj([J.kv("sent", J.bool(True{})),
      J.kv("smtp_outcome", J.str("accepted")),
      J.kv("sent_copy", J.str("failed or unconfirmed (check Sent before saving again): refused")),
      J.kv("original_marked", J.bool(True{})),
      J.kv("original_mark_reason", J.str("answered_observed"))])} : Policy.Out} &
   {Tools.with_fields(reply_mark_accepted_with_failed_copy(),
      Tools.original_mark.fields(Tools.original_mark.result(
        Policy.ProcOk{0, reply_mark_changed_transcript(), ""}, Tools.Original{"Original", 7, 91}))) ==
    Policy.Ok{J.obj([J.kv("sent", J.bool(True{})),
      J.kv("smtp_outcome", J.str("accepted")),
      J.kv("sent_copy", J.str("failed or unconfirmed (check Sent before saving again): refused")),
      J.kv("original_marked", J.bool(False{})),
      J.kv("original_mark_reason", J.str("identity_changed"))])} : Policy.Out} &
   {Tools.with_fields(reply_mark_accepted_with_failed_copy(),
      Tools.original_mark.fields(Tools.original_mark.result(
        Policy.ProcRefused{"not started"}, Tools.Original{"Original", 7, 91}))) ==
    Policy.Ok{J.obj([J.kv("sent", J.bool(True{})),
      J.kv("smtp_outcome", J.str("accepted")),
      J.kv("sent_copy", J.str("failed or unconfirmed (check Sent before saving again): refused")),
      J.kv("original_marked", J.bool(False{})),
      J.kv("original_mark_reason", J.str("helper_not_started"))])} : Policy.Out} &
   {Tools.with_fields(reply_mark_accepted_with_failed_copy(),
      Tools.original_mark.fields(Tools.original_mark.result(
        Policy.ProcFail{1, "uncertain"}, Tools.Original{"Original", 7, 91}))) ==
    Policy.Ok{J.obj([J.kv("sent", J.bool(True{})),
      J.kv("smtp_outcome", J.str("accepted")),
      J.kv("sent_copy", J.str("failed or unconfirmed (check Sent before saving again): refused")),
      J.kv("original_marked", J.str("unverified")),
      J.kv("original_mark_reason", J.str("mark_unverified"))])} : Policy.Out})

def original_mark_result_fields_examples():
  ({==}, {==}, {==}, {==})

# Fixed stopped transcripts pin refusal output, not arbitrary parsing or
# refusal precedence. SMTP acceptance and the failed Sent copy remain intact.
law original_mark_search_refusal_fields_example:
  {Tools.with_fields(reply_mark_accepted_with_failed_copy(),
      Tools.original_mark.fields(Tools.original_mark.result(
        Policy.ProcOk{0, "* OK [UIDVALIDITY 91] stable\r\na1 OK selected\r\na2 NO search refused\r\n", ""},
        Tools.Original{"Original", 7, 91}))) ==
    Policy.Ok{J.obj([J.kv("sent", J.bool(True{})),
      J.kv("smtp_outcome", J.str("accepted")),
      J.kv("sent_copy", J.str("failed or unconfirmed (check Sent before saving again): refused")),
      J.kv("original_marked", J.bool(False{})),
      J.kv("original_mark_reason", J.str("search_refused"))])} : Policy.Out}

def original_mark_search_refusal_fields_example():
  {==}

law original_mark_store_refusal_fields_example:
  {Tools.with_fields(reply_mark_accepted_with_failed_copy(),
      Tools.original_mark.fields(Tools.original_mark.result(
        Policy.ProcOk{0, "* OK [UIDVALIDITY 91] stable\r\na1 OK selected\r\n" ++
          "* SEARCH 7\r\na2 OK searched\r\na3 NO store refused\r\n", ""},
        Tools.Original{"Original", 7, 91}))) ==
    Policy.Ok{J.obj([J.kv("sent", J.bool(True{})),
      J.kv("smtp_outcome", J.str("accepted")),
      J.kv("sent_copy", J.str("failed or unconfirmed (check Sent before saving again): refused")),
      J.kv("original_marked", J.bool(False{})),
      J.kv("original_mark_reason", J.str("store_refused"))])} : Policy.Out}

def original_mark_store_refusal_fields_example():
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

# The rejected correspondence window returns the selected page without IO.
# Runtime tests cover the clock sample, threshold and callers.
law invalid_brief_clock_keeps_selected_page:
  for p: Tools.BriefPage
  for me: String
  for now: U32
  {Tools.brief_contacts.clock(False{}, p, me, now) ==
    IO.pure(Tools.Shown, Tools.brief_output(p, Tools.contacts_failed("",
      "not scanned: system clock cannot support the 30-day correspondence window"), me, "")) :
    IO(Tools.Shown)}

def invalid_brief_clock_keeps_selected_page(p, me, now):
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
