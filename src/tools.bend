# The mail tools: JSON arguments in, JSON results out. IMAP work goes
# through the plans in ops.bend and the TLS helper; this module never reads
# MAILBEND_APP_PASSWORD (only the helper does), so no tool result can hold it.

import Base
import ./codec.bend as C
import ./json.bend as J
import ./imap.bend as I
import ./mime.bend as M
import ./smtp.bend as S
import ./ops.bend as Ops
import ./schema.bend as Schema

# Results
# =======

# A tool's result: its JSON, or an error for the caller.
type Out is Data:
  Ok{j: J.Json}
  Err{msg: String}
  # A change that stopped part-way: an error for the caller, with its result.
  Partial{j: J.Json}

# The steps of a tool answer Base's Result: a value, or the message of the
# tool's error.

# The reply lines of a helper session.
def Run() -> Data:
  Result<&2, &2, String, List<&2, I.RLine>>

# The UIDs a tool is asked to act on.
def Uids() -> Data:
  Result<&2, &2, String, List<&2, U32>>

# The keys of a search.
def Keys() -> Data:
  Result<&2, &2, String, List<&2, I.Key>>

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

# The folders, or why their special-use roles could not be read.
def Fs() -> Data:
  Result<&2, &2, String, Folders>

# An attachment read from disk, and all of a message's attachments.
def Attachment() -> Data:
  Result<&2, &2, String, M.Attach>

def Attachments() -> Data:
  Result<&2, &2, String, List<&2, M.Attach>>

def ok_obj(kvs: List<&2, J.Json>) -> Out:
  Ok{J.obj(kvs)}

def pure_out(o: Out) -> IO(Out):
  IO.pure(Out, o)

def pure_str(s: String) -> IO(String):
  IO.pure(String, s)

# Adds fields to a successful result object.
def with_fields(o: Out, extra: List<&2, J.Json>) -> Out:
  match o:
    case Ok{J.JObj{items}}:
      Ok{J.JObj{J.chain(List.append(&2, J.Json, J.unchain(items), extra))}}
    case _:
      o

# A check's problem ("" for none) as a Result, so checks chain in `do`.
def checked(problem: String) -> Result<&2, &2, String, Unit>:
  match problem:
    case SNil{}:
      Done{Unit{}}
    case SCon{h, t}:
      Fail{SCon{h, t}}

# `a`, unless it is empty: the first of two problems.
def first_of(+a: String, b: String) -> String:
  Bool.pick(String, String.is_empty(a), b, a)

# The environment and the TLS helper
# ==================================

# Environment
# -----------

def env_pick(r: Result<&1, &1, U32 & String, String>, d: String) -> String:
  match r:
    case Done{+v}:
      Bool.pick(String, String.is_empty(v), d, v)
    case Fail{e}:
      d

# An environment variable, or `d` when it is unset or empty.
def env_or(name: String, d: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return env_pick(r, d)

# Safety switches
# ---------------

# The safety switches. A value that is not clearly on or off is refused
# rather than read as off: MAILBEND_READ_ONLY=yes must not leave writes on.
type Mode is Data:
  Mode{read_only: Bool, drafts_only: Bool}
  ModeBad{msg: String}

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

def flag(+name: String) -> IO(Flag):
  do IO<Flag>:
    v : String <- env_or(name, "")
    return flag_value(name, v)

def mode_drafts(ro: Bool, f: Flag) -> Mode:
  match f:
    case FlagOn{}:
      Mode{ro, True{}}
    case FlagOff{}:
      Mode{ro, False{}}
    case FlagBad{m}:
      ModeBad{m}

def mode_of(r: Flag, d: Flag) -> Mode:
  match r:
    case FlagOn{}:
      mode_drafts(True{}, d)
    case FlagOff{}:
      mode_drafts(False{}, d)
    case FlagBad{m}:
      ModeBad{m}

# MAILBEND_READ_ONLY=1 refuses every tool that could change the mailbox or
# send mail, for trying MailBend safely against a real account.
# MAILBEND_DRAFTS_ONLY=1 still allows changes but refuses to send: mail_send,
# and replies or forwards without as_draft, so a person reviews every
# outgoing message in Drafts first.
def mode() -> IO(Mode):
  do IO<Mode>:
    r : Flag <- flag("MAILBEND_READ_ONLY")
    d : Flag <- flag("MAILBEND_DRAFTS_ONLY")
    return mode_of(r, d)

# Send settings
# -------------

# What sending must also do: keep a Sent copy; refuse recipients outside
# the allowlist (empty for none); and stay within the daily limit (0 for
# none), counted in a file in `state_dir`. Only sending reads them, so a bad
# value refuses every send and leaves drafts and reads alone.
type Sending is Data:
  Sending{save_sent: Bool, allow: List<&2, String>, limit: U32, state_dir: String}

def Sends() -> Data:
  Result<&2, &2, String, Sending>

def flag_on(f: Flag) -> Result<&2, &2, String, Bool>:
  match f:
    case FlagOn{}:
      Done{True{}}
    case FlagOff{}:
      Done{False{}}
    case FlagBad{m}:
      Fail{m}

# A bare address, or "@" and a domain (written as the domain of an address).
def allow_entry_ok(+entry: String) -> Bool:
  match entry:
    case SCon{'@', domain}:
      M.addr_ok("x" ++ entry) && String.eq(M.addr_spec("x" ++ entry), "x" ++ entry)
    case _:
      M.addr_ok(entry) && String.eq(M.addr_spec(entry), entry)

def allow_entry.if(ok: Bool, entry: String) -> Result<&2, &2, String, String>:
  match ok:
    case True{}:
      Done{entry}
    case False{}:
      Fail{"MAILBEND_ALLOWED_RECIPIENTS: \"" ++ entry ++ "\" is neither an address like " ++
        "name@example.com nor a domain like @example.com"}

def allow_entry(+entry: String) -> Result<&2, &2, String, String>:
  allow_entry.if(allow_entry_ok(entry), entry)

def allow_entries(es: List<&2, String>) -> Result<&2, &2, String, List<&2, String>>:
  match es:
    case Nil{}:
      Done{[]}
    case e <> rest:
      do Result<&2, &2, String, List<&2, String>>:
        entry : String <- allow_entry(String.to_lower(String.trim(e)))
        entries : List<&2, String> <- allow_entries(rest)
        return entry <> entries

# MAILBEND_ALLOWED_RECIPIENTS: comma-separated entries, lower-cased; empty
# for no allowlist. One malformed entry (an empty one too) refuses it all.
def allowlist(+v: String) -> Result<&2, &2, String, List<&2, String>>:
  match v:
    case SNil{}:
      Done{[]}
    case _:
      allow_entries(String.split(v, ','))

def bad_limit() -> String:
  "MAILBEND_MAX_SENDS_PER_DAY must be a positive whole number"

def send_limit.put(n: Maybe<&2, U32>) -> Result<&2, &2, String, U32>:
  match n:
    case Some{+k}:
      Bool.pick(Result<&2, &2, String, U32>, U32.is_zero(k), Fail{bad_limit()}, Done{k})
    case None{}:
      Fail{bad_limit()}

# MAILBEND_MAX_SENDS_PER_DAY: a positive number; empty for no limit (0).
def send_limit(+v: String) -> Result<&2, &2, String, U32>:
  match v:
    case SNil{}:
      Done{0}
    case _:
      send_limit.put(U32.read(v))

# $XDG_STATE_HOME/mailbend, else ~/.local/state/mailbend; a relative
# XDG_STATE_HOME or HOME is ignored, as the XDG base directory spec says.
# "" when neither is usable.
def state_home(+xdg: String, +home: String) -> String:
  match xdg:
    case SCon{'/', t}:
      xdg ++ "/mailbend"
    case _:
      match home:
        case SCon{'/', t}:
          home ++ "/.local/state/mailbend"
        case _:
          ""

# The directory of the send counter: MAILBEND_STATE_DIR, else state_home.
def state_dir(+dir: String, xdg: String, home: String) -> Result<&2, &2, String, String>:
  match dir:
    case SNil{}:
      Done{state_home(xdg, home)}
    case SCon{'/', t}:
      Done{dir}
    case _:
      Fail{"MAILBEND_STATE_DIR must be an absolute path"}

def sending_of(
  save: String,
  allow: String,
  max: String,
  dir: String,
  xdg: String,
  home: String
) -> Sends():
  do Result<&2, &2, String, Sending>:
    save_sent : Bool <- flag_on(flag_value("MAILBEND_SAVE_SENT", save))
    entries : List<&2, String> <- allowlist(allow)
    limit : U32 <- send_limit(max)
    state : String <- state_dir(dir, xdg, home)
    return Sending{save_sent, entries, limit, state}

def sending() -> IO(Sends()):
  do IO<Sends()>:
    save : String <- env_or("MAILBEND_SAVE_SENT", "")
    allow : String <- env_or("MAILBEND_ALLOWED_RECIPIENTS", "")
    max : String <- env_or("MAILBEND_MAX_SENDS_PER_DAY", "")
    dir : String <- env_or("MAILBEND_STATE_DIR", "")
    xdg : String <- env_or("XDG_STATE_HOME", "")
    home : String <- env_or("HOME", "")
    return sending_of(save, allow, max, dir, xdg, home)

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

# A helper run may print up to 128 MiB and take up to five minutes.
def run_helper(path: String, mode: String, input: String) -> IO(Proc):
  do IO<Proc>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run(path, [mode], input, 134217728, 300000)
    return proc_of(r)

# The helper gets the password through the environment, so it is only ever
# started from an absolute MAILBEND_TLS_HELPER path (scripts/mailbend sets
# it), never from a path relative to the working directory.
def helper_at(+path: String, mode: String, input: String) -> IO(Proc):
  match path:
    case SCon{'/', t}:
      run_helper(path, mode, input)
    case _:
      IO.pure(Proc, ProcRefused{
        "MAILBEND_TLS_HELPER must be the absolute path of mailbend-tls " ++
          "(scripts/mailbend sets it)"})

def helper(mode: String, input: String) -> IO(Proc):
  do IO<Proc>:
    path : String <- env_or("MAILBEND_TLS_HELPER", "")
    helper_at(path, mode, input)

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

# The helper's own message (its stderr never holds credentials).
def helper_msg(err: String) -> String:
  lines = List.reverse(&2, String, String.lines(String.trim(err)))
  strip_prefix(String.trim(String.join(lines, " | ")), "mailbend-tls: ")

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

def stale_msg() -> String:
  "the folder's UIDVALIDITY changed since these UIDs were read, so they may name other " ++
    "messages; nothing was changed: search again"

# Why the server refused a command: the folder's UIDVALIDITY changed
# (`stale`), or the status line of the first command it refused.
def imap_refusal(stale: Bool, lines: List<&2, I.RLine>) -> String:
  match stale:
    case True{}:
      stale_msg()
    case False{}:
      "the server rejected a command: " ++ String.trim(I.first_failure(lines))

# A session's reply lines, or why it failed: the helper exits with 5 when
# the server refused a command.
def imap_code(code: U32, lines: List<&2, I.RLine>, err: String) -> Run():
  match code:
    case 0:
      Done{lines}
    case 5:
      Fail{imap_refusal(String.contains(err, "[UIDVALIDITY "), lines)}
    case _:
      Fail{helper_error(code, err)}

def imap_result(p: Proc) -> Run():
  match p:
    case ProcOk{code, out, err}:
      imap_code(code, I.frame(out), err)
    case _:
      Fail{"cannot run the TLS helper: " ++ proc_failure(p)}

def imap_proc(cmds: List<&2, I.Cmd>) -> IO(Proc):
  helper("imap", I.script(cmds))

# Runs one IMAP session: the helper logs in, runs the plan, logs out.
def imap_run(cmds: List<&2, I.Cmd>) -> IO(Run()):
  do IO<Run()>:
    p : Proc <- imap_proc(cmds)
    return imap_result(p)

def proc_lines(p: Proc) -> List<&2, I.RLine>:
  match p:
    case ProcOk{code, out, err}:
      I.frame(out)
    case _:
      []

def run_failure(r: Run()) -> String:
  match r:
    case Fail{m}:
      m
    case Done{lines}:
      ""

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

# Whether command `n` was answered OK.
def ok_at(lines: List<&2, I.RLine>, n: U32) -> Bool:
  String.eq(I.status(lines, n), "OK")

# The server's queue confirmation, or why it refused the message: the helper
# exits with 5 when it did.
def smtp_code(code: U32, out: String, err: String) -> Out:
  match code:
    case 0:
      Ok{J.str(S.last_ok(String.lines(out), ""))}
    case 5:
      Err{"the SMTP server refused the message: " ++ S.last_error(String.lines(out), "")}
    case _:
      Err{helper_error(code, err)}

def smtp_result(p: Proc) -> Out:
  match p:
    case ProcOk{code, out, err}:
      smtp_code(code, out, err)
    case _:
      Err{"cannot run the TLS helper: " ++ proc_failure(p)}

def smtp_run(envelope: String) -> IO(Out):
  do IO<Out>:
    p : Proc <- helper("smtp", envelope)
    return smtp_result(p)

# Arguments and JSON
# ==================

# Arguments
# ---------

def str_arg(args: J.Json, key: String, d: String) -> String:
  Maybe.default(&2, String, J.as_str(J.get(args, key)), d)

def bool_arg(args: J.Json, key: String, d: Bool) -> Bool:
  Maybe.default(&2, Bool, J.as_bool(J.get(args, key)), d)

def u32_arg(args: J.Json, key: String, d: U32) -> U32:
  Maybe.default(&2, U32, J.as_u32(J.get(args, key)), d)

def folder_arg(args: J.Json) -> String:
  str_arg(args, "folder", "INBOX")

def clamp(n: U32, lo: U32, hi: U32) -> U32:
  U32.max(lo, U32.min(n, hi))

def json_strs(xs: List<&2, J.Json>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case J.JStr{s} <> t:
      s <> json_strs(t)
    case x <> t:
      json_strs(t)

def strs_of(m: Maybe<&2, J.Json>) -> List<&2, String>:
  match m:
    case Some{J.JStr{+s}}:
      Bool.pick(List<&2, String>, String.is_empty(String.trim(s)), [], [s])
    case Some{J.JArr{items}}:
      json_strs(J.unchain(items))
    case _:
      []

# A list of strings; a single string counts as a one-element list.
def strs_arg(args: J.Json, key: String) -> List<&2, String>:
  strs_of(J.get(args, key))

# The attachments argument: [{path, filename?, content_type?}].
def attachments_arg(args: J.Json) -> List<&2, J.Json>:
  Maybe.default(&2, List<&2, J.Json>, J.as_list(J.get(args, "attachments")), [])

# A UID: a positive number.
def positive(m: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match m:
    case Some{+u}:
      Bool.pick(Maybe<&2, U32>, U32.is_zero(u), None{}, Some{u})
    case None{}:
      None{}

# The UIDs of a JSON array; None when one of them is not a UID.
def uids_from.go(xs: List<&2, J.Json>) -> Maybe<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Some{[]}
    case x <> t:
      do Maybe<&2, List<&2, U32>>:
        u : U32 <- positive(J.as_u32(Some{x}))
        rest : List<&2, U32> <- uids_from.go(t)
        return u <> rest

def uids_of(m: Maybe<&2, List<&2, U32>>) -> Uids():
  match m:
    case Some{Nil{}}:
      Fail{"\"uids\" must list at least one UID"}
    case Some{xs}:
      Done{xs}
    case None{}:
      Fail{"\"uids\" must be an array of positive integer UIDs"}

def one_uid(m: Maybe<&2, J.Json>) -> List<&2, J.Json>:
  match m:
    case Some{x}:
      [x]
    case None{}:
      []

def uids_from(m: Maybe<&2, List<&2, J.Json>>, args: J.Json) -> Uids():
  match m:
    case Some{xs}:
      uids_of(uids_from.go(xs))
    case None{}:
      uids_of(uids_from.go(one_uid(J.get(args, "uid"))))

# The "uids" argument (an array), or "uid" (one number).
def uids_arg(+args: J.Json) -> Uids():
  uids_from(J.as_list(J.get(args, "uids")), args)

def uidv_arg(args: J.Json) -> U32:
  u32_arg(args, "uidvalidity", 0)

# JSON helpers
# ------------

def uids_items(xs: List<&2, U32>) -> List<&2, J.Json>:
  match xs:
    case Nil{}:
      []
    case x <> t:
      J.num(x) <> uids_items(t)

def uids_json(xs: List<&2, U32>) -> J.Json:
  J.arr(uids_items(xs))

def maybe_str(m: Maybe<&2, String>) -> J.Json:
  match m:
    case Some{s}:
      J.str(s)
    case None{}:
      J.JNull{}

def maybe_strs(m: Maybe<&2, List<&2, String>>) -> J.Json:
  match m:
    case Some{xs}:
      J.strs(xs)
    case None{}:
      J.JNull{}

def maybe_num(m: Maybe<&2, U32>) -> J.Json:
  match m:
    case Some{n}:
      J.num(n)
    case None{}:
      J.JNull{}

# Folders and their roles
# =======================

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

def role_of(attrs: List<&2, String>) -> J.Json:
  maybe_str(role_in(role_attrs(), attrs))

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

# Why the override `value` of `variable` cannot be used; "" when it is unset
# or names one existing selectable mailbox.
def invalid_override(fs: List<&2, I.Folder>, +value: String, variable: String) -> String:
  Bool.pick(String,
    String.is_empty(value) || Maybe.is_some(&2, String, named_folder(fs, value)), "",
    variable ++ " must name one existing selectable mailbox")

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

# The roles resolved, once every override names a usable mailbox; the first
# that does not is reported.
def validate_overrides(
  +fs: List<&2, I.Folder>,
  +drafts: String,
  +trash: String,
  +sent: String,
  +junk: String,
  +archive: String
) -> Fs():
  do Result<&2, &2, String, Folders>:
    drafts_ok : Unit <- checked(invalid_override(fs, drafts, "MAILBEND_DRAFTS_FOLDER"))
    trash_ok : Unit <- checked(invalid_override(fs, trash, "MAILBEND_TRASH_FOLDER"))
    sent_ok : Unit <- checked(invalid_override(fs, sent, "MAILBEND_SENT_FOLDER"))
    junk_ok : Unit <- checked(invalid_override(fs, junk, "MAILBEND_JUNK_FOLDER"))
    archive_ok : Unit <- checked(invalid_override(fs, archive, "MAILBEND_ARCHIVE_FOLDER"))
    return resolved_folders(fs, drafts, trash, sent, junk, archive)

def folders_overrides(fs: List<&2, I.Folder>) -> IO(Fs()):
  do IO<Fs()>:
    drafts : String <- env_or("MAILBEND_DRAFTS_FOLDER", "")
    trash : String <- env_or("MAILBEND_TRASH_FOLDER", "")
    sent : String <- env_or("MAILBEND_SENT_FOLDER", "")
    junk : String <- env_or("MAILBEND_JUNK_FOLDER", "")
    archive : String <- env_or("MAILBEND_ARCHIVE_FOLDER", "")
    return validate_overrides(fs, drafts, trash, sent, junk, archive)

# Listing the folders
# -------------------

def merge_attrs(xs: List<&2, String>, +ys: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      ys
    case +x <> t:
      merge_attrs(t, Bool.pick(List<&2, String>, I.has_attr(ys, x), ys, x <> ys))

# Whether the first folder of `fs` has `entry`'s name.
def merge_folder.same(fs: List<&2, I.Folder>, entry: I.Folder) -> Bool:
  match fs:
    case Nil{}:
      False{}
    case I.Folder{name, d, a} <> t:
      I.Folder{other, e, extra} = entry
      I.same_name(name, other)

# Folder `f` with `entry`'s attributes added.
def merge_folder.into(f: I.Folder, entry: I.Folder) -> I.Folder:
  I.Folder{name, delimiter, attrs} = f
  I.Folder{other, d, extra} = entry
  I.Folder{name, delimiter, merge_attrs(extra, attrs)}

# `same` says whether the first folder of `fs` has `entry`'s name. A match,
# not a Bool.pick, so the walk stops at that folder and only it merges.
def merge_folder.go(
  fs: List<&2, I.Folder>, +entry: I.Folder, same: Bool
) -> List<&2, I.Folder>:
  match fs same:
    case Nil{} _:
      [entry]
    case f <> t True{}:
      merge_folder.into(f, entry) <> t
    case f <> +t False{}:
      f <> merge_folder.go(t, entry, merge_folder.same(t, entry))

# `fs` with `entry`'s attributes added to the folder of the same name, or
# with `entry` appended when there is none.
def merge_folder(+fs: List<&2, I.Folder>, +entry: I.Folder) -> List<&2, I.Folder>:
  merge_folder.go(fs, entry, merge_folder.same(fs, entry))

def merge_folders(extra: List<&2, I.Folder>, ordinary: List<&2, I.Folder>) -> List<&2, I.Folder>:
  match extra:
    case Nil{}:
      ordinary
    case entry <> t:
      merge_folders(t, merge_folder(ordinary, entry))

def roles_of(r: Run(), ordinary: List<&2, I.Folder>) -> IO(Fs()):
  match r:
    case Fail{m}:
      IO.pure(Fs(), Fail{"cannot read the special-use folder roles the server advertises: " ++ m})
    case Done{lines}:
      folders_overrides(merge_folders(I.folders(lines), ordinary))

def folders_io.if(ask: Bool, fs: List<&2, I.Folder>) -> IO(Fs()):
  match ask:
    case False{}:
      folders_overrides(fs)
    case True{}:
      do IO<Fs()>:
        r : Run() <- imap_run(Ops.plan_roles())
        roles_of(r, fs)

# SPECIAL-USE may be partial even in ordinary LIST: always request the
# extended metadata when the authenticated capability advertises it.
def folders_io(+lines: List<&2, I.RLine>) -> IO(Fs()):
  folders_io.if(I.has_cap(I.caps(lines), "SPECIAL-USE"), merge_folders(I.folders(lines), []))

def special_json(f: Folders) -> J.Json:
  Folders{fs, drafts, trash, sent, junk, archive} = f
  J.obj([
    J.kv("inbox", maybe_str(named_folder(fs, "INBOX"))),
    J.kv("drafts", maybe_str(drafts)),
    J.kv("sent", maybe_str(sent)),
    J.kv("trash", maybe_str(trash)),
    J.kv("junk", maybe_str(junk)),
    J.kv("archive", maybe_str(archive))
  ])

def folder_json(f: I.Folder) -> J.Json:
  I.Folder{name, delim, +attrs} = f
  J.obj([
    J.kv("name", J.str(name)),
    J.kv("delimiter", J.str(delim)),
    J.kv("attributes", J.strs(attrs)),
    J.kv("special_use", role_of(attrs)),
    J.kv("selectable", J.bool(selectable(attrs)))
  ])

def folders_json(fs: List<&2, I.Folder>) -> List<&2, J.Json>:
  match fs:
    case Nil{}:
      []
    case f <> t:
      folder_json(f) <> folders_json(t)

# Reading mail
# ============

# Message summaries
# -----------------

def hdr_text(hs: List<&2, M.Hdr>, name: String) -> String:
  M.decode_header(M.header(hs, name))

def summary(m: I.Msg) -> J.Json:
  I.Msg{uid, +flags, date, size, headers, body} = m
  +hs = M.headers(headers)
  J.obj([
    J.kv("uid", J.num(uid)),
    J.kv("date", J.str(hdr_text(hs, "date"))),
    J.kv("from", J.str(hdr_text(hs, "from"))),
    J.kv("to", J.str(hdr_text(hs, "to"))),
    J.kv("cc", J.str(hdr_text(hs, "cc"))),
    J.kv("subject", J.str(hdr_text(hs, "subject"))),
    J.kv("message_id", J.str(M.header(hs, "message-id"))),
    J.kv("internal_date", J.str(date)),
    J.kv("size", J.num(size)),
    J.kv("flags", J.strs(flags)),
    J.kv("seen", J.bool(I.has_attr(flags, "\\Seen"))),
    J.kv("flagged", J.bool(I.has_attr(flags, "\\Flagged")))
  ])

def summaries(ms: List<&2, I.Msg>) -> List<&2, J.Json>:
  match ms:
    case Nil{}:
      []
    case m <> t:
      summary(m) <> summaries(t)

def msg_uid(m: I.Msg) -> U32:
  I.Msg{uid, flags, date, size, headers, body} = m
  uid

def newest_first(ms: List<&2, I.Msg>) -> List<&2, I.Msg>:
  List.sort(~I.Msg, ~(a => b => U32.is_ge(msg_uid(a), msg_uid(b))), ms)

def oldest_first(ms: List<&2, I.Msg>) -> List<&2, I.Msg>:
  List.sort(~I.Msg, ~(a => b => U32.is_le(msg_uid(a), msg_uid(b))), ms)

def desc(xs: List<&2, U32>) -> List<&2, U32>:
  List.sort(~U32, ~(a => b => U32.is_ge(a, b)), xs)

def asc(xs: List<&2, U32>) -> List<&2, U32>:
  List.sort(~U32, ~(a => b => U32.is_le(a, b)), xs)

# UIDs and UIDVALIDITY
# --------------------

def uid_in(u: U32, uids: List<&2, U32>) -> Bool:
  List.contains(~U32, ~U32.is_eq, uids, u)

# The FETCH responses for the requested UIDs only (a server may add
# unsolicited ones, e.g. flag updates).
def requested(ms: List<&2, I.Msg>, +uids: List<&2, U32>) -> List<&2, I.Msg>:
  match ms:
    case Nil{}:
      []
    case +m <> t:
      List.filter.put(I.Msg, m, requested(t, uids), uid_in(msg_uid(m), uids))

def uidv_is(have: Maybe<&2, U32>, want: U32) -> Bool:
  match have:
    case Some{n}:
      U32.is_eq(n, want)
    case None{}:
      False{}

def same_uidv(a: Maybe<&2, U32>, b: Maybe<&2, U32>) -> Bool:
  match a:
    case Some{x}:
      uidv_is(b, x)
    case None{}:
      Maybe.is_none(&2, U32, b)

def moved_msg() -> String:
  "the folder's UIDVALIDITY changed between the search and the fetch, so these UIDs may " ++
    "name other messages; search again"

# The preflight's early check (the plans check again in the changing session).
def uidv_problem(lines: List<&2, I.RLine>, want: U32) -> String:
  Bool.pick(String, uidv_is(I.ok_code(lines, "UIDVALIDITY"), want), "", stale_msg())

def uidv_missing() -> String:
  "\"uidvalidity\" is required: pass the value mail_search or mail_get returned with " ++
    "these UIDs, so stale UIDs can never change other messages"

# mail_probe and mail_list_folders
# --------------------------------

def probe_json(
  lines: List<&2, I.RLine>,
  +f: Folders,
  host: String,
  email: String
) -> Out:
  Folders{fs, drafts, trash, sent, junk, archive} = f
  +caps = I.caps(lines)
  ok_obj([
    J.kv("ok", J.bool(True{})),
    J.kv("account", J.str(email)),
    J.kv("imap_host", J.str(host)),
    J.kv("tls_verified", J.bool(True{})),
    J.kv("capabilities", J.strs(caps)),
    J.kv("idle", J.bool(I.has_cap(caps, "IDLE"))),
    J.kv("move", J.bool(I.has_cap(caps, "MOVE"))),
    J.kv("uidplus", J.bool(I.has_cap(caps, "UIDPLUS"))),
    J.kv("special_use", special_json(f)),
    J.kv("folder_count", J.num(U32.from_nat(List.length(&2, I.Folder, fs))))
  ])

def probe_fs(f: Fs(), lines: List<&2, I.RLine>, host: String, email: String) -> Out:
  match f:
    case Fail{m}:
      Err{m}
    case Done{folders}:
      probe_json(lines, folders, host, email)

def probe_out(r: Run(), host: String, email: String) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      do IO<Out>:
        f : Fs() <- folders_io(lines)
        return probe_fs(f, lines, host, email)

def t_probe(args: J.Json) -> IO(Out):
  do IO<Out>:
    r : Run() <- imap_run(Ops.plan_probe())
    host : String <- env_or("MAILBEND_IMAP_HOST", "imap.mail.me.com")
    email : String <- env_or("MAILBEND_EMAIL", "")
    probe_out(r, host, email)

def folders_fs(f: Fs()) -> Out:
  match f:
    case Fail{m}:
      Err{m}
    case Done{Folders{fs, drafts, trash, sent, junk, archive}}:
      ok_obj([J.kv("folders", J.arr(folders_json(fs)))])

def folders_out(r: Run()) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{lines}:
      do IO<Out>:
        f : Fs() <- folders_io(lines)
        return folders_fs(f)

def t_folders(args: J.Json) -> IO(Out):
  do IO<Out>:
    r : Run() <- imap_run(Ops.plan_folders())
    folders_out(r)

# mail_search
# -----------

def text_key.if(empty: Bool, v: String, key: String -> I.Key) -> List<&2, I.Key>:
  match empty:
    case True{}:
      []
    case False{}:
      [key(v)]

# The search key `key` makes of the string argument `name`, if it is given.
def text_key(args: J.Json, name: String, key: String -> I.Key) -> List<&2, I.Key>:
  +v = str_arg(args, name, "")
  text_key.if(String.is_empty(v), v, key)

def text_keys(+args: J.Json) -> List<&2, I.Key>:
  List.concat(&2, I.Key, [
    text_key(args, "from", v => I.KFrom{v}),
    text_key(args, "to", v => I.KTo{v}),
    text_key(args, "cc", v => I.KCc{v}),
    text_key(args, "subject", v => I.KSubject{v}),
    text_key(args, "body", v => I.KBody{v}),
    text_key(args, "text", v => I.KText{v})
  ])

def flag_keys(+args: J.Json) -> List<&2, I.Key>:
  List.concat(&2, I.Key, [
    Bool.pick(List<&2, I.Key>, bool_arg(args, "unseen", False{}), [I.KUnseen{}], []),
    Bool.pick(List<&2, I.Key>, bool_arg(args, "seen", False{}), [I.KSeen{}], []),
    Bool.pick(List<&2, I.Key>, bool_arg(args, "flagged", False{}), [I.KFlagged{}], [])
  ])

def date_key_of(m: Maybe<&2, String>, name: String) -> Keys():
  match m:
    case Some{+d}:
      Done{Bool.pick(List<&2, I.Key>, String.eq(name, "since"), [I.KSince{d}], [I.KBefore{d}])}
    case None{}:
      Fail{"\"" ++ name ++ "\" must be a date like 2026-02-01"}

def date_key.if(empty: Bool, v: String, name: String) -> Keys():
  match empty:
    case True{}:
      Done{[]}
    case False{}:
      date_key_of(I.imap_date(v), name)

# The key of the date argument `name` ("since" or "before"), if it is given.
def date_key(args: J.Json, +name: String) -> Keys():
  +v = str_arg(args, name, "")
  date_key.if(String.is_empty(v), v, name)

# The search keys; a bad "since" is reported before a bad "before".
def keys_of(+args: J.Json) -> Keys():
  do Result<&2, &2, String, List<&2, I.Key>>:
    since : List<&2, I.Key> <- date_key(args, "since")
    before : List<&2, I.Key> <- date_key(args, "before")
    return List.concat(&2, I.Key, [text_keys(args), flag_keys(args), since, before])

def list_out(folder: String, uidv: Maybe<&2, U32>, total: U32, ms: List<&2, J.Json>) -> Out:
  ok_obj([
    J.kv("folder", J.str(folder)),
    J.kv("uidvalidity", maybe_num(uidv)),
    J.kv("total", J.num(total)),
    J.kv("messages", J.arr(ms))
  ])

def search_headers.if(
  same: Bool,
  lines: List<&2, I.RLine>,
  folder: String,
  uidv: Maybe<&2, U32>,
  total: U32,
  uids: List<&2, U32>
) -> Out:
  match same:
    case True{}:
      list_out(folder, uidv, total, summaries(newest_first(requested(I.fetched(lines), uids))))
    case False{}:
      Err{moved_msg()}

# The fetch runs in a second session: its EXAMINE must report the same
# UIDVALIDITY as the search, or the UIDs may name other messages.
def search_headers(
  r: Run(),
  folder: String,
  +uidv: Maybe<&2, U32>,
  total: U32,
  uids: List<&2, U32>
) -> Out:
  match r:
    case Fail{m}:
      Err{m}
    case Done{+lines}:
      search_headers.if(same_uidv(uidv, I.ok_code(lines, "UIDVALIDITY")), lines, folder, uidv,
        total, uids)

def search_fetch(
  +uids: List<&2, U32>,
  +folder: String,
  uidv: Maybe<&2, U32>,
  total: U32
) -> IO(Out):
  match uids:
    case Nil{}:
      pure_out(list_out(folder, uidv, total, []))
    case h <> t:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_headers(folder, uids))
        return search_headers(r, folder, uidv, total, uids)

def search_found(r: Run(), folder: String, limit: U32) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      +uids = I.search_uids(lines)
      search_fetch(List.take(&2, U32, desc(uids), U32.to_nat(limit)), folder,
        I.ok_code(lines, "UIDVALIDITY"), U32.from_nat(List.length(&2, U32, uids)))

def search_keys(ks: Keys(), +folder: String, limit: U32) -> IO(Out):
  match ks:
    case Fail{m}:
      pure_out(Err{m})
    case Done{keys}:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_search(folder, keys))
        search_found(r, folder, limit)

def t_search(+args: J.Json) -> IO(Out):
  search_keys(keys_of(args), folder_arg(args), clamp(u32_arg(args, "limit", 20), 1, 200))

# mail_get
# --------

def atts_json(xs: List<&2, M.Att>) -> List<&2, J.Json>:
  match xs:
    case Nil{}:
      []
    case M.Att{n, t, s} <> r:
      J.obj([J.kv("filename", J.str(n)), J.kv("content_type", J.str(t)), J.kv("size", J.num(s))]) <>
        atts_json(r)

def get_json(
  m: I.Msg,
  folder: String,
  uidv: Maybe<&2, U32>,
  max: U32,
  +hs: List<&2, M.Hdr>,
  +p: M.Parts
) -> Out:
  I.Msg{uid, +flags, date, +size, headers, body} = m
  M.Parts{_, html, atts} = p
  ok_obj([
    J.kv("folder", J.str(folder)),
    J.kv("uid", J.num(uid)),
    J.kv("uidvalidity", maybe_num(uidv)),
    J.kv("flags", J.strs(flags)),
    J.kv("seen", J.bool(I.has_attr(flags, "\\Seen"))),
    J.kv("internal_date", J.str(date)),
    J.kv("size", J.num(size)),
    J.kv("truncated", J.bool(U32.is_gt(size, max))),
    J.kv("from", J.str(hdr_text(hs, "from"))),
    J.kv("to", J.str(hdr_text(hs, "to"))),
    J.kv("cc", J.str(hdr_text(hs, "cc"))),
    J.kv("reply_to", J.str(hdr_text(hs, "reply-to"))),
    J.kv("subject", J.str(hdr_text(hs, "subject"))),
    J.kv("date", J.str(hdr_text(hs, "date"))),
    J.kv("message_id", J.str(M.header(hs, "message-id"))),
    J.kv("in_reply_to", J.str(M.header(hs, "in-reply-to"))),
    J.kv("references", J.str(M.header(hs, "references"))),
    J.kv("text", J.str(M.readable_text(p))),
    J.kv("html_available", J.bool(Bool.not(String.is_empty(html)))),
    J.kv("attachments", J.arr(atts_json(atts)))
  ])

def msg_body(m: I.Msg) -> String:
  I.Msg{uid, flags, date, size, headers, body} = m
  body

# The headers of a whole message.
def body_headers(body: String) -> List<&2, M.Hdr>:
  M.headers(M.head_of(M.split(body)))

# The FETCH response for `uid` (a server may also send unsolicited FETCHes).
def with_uid(ms: List<&2, I.Msg>, +uid: U32) -> List<&2, I.Msg>:
  match ms:
    case Nil{}:
      []
    case +m <> t:
      Bool.pick(List<&2, I.Msg>, U32.is_eq(msg_uid(m), uid), [m], with_uid(t, uid))

def get_msg(
  ms: List<&2, I.Msg>,
  folder: String,
  uid: U32,
  uidv: Maybe<&2, U32>,
  max: U32
) -> Out:
  match ms:
    case Nil{}:
      Err{"no message with UID " ++ U32.show(uid) ++ " in " ++ folder}
    case +m <> t:
      +body = msg_body(m)
      get_json(m, folder, uidv, max, body_headers(body), M.parts(body))

def get_out(r: Run(), folder: String, +uid: U32, max: U32) -> Out:
  match r:
    case Fail{m}:
      Err{m}
    case Done{+lines}:
      get_msg(with_uid(I.fetched(lines), uid), folder, uid, I.ok_code(lines, "UIDVALIDITY"), max)

def get_uid(u: Uids(), +folder: String, +max: U32) -> IO(Out):
  match u:
    case Done{+uid <> Nil{}}:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_get(folder, uid, max))
        return get_out(r, folder, uid, max)
    case Done{xs}:
      pure_out(Err{"mail_get reads one message: pass a single \"uid\""})
    case Fail{m}:
      pure_out(Err{m})

def t_get(+args: J.Json) -> IO(Out):
  get_uid(uids_arg(args), folder_arg(args),
    clamp(u32_arg(args, "max_bytes", 262144), 1024, 16777216))

# mail_get_new
# ------------

def above(xs: List<&2, U32>, +since: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      []
    case +x <> t:
      List.filter.put(U32, x, above(t, since), U32.is_gt(x, since))

def last_or(xs: List<&2, U32>, d: U32) -> U32:
  Maybe.default(&2, U32, List.last(&2, U32, xs), d)

def new_out(
  folder: String,
  uidv: U32,
  changed: Bool,
  next: U32,
  more: Bool,
  ms: List<&2, J.Json>
) -> Out:
  ok_obj([
    J.kv("folder", J.str(folder)),
    J.kv("uidvalidity", J.num(uidv)),
    J.kv("uidvalidity_changed", J.bool(changed)),
    J.kv("next_since_uid", J.num(next)),
    J.kv("has_more", J.bool(more)),
    J.kv("messages", J.arr(ms))
  ])

def new_headers.if(
  same: Bool,
  lines: List<&2, I.RLine>,
  now: Maybe<&2, U32>,
  folder: String,
  uidv: U32,
  next: U32,
  more: Bool,
  uids: List<&2, U32>
) -> Out:
  match same:
    case True{}:
      new_out(folder, uidv, False{}, next, more,
        summaries(oldest_first(requested(I.fetched(lines), uids))))
    case False{}:
      new_out(folder, Maybe.default(&2, U32, now, 0), True{}, 0, True{}, [])

# As for search: a UIDVALIDITY change between the two sessions resets the
# checkpoint instead of returning messages under stale UIDs.
def new_headers(
  r: Run(),
  folder: String,
  +uidv: U32,
  next: U32,
  more: Bool,
  uids: List<&2, U32>
) -> Out:
  match r:
    case Fail{m}:
      Err{m}
    case Done{+lines}:
      +now = I.ok_code(lines, "UIDVALIDITY")
      new_headers.if(uidv_is(now, uidv), lines, now, folder, uidv, next, more, uids)

def new_fetch(
  +uids: List<&2, U32>,
  +folder: String,
  uidv: U32,
  since: U32,
  more: Bool
) -> IO(Out):
  match uids:
    case Nil{}:
      pure_out(new_out(folder, uidv, False{}, since, False{}, []))
    case h <> t:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_headers(folder, uids))
        return new_headers(r, folder, uidv, last_or(uids, since), more, uids)

def new_reset(
  changed: Bool,
  uidv: U32,
  +uids: List<&2, U32>,
  folder: String,
  since: U32,
  +limit: U32
) -> IO(Out):
  match changed:
    case True{}:
      pure_out(new_out(folder, uidv, True{}, 0, True{}, []))
    case False{}:
      new_fetch(List.take(&2, U32, uids, U32.to_nat(limit)), folder, uidv, since,
        Nat.is_gt(List.length(&2, U32, uids), U32.to_nat(limit)))

def new_check(
  +uidv: U32,
  uids: List<&2, U32>,
  folder: String,
  since: U32,
  +known: U32,
  limit: U32
) -> IO(Out):
  new_reset(Bool.not(U32.is_zero(known)) && Bool.not(U32.is_eq(known, uidv)), uidv, uids,
    folder, since, limit)

# When UIDVALIDITY changed, every stored UID is void: report it and restart
# the checkpoint at 0 instead of guessing which messages are new.
def new_found(r: Run(), folder: String, +since: U32, known: U32, limit: U32) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      new_check(Maybe.default(&2, U32, I.ok_code(lines, "UIDVALIDITY"), 0),
        asc(above(I.search_uids(lines), since)), folder, since, known, limit)

# A checkpoint is a UID together with its UIDVALIDITY: a UID alone could
# belong to a recreated folder and skip or repeat messages.
def new_request(since: U32, known: U32) -> String:
  Bool.pick(String, Bool.not(U32.is_zero(since)) && U32.is_zero(known),
    "\"uidvalidity\" is required with \"since_uid\": pass the uidvalidity returned with " ++
      "that checkpoint",
    "")

def t_get_new.if(problem: String, +args: J.Json) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      +folder = folder_arg(args)
      +since = u32_arg(args, "since_uid", 0)
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_new(folder, since))
        new_found(r, folder, since, uidv_arg(args), clamp(u32_arg(args, "limit", 50), 1, 500))

def t_get_new(+args: J.Json) -> IO(Out):
  t_get_new.if(new_request(u32_arg(args, "since_uid", 0), uidv_arg(args)), args)

# Changing mail
# =============

# Change results
# --------------

def minus(xs: List<&2, U32>, +ys: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      []
    case +x <> t:
      List.filter.put(U32, x, minus(t, ys), Bool.not(uid_in(x, ys)))

def changed_found.if(
  none: Bool,
  +found: List<&2, U32>,
  uids: List<&2, U32>,
  folder: String,
  kvs: List<&2, J.Json>
) -> Out:
  match none:
    case True{}:
      Err{"none of these UIDs exist in " ++ folder ++ "; nothing was changed"}
    case False{}:
      ok_obj(List.append(&2, J.Json, kvs, [
        J.kv("changed", uids_json(found)),
        J.kv("missing", uids_json(minus(uids, found)))
      ]))

# The result of a change: which requested UIDs existed when it ran (`found`,
# from the guard's UID SEARCH) and which did not. If none existed, nothing
# changed.
def changed_found(
  +found: List<&2, U32>,
  uids: List<&2, U32>,
  folder: String,
  kvs: List<&2, J.Json>
) -> Out:
  changed_found.if(List.is_empty(&2, U32, found), found, uids, folder, kvs)

def changed_of(
  lines: List<&2, I.RLine>,
  uids: List<&2, U32>,
  folder: String,
  kvs: List<&2, J.Json>
) -> Out:
  changed_found(asc(I.search_uids(lines)), uids, folder, kvs)

def changed_out(r: Run(), uids: List<&2, U32>, folder: String, kvs: List<&2, J.Json>) -> Out:
  match r:
    case Fail{m}:
      Err{m}
    case Done{lines}:
      changed_of(lines, uids, folder, kvs)

# Flags
# -----

# What mark_uids changes: \Seen; \Flagged, with a colour or keeping the
# current one; or \Flagged and every colour bit cleared.
type Mark is Data:
  MarkSeen{seen: Bool}
  MarkFlag{colour: Maybe<&2, I.Colour>}
  MarkUnflag{}

# A changed message's flags as a flag change's trailing FETCH last reported
# them; None when no FETCH with FLAGS named its UID.
type Observed is Data:
  Observed{uid: U32, flags: Maybe<&2, List<&2, String>>}

# Which of a plan's stores store_changes picks: those answered OK, or those
# that may have run unanswered (with `lost`, the transcript is not whole).
type Answer is Data:
  Acked{}
  Unanswered{lost: Bool}

# Where a stopped flag change got to: the store changes acknowledged, those
# that may have run unanswered, and whether every store was acknowledged.
type Cut is Data:
  Cut{acked: List<&2, String>, unconfirmed: List<&2, String>, all_acked: Bool}

def mark_plan(uids: List<&2, U32>, folder: String, mark: Mark, uidv: U32) -> List<&2, I.Cmd>:
  match mark:
    case MarkSeen{seen}:
      Ops.plan_mark(folder, uids, seen, uidv)
    case MarkFlag{colour}:
      Ops.plan_flag(folder, uids, colour, uidv)
    case MarkUnflag{}:
      Ops.plan_unflag(folder, uids, uidv)

def mark_fields(folder: String, key: String, b: Bool) -> List<&2, J.Json>:
  [J.kv("ok", J.bool(True{})), J.kv("folder", J.str(folder)), J.kv(key, J.bool(b))]

# The fields a mark result opens with: the folder and what was set.
def mark_kvs(folder: String, mark: Mark) -> List<&2, J.Json>:
  match mark:
    case MarkSeen{seen}:
      mark_fields(folder, "seen", seen)
    case MarkFlag{colour}:
      mark_fields(folder, "flagged", True{})
    case MarkUnflag{}:
      mark_fields(folder, "flagged", False{})

# The colour a mark sets explicitly, if any.
def mark_colour(mark: Mark) -> Maybe<&2, I.Colour>:
  match mark:
    case MarkFlag{colour}:
      colour
    case _:
      None{}

# The flags of the last FETCH for `uid` in `ms`, which are in wire order.
def last_flags(
  ms: List<&2, I.Msg>,
  +uid: U32,
  last: Maybe<&2, List<&2, String>>
) -> Maybe<&2, List<&2, String>>:
  match ms:
    case Nil{}:
      last
    case I.Msg{u, flags, date, size, headers, body} <> t:
      last_flags(t, uid,
        Bool.pick(Maybe<&2, List<&2, String>>, U32.is_eq(u, uid), Some{flags}, last))

def observed(uids: List<&2, U32>, +ms: List<&2, I.Msg>) -> List<&2, Observed>:
  match uids:
    case Nil{}:
      []
    case +u <> t:
      Observed{u, last_flags(ms, u, None{})} <> observed(t, ms)

def observed_json(os: List<&2, Observed>) -> List<&2, J.Json>:
  match os:
    case Nil{}:
      []
    case Observed{uid, flags} <> t:
      J.obj([J.kv("uid", J.num(uid)), J.kv("flags", maybe_strs(flags))]) <> observed_json(t)

# Whether a message has a colour bit exactly when the colour sets it.
def bit_shown(flags: List<&2, String>, want: Bool, f: I.Flag) -> Bool:
  Bool.not(Bool.xor(want, I.has_attr(flags, I.flag_name(f))))

# Whether a message's flags show the colour: Apple Mail reads it from
# $MailFlagBit0..2 while \Flagged is set.
def shows_colour(+flags: List<&2, String>, bits: I.Bits) -> Bool:
  I.Bits{b0, b1, b2} = bits
  (I.has_attr(flags, "\\Flagged") && bit_shown(flags, b0, I.FColourBit0{}) &&
    bit_shown(flags, b1, I.FColourBit1{}) && bit_shown(flags, b2, I.FColourBit2{}))

# The UIDs whose reported flags do not show the colour.
def colour_misses(os: List<&2, Observed>, +bits: I.Bits) -> List<&2, U32>:
  match os:
    case Nil{}:
      []
    case Observed{uid, Some{flags}} <> t:
      List.filter.put(U32, uid, colour_misses(t, bits), Bool.not(shows_colour(flags, bits)))
    case Observed{uid, None{}} <> t:
      colour_misses(t, bits)

def any_unobserved(os: List<&2, Observed>) -> Bool:
  match os:
    case Nil{}:
      False{}
    case Observed{uid, Some{flags}} <> t:
      any_unobserved(t)
    case Observed{uid, None{}} <> t:
      True{}

def keyword_permanent(ps: List<&2, String>, any: Bool, f: I.Flag) -> Bool:
  any || I.has_attr(ps, I.flag_name(f))

# Whether PERMANENTFLAGS `ps` lets every flag a colour stores last beyond
# this session: \Flagged must be listed, and each colour keyword listed or
# covered by \* (any new keyword). A cleared bit counts too: clearing a
# session-only keyword may not last either.
def colour_permanent(+ps: List<&2, String>) -> Bool:
  +any = I.has_attr(ps, "\\*")
  (I.has_attr(ps, "\\Flagged") && keyword_permanent(ps, any, I.FColourBit0{}) &&
    keyword_permanent(ps, any, I.FColourBit1{}) && keyword_permanent(ps, any, I.FColourBit2{}))

# Whether the colour's changes are known to last only for this session (not
# known without PERMANENTFLAGS).
def session_only(perm: Maybe<&2, List<&2, String>>) -> Bool:
  match perm:
    case Some{ps}:
      Bool.not(colour_permanent(ps))
    case None{}:
      False{}

# The changed UIDs known not to keep the colour: all of them when its changes
# last only for this session, else those whose reported flags differ.
def colour_not_kept(
  session: Bool,
  found: List<&2, U32>,
  os: List<&2, Observed>,
  bits: I.Bits
) -> List<&2, U32>:
  match session:
    case True{}:
      found
    case False{}:
      colour_misses(os, bits)

# colour_kept: false on a known failure, "unverified" when the evidence is
# incomplete (no PERMANENTFLAGS, or a changed UID without reported flags),
# else true.
def kept_json(failed: Bool, unknown: Bool) -> J.Json:
  Bool.pick(J.Json, failed, J.bool(False{}),
    Bool.pick(J.Json, unknown, J.str("unverified"), J.bool(True{})))

# For an explicit colour: which one, whether the server kept it, and the
# changed UIDs known not to have kept it.
def colour_kvs(
  colour: Maybe<&2, I.Colour>,
  found: List<&2, U32>,
  +os: List<&2, Observed>,
  +perm: Maybe<&2, List<&2, String>>
) -> List<&2, J.Json>:
  match colour:
    case None{}:
      []
    case Some{+c}:
      +not_kept = colour_not_kept(session_only(perm), found, os, I.colour_bits(c))
      unknown = Maybe.is_none(&2, List<&2, String>, perm) || any_unobserved(os)
      [
        J.kv("colour", J.str(I.colour_name(c))),
        J.kv("colour_kept", kept_json(Bool.not(List.is_empty(&2, U32, not_kept)), unknown)),
        J.kv("colour_not_kept", uids_json(not_kept))
      ]

# A finished flag change: the flags the trailing FETCH (the plan's last
# command) reported for each changed message, and for an explicit colour
# whether the server kept it, judged with the PERMANENTFLAGS that SELECT
# (command 1) reported.
def flag_done(
  +lines: List<&2, I.RLine>,
  plan: List<&2, I.Cmd>,
  uids: List<&2, U32>,
  +folder: String,
  +mark: Mark
) -> Out:
  +found = asc(I.search_uids(lines))
  +os = observed(found, I.flag_fetches(I.replies(lines, I.tag_count(plan))))
  perm = I.permanent_flags(I.replies(lines, 1))
  changed_found(found, uids, folder, List.concat(&2, J.Json, [
    mark_kvs(folder, mark),
    [J.kv("flags", J.arr(observed_json(os)))],
    colour_kvs(mark_colour(mark), found, os, perm)
  ]))

def flag_run(
  r: Run(),
  plan: List<&2, I.Cmd>,
  uids: List<&2, U32>,
  folder: String,
  mark: Mark
) -> Out:
  match r:
    case Fail{m}:
      Err{m}
    case Done{lines}:
      flag_done(lines, plan, uids, folder, mark)

# A store as the change it asks for, such as "+\Flagged" or "-$MailFlagBit0".
def store_changes.if(keep: Bool, add: Bool, f: I.Flag, rest: List<&2, String>) -> List<&2, String>:
  match keep:
    case True{}:
      (Bool.pick(String, add, "+", "-") ++ I.flag_name(f)) <> rest
    case False{}:
      rest

# Whether store `n` is one `which` picks. A store may have run unanswered
# when it got no answer and it was sent (the command before it was answered
# OK), or the transcript is not whole, so whether it was sent is unknown.
def store_is(which: Answer, +lines: List<&2, I.RLine>, +n: U32) -> Bool:
  match which:
    case Acked{}:
      ok_at(lines, n)
    case Unanswered{lost}:
      String.is_empty(I.status(lines, n)) && (lost || ok_at(lines, (n - 1 : U32)))

# The changes of the plan's stores, from tag `n` on, that `which` picks.
def store_changes(
  cs: List<&2, I.Cmd>,
  +n: U32,
  +lines: List<&2, I.RLine>,
  +which: Answer
) -> List<&2, String>:
  match cs:
    case Nil{}:
      []
    case I.CStore{u, add, f} <> t:
      store_changes.if(store_is(which, lines, n), add, f,
        store_changes(t, (n + 1 : U32), lines, which))
    case c <> t:
      store_changes(t, Bool.pick(U32, I.is_expect(c), n, (n + 1 : U32)), lines, which)

def changes_text(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      "nothing"
    case h <> t:
      String.join(h <> t, ", ")

def cut_text(all_acked: Bool, acked: List<&2, String>, unconfirmed: List<&2, String>) -> String:
  match all_acked:
    case True{}:
      "the server acknowledged every flag and colour change, but the run did not finish, " ++
        "so the flags were not read back. A retry is idempotent"
    case False{}:
      "the flag change stopped part-way, so the flag and colour changes may be incomplete " ++
        "(acknowledged: " ++ changes_text(acked) ++
        "; may have run unanswered: " ++ changes_text(unconfirmed) ++
        "). A retry is idempotent, but a server that refused a store may refuse it again"

# A flag change that stopped where it may have changed something. It is an
# error for the caller, but not one that implies nothing changed.
def flag_partial(reason: String, folder: String, c: Cut) -> Out:
  Cut{+acked, +unconfirmed, all_acked} = c
  Partial{J.obj([
    J.kv("ok", J.bool(False{})),
    J.kv("partial", J.bool(True{})),
    J.kv("folder", J.str(folder)),
    J.kv("acknowledged", J.strs(acked)),
    J.kv("unconfirmed", J.strs(unconfirmed)),
    J.kv("message", J.str(cut_text(all_acked, acked, unconfirmed) ++ " (" ++ reason ++ ")"))
  ])}

# Whether the guard's UID SEARCH (command 2) was answered and found none of
# the UIDs, so no store could change anything.
def searched_none(+lines: List<&2, I.RLine>) -> Bool:
  Bool.not(String.is_empty(I.status(lines, 2))) && List.is_empty(&2, U32, I.search_uids(lines))

# Where a flag change stopped, if it may have changed something: it did not
# finish (or its transcript is not whole), a store was acknowledged or may
# have run unanswered, and the search did not show that no UID exists. None
# for a finished run, or one that stopped before any store could run.
def flag_cut(+p: Proc, +plan: List<&2, I.Cmd>) -> Maybe<&2, Cut>:
  +lines = proc_lines(p)
  +lost = helper_lost(p)
  +last = I.tag_count(plan)
  +acked = store_changes(plan, 1, lines, Acked{})
  +unconfirmed = store_changes(plan, 1, lines, Unanswered{lost})
  stopped = (lost || Bool.not(ok_at(lines, last))) && Bool.not(searched_none(lines)) &&
    Bool.not(List.is_empty(&2, String, List.append(&2, String, acked, unconfirmed)))
  Bool.pick(Maybe<&2, Cut>, stopped,
    Some{Cut{acked, unconfirmed, ok_at(lines, (last - 1 : U32))}}, None{})

def flag_out.put(
  cut: Maybe<&2, Cut>,
  p: Proc,
  plan: List<&2, I.Cmd>,
  uids: List<&2, U32>,
  folder: String,
  mark: Mark
) -> Out:
  match cut:
    case Some{c}:
      flag_partial(run_failure(imap_result(p)), folder, c)
    case None{}:
      flag_run(imap_result(p), plan, uids, folder, mark)

# A flag change's result: partial when it stopped where it may have changed
# something, else the finished result or a plain error.
def flag_out(
  +p: Proc,
  +plan: List<&2, I.Cmd>,
  uids: List<&2, U32>,
  folder: String,
  mark: Mark
) -> Out:
  flag_out.put(flag_cut(p, plan), p, plan, uids, folder, mark)

def mark_result(
  p: Proc,
  plan: List<&2, I.Cmd>,
  uids: List<&2, U32>,
  +folder: String,
  +mark: Mark
) -> Out:
  match mark:
    case MarkSeen{seen}:
      changed_out(imap_result(p), uids, folder, mark_kvs(folder, mark))
    case _:
      flag_out(p, plan, uids, folder, mark)

def mark_uids.run(+uids: List<&2, U32>, +folder: String, +mark: Mark, uidv: U32) -> IO(Out):
  +plan = mark_plan(uids, folder, mark, uidv)
  do IO<Out>:
    p : Proc <- imap_proc(plan)
    return mark_result(p, plan, uids, folder, mark)

def mark_uids.if(
  missing: Bool,
  uids: List<&2, U32>,
  folder: String,
  mark: Mark,
  uidv: U32
) -> IO(Out):
  match missing:
    case True{}:
      pure_out(Err{uidv_missing()})
    case False{}:
      mark_uids.run(uids, folder, mark, uidv)

def mark_uids(u: Uids(), folder: String, mark: Mark, +uidv: U32) -> IO(Out):
  match u:
    case Fail{m}:
      pure_out(Err{m})
    case Done{uids}:
      mark_uids.if(U32.is_zero(uidv), uids, folder, mark, uidv)

def t_mark(+args: J.Json, mark: Mark) -> IO(Out):
  mark_uids(uids_arg(args), folder_arg(args), mark, uidv_arg(args))

def flag_colour(m: Maybe<&2, I.Colour>, args: J.Json) -> IO(Out):
  match m:
    case Some{c}:
      t_mark(args, MarkFlag{Some{c}})
    case None{}:
      pure_out(Err{"\"colour\" must be one of " ++ String.join(I.colour_names(), ", ")})

# Without a "colour", flagging leaves the message's colour bits as they are.
def flag_named(m: Maybe<&2, String>, args: J.Json) -> IO(Out):
  match m:
    case None{}:
      t_mark(args, MarkFlag{None{}})
    case Some{n}:
      flag_colour(I.colour_from_name(n), args)

def t_flag(+args: J.Json) -> IO(Out):
  flag_named(J.as_str(J.get(args, "colour")), args)

# Move, trash and delete
# ----------------------

def method_name(move: Bool) -> String:
  Bool.pick(String, move, "UID MOVE", "UID COPY + UID EXPUNGE")

# Whether a plan has a UID COPY (a UID MOVE plan has none).
def has_copy(plan: List<&2, I.Cmd>) -> Bool:
  U32.is_gt(I.copy_tag(plan, 1), 0)

# Whether a session's transcript shows a UID COPY that may have run without
# the plan finishing: the command before it was answered, the server did not
# refuse it, and the last command did not finish. A COPY the server dropped
# unanswered and one the helper never got to send look the same, so both
# count.
def copy_unfinished(+plan: List<&2, I.Cmd>, +lines: List<&2, I.RLine>) -> Bool:
  +c = I.copy_tag(plan, 1)
  has_copy(plan) && ok_at(lines, (c - 1 : U32)) && Bool.not(I.refused(lines, c)) &&
    Bool.not(ok_at(lines, I.tag_count(plan)))

# A move that may have copied without finishing. A UID MOVE plan has no COPY,
# so it is never interrupted. A lost helper counts when the plan has a COPY.
def interrupted(+plan: List<&2, I.Cmd>, +p: Proc) -> Bool:
  (helper_lost(p) && has_copy(plan)) || copy_unfinished(plan, proc_lines(p))

# The fields a finished move or label opens with.
def moved_kvs(folder: String, dest: String, move: Bool) -> List<&2, J.Json>:
  [
    J.kv("ok", J.bool(True{})),
    J.kv("folder", J.str(folder)),
    J.kv("destination", J.str(dest)),
    J.kv("method", J.str(method_name(move)))
  ]

# The result of a move that stopped part-way. It is an error for the caller,
# not one that implies nothing changed: the one-copy guarantee holds only for
# a completed move. `reason` is never empty here: a finished run is not
# interrupted.
def partial_out(reason: String, +folder: String, +dest: String, move: Bool) -> Out:
  Partial{J.obj([
    J.kv("ok", J.bool(False{})),
    J.kv("partial", J.bool(True{})),
    J.kv("folder", J.str(folder)),
    J.kv("destination", J.str(dest)),
    J.kv("method", J.str(method_name(move))),
    J.kv("message", J.str(
      "the move was cut off and may have copied the messages to " ++ dest ++
        ": they may now be in both " ++ folder ++ " and " ++ dest ++
        "; check the destination before retrying (" ++ reason ++ ")"))
  ])}

def moved_out.if(
  cut: Bool,
  r: Run(),
  +folder: String,
  uids: List<&2, U32>,
  dest: String,
  move: Bool
) -> Out:
  match cut:
    case True{}:
      partial_out(run_failure(r), folder, dest, move)
    case False{}:
      changed_out(r, uids, folder, moved_kvs(folder, dest, move))

def moved_out(
  +p: Proc,
  plan: List<&2, I.Cmd>,
  folder: String,
  uids: List<&2, U32>,
  dest: String,
  move: Bool
) -> Out:
  moved_out.if(interrupted(plan, p), imap_result(p), folder, uids, dest, move)

def move_plan(
  +plan: List<&2, I.Cmd>,
  folder: String,
  uids: List<&2, U32>,
  dest: String,
  move: Bool
) -> IO(Out):
  match plan:
    case Nil{}:
      pure_out(Err{
        "the server supports neither MOVE nor UIDPLUS; refusing to move with a plain " ++
          "EXPUNGE, which could remove other messages"})
    case h <> t:
      do IO<Out>:
        p : Proc <- imap_proc(plan)
        return moved_out(p, plan, folder, uids, dest, move)

def move_caps.if(
  problem: String,
  +caps: List<&2, String>,
  +folder: String,
  +uids: List<&2, U32>,
  +dest: String,
  uidv: U32
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      +move = I.has_cap(caps, "MOVE")
      move_plan(Ops.plan_move(folder, uids, dest, move, I.has_cap(caps, "UIDPLUS"), uidv),
        folder, uids, dest, move)

def move_caps(
  r: Run(),
  folder: String,
  uids: List<&2, U32>,
  dest: String,
  +uidv: U32
) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      move_caps.if(uidv_problem(lines, uidv), I.caps(lines), folder, uids, dest, uidv)

def move_request(uidv: U32, folder: String, +dest: String) -> String:
  Bool.pick(String, String.is_empty(dest) || I.same_name(dest, folder),
    "\"destination\" must name a different folder",
    Bool.pick(String, U32.is_zero(uidv), uidv_missing(), ""))

def move_uids.if(
  problem: String,
  +folder: String,
  uids: List<&2, U32>,
  dest: String,
  uidv: U32
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_preflight(folder))
        move_caps(r, folder, uids, dest, uidv)

def move_uids(u: Uids(), +folder: String, +dest: String, +uidv: U32) -> IO(Out):
  match u:
    case Fail{m}:
      pure_out(Err{m})
    case Done{uids}:
      move_uids.if(move_request(uidv, folder, dest), folder, uids, dest, uidv)

def t_move(+args: J.Json) -> IO(Out):
  move_uids(uids_arg(args), folder_arg(args), str_arg(args, "destination", ""), uidv_arg(args))

def trash_into(
  same: Bool,
  +trash: String,
  +caps: List<&2, String>,
  +folder: String,
  +uids: List<&2, U32>,
  uidv: U32
) -> IO(Out):
  match same:
    case True{}:
      pure_out(Err{
        "these messages are already in " ++ trash ++
          "; use mail_delete to remove them permanently"})
    case False{}:
      +move = I.has_cap(caps, "MOVE")
      move_plan(Ops.plan_trash(folder, uids, trash, move, I.has_cap(caps, "UIDPLUS"), uidv),
        folder, uids, trash, move)

def trash_to(
  trash: Maybe<&2, String>,
  caps: List<&2, String>,
  +folder: String,
  uids: List<&2, U32>,
  uidv: U32
) -> IO(Out):
  match trash:
    case None{}:
      pure_out(Err{"no unique selectable Trash folder: configure MAILBEND_TRASH_FOLDER"})
    case Some{+t}:
      trash_into(I.same_name(t, folder), t, caps, folder, uids, uidv)

def trash_fs(
  f: Fs(),
  caps: List<&2, String>,
  folder: String,
  uids: List<&2, U32>,
  uidv: U32
) -> IO(Out):
  match f:
    case Fail{m}:
      pure_out(Err{m ++ "; nothing was changed"})
    case Done{Folders{fs, drafts, trash, sent, junk, archive}}:
      trash_to(trash, caps, folder, uids, uidv)

def trash_found.if(
  problem: String,
  +lines: List<&2, I.RLine>,
  folder: String,
  uids: List<&2, U32>,
  uidv: U32
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        f : Fs() <- folders_io(lines)
        trash_fs(f, I.caps(lines), folder, uids, uidv)

def trash_found(r: Run(), folder: String, uids: List<&2, U32>, +uidv: U32) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      trash_found.if(uidv_problem(lines, uidv), lines, folder, uids, uidv)

def trash_uids.if(missing: Bool, +folder: String, uids: List<&2, U32>, uidv: U32) -> IO(Out):
  match missing:
    case True{}:
      pure_out(Err{uidv_missing()})
    case False{}:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_preflight(folder))
        trash_found(r, folder, uids, uidv)

def trash_uids(u: Uids(), folder: String, +uidv: U32) -> IO(Out):
  match u:
    case Fail{m}:
      pure_out(Err{m})
    case Done{uids}:
      trash_uids.if(U32.is_zero(uidv), folder, uids, uidv)

def t_trash(+args: J.Json) -> IO(Out):
  trash_uids(uids_arg(args), folder_arg(args), uidv_arg(args))

def delete_plan(plan: List<&2, I.Cmd>, +folder: String, uids: List<&2, U32>) -> IO(Out):
  match plan:
    case Nil{}:
      pure_out(Err{
        "the server lacks UIDPLUS; refusing a plain EXPUNGE, which could remove other messages"})
    case h <> t:
      do IO<Out>:
        r : Run() <- imap_run(plan)
        return changed_out(r, uids, folder, [
          J.kv("ok", J.bool(True{})),
          J.kv("folder", J.str(folder)),
          J.kv("permanently_deleted", J.bool(True{}))
        ])

def delete_caps.if(
  problem: String,
  caps: List<&2, String>,
  +folder: String,
  +uids: List<&2, U32>,
  confirm: String,
  uidv: U32
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      delete_plan(Ops.plan_delete(folder, uids, confirm, I.has_cap(caps, "UIDPLUS"), uidv),
        folder, uids)

def delete_caps(
  r: Run(),
  folder: String,
  uids: List<&2, U32>,
  confirm: String,
  +uidv: U32
) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      delete_caps.if(uidv_problem(lines, uidv), I.caps(lines), folder, uids, confirm, uidv)

def delete_uids.if(
  problem: String,
  +folder: String,
  uids: List<&2, U32>,
  confirm: String,
  uidv: U32
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_preflight(folder))
        delete_caps(r, folder, uids, confirm, uidv)

# The plan itself refuses without the confirmation word (a proven law);
# these checks only explain why before connecting.
def delete_request(confirm: String, uidv: U32) -> String:
  Bool.pick(String, Bool.not(String.eq(confirm, Ops.confirm_word())),
    "mail_delete permanently removes messages and cannot be undone; pass \"confirm\": " ++
      "\"permanently-delete\" to proceed (use mail_trash to move them to Trash instead)",
    Bool.pick(String, U32.is_zero(uidv), uidv_missing(), ""))

def delete_uids(u: Uids(), folder: String, +confirm: String, +uidv: U32) -> IO(Out):
  match u:
    case Fail{m}:
      pure_out(Err{m})
    case Done{uids}:
      delete_uids.if(delete_request(confirm, uidv), folder, uids, confirm, uidv)

def t_delete(+args: J.Json) -> IO(Out):
  delete_uids(uids_arg(args), folder_arg(args), str_arg(args, "confirm", ""), uidv_arg(args))

# Folders: create, rename, label
# ------------------------------

# A label is a folder. The rules below keep these tools from touching the
# folders MailBend relies on, directly or through a parent, a child or a
# rename that moves a whole subtree. They are decided here, before any
# command is sent; the plans themselves only create, rename, subscribe and
# unsubscribe.

# What folder creation, renaming and labelling must keep clear of: the
# folders, the lower-case names that are reserved (see guard_of), and the
# delimiter LIST reports, which nests one folder in another.
type Guard is Data:
  Guard{fs: List<&2, I.Folder>, reserved: List<&2, String>, delim: String}

# A folder tool's request: create `name`, or rename `from` to `to`.
type FolderChange is Data:
  FolderCreate{name: String}
  FolderRename{from: String, to: String}

def review_folder() -> String:
  "To Delete"

# Names reserved whether or not the server advertises them: the review folder,
# and the conventional role names that role resolution falls back to.
def reserved_names() -> List<&2, String>:
  review_folder() <> conventional_names()

def reserved_note() -> String:
  "INBOX, Drafts, Sent, Trash, Junk, Archive (also under their usual names), To Delete, " ++
    "and any folder configured for one of those roles or advertised with any special-use role"

def is_inbox(name: String) -> Bool:
  I.same_name(name, "INBOX")

def maybe_name(m: Maybe<&2, String>, rest: List<&2, String>) -> List<&2, String>:
  match m:
    case Some{n}:
      n <> rest
    case None{}:
      rest

# The folders that advertise a role.
def advertised_names(fs: List<&2, I.Folder>) -> List<&2, String>:
  match fs:
    case Nil{}:
      []
    case I.Folder{name, d, attrs} <> t:
      List.filter.put(String, name, advertised_names(t), recognized_role(attrs))

# Kept by hand: List.map takes only affine lists.
def lowered(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case x <> t:
      String.to_lower(x) <> lowered(t)

# The delimiter LIST reports for INBOX; "" when INBOX is not listed or has none.
def inbox_delim(fs: List<&2, I.Folder>) -> String:
  match fs:
    case Nil{}:
      ""
    case I.Folder{n, d, a} <> t:
      Bool.pick(String, is_inbox(n), d, inbox_delim(t))

# The first delimiter LIST reports for any folder; "" when it reports none.
def any_delim(fs: List<&2, I.Folder>) -> String:
  match fs:
    case Nil{}:
      ""
    case I.Folder{n, d, a} <> t:
      first_of(d, any_delim(t))

# The hierarchy delimiter: INBOX's, else any folder's. "" means none is known.
def delim_of(+fs: List<&2, I.Folder>) -> String:
  first_of(inbox_delim(fs), any_delim(fs))

# Reserved, in lower case: the resolved role folders, the folders that
# advertise a role, and the reserved names.
def guard_of(
  +fs: List<&2, I.Folder>,
  drafts: Maybe<&2, String>,
  trash: Maybe<&2, String>,
  sent: Maybe<&2, String>,
  junk: Maybe<&2, String>,
  archive: Maybe<&2, String>
) -> Guard:
  resolved = maybe_name(drafts, maybe_name(trash, maybe_name(sent,
    maybe_name(junk, maybe_name(archive, [])))))
  named = List.append(&2, String, advertised_names(fs), reserved_names())
  Guard{fs, lowered(List.append(&2, String, resolved, named)), delim_of(fs)}

# The guard for the folders and their resolved roles.
def guard_for(f: Folders) -> Guard:
  Folders{fs, drafts, trash, sent, junk, archive} = f
  guard_of(fs, drafts, trash, sent, junk, archive)

def guard_fs(g: Guard) -> List<&2, I.Folder>:
  Guard{fs, reserved, delim} = g
  fs

def guard_reserved(g: Guard) -> List<&2, String>:
  Guard{fs, reserved, delim} = g
  reserved

def guard_delim(g: Guard) -> String:
  Guard{fs, reserved, delim} = g
  delim

def has_folder(g: Guard, name: String) -> Bool:
  Maybe.is_some(&2, String, I.named(guard_fs(g), name))

# Whether `name` lies inside the folder `ancestor` (and is not that folder):
# "Mail/Sent" lies inside "Mail" when the delimiter is "/". A server with no
# delimiter has no nesting.
def inside(+delim: String, ancestor: String, name: String) -> Bool:
  Bool.not(String.is_empty(delim)) && String.starts_with(name, ancestor ++ delim)

def at_or_inside(delim: String, +ancestor: String, +name: String) -> Bool:
  String.eq(ancestor, name) || inside(delim, ancestor, name)

# Whether the lower-case `name` is a reserved folder or inside one.
def inside_reserved(+delim: String, reserved: List<&2, String>, +name: String) -> Bool:
  match reserved:
    case Nil{}:
      False{}
    case r <> t:
      at_or_inside(delim, r, name) || inside_reserved(delim, t, name)

# Whether the lower-case `name` is a reserved folder or contains one.
def holds_reserved(+delim: String, reserved: List<&2, String>, +name: String) -> Bool:
  match reserved:
    case Nil{}:
      False{}
    case r <> t:
      at_or_inside(delim, name, r) || holds_reserved(delim, t, name)

# INBOX is reserved itself, but not its children: some servers keep every
# folder under it.
def reserved_target(+g: Guard, +name: String) -> Bool:
  is_inbox(name) || inside_reserved(guard_delim(g), guard_reserved(g), String.to_lower(name))

def reserved_source(+g: Guard, +name: String) -> Bool:
  is_inbox(name) || holds_reserved(guard_delim(g), guard_reserved(g), String.to_lower(name))

# A folder name is split into its levels at the delimiter; a server without
# one has a single level.
def levels(delim: String, name: String) -> List<&2, String>:
  match delim:
    case SCon{c, SNil{}}:
      String.split(name, c)
    case _:
      [name]

def has_empty_level(ls: List<&2, String>) -> Bool:
  List.any(~&2, ~String, ~(l => String.is_empty(l)), ls)

# `ls` without its last level, given the level `h` that precedes it.
def without_last(ls: List<&2, String>, h: String) -> List<&2, String>:
  match ls:
    case Nil{}:
      []
    case n <> rest:
      h <> without_last(rest, n)

def init_of(ls: List<&2, String>) -> List<&2, String>:
  match ls:
    case Nil{}:
      []
    case h <> t:
      without_last(t, h)

# The folder `name` sits in; "" for a top-level name.
def parent_of(+delim: String, name: String) -> String:
  String.join(init_of(levels(delim, name)), delim)

# `ls` with a first level spelled "inbox" in any case replaced by `inbox`.
def with_inbox(inbox: String, ls: List<&2, String>) -> List<&2, String>:
  match ls:
    case Nil{}:
      []
    case +h <> +t:
      Bool.pick(List<&2, String>, is_inbox(h), inbox <> t, h <> t)

# Only the exact name INBOX is case-insensitive, so a server could take
# "inbox/x" for a new top-level folder: the first level is rewritten to the
# INBOX name LIST gives.
def canonical_name(+g: Guard, name: String) -> String:
  +delim = guard_delim(g)
  inbox = Maybe.default(&2, String, I.named(guard_fs(g), "INBOX"), "INBOX")
  String.join(with_inbox(inbox, levels(delim, name)), delim)

# Checks that need no connection.
def raw_name_problem(+name: String) -> String:
  Bool.pick(String, String.is_empty(name), "a folder name cannot be empty",
    Bool.pick(String, M.no_ctl(name), "", "a folder name cannot contain control characters"))

# With no known delimiter a nested-looking name is refused, not guessed at.
def shape_problem(g: Guard, +name: String) -> String:
  +delim = guard_delim(g)
  unknown = String.is_empty(delim) && (String.contains(name, "/") || String.contains(name, "."))
  Bool.pick(String, unknown,
    "cannot tell the server's hierarchy delimiter (LIST reports none), so \"" ++ name ++
      "\" cannot be checked as a nested name",
    Bool.pick(String, has_empty_level(levels(delim, name)),
      "\"" ++ name ++ "\" has an empty level: a folder name cannot start or end with the " ++
        "delimiter \"" ++ delim ++ "\" or repeat it",
      ""))

def reserved_problem(g: Guard, +name: String) -> String:
  Bool.pick(String, reserved_target(g, name),
    "\"" ++ name ++ "\" is, or lies inside, a folder MailBend relies on: " ++ reserved_note(), "")

def exists_problem(g: Guard, +name: String) -> String:
  Bool.pick(String, has_folder(g, name), "a folder named \"" ++ name ++ "\" already exists", "")

def parent_problem(+g: Guard, name: String) -> String:
  +parent = parent_of(guard_delim(g), name)
  Bool.pick(String, String.is_empty(parent) || has_folder(g, parent), "",
    "the parent folder \"" ++ parent ++ "\" does not exist; create it first")

# A new folder name: well formed, not reserved or inside a reserved folder,
# not taken, and directly under a folder that exists (no implicit parents).
def target_problem(+g: Guard, +name: String) -> String:
  first_of(shape_problem(g, name), first_of(reserved_problem(g, name),
    first_of(exists_problem(g, name), parent_problem(g, name))))

def create_problem.if(review: Bool, g: Guard, name: String) -> String:
  match review:
    case True{}:
      exists_problem(g, name)
    case False{}:
      target_problem(g, name)

# mail_create_folder may also create the review folder, once and at top level.
def create_problem(g: Guard, +name: String) -> String:
  create_problem.if(String.eq(name, review_folder()), g, name)

def source_problem(+g: Guard, +name: String) -> String:
  first_of(Bool.pick(String, has_folder(g, name), "", "no folder is named \"" ++ name ++ "\""),
    Bool.pick(String, reserved_source(g, name),
      "\"" ++ name ++ "\" is, or contains, a folder MailBend relies on, so it cannot be " ++
        "renamed: " ++ reserved_note(),
      ""))

def nesting_problem(g: Guard, from: String, to: String) -> String:
  Bool.pick(String, at_or_inside(guard_delim(g), from, to),
    "a folder cannot be renamed to itself or into itself", "")

def moved_problem(name: String, moved: String, +problem: String) -> String:
  Bool.pick(String, String.is_empty(problem), "",
    "renaming would turn the subfolder \"" ++ name ++ "\" into \"" ++ moved ++ "\": " ++ problem)

def child_problem.if(child: Bool, +g: Guard, name: String, +moved: String) -> String:
  match child:
    case True{}:
      moved_problem(name, moved, first_of(reserved_problem(g, moved), exists_problem(g, moved)))
    case False{}:
      ""

# A subfolder follows its parent to the new path, which must be as free as a
# new folder's. Its parent comes from the rename itself, so only the
# destination's own parent has to exist already.
def child_problem(+g: Guard, +from: String, to: String, +name: String) -> String:
  child_problem.if(inside(guard_delim(g), from, name), g, name, Ops.renamed_to(from, to, name))

def children_problem(+g: Guard, +from: String, +to: String, fs: List<&2, I.Folder>) -> String:
  match fs:
    case Nil{}:
      ""
    case I.Folder{name, d, a} <> t:
      first_of(child_problem(g, from, to, name), children_problem(g, from, to, t))

def rename_problem(+g: Guard, +from: String, +to: String) -> String:
  first_of(source_problem(g, from), first_of(target_problem(g, to),
    first_of(nesting_problem(g, from, to), children_problem(g, from, to, guard_fs(g)))))

# A label folder: it exists, can be opened, and is none of the folders
# MailBend relies on, nor inside one (use mail_move or mail_trash for those).
def label_problem(+g: Guard, +label: String) -> String:
  first_of(
    Bool.pick(String, has_folder(g, label), "",
      "the label folder \"" ++ label ++ "\" does not exist: create it with mail_create_folder"),
    first_of(
      Bool.pick(String, Maybe.is_none(&2, String, named_folder(guard_fs(g), label)),
        "the label folder \"" ++ label ++ "\" cannot be selected", ""),
      reserved_problem(g, label)))

# What each kind of folder change checks, plans and reports.
def change_raw_problem(c: FolderChange) -> String:
  match c:
    case FolderCreate{name}:
      raw_name_problem(name)
    case FolderRename{from, to}:
      first_of(raw_name_problem(from), raw_name_problem(to))

def change_problem(g: Guard, c: FolderChange) -> String:
  match c:
    case FolderCreate{name}:
      create_problem(g, name)
    case FolderRename{from, to}:
      rename_problem(g, from, to)

def change_canonical(g: Guard, c: FolderChange) -> FolderChange:
  match c:
    case FolderCreate{name}:
      FolderCreate{canonical_name(g, name)}
    case FolderRename{from, to}:
      FolderRename{from, canonical_name(g, to)}

# The folders of `fs` that are `root` or inside it, exist, and are among the
# subscribed folders `subs`: the ones whose subscription a rename moves.
def subscribed_tree(
  +delim: String,
  +root: String,
  fs: List<&2, I.Folder>,
  +subs: List<&2, I.Folder>
) -> List<&2, String>:
  match fs:
    case Nil{}:
      []
    case I.Folder{+name, d, attrs} <> t:
      moves = at_or_inside(delim, root, name) && Bool.not(I.has_attr(attrs, "\\NonExistent")) &&
        Maybe.is_some(&2, String, I.named(subs, name))
      List.filter.put(String, name, subscribed_tree(delim, root, t, subs), moves)

def change_plan(+g: Guard, subs: List<&2, I.Folder>, c: FolderChange) -> List<&2, I.Cmd>:
  match c:
    case FolderCreate{name}:
      Ops.plan_create(name)
    case FolderRename{+from, to}:
      Ops.plan_rename(from, to, subscribed_tree(guard_delim(g), from, guard_fs(g), subs))

def change_verb(c: FolderChange) -> String:
  match c:
    case FolderCreate{name}:
      "created"
    case FolderRename{from, to}:
      "renamed"

def change_result(c: FolderChange) -> List<&2, J.Json>:
  match c:
    case FolderCreate{name}:
      [J.kv("ok", J.bool(True{})), J.kv("folder", J.str(name))]
    case FolderRename{from, to}:
      [J.kv("ok", J.bool(True{})), J.kv("from", J.str(from)), J.kv("to", J.str(to))]

# Why updating the subscriptions failed: with `names_ok` every new name got
# subscribed, so only dropping the old names failed.
def subscription_failure(names_ok: Bool, reason: String) -> String:
  match names_ok:
    case True{}:
      "dropping its old subscriptions failed (" ++ reason ++
        "); the old names may still be listed as subscribed"
    case False{}:
      "updating its subscriptions failed (" ++ reason ++
        "); some clients may not show it until it is subscribed"

def subscription_kvs(
  all_ok: Bool,
  names_ok: Bool,
  c: FolderChange,
  reason: String
) -> List<&2, J.Json>:
  match all_ok:
    case True{}:
      [J.kv("subscribed", J.bool(True{}))]
    case False{}:
      [
        J.kv("subscribed", J.bool(False{})),
        J.kv("note", J.str("the folder was " ++ change_verb(c) ++ ", but " ++
          subscription_failure(names_ok, reason) ++ ". Do not retry"))
      ]

# The change went through; only the subscriptions may have failed, which a
# retry would not fix (the folder now exists, or the old name is gone).
def folder_done(names_ok: Bool, all_ok: Bool, +c: FolderChange, reason: String) -> Out:
  ok_obj(List.append(&2, J.Json, change_result(c), subscription_kvs(all_ok, names_ok, c, reason)))

# Whether the change (tag 2, after the CAPABILITY anchor) may have run
# unanswered: the session got past the anchor and the change got no answer,
# or the helper was lost. Anything earlier changed nothing.
def folder_unanswered(+p: Proc) -> Bool:
  +lines = proc_lines(p)
  helper_lost(p) || (ok_at(lines, 1) && String.is_empty(I.status(lines, 2)))

def folder_out.if(
  changed: Bool,
  p: Proc,
  +plan: List<&2, I.Cmd>,
  c: FolderChange,
  +reason: String
) -> Out:
  match changed:
    case True{}:
      +lines = proc_lines(p)
      +last = I.tag_count(plan)
      folder_done(ok_at(lines, (last - I.unsubscribe_count(plan) : U32)), ok_at(lines, last), c,
        reason)
    case False{}:
      Bool.pick(Out, folder_unanswered(p),
        Err{"the folder may have been " ++ change_verb(c) ++
          "; list the folders before retrying (" ++ reason ++ ")"},
        Err{reason})

# The plan is CAPABILITY, the change, then its subscriptions. A refused change
# or one that never started is a plain error; one that may have run
# unanswered tells the agent to look before retrying.
def folder_out(+p: Proc, plan: List<&2, I.Cmd>, c: FolderChange) -> Out:
  folder_out.if(ok_at(proc_lines(p), 2), p, plan, c, run_failure(imap_result(p)))

def folder_guarded.if(problem: String, +plan: List<&2, I.Cmd>, c: FolderChange) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        p : Proc <- imap_proc(plan)
        return folder_out(p, plan, c)

def folder_guarded(+g: Guard, subs: List<&2, I.Folder>, c: FolderChange) -> IO(Out):
  +canonical = change_canonical(g, c)
  folder_guarded.if(change_problem(g, canonical), change_plan(g, subs, canonical), canonical)

def folder_fs(f: Fs(), subs: List<&2, I.Folder>, c: FolderChange) -> IO(Out):
  match f:
    case Fail{m}:
      pure_out(Err{m ++ "; nothing was changed"})
    case Done{folders}:
      folder_guarded(guard_for(folders), subs, c)

def folder_found(r: Run(), c: FolderChange) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      do IO<Out>:
        f : Fs() <- folders_io(lines)
        folder_fs(f, I.subscribed(lines), c)

def folder_change.if(problem: String, c: FolderChange) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_folder_scan())
        folder_found(r, c)

def folder_change(+c: FolderChange) -> IO(Out):
  folder_change.if(change_raw_problem(c), c)

def t_create_folder(args: J.Json) -> IO(Out):
  folder_change(FolderCreate{str_arg(args, "name", "")})

def t_rename_folder(+args: J.Json) -> IO(Out):
  folder_change(FolderRename{str_arg(args, "from", ""), str_arg(args, "to", "")})

# Runs the label plan unless `problem` rules it out.
def label_fs.if(
  problem: String,
  plan: List<&2, I.Cmd>,
  folder: String,
  uids: List<&2, U32>,
  label: String,
  move: Bool
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      move_plan(plan, folder, uids, label, move)

def label_fs(
  f: Fs(),
  +caps: List<&2, String>,
  +folder: String,
  +uids: List<&2, U32>,
  +label: String,
  uidv: U32
) -> IO(Out):
  match f:
    case Fail{m}:
      pure_out(Err{m ++ "; nothing was changed"})
    case Done{folders}:
      +move = I.has_cap(caps, "MOVE")
      label_fs.if(label_problem(guard_for(folders), label),
        Ops.plan_label(folder, uids, label, move, I.has_cap(caps, "UIDPLUS"), uidv),
        folder, uids, label, move)

def label_found.if(
  problem: String,
  +lines: List<&2, I.RLine>,
  folder: String,
  uids: List<&2, U32>,
  label: String,
  uidv: U32
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        f : Fs() <- folders_io(lines)
        label_fs(f, I.caps(lines), folder, uids, label, uidv)

def label_found(
  r: Run(),
  folder: String,
  uids: List<&2, U32>,
  label: String,
  +uidv: U32
) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      label_found.if(uidv_problem(lines, uidv), lines, folder, uids, label, uidv)

def label_uids.if(
  problem: String,
  +folder: String,
  uids: List<&2, U32>,
  label: String,
  uidv: U32
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_preflight(folder))
        label_found(r, folder, uids, label, uidv)

def label_request(uidv: U32, folder: String, +label: String) -> String:
  Bool.pick(String, String.is_empty(label) || I.same_name(label, folder),
    "\"label\" must name a folder other than the one the messages are in",
    Bool.pick(String, U32.is_zero(uidv), uidv_missing(), ""))

def label_uids(u: Uids(), +folder: String, +label: String, +uidv: U32) -> IO(Out):
  match u:
    case Fail{m}:
      pure_out(Err{m})
    case Done{uids}:
      label_uids.if(label_request(uidv, folder, label), folder, uids, label, uidv)

def t_label(+args: J.Json) -> IO(Out):
  label_uids(uids_arg(args), folder_arg(args), str_arg(args, "label", ""), uidv_arg(args))

# Composing
# =========

# Attachments
# -----------

def basename(+path: String) -> String:
  Maybe.default(&2, String, List.last(&2, String, String.split(path, '/')), path)

# A file name ending and the content type it implies.
type Suffix is Data:
  Suffix{ending: String, ctype: String}

def suffix_types() -> List<&2, Suffix>:
  [
    Suffix{".pdf", "application/pdf"},
    Suffix{".txt", "text/plain"},
    Suffix{".md", "text/plain"},
    Suffix{".log", "text/plain"},
    Suffix{".csv", "text/csv"},
    Suffix{".html", "text/html"},
    Suffix{".htm", "text/html"},
    Suffix{".json", "application/json"},
    Suffix{".png", "image/png"},
    Suffix{".jpg", "image/jpeg"},
    Suffix{".jpeg", "image/jpeg"},
    Suffix{".gif", "image/gif"},
    Suffix{".zip", "application/zip"},
    Suffix{".eml", "message/rfc822"}
  ]

# The content type of the first of `ss` that the lower-case `name` ends with.
def suffix_type(ss: List<&2, Suffix>, +name: String) -> String:
  match ss:
    case Nil{}:
      "application/octet-stream"
    case Suffix{ending, ctype} <> t:
      Bool.pick(String, String.ends_with(name, ending), ctype, suffix_type(t, name))

def ext_type(name: String) -> String:
  suffix_type(suffix_types(), String.to_lower(name))

def max_attachment() -> U32:
  26214400

def pure_att(a: Attachment()) -> IO(Attachment()):
  IO.pure(Attachment(), a)

# mailbend-attach's own message.
def attach_msg(err: String) -> String:
  strip_prefix(helper_msg(err), "mailbend-attach: ")

# Like the TLS helper, mailbend-attach is only started from an absolute path.
def attach_helper_refusal() -> String:
  "MAILBEND_ATTACH_HELPER must be the absolute path of mailbend-attach " ++
    "(scripts/mailbend sets it)"

def att_proc(p: Proc, name: String, ctype: String) -> Attachment():
  match p:
    case ProcOk{code, out, err}:
      match code:
        case 0:
          Done{M.Attach{name, ctype, out}}
        case _:
          Fail{attach_msg(err)}
    case _:
      Fail{"cannot run mailbend-attach: " ++ proc_failure(p)}

# `budget` is what is left of the 25 MB all attachments may take together;
# the reader refuses a file larger than that before reading it.
def att_read(
  helper: String,
  dir: String,
  path: String,
  name: String,
  ctype: String,
  budget: U32
) -> IO(Attachment()):
  do IO<Attachment()>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run(helper, [dir, path, U32.show(budget)], "", 60000000, 60000)
    return att_proc(proc_of(r), name, ctype)

def att_at(
  helper: String,
  dir: String,
  path: String,
  name: String,
  ctype: String,
  budget: U32
) -> IO(Attachment()):
  match helper:
    case SCon{'/', t}:
      att_read(helper, dir, path, name, ctype, budget)
    case _:
      pure_att(Fail{attach_helper_refusal()})

# Attachments come only from MAILBEND_ATTACH_DIR and are off without it: an
# agent tricked by a message must not mail out files such as
# /proc/self/environ (which holds the app password) or ~/.ssh keys. They are
# read by mailbend-attach, a separate program that holds no credentials: it
# opens the file beneath that directory with no symlinks allowed and checks
# the opened descriptor itself, so a path swapped mid-way cannot redirect
# the read.
def att_dir(
  dir: String,
  path: String,
  name: String,
  ctype: String,
  budget: U32
) -> IO(Attachment()):
  match dir:
    case SNil{}:
      pure_att(Fail{
        "attachments are disabled: set MAILBEND_ATTACH_DIR to the directory whose files " ++
          "may be attached"})
    case SCon{h, t}:
      do IO<Attachment()>:
        helper : String <- env_or("MAILBEND_ATTACH_HELPER", "")
        att_at(helper, dir, path, name, ctype, budget)

def att_path(
  missing: Bool,
  path: String,
  name: String,
  ctype: String,
  budget: U32
) -> IO(Attachment()):
  match missing:
    case True{}:
      pure_att(Fail{"each attachment needs a \"path\""})
    case False{}:
      do IO<Attachment()>:
        dir : String <- env_or("MAILBEND_ATTACH_DIR", "")
        att_dir(dir, path, name, ctype, budget)

def att_one(+a: J.Json, budget: U32) -> IO(Attachment()):
  +path = str_arg(a, "path", "")
  +name = str_arg(a, "filename", basename(path))
  att_path(String.is_empty(path), path, name, str_arg(a, "content_type", ext_type(name)), budget)

def max_attachments() -> U32:
  32

def att_size(a: Attachment()) -> U32:
  match a:
    case Done{M.Attach{n, c, data}}:
      C.byte_len(data)
    case Fail{m}:
      0

def att_ok(a: Attachment()) -> Bool:
  Result.is_done(&2, &2, String, M.Attach, a)

def att_gated(too_many: Bool, spent: Bool, a: J.Json, budget: U32) -> IO(Attachment()):
  match too_many:
    case True{}:
      pure_att(Fail{"at most 32 attachments"})
    case False{}:
      match spent:
        case True{}:
          pure_att(Fail{"attachments (with a forwarded original) may total at most 25 MB"})
        case False{}:
          att_one(a, budget)

# Reads the next attachment only while everything before it was read, the
# 25 MB total budget is not spent and there are at most 32; once one fails
# the rest are never read (a placeholder keeps the first error first).
def att_gate(go: Bool, n: U32, a: J.Json, +budget: U32) -> IO(Attachment()):
  match go:
    case False{}:
      pure_att(Fail{"not read"})
    case True{}:
      att_gated(U32.is_ge(n, max_attachments()), U32.is_zero(budget), a, budget)

def atts_read_within.go(
  xs: List<&2, J.Json>,
  +go: Bool,
  +n: U32,
  +budget: U32
) -> IO(List<&2, Attachment()>):
  match xs:
    case Nil{}:
      IO.pure(List<&2, Attachment()>, [])
    case a <> t:
      do IO<List<&2, Attachment()>>:
        +o : Attachment() <- att_gate(go, n, a, budget)
        rest : List<&2, Attachment()> <-
          atts_read_within.go(t, go && att_ok(o), (n + 1 : U32), (budget - att_size(o) : U32))
        return o <> rest

def atts_read_within(xs: List<&2, J.Json>, budget: U32) -> IO(List<&2, Attachment()>):
  atts_read_within.go(xs, True{}, 0, budget)

def atts_read(xs: List<&2, J.Json>) -> IO(List<&2, Attachment()>):
  atts_read_within(xs, max_attachment())

def atts_cons(a: M.Attach, rest: Attachments()) -> Attachments():
  match rest:
    case Done{xs}:
      Done{a <> xs}
    case Fail{m}:
      Fail{m}

def atts_collect(rs: List<&2, Attachment()>) -> Attachments():
  match rs:
    case Nil{}:
      Done{[]}
    case Fail{m} <> t:
      Fail{m}
    case Done{a} <> t:
      atts_cons(a, atts_collect(t))

# Stamps and drafts
# -----------------

# A date, a unique token (for Message-ID and the MIME boundary), and the
# UTC day (YYYY-MM-DD) a send counts against.
type Stamp is Data:
  Stamp{date: String, token: String, day: String}

# What the tools want composed; Bcc goes only into the SMTP envelope.
type Want is Data:
  Want{
    to: List<&2, String>,
    cc: List<&2, String>,
    bcc: List<&2, String>,
    subject: String,
    text: String,
    irt: String,
    refs: String,
    atts: List<&2, M.Attach>,
    draft: Bool
  }

def secs_of(p: Proc) -> U32:
  match p:
    case ProcOk{code, out, err}:
      Maybe.default(&2, U32, U32.read(String.trim(out)), 0)
    case _:
      0

def rand_of(r: Result<&1, &1, U32 & String, U32>) -> U32:
  match r:
    case Done{n}:
      n
    case Fail{e}:
      0

def stamp_of(+secs: U32, a: U32, b: U32) -> Stamp:
  Stamp{M.rfc5322_date(secs), C.hex8(secs) ++ "." ++ C.hex8(a) ++ C.hex8(b), M.iso_date(secs)}

def stamp() -> IO(Stamp):
  do IO<Stamp>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("/bin/date", ["+%s"], "", 64, 5000)
    a : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    b : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    return stamp_of(secs_of(proc_of(r)), rand_of(a), rand_of(b))

def domain_of(addr: String) -> String:
  Maybe.default(&2, String, List.last(&2, String, String.split(M.addr_spec(addr), '@')),
    "mailbend.invalid")

# A saved draft keeps its Bcc header (a mail client sends it later and drops
# the header); a sent message never carries one, Bcc goes only into the
# SMTP envelope.
def draft_of(w: Want, +from: String, st: Stamp, keep_bcc: Bool) -> M.Draft:
  Want{to, cc, bcc, subject, text, irt, refs, atts, draft} = w
  Stamp{date, token, day} = st
  msgid = "<" ++ token ++ "@" ++ domain_of(from) ++ ">"
  M.Draft{from, to, cc, Bool.pick(List<&2, String>, keep_bcc, bcc, []), subject, text, date,
    msgid, irt, refs, atts}

def msgid_of(d: M.Draft) -> String:
  M.Draft{f, t, c, bc, s, x, dt, msgid, i, r, a} = d
  msgid

def boundary_of(st: Stamp) -> String:
  Stamp{date, token, day} = st
  "mailbend-" ++ token

def day_of(st: Stamp) -> String:
  Stamp{date, token, day} = st
  day

def all_rcpts(w: Want) -> List<&2, String>:
  Want{to, cc, bcc, s, x, i, r, a, d} = w
  List.concat(&2, String, [to, cc, bcc])

def is_draft(w: Want) -> Bool:
  Want{t, c, b, s, x, i, r, a, draft} = w
  draft

def specs(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case x <> t:
      M.addr_spec(x) <> specs(t)

# Saving drafts
# -------------

# "[APPENDUID <uidvalidity> <uid>]" in the APPEND's tagged OK.
def appenduid(ws: List<&2, String>) -> J.Json:
  match ws:
    case code <> v <> uid <> Nil{}:
      Bool.pick(J.Json, String.eq(String.to_upper(code), "APPENDUID"), maybe_num(U32.read(uid)),
        J.JNull{})
    case _:
      J.JNull{}

def appended_uid(lines: List<&2, I.RLine>) -> J.Json:
  appenduid(String.split(I.resp_code(I.status_text(lines, 1)), ' '))

def draft_saved(r: Run(), drafts: String, msgid: String) -> Out:
  match r:
    case Fail{m}:
      Err{"failed or unconfirmed (check " ++ drafts ++ " before saving again): " ++ m}
    case Done{lines}:
      ok_obj([
        J.kv("ok", J.bool(True{})),
        J.kv("saved_to", J.str(drafts)),
        J.kv("uid", appended_uid(lines)),
        J.kv("message_id", J.str(msgid))
      ])

def draft_append(m: Maybe<&2, String>, msg: String, msgid: String) -> IO(Out):
  match m:
    case None{}:
      pure_out(Err{"no unique selectable Drafts folder: configure MAILBEND_DRAFTS_FOLDER"})
    case Some{+drafts}:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_draft(drafts, msg))
        return draft_saved(r, drafts, msgid)

def draft_fs(f: Fs(), msg: String, msgid: String) -> IO(Out):
  match f:
    case Fail{m}:
      pure_out(Err{m ++ "; no draft was saved"})
    case Done{Folders{fs, drafts, trash, sent, junk, archive}}:
      draft_append(drafts, msg, msgid)

def draft_folder(r: Run(), msg: String, msgid: String) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{lines}:
      do IO<Out>:
        f : Fs() <- folders_io(lines)
        draft_fs(f, msg, msgid)

def sent_out(o: Out, msgid: String, n: U32) -> Out:
  match o:
    case Err{m}:
      Err{m}
    case Partial{j}:
      Partial{j}
    case Ok{reply}:
      ok_obj([
        J.kv("ok", J.bool(True{})),
        J.kv("sent", J.bool(True{})),
        J.kv("message_id", J.str(msgid)),
        J.kv("recipients", J.num(n)),
        J.kv("server_reply", reply)
      ])

# The Sent copy
# -------------

# With MAILBEND_SAVE_SENT=1, a sent message is appended to the Sent folder,
# unless the server already filed it there: a read-only search for its
# Message-ID, then an exact comparison of the fetched Message-ID headers
# (SEARCH HEADER matches substrings). What happened is reported beside the
# successful send as `sent_copy`; a failed copy does not make the send fail.

def sent_copy.fin(r: Run(), sent: String) -> String:
  match r:
    case Fail{m}:
      "failed or unconfirmed (check " ++ sent ++ " before saving again): " ++ m
    case Done{lines}:
      "saved to " ++ sent

def sent_copy.run(+sent: String, msg: String) -> IO(String):
  do IO<String>:
    r : Run() <- imap_run(Ops.plan_sent_copy(sent, msg))
    return sent_copy.fin(r, sent)

def msg_id(m: I.Msg) -> String:
  I.Msg{uid, flags, date, size, headers, body} = m
  String.trim(M.header(M.headers(headers), "message-id"))

def has_msg_id(ms: List<&2, I.Msg>, +msgid: String) -> Bool:
  match ms:
    case Nil{}:
      False{}
    case m <> t:
      String.eq(msg_id(m), msgid) || has_msg_id(t, msgid)

def sent_copy.if(filed: Bool, sent: String, msg: String) -> IO(String):
  match filed:
    case True{}:
      pure_str("already in " ++ sent)
    case False{}:
      sent_copy.run(sent, msg)

def sent_copy.headers(r: Run(), sent: String, msgid: String, msg: String) -> IO(String):
  match r:
    case Fail{m}:
      pure_str("failed: " ++ m)
    case Done{lines}:
      sent_copy.if(has_msg_id(I.fetched(lines), msgid), sent, msg)

def sent_copy.matches(
  +uids: List<&2, U32>,
  +sent: String,
  msgid: String,
  msg: String
) -> IO(String):
  match uids:
    case Nil{}:
      sent_copy.run(sent, msg)
    case h <> t:
      do IO<String>:
        r : Run() <- imap_run(Ops.plan_headers(sent, uids))
        sent_copy.headers(r, sent, msgid, msg)

def sent_copy.search(r: Run(), sent: String, msgid: String, msg: String) -> IO(String):
  match r:
    case Fail{m}:
      pure_str("failed: " ++ m)
    case Done{lines}:
      sent_copy.matches(I.search_uids(lines), sent, msgid, msg)

def sent_copy.folder(f: Fs(), +msgid: String, msg: String) -> IO(String):
  match f:
    case Fail{m}:
      pure_str("failed: " ++ m)
    case Done{Folders{fs, drafts, trash, sent, junk, archive}}:
      match sent:
        case None{}:
          pure_str(
            "not saved: no unique selectable Sent folder: configure MAILBEND_SENT_FOLDER")
        case Some{+s}:
          do IO<String>:
            r : Run() <- imap_run(Ops.plan_search(s, [I.KHeader{"Message-ID", msgid}]))
            sent_copy.search(r, s, msgid, msg)

def sent_copy.folders(r: Run(), msgid: String, msg: String) -> IO(String):
  match r:
    case Fail{m}:
      pure_str("failed: " ++ m)
    case Done{lines}:
      do IO<String>:
        f : Fs() <- folders_io(lines)
        sent_copy.folder(f, msgid, msg)

# What became of the Sent copy of the message `msgid`, as `sent_copy` says it.
def sent_copy(msgid: String, msg: String) -> IO(String):
  do IO<String>:
    r : Run() <- imap_run(Ops.plan_probe())
    sent_copy.folders(r, msgid, msg)

# The daily limit
# ---------------

# With MAILBEND_MAX_SENDS_PER_DAY, each send first reserves one place in
# the day's count (UTC), kept by mailbend-attach in `<state dir>/sends`,
# which no tool reads or writes. The reservation comes before SMTP, so a
# send that then fails or times out still counts, and a count that cannot
# be read refuses the send.

def limit_reached(limit: U32) -> String:
  "the daily send limit is reached: MAILBEND_MAX_SENDS_PER_DAY allows " ++ U32.show(limit) ++
    " per day (UTC)"

# The helper's answer, "ok <n>" or "full <n>", as a problem.
def reservation.answer(+out: String, limit: U32) -> String:
  Bool.pick(String, String.starts_with(out, "ok "), "",
    Bool.pick(String, String.starts_with(out, "full "), limit_reached(limit),
      "mailbend-attach gave an unexpected count"))

# Why the reservation refuses the send ("" when it may go).
def reservation(p: Proc, limit: U32) -> String:
  match p:
    case ProcOk{code, out, err}:
      match code:
        case 0:
          reservation.answer(String.trim(out), limit)
        case _:
          "cannot count this send for MAILBEND_MAX_SENDS_PER_DAY: " ++ attach_msg(err)
    case _:
      "cannot run mailbend-attach: " ++ proc_failure(p)

def reserve.run(helper: String, dir: String, +limit: U32, day: String) -> IO(String):
  match helper:
    case SCon{'/', t}:
      do IO<String>:
        r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
          Process.run(helper, ["count", dir, U32.show(limit), day], "", 4096, 60000)
        return reservation(proc_of(r), limit)
    case _:
      pure_str(attach_helper_refusal())

def reserve.dir(+dir: String, limit: U32, day: String) -> IO(String):
  match dir:
    case SNil{}:
      pure_str("MAILBEND_MAX_SENDS_PER_DAY needs a state directory: set MAILBEND_STATE_DIR " ++
        "(or HOME)")
    case _:
      do IO<String>:
        helper : String <- env_or("MAILBEND_ATTACH_HELPER", "")
        reserve.run(helper, dir, limit, day)

# Why the daily limit refuses this send ("" when it may go, or there is no
# limit).
def reserve(+limit: U32, dir: String, day: String) -> IO(String):
  match limit:
    case 0:
      pure_str("")
    case _:
      reserve.dir(dir, limit, day)

# Sending
# -------

# What a sent message reports: its Message-ID and recipient count; and, with
# `save`, the copy to keep in Sent, which keeps the Bcc header as a saved
# draft does. The copy is composed only once the send has succeeded.
type Sent is Data:
  Sent{msgid: String, rcpts: U32, save: Bool, copy: M.Draft, boundary: String}

def send_allowed.copy(o: Out, save: Bool, msgid: String, copy: M.Draft, boundary: String) ->
  IO(Out):
  match o save:
    case Ok{j} True{}:
      do IO<Out>:
        c : String <- sent_copy(msgid, M.compose(copy, boundary))
        return with_fields(Ok{j}, [J.kv("sent_copy", J.str(c))])
    case Ok{j} False{}:
      pure_out(Ok{j})
    case Err{m} _:
      pure_out(Err{m})
    case Partial{j} _:
      pure_out(Partial{j})

# A delivered message's result, with what became of its Sent copy.
def send_allowed.fin(o: Out, s: Sent) -> IO(Out):
  Sent{+msgid, n, save, copy, boundary} = s
  send_allowed.copy(sent_out(o, msgid, n), save, msgid, copy, boundary)

def send_allowed.if(problem: String, envelope: String, s: Sent) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t} ++ "; nothing was sent"})
    case SNil{}:
      do IO<Out>:
        o : Out <- smtp_run(envelope)
        send_allowed.fin(o, s)

def unlisted_msg(refused: List<&2, String>) -> String:
  "MAILBEND_ALLOWED_RECIPIENTS does not allow sending to " ++ String.join(refused, ", ") ++
    "; nothing was sent"

# The send itself: S.outbound gives the envelope only when the allowlist
# allows every recipient; only then is a place in the daily count reserved.
def send_allowed(
  envelope: Maybe<&2, String>,
  allow: List<&2, String>,
  rcpts: List<&2, String>,
  limit: U32,
  dir: String,
  day: String,
  s: Sent
) -> IO(Out):
  match envelope:
    case None{}:
      pure_out(Err{unlisted_msg(S.refused(allow, rcpts))})
    case Some{e}:
      do IO<Out>:
        problem : String <- reserve(limit, dir, day)
        send_allowed.if(problem, e, s)

def send_with(cfg: Sends(), +w: Want, +from: String, +st: Stamp) -> IO(Out):
  match cfg:
    case Fail{m}:
      pure_out(Err{"configuration error: " ++ m})
    case Done{Sending{save, +allow, limit, dir}}:
      +d = draft_of(w, from, st, False{})
      +rcpts = specs(all_rcpts(w))
      send_allowed(
        S.outbound(allow, rcpts, M.addr_spec(from), M.compose(d, boundary_of(st))),
        allow, rcpts, limit, dir, day_of(st),
        Sent{msgid_of(d), U32.from_nat(List.length(&2, String, rcpts)), save,
          draft_of(w, from, st, True{}), boundary_of(st)})

def deliver_as(draft: Bool, +w: Want, +from: String, +st: Stamp) -> IO(Out):
  match draft:
    case True{}:
      +d = draft_of(w, from, st, True{})
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_probe())
        draft_folder(r, M.compose(d, boundary_of(st)), msgid_of(d))
    case False{}:
      do IO<Out>:
        cfg : Sends() <- sending()
        send_with(cfg, w, from, st)

def deliver(+w: Want, from: String, st: Stamp) -> IO(Out):
  deliver_as(is_draft(w), w, from, st)

def check_want(+w: Want, from: String) -> String:
  +rcpts = all_rcpts(w)
  Bool.pick(String, Bool.not(M.addr_ok(from)), "MAILBEND_EMAIL is not a valid address",
    Bool.pick(String, Bool.not(M.all_addrs_ok(rcpts)),
      "every recipient must be an address like name@example.com or " ++
        "\"Name <name@example.com>\"",
      Bool.pick(String, List.is_empty(&2, String, rcpts) && Bool.not(is_draft(w)),
        "at least one recipient (to, cc or bcc) is needed", "")))

def with_atts.if(problem: String, w: Want, from: String) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        st : Stamp <- stamp()
        deliver(w, from, st)

def with_atts.want(+w: Want, +from: String) -> IO(Out):
  with_atts.if(check_want(w, from), w, from)

def with_atts(
  a: Attachments(),
  to: List<&2, String>,
  cc: List<&2, String>,
  bcc: List<&2, String>,
  subject: String,
  text: String,
  irt: String,
  refs: String,
  draft: Bool
) -> IO(Out):
  match a:
    case Fail{m}:
      pure_out(Err{m})
    case Done{xs}:
      do IO<Out>:
        from : String <- env_or("MAILBEND_EMAIL", "")
        with_atts.want(Want{to, cc, bcc, subject, text, irt, refs, xs, draft}, from)

# Composes from the common arguments: to, cc, bcc, subject, body,
# in_reply_to, references and attachments ([{path, filename?, content_type?}]).
def t_compose(+args: J.Json, draft: Bool) -> IO(Out):
  do IO<Out>:
    rs : List<&2, Attachment()> <- atts_read(attachments_arg(args))
    with_atts(atts_collect(rs), strs_arg(args, "to"), strs_arg(args, "cc"),
      strs_arg(args, "bcc"), str_arg(args, "subject", ""), str_arg(args, "body", ""),
      str_arg(args, "in_reply_to", ""), str_arg(args, "references", ""), draft)

# Reply and forward
# -----------------

def prefixed(+p: String, +subject: String) -> String:
  Bool.pick(String, String.starts_with(String.to_lower(String.trim(subject)), String.to_lower(p)),
    subject, p ++ " " ++ subject)

def quote_lines(ls: List<&2, String>) -> String:
  match ls:
    case Nil{}:
      ""
    case l <> t:
      "> " ++ l ++ "\n" ++ quote_lines(t)

# An address as a comparison key: its addr-spec, lower-cased.
def spec_key(a: String) -> String:
  String.to_lower(M.addr_spec(a))

def spec_keys(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case x <> t:
      spec_key(x) <> spec_keys(t)

def key_in(k: String, ks: List<&2, String>) -> Bool:
  List.contains(~String, ~String.eq, ks, k)

# The addresses whose addr-spec is not in `seen` and not repeated, in order.
def fresh(xs: List<&2, String>, +seen: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case +x <> t:
      +k = spec_key(x)
      +repeated = key_in(k, seen)
      List.filter.put(String, x,
        fresh(t, Bool.pick(List<&2, String>, repeated, seen, k <> seen)), Bool.not(repeated))

def decoded(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case x <> t:
      M.decode_header(x) <> decoded(t)

# The addresses of a header, split before RFC 2047 decoding (a decoded name
# may contain commas).
def hdr_addrs(hs: List<&2, M.Hdr>, name: String) -> List<&2, String>:
  decoded(M.addr_list(M.header(hs, name)))

def reply_to(+hs: List<&2, M.Hdr>) -> List<&2, String>:
  hdr_addrs(hs, Bool.pick(String, String.is_empty(M.header(hs, "reply-to")), "from", "reply-to"))

# Replies read only the first 256 KB of the original; when it is larger the
# quote says so instead of silently quoting a truncated copy.
def cut_note(cut: Bool) -> String:
  Bool.pick(String, cut,
    "> [the original is larger than 256 KB and only its start was read, so this quote may " ++
      "be incomplete]\n",
    "")

# A reply also says whether its quote covers the whole original: how many
# bytes of the original were read and quoted, and how large it is.
def quote_fields(cut: Bool, quoted: U32, size: U32) -> List<&2, J.Json>:
  [
    J.kv("quoted_original_truncated", J.bool(cut)),
    J.kv("quoted_bytes", J.num(quoted)),
    J.kv("original_bytes", J.num(size))
  ]

# With reply_all, the original's To and Cc, less me, the replied-to
# addresses and repeats.
def reply_cc(all: Bool, +hs: List<&2, M.Hdr>, me: String, replied: List<&2, String>) ->
  List<&2, String>:
  match all:
    case True{}:
      fresh(List.append(&2, String, hdr_addrs(hs, "to"), hdr_addrs(hs, "cc")),
        spec_key(me) <> spec_keys(replied))
    case False{}:
      []

# The reply's text above the quoted original.
def reply_body(args: J.Json, +hs: List<&2, M.Hdr>, p: M.Parts, cut: Bool) -> String:
  str_arg(args, "body", "") ++ "\n\nOn " ++ hdr_text(hs, "date") ++ ", " ++
    hdr_text(hs, "from") ++ " wrote:\n" ++ quote_lines(String.lines(M.readable_text(p))) ++
    cut_note(cut)

def reply_want(
  +hs: List<&2, M.Hdr>,
  p: M.Parts,
  +cut: Bool,
  quoted: U32,
  size: U32,
  +args: J.Json,
  me: String
) -> IO(Out):
  +replied = reply_to(hs)
  do IO<Out>:
    rs : List<&2, Attachment()> <- atts_read(attachments_arg(args))
    o : Out <- with_atts(atts_collect(rs),
      fresh(replied, []),
      reply_cc(bool_arg(args, "reply_all", False{}), hs, me, replied),
      strs_arg(args, "bcc"),
      prefixed("Re:", hdr_text(hs, "subject")),
      reply_body(args, hs, p, cut),
      M.header(hs, "message-id"),
      String.trim(M.header(hs, "references") ++ " " ++ M.header(hs, "message-id")),
      bool_arg(args, "as_draft", False{}))
    return with_fields(o, quote_fields(cut, quoted, size))

def fwd_note(+hs: List<&2, M.Hdr>) -> String:
  "\n\n---------- Forwarded message ----------\nFrom: " ++ hdr_text(hs, "from") ++
    "\nDate: " ++ hdr_text(hs, "date") ++ "\nSubject: " ++ hdr_text(hs, "subject") ++
    "\nTo: " ++ hdr_text(hs, "to") ++ "\n"

def fwd_want(+hs: List<&2, M.Hdr>, +raw: String, +args: J.Json) -> IO(Out):
  do IO<Out>:
    rs : List<&2, Attachment()> <-
      atts_read_within(attachments_arg(args), (max_attachment() - C.byte_len(raw) : U32))
    with_atts(atts_cons(M.Attach{"forwarded-message.eml", "message/rfc822", raw}, atts_collect(rs)),
      strs_arg(args, "to"), strs_arg(args, "cc"), strs_arg(args, "bcc"),
      prefixed("Fwd:", hdr_text(hs, "subject")),
      str_arg(args, "body", "") ++ fwd_note(hs),
      "", "", bool_arg(args, "as_draft", False{}))

def respond_to(
  reply: Bool,
  too_big: Bool,
  size: U32,
  +body: String,
  args: J.Json,
  me: String
) -> IO(Out):
  match reply:
    case True{}:
      reply_want(body_headers(body), M.parts(body), too_big, C.byte_len(body), size, args, me)
    case False{}:
      match too_big:
        case True{}:
          pure_out(Err{"the original is larger than 25 MB and cannot be forwarded whole"})
        case False{}:
          fwd_want(body_headers(body), body, args)

# Fetches the original (read-only, PEEK), then replies (mode 0) or
# forwards (mode 1).
def orig_msg(ms: List<&2, I.Msg>, +args: J.Json, mode: U32, max: U32, me: String) -> IO(Out):
  match ms:
    case Nil{}:
      pure_out(Err{
        "no message with UID " ++ U32.show(u32_arg(args, "uid", 0)) ++ " in " ++
          folder_arg(args)})
    case I.Msg{uid, flags, date, +size, headers, body} <> t:
      respond_to(U32.is_eq(mode, 0), U32.is_gt(size, max), size, body, args, me)

def orig_found.if(
  stale: Bool,
  lines: List<&2, I.RLine>,
  +args: J.Json,
  mode: U32,
  max: U32,
  me: String
) -> IO(Out):
  match stale:
    case True{}:
      pure_out(Err{stale_msg()})
    case False{}:
      orig_msg(with_uid(I.fetched(lines), u32_arg(args, "uid", 0)), args, mode, max, me)

# The original is used only if its folder still has the caller's
# UIDVALIDITY (checked in the same session that fetched it).
def orig_found(r: Run(), +args: J.Json, mode: U32, max: U32, me: String) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      orig_found.if(Bool.not(uidv_is(I.ok_code(lines, "UIDVALIDITY"), uidv_arg(args))), lines,
        args, mode, max, me)

def respond_request(+args: J.Json) -> String:
  Bool.pick(String, U32.is_zero(u32_arg(args, "uid", 0)),
    "\"uid\" (the message to answer) is required",
    Bool.pick(String, U32.is_zero(uidv_arg(args)), uidv_missing(), ""))

def t_respond.if(problem: String, +args: J.Json, mode: U32, +max: U32) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        me : String <- env_or("MAILBEND_EMAIL", "")
        r : Run() <- imap_run(Ops.plan_get(folder_arg(args), u32_arg(args, "uid", 0), max))
        orig_found(r, args, mode, max, me)

def t_respond(+args: J.Json, +mode: U32) -> IO(Out):
  t_respond.if(respond_request(args), args, mode,
    Bool.pick(U32, U32.is_eq(mode, 0), 262144, max_attachment()))

# Dispatch
# ========

# Running a tool
# --------------

def run_op(op: Ops.Op, args: J.Json) -> IO(Out):
  match op:
    case Ops.OProbe{}:
      t_probe(args)
    case Ops.OListFolders{}:
      t_folders(args)
    case Ops.OSearch{}:
      t_search(args)
    case Ops.OGet{}:
      t_get(args)
    case Ops.OGetNew{}:
      t_get_new(args)
    case Ops.OMarkRead{}:
      t_mark(args, MarkSeen{True{}})
    case Ops.OMarkUnread{}:
      t_mark(args, MarkSeen{False{}})
    case Ops.OFlag{}:
      t_flag(args)
    case Ops.OUnflag{}:
      t_mark(args, MarkUnflag{})
    case Ops.OMove{}:
      t_move(args)
    case Ops.OLabel{}:
      t_label(args)
    case Ops.OTrash{}:
      t_trash(args)
    case Ops.ODelete{}:
      t_delete(args)
    case Ops.OCreateFolder{}:
      t_create_folder(args)
    case Ops.ORenameFolder{}:
      t_rename_folder(args)
    case Ops.OSaveDraft{}:
      t_compose(args, True{})
    case Ops.OSend{}:
      t_compose(args, False{})
    case Ops.OReply{}:
      t_respond(args, 0)
    case Ops.OForward{}:
      t_respond(args, 1)

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

def refusal(+op: Ops.Op, args: J.Json, ro: Bool, drafts: Bool) -> String:
  Bool.pick(String, ro && Bool.not(Ops.is_read_only(op)),
    Ops.name(op) ++ " is disabled: MAILBEND_READ_ONLY is set",
    Bool.pick(String, drafts && sends(op, args),
      Ops.name(op) ++ " would send mail, which MAILBEND_DRAFTS_ONLY forbids: use " ++
        "mail_save_draft, or as_draft for a reply or forward",
      ""))

def gated.if(problem: String, op: Ops.Op, args: J.Json) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      run_op(op, args)

def gated(+op: Ops.Op, +args: J.Json, m: Mode) -> IO(Out):
  match m:
    case Mode{ro, drafts}:
      gated.if(refusal(op, args, ro, drafts), op, args)
    case ModeBad{msg}:
      pure_out(Err{"configuration error: " ++ msg})

def call_op(m: Maybe<&2, Ops.Op>, name: String, args: J.Json) -> IO(Out):
  match m:
    case None{}:
      pure_out(Err{"unknown tool: " ++ name})
    case Some{op}:
      do IO<Out>:
        md : Mode <- mode()
        gated(op, args, md)

# The tools offered
# -----------------

# Read-only mode lists only the read-only tools (also when a switch is
# misconfigured, since every call then fails); drafts-only mode hides
# mail_send. Hidden tools are refused anyway if called.

def offered(+n: String, ro: Bool, drafts: Bool) -> Bool:
  Bool.not(ro && Bool.not(key_in(n, Ops.read_only_names(Ops.all_ops())))) &&
    Bool.not(drafts && String.eq(n, "mail_send"))

def offered_items.if(keep: Bool, t: J.Json, rest: J.Json) -> J.Json:
  match keep:
    case True{}:
      J.JCons{t, rest}
    case False{}:
      rest

def offered_items(ts: J.Json, +ro: Bool, +drafts: Bool) -> J.Json:
  match ts:
    case J.JCons{+t, rest}:
      offered_items.if(offered(str_arg(t, "name", ""), ro, drafts), t,
        offered_items(rest, ro, drafts))
    case _:
      J.JEnd{}

def offered_in(ts: J.Json, ro: Bool, drafts: Bool) -> J.Json:
  match ts:
    case J.JArr{xs}:
      J.JArr{offered_items(xs, ro, drafts)}
    case _:
      ts

def offered_for(ts: J.Json, m: Mode) -> J.Json:
  match m:
    case Mode{ro, drafts}:
      offered_in(ts, ro, drafts)
    case ModeBad{msg}:
      offered_in(ts, True{}, False{})

# The tool definitions `ts` (a JSON array) that this configuration offers.
def offered_tools(ts: J.Json) -> IO(J.Json):
  do IO<J.Json>:
    md : Mode <- mode()
    return offered_for(ts, md)

# Arguments checked against the tool's input schema
# -------------------------------------------------

# A value of the wrong type, or a misspelt name, is refused rather than read as
# absent: "as_draft": "true" must not fall back to false and send the mail.

def tool_named(ts: J.Json, +name: String) -> Maybe<&2, J.Json>:
  match ts:
    case J.JCons{+t, rest}:
      Bool.pick(Maybe<&2, J.Json>, String.eq(str_arg(t, "name", ""), name), Some{t},
        tool_named(rest, name))
    case _:
      None{}

# The items of a JSON array; none for anything else.
def array_items(m: Maybe<&2, J.Json>) -> J.Json:
  match m:
    case Some{J.JArr{xs}}:
      xs
    case _:
      J.JEnd{}

def input_of(m: Maybe<&2, J.Json>) -> Maybe<&2, J.Json>:
  match m:
    case Some{t}:
      J.get(t, "inputSchema")
    case None{}:
      None{}

# The tool's inputSchema (properties and required list); None for no tool.
def tool_input(name: String) -> Maybe<&2, J.Json>:
  input_of(tool_named(array_items(J.parse(Schema.tool_defs())), name))

def int_raw(s: String) -> Bool:
  match s:
    case SCon{'-', t}:
      C.all_digits(t)
    case _:
      C.all_digits(s)

def prim_ok(want: String, v: J.Json) -> Bool:
  match v:
    case J.JStr{x}:
      String.eq(want, "string")
    case J.JNum{raw}:
      String.eq(want, "integer") && int_raw(raw)
    case J.JBool{b}:
      String.eq(want, "boolean")
    case J.JObj{i}:
      String.eq(want, "object")
    case J.JArr{i}:
      String.eq(want, "array")
    case _:
      False{}

def items_all(+want: String, xs: J.Json) -> Bool:
  match xs:
    case J.JCons{v, t}:
      prim_ok(want, v) && items_all(want, t)
    case _:
      True{}

# Address lists also take one address as a plain string.
def value_ok(+want: String, item: String, v: J.Json) -> Bool:
  match v:
    case J.JArr{xs}:
      String.eq(want, "array") && items_all(item, xs)
    case J.JStr{x}:
      String.eq(want, "string") || (String.eq(want, "array") && String.eq(item, "string"))
    case _:
      prim_ok(want, v)

def type_words(+want: String, +item: String) -> String:
  Bool.pick(String, String.eq(want, "boolean"), "true or false",
    Bool.pick(String, String.eq(want, "integer"), "an integer",
      Bool.pick(String, String.eq(want, "string"), "a string",
        Bool.pick(String, String.eq(want, "object"), "an object",
          Bool.pick(String, String.eq(item, "string"), "a string or an array of strings",
            "an array of " ++ item ++ "s")))))

def want_of(s: J.Json) -> String:
  str_arg(s, "type", "")

def item_of(s: J.Json) -> String:
  str_arg(Maybe.default(&2, J.Json, J.get(s, "items"), J.JNull{}), "type", "")

def prop_problem(p: Maybe<&2, J.Json>, k: String, v: J.Json, tool: String) -> String:
  match p:
    case None{}:
      "unknown argument \"" ++ k ++ "\" for " ++ tool
    case Some{+s}:
      +want = want_of(s)
      +item = item_of(s)
      Bool.pick(String, value_ok(want, item, v), "",
        "\"" ++ k ++ "\" must be " ++ type_words(want, item))

def args_problem(+props: J.Json, kvs: J.Json, +tool: String) -> String:
  match kvs:
    case J.JCons{J.JKv{+k, v}, t}:
      first_of(prop_problem(J.get(props, k), k, v, tool), args_problem(props, t, tool))
    case _:
      ""

def elems_problem(+props: J.Json, xs: J.Json, +tool: String) -> String:
  match xs:
    case J.JCons{J.JObj{kvs}, t}:
      first_of(args_problem(props, kvs, tool ++ " attachments"), elems_problem(props, t, tool))
    case J.JCons{v, t}:
      elems_problem(props, t, tool)
    case _:
      ""

def object_field(object: J.Json, key: String) -> J.Json:
  Maybe.default(&2, J.Json, J.get(object, key), J.JNull{})

def item_props(props: J.Json) -> J.Json:
  object_field(object_field(object_field(props, "attachments"), "items"), "properties")

def att_check(m: Maybe<&2, J.Json>, props: J.Json, tool: String) -> String:
  match m:
    case Some{J.JArr{xs}}:
      elems_problem(item_props(props), xs, tool)
    case _:
      ""

def required_msg(+k: String) -> String:
  Bool.pick(String, String.eq(k, "uidvalidity"), uidv_missing(),
    Bool.pick(String, String.eq(k, "confirm"),
      "\"confirm\" is required: it must be exactly \"permanently-delete\"",
      "\"" ++ k ++ "\" is required"))

# The first required argument that is missing; an omitted field must not
# be read as its default (a reply with no body would still send).
def missing_problem(req: J.Json, +kvs: J.Json) -> String:
  match req:
    case J.JCons{J.JStr{+k}, t}:
      first_of(Bool.pick(String, Maybe.is_some(&2, J.Json, J.find(kvs, k)), "", required_msg(k)),
        missing_problem(t, kvs))
    case J.JCons{v, t}:
      missing_problem(t, kvs)
    case _:
      ""

def args_obj_problem(args: J.Json, +input: J.Json, +tool: String) -> String:
  match args:
    case J.JObj{+kvs}:
      +props = object_field(input, "properties")
      first_of(args_problem(props, kvs, tool),
        first_of(missing_problem(array_items(J.get(input, "required")), kvs),
          att_check(J.find(kvs, "attachments"), props, tool)))
    case _:
      "the arguments must be a JSON object"

def schema_problem(input: Maybe<&2, J.Json>, args: J.Json, tool: String) -> String:
  match input:
    case None{}:
      ""
    case Some{i}:
      args_obj_problem(args, i, tool)

def call.if(problem: String, +name: String, args: J.Json) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      call_op(Ops.from_name(name), name, args)

# Runs the named tool with its JSON arguments, once they match its schema.
def call(+name: String, +args: J.Json) -> IO(Out):
  call.if(schema_problem(tool_input(name), args, name), name, args)
