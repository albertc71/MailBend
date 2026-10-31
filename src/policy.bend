# Pure mail policy: switches, helper outcomes and role-folder resolution.

import Base
import ./json.bend as J
import ./imap.bend as I
import ./smtp.bend as S
import ./ops.bend as Ops
import ./jev.bend as Jev

# Results
# =======

# A tool's result: its JSON, or an error for the caller.
type Out is Data:
  Ok{j: J.Json}
  Err{msg: String}
  # An error for the caller that still carries a result: a change that
  # stopped part-way, or a refusal that reports what the call found.
  Partial{j: J.Json}

# The folders, and the one resolved for each special-use role.
type Folders is Data:
  Folders{
    fs: List<&2, I.Folder>,
    drafts: Maybe<&2, String>,
    trash: Maybe<&2, String>,
    sent: Maybe<&2, String>,
    junk: Maybe<&2, String>,
    archive: Maybe<&2, String>
  }

# A check's problem ("" for none) as a Result, so checks chain in `do`.
def checked(problem: String) -> Result<&2, &2, String, Unit>:
  match problem:
    case SNil{}:
      Done{Unit{}}
    case SCon{h, t}:
      Fail{SCon{h, t}}

# Safety switches
# ---------------

# The switches every tool depends on. A value that is not clearly on or off
# is refused rather than read as off: MAILBEND_READ_ONLY=yes must not leave
# writes on. ConfigBad fails every tool.
type Config is Data:
  Config{read_only: Bool, drafts_only: Bool, jev: Jev.Switch, images: Jev.ImageMode}
  ConfigBad{msg: String}

type Flag is Data:
  FlagOn{}
  FlagOff{}
  FlagBad{msg: String}

def flag_value.if(off: Bool, on: Bool, name: String) -> Flag:
  match off on:
    case True{} _:
      FlagOff{}
    case False{} True{}:
      FlagOn{}
    case False{} False{}:
      FlagBad{name ++ " must be 1, true, 0, false or empty"}

def flag_value(name: String, +v: String) -> Flag:
  +low = String.to_lower(v)
  off = String.is_empty(v) || String.eq(v, "0") || String.eq(low, "false")
  on = String.eq(v, "1") || String.eq(low, "true")
  flag_value.if(off, on, name)

def flag_on(f: Flag) -> Result<&2, &2, String, Bool>:
  match f:
    case FlagOn{}:
      Done{True{}}
    case FlagOff{}:
      Done{False{}}
    case FlagBad{m}:
      Fail{m}

# The TypeSafe key is read only from its file, by mailbend-typesafe: in an
# environment variable it would reach every helper, mailbend-tls included.
def api_key_problem(set: Bool) -> String:
  Bool.pick(String, set,
    "MAILBEND_TYPESAFE_API_KEY must not be set: put the TypeSafe key in a file readable only " ++
      "by you and set MAILBEND_TYPESAFE_KEY_FILE to its absolute path",
    "")

def content_of.if(headers: Bool, body: Bool) -> Result<&2, &2, String, Jev.Content>:
  match headers body:
    case True{} _:
      Done{Jev.Headers{}}
    case False{} True{}:
      Done{Jev.Body{}}
    case False{} False{}:
      Fail{"MAILBEND_TYPESAFE_CONTENT must be headers, body or empty"}

# MAILBEND_TYPESAFE_CONTENT: what Jev may see, headers (the default) or body.
def content_of(+v: String) -> Result<&2, &2, String, Jev.Content>:
  +low = String.to_lower(v)
  content_of.if(String.is_empty(v) || String.eq(low, "headers"), String.eq(low, "body"))

# Body content sends message text to TypeSafe, so it needs the operator's
# MAILBEND_TYPESAFE_ZERO_RETENTION=1 (MailBend cannot verify the plan).
def attested(c: Jev.Content, zero_retention: Bool) -> Result<&2, &2, String, Jev.Content>:
  match c zero_retention:
    case Jev.Headers{} _:
      Done{Jev.Headers{}}
    case Jev.Body{} True{}:
      Done{Jev.Body{}}
    case Jev.Body{} False{}:
      Fail{"MAILBEND_TYPESAFE_CONTENT=body sends message text to TypeSafe and needs " ++
        "MAILBEND_TYPESAFE_ZERO_RETENTION=1, the operator's statement that the TypeSafe " ++
        "account has a zero-retention plan"}

# Jev on needs the absolute path of the key file (which only
# mailbend-typesafe reads).
def jev_switch(on: Bool, c: Jev.Content, absolute: Bool) -> Result<&2, &2, String, Jev.Switch>:
  match on absolute:
    case False{} _:
      Done{Jev.Off{}}
    case True{} True{}:
      Done{Jev.On{c}}
    case True{} False{}:
      Fail{"MAILBEND_TYPESAFE_KEY_FILE must be the absolute path of the TypeSafe key file " ++
        "when MAILBEND_TYPESAFE is on"}

# The switches, checked in this order; the first bad value fails every tool,
# including a TypeSafe setting while Jev is off.
# Off, or on together with body content. On in headers mode, or without
# the zero-retention statement, is refused. attested still fails first when
# body mode lacks that statement.
def image_mode(on: Bool, c: Jev.Content) -> Result<&2, &2, String, Jev.ImageMode>:
  match on c:
    case False{} _:
      Done{Jev.ImagesOff{}}
    case True{} Jev.Body{}:
      Done{Jev.ImagesOn{}}
    case True{} Jev.Headers{}:
      Fail{"MAILBEND_TYPESAFE_IMAGES needs MAILBEND_TYPESAFE_CONTENT=body and " ++
        "MAILBEND_TYPESAFE_ZERO_RETENTION=1"}

def config_of(
  read_only: Flag,
  drafts_only: Flag,
  api_key_set: Bool,
  typesafe: Flag,
  content: String,
  zero_retention: Flag,
  images: Flag,
  key_file: String
) -> Result<&2, &2, String, Config>:
  do Result<&2, &2, String, Config>:
    ro : Bool <- flag_on(read_only)
    drafts : Bool <- flag_on(drafts_only)
    key_ok : Unit <- checked(api_key_problem(api_key_set))
    on : Bool <- flag_on(typesafe)
    wanted : Jev.Content <- content_of(content)
    zr : Bool <- flag_on(zero_retention)
    +c : Jev.Content <- attested(wanted, zr)
    images_on : Bool <- flag_on(images)
    mode : Jev.ImageMode <- image_mode(images_on, c)
    jev : Jev.Switch <- jev_switch(on, c, String.starts_with(key_file, "/"))
    return Config{ro, drafts, jev, mode}

def config.put(r: Result<&2, &2, String, Config>) -> Config:
  match r:
    case Done{c}:
      c
    case Fail{m}:
      ConfigBad{m}

# Running the helper
# ------------------

# How a helper run ended: it exited with `code`; it never started (MailBend
# refused its path, or spawning it failed); or it failed with errno `code`
# after it started, or when that is not known, so what it did is unknown.
type Proc is Data:
  ProcOk{code: U32, out: String, err: String}
  ProcRefused{msg: String}
  ProcFail{code: U32, msg: String}

# Errnos only spawning can give (Process.run: the pipes, posix_spawnp), with
# the values Linux and macOS share: EPERM, ENOENT, E2BIG, ENOEXEC, EACCES,
# ENOTDIR, EISDIR, ENFILE, EMFILE, ETXTBSY. Once the helper runs, Process.run
# fails only with others (timeout, output cap, poll, read, write, waitpid).
def spawn_errnos() -> List<&2, U32>:
  [1, 2, 7, 8, 13, 20, 21, 23, 24, 26]

def never_started(code: U32) -> Bool:
  List.contains(~U32, ~U32.is_eq, spawn_errnos(), code)

def proc_fail.if(refused: Bool, code: U32, msg: String) -> Proc:
  match refused:
    case True{}:
      ProcRefused{msg}
    case False{}:
      ProcFail{code, msg}

def proc_fail(+code: U32, msg: String) -> Proc:
  proc_fail.if(never_started(code), code, msg)

def proc_of(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> Proc:
  match r:
    case Done{(code, (out, err))}:
      ProcOk{code, out, err}
    case Fail{(code, msg)}:
      proc_fail(code, msg)

# Why a helper run gave no exit status ("" when it did).
def proc_failure(p: Proc) -> String:
  match p:
    case ProcOk{code, out, err}:
      ""
    case ProcRefused{m}:
      m
    case ProcFail{code, m}:
      m

# Helper results
# --------------

def strip_prefix.if(has: Bool, s: String, p: String) -> String:
  match has:
    case True{}:
      String.drop(s, String.length(p))
    case False{}:
      s

def strip_prefix(+s: String, +p: String) -> String:
  strip_prefix.if(String.starts_with(s, p), s, p)

# A helper's own message, from its stderr (which never holds credentials):
# its lines, last first, without the program's `prefix`.
def stderr_msg(err: String, prefix: String) -> String:
  lines = List.reverse(&2, String, String.lines(String.trim(err)))
  strip_prefix(String.trim(String.join(lines, " | ")), prefix)

def helper_msg(err: String) -> String:
  stderr_msg(err, "mailbend-tls: ")

# Process.run reports a helper killed by a signal as exit status 128 plus the
# signal; mailbend-tls itself exits with at most 6.
def signalled(code: U32) -> Bool:
  U32.is_gt(code, 128)

# What a helper's exit status means, as the start of its error.
def helper_cause(code: U32) -> String:
  match code:
    case 2:
      "configuration error: "
    case 3:
      "connection or TLS verification failed: "
    case 4:
      "authentication failed (check MAILBEND_EMAIL and the app-specific password): "
    case _:
      Bool.pick(String, signalled(code), "the TLS helper was killed by a signal: ",
        "mail server error: ")

def helper_error(code: U32, err: String) -> String:
  helper_cause(code) ++ helper_msg(err)

# Whether the helper may have acted on the mailbox without leaving a whole
# transcript: it failed after it started (or may have), or a signal killed
# it. The one classifier for flag changes, COPY-based moves and folder
# changes. A helper that never started did nothing.
def helper_lost(p: Proc) -> Bool:
  match p:
    case ProcOk{code, out, err}:
      signalled(code)
    case ProcRefused{m}:
      False{}
    case ProcFail{code, m}:
      True{}

def smtp_phase.step(line: String, phase: String) -> String:
  match line:
    case "mailbend-smtp: before_data":
      "before_data"
    case "mailbend-smtp: data_started":
      "data_started"
    case "mailbend-smtp: data_accepted":
      "data_accepted"
    case "mailbend-smtp: data_rejected":
      "data_rejected"
    case _:
      phase

# Outcome and bounded protocol phase/reason; guidance belongs to Bend.
def smtp_fields(outcome: String, phase: String, reason: String, next: String) ->
  List<&2, J.Json>:
  [J.kv("smtp_outcome", J.str(outcome)), J.kv("smtp_phase", J.str(phase)),
    J.kv("smtp_reason", J.str(reason)), J.kv("next_action", J.str(next))]

def smtp_failure(msg: String, +outcome: String, phase: String, reason: String) -> Out:
  next = Bool.pick(String, String.eq(outcome, "unknown"),
    "Do not retry automatically. Check server records or ask the recipient; a missing " ++
      "Sent copy does not prove non-delivery.",
    "SMTP did not accept this message. Resolve the reported problem before a new attempt.")
  Partial{J.obj(J.kv("error", J.str(msg)) <> smtp_fields(outcome, phase, reason, next))}

# Fixed native progress comes only from stderr, never from server replies.
# Keep the latest marker; absence is not proof that DATA was never sent.
def smtp_phase(lines: List<&2, String>, phase: String) -> String:
  match lines:
    case Nil{}:
      phase
    case line <> rest:
      smtp_phase(rest, smtp_phase.step(String.trim(line), phase))

# Progress is a separate machine channel, not part of the human error.
def smtp_diagnostics(lines: List<&2, String>) -> List<&2, String>:
  match lines:
    case Nil{}:
      []
    case +line <> rest:
      List.filter.put(String, line, smtp_diagnostics(rest),
        Bool.not(String.starts_with(line, "mailbend-smtp: ")))

def smtp_error(code: U32, out: String, err: String) -> String:
  match code:
    case 0:
      "the helper reported completion without acceptance evidence"
    case 5:
      "the SMTP server refused the message: " ++ S.last_error(String.lines(out), "")
    case _:
      helper_error(code, err)

# Native data_started/data_accepted/data_rejected map to public data_reply;
# before_data stays before_data, and missing progress is unknown. Only the
# data_accepted marker is acceptance evidence, regardless of process exit.
def smtp_code.phase(phase: String, code: U32, out: String, err: String) -> Out:
  match phase:
    case "data_accepted":
      Ok{J.str(S.last_ok(String.lines(out), ""))}
    case "before_data":
      smtp_failure(smtp_error(code, out, err), "not_sent", "before_data", "stopped_before_data")
    case "data_rejected":
      smtp_failure("the SMTP server refused the message: " ++ S.last_error(String.lines(out), ""),
        "not_sent", "data_reply", "explicit_rejection")
    case "data_started":
      smtp_failure(helper_error(code, err), "unknown", "data_reply", "acceptance_unconfirmed")
    case _:
      smtp_failure("SMTP progress is missing; acceptance is unknown: " ++
        smtp_error(code, out, err),
        "unknown", "unknown", "missing_progress")

def smtp_code(code: U32, out: String, +err: String) -> Out:
  smtp_code.phase(smtp_phase(String.lines(err), ""), code, out,
    String.join(smtp_diagnostics(String.lines(err)), "\n"))

def smtp_result(p: Proc) -> Out:
  match p:
    case ProcOk{code, out, err}:
      smtp_code(code, out, err)
    case ProcRefused{m}:
      smtp_failure("cannot run the TLS helper: " ++ m,
        "not_sent", "before_smtp", "helper_not_started")
    case ProcFail{code, m}:
      smtp_failure("cannot run the TLS helper: " ++ m,
        "unknown", "unknown", "missing_progress")

# Arguments and JSON
# ==================

# Arguments
# ---------

def str_arg(args: J.Json, key: String, d: String) -> String:
  Maybe.default(&2, String, J.as_str(J.get(args, key)), d)

def bool_arg(args: J.Json, key: String, d: Bool) -> Bool:
  Maybe.default(&2, Bool, J.as_bool(J.get(args, key)), d)

# Special-use attributes
# ----------------------

# A special-use attribute and the role name the tools report for it.
type RoleAttr is Data:
  RoleAttr{attr: String, name: String}

# The special-use roles MailBend recognises, in the order role_of reports them.
def role_attrs() -> List<&2, RoleAttr>:
  [
    RoleAttr{"\\Drafts", "drafts"},
    RoleAttr{"\\Sent", "sent"},
    RoleAttr{"\\Trash", "trash"},
    RoleAttr{"\\Junk", "junk"},
    RoleAttr{"\\Archive", "archive"},
    RoleAttr{"\\All", "all"},
    RoleAttr{"\\Flagged", "flagged"}
  ]

# The first of `roles` that `attrs` advertises.
def role_in(roles: List<&2, RoleAttr>, +attrs: List<&2, String>) -> Maybe<&2, String>:
  match roles:
    case Nil{}:
      None{}
    case RoleAttr{attr, name} <> t:
      Bool.pick(Maybe<&2, String>, I.has_attr(attrs, attr), Some{name}, role_in(t, attrs))

# Attribute checks retain the server's actual LIST metadata. Role resolution
# never adds attributes to a conventionally named or overridden mailbox.
def recognized_role(attrs: List<&2, String>) -> Bool:
  Maybe.is_some(&2, String, role_in(role_attrs(), attrs))

def selectable(+attrs: List<&2, String>) -> Bool:
  Bool.not(I.has_attr(attrs, "\\Noselect") || I.has_attr(attrs, "\\NonExistent"))

# Role resolution
# ---------------

# Whether a folder may take the role: with `advertised`, it carries the
# role's attribute; otherwise it has one of the conventional names `a` and
# `b`, can be selected, and advertises no role of its own.
def role_match(
  advertised: Bool,
  +name: String,
  +attrs: List<&2, String>,
  attr: String,
  a: String,
  b: String
) -> Bool:
  match advertised:
    case True{}:
      I.has_attr(attrs, attr)
    case False{}:
      (I.same_name(name, a) || I.same_name(name, b)) && selectable(attrs) &&
        Bool.not(recognized_role(attrs))

# Keep all matches until uniqueness has been established. An advertised but
# unselectable role still blocks fallback to a different mailbox.
def role_candidates(
  fs: List<&2, I.Folder>,
  +attr: String,
  +a: String,
  +b: String,
  +advertised: Bool
) -> List<&2, I.Folder>:
  match fs:
    case Nil{}:
      []
    case I.Folder{+name, delimiter, +attrs} <> t:
      List.filter.put(I.Folder, I.Folder{name, delimiter, attrs},
        role_candidates(t, attr, a, b, advertised),
        role_match(advertised, name, attrs, attr, a, b))

def unique_folder(fs: List<&2, I.Folder>) -> Maybe<&2, String>:
  match fs:
    case I.Folder{name, d, attrs} <> Nil{}:
      Bool.pick(Maybe<&2, String>, selectable(attrs), Some{name}, None{})
    case _:
      None{}

def role_fallback(
  marked: List<&2, I.Folder>,
  fs: List<&2, I.Folder>,
  attr: String,
  a: String,
  b: String
) -> Maybe<&2, String>:
  match marked:
    case Nil{}:
      unique_folder(role_candidates(fs, attr, a, b, False{}))
    case _:
      unique_folder(marked)

def role(+fs: List<&2, I.Folder>, +attr: String, +a: String, +b: String) -> Maybe<&2, String>:
  role_fallback(role_candidates(fs, attr, a, b, True{}), fs, attr, a, b)

def override_candidates(fs: List<&2, I.Folder>, +want: String) -> List<&2, I.Folder>:
  match fs:
    case Nil{}:
      []
    case +f <> t:
      I.Folder{name, d, attrs} = f
      List.filter.put(I.Folder, f, override_candidates(t, want), I.same_name(name, want))

# The one selectable folder named `name`, if there is exactly one.
def named_folder(fs: List<&2, I.Folder>, name: String) -> Maybe<&2, String>:
  unique_folder(override_candidates(fs, name))

def resolved_role.if(
  unset: Bool,
  fs: List<&2, I.Folder>,
  override: String,
  attr: String,
  a: String,
  b: String
) -> Maybe<&2, String>:
  match unset:
    case True{}:
      role(fs, attr, a, b)
    case False{}:
      named_folder(fs, override)

# A role's folder: the configured `override`, else the role resolved.
def resolved_role(
  fs: List<&2, I.Folder>,
  +override: String,
  attr: String,
  a: String,
  b: String
) -> Maybe<&2, String>:
  resolved_role.if(String.is_empty(override), fs, override, attr, a, b)

# The conventional names role resolution falls back to. reserved_names uses
# the same list, so a name added here is protected as well.
def drafts_name() -> String:
  "Drafts"

def trash_name() -> String:
  "Trash"

def deleted_messages_name() -> String:
  "Deleted Messages"

def sent_name() -> String:
  "Sent"

def sent_messages_name() -> String:
  "Sent Messages"

def junk_name() -> String:
  "Junk"

def archive_name() -> String:
  "Archive"

def conventional_names() -> List<&2, String>:
  [
    drafts_name(),
    trash_name(),
    deleted_messages_name(),
    sent_name(),
    sent_messages_name(),
    junk_name(),
    archive_name()
  ]

def resolved_folders(
  +fs: List<&2, I.Folder>,
  drafts: String,
  trash: String,
  sent: String,
  junk: String,
  archive: String
) -> Folders:
  Folders{
    fs,
    resolved_role(fs, drafts, "\\Drafts", drafts_name(), drafts_name()),
    resolved_role(fs, trash, "\\Trash", trash_name(), deleted_messages_name()),
    resolved_role(fs, sent, "\\Sent", sent_name(), sent_messages_name()),
    resolved_role(fs, junk, "\\Junk", junk_name(), junk_name()),
    resolved_role(fs, archive, "\\Archive", archive_name(), archive_name())
  }

# Asking Jev
# ==========

# With MAILBEND_TYPESAFE on, tools ask TypeSafe's Jev through these:
# mail_classify and mail_triage, the gates before a send or a permanent
# delete, and the annotations of reads.

# One request
# -----------

def jev_off(name: String) -> String:
  name ++ " is disabled: it consults TypeSafe's Jev, and MAILBEND_TYPESAFE is off"

# Whether this call would send mail over SMTP.
def sends(op: Ops.Op, args: J.Json) -> Bool:
  match op:
    case Ops.OSend{}:
      True{}
    case Ops.OReply{}:
      Bool.not(bool_arg(args, "as_draft", False{}))
    case Ops.OForward{}:
      Bool.not(bool_arg(args, "as_draft", False{}))
    case _:
      False{}

def refusal(+op: Ops.Op, args: J.Json, ro: Bool, drafts: Bool, jev: Bool) -> String:
  Bool.pick(String, ro && Bool.not(Ops.is_read_only(op)),
    Ops.name(op) ++ " is disabled: MAILBEND_READ_ONLY is set",
    Bool.pick(String, drafts && sends(op, args),
      Ops.name(op) ++ " would send mail, which MAILBEND_DRAFTS_ONLY forbids: use " ++
        "mail_save_draft, or as_draft for a reply or forward",
      Bool.pick(String, Bool.not(jev) && Ops.needs_jev(op),
        jev_off(Ops.name(op)),
        "")))
