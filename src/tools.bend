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
import ./thread.bend as T
import ./jev.bend as Jev
import ./secrets.bend as Secrets

# Results
# =======

# A tool's result: its JSON, or an error for the caller.
type Out is Data:
  Ok{j: J.Json}
  Err{msg: String}
  # An error for the caller that still carries a result: a change that
  # stopped part-way, or a refusal that reports what the call found.
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

# Puts fields before those of a result object, also of a partial one (where
# with_fields adds them after, to a successful one only).
def with_fields_first(o: Out, first: List<&2, J.Json>) -> Out:
  match o:
    case Ok{J.JObj{items}}:
      Ok{J.JObj{J.chain(List.append(&2, J.Json, first, J.unchain(items)))}}
    case Partial{J.JObj{items}}:
      Partial{J.JObj{J.chain(List.append(&2, J.Json, first, J.unchain(items)))}}
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

# The switches every tool depends on. A value that is not clearly on or off
# is refused rather than read as off: MAILBEND_READ_ONLY=yes must not leave
# writes on. ConfigBad fails every tool.
type Config is Data:
  Config{read_only: Bool, drafts_only: Bool, jev: Jev.Switch}
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

def flag(+name: String) -> IO(Flag):
  do IO<Flag>:
    v : String <- env_or(name, "")
    return flag_value(name, v)

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
def config_of(
  read_only: Flag,
  drafts_only: Flag,
  api_key_set: Bool,
  typesafe: Flag,
  content: String,
  zero_retention: Flag,
  key_file: String
) -> Result<&2, &2, String, Config>:
  do Result<&2, &2, String, Config>:
    ro : Bool <- flag_on(read_only)
    drafts : Bool <- flag_on(drafts_only)
    key_ok : Unit <- checked(api_key_problem(api_key_set))
    on : Bool <- flag_on(typesafe)
    wanted : Jev.Content <- content_of(content)
    zr : Bool <- flag_on(zero_retention)
    c : Jev.Content <- attested(wanted, zr)
    jev : Jev.Switch <- jev_switch(on, c, String.starts_with(key_file, "/"))
    return Config{ro, drafts, jev}

def config.put(r: Result<&2, &2, String, Config>) -> Config:
  match r:
    case Done{c}:
      c
    case Fail{m}:
      ConfigBad{m}

# Whether a variable is set at all, even to "".
def is_set(r: Result<&1, &1, U32 & String, String>) -> Bool:
  match r:
    case Done{v}:
      True{}
    case Fail{e}:
      False{}

# MAILBEND_READ_ONLY=1 refuses every tool that could change the mailbox or
# send mail, for trying MailBend safely against a real account.
# MAILBEND_DRAFTS_ONLY=1 still allows changes but refuses to send: mail_send,
# and replies or forwards without as_draft, so a person reviews every
# outgoing message in Drafts first. MAILBEND_TYPESAFE=1 turns on the tools
# that consult TypeSafe's Jev.
def config() -> IO(Config):
  do IO<Config>:
    r : Flag <- flag("MAILBEND_READ_ONLY")
    d : Flag <- flag("MAILBEND_DRAFTS_ONLY")
    key : Result<&1, &1, U32 & String, String> <- IO.get_env("MAILBEND_TYPESAFE_API_KEY")
    t : Flag <- flag("MAILBEND_TYPESAFE")
    c : String <- env_or("MAILBEND_TYPESAFE_CONTENT", "")
    z : Flag <- flag("MAILBEND_TYPESAFE_ZERO_RETENTION")
    k : String <- env_or("MAILBEND_TYPESAFE_KEY_FILE", "")
    return config.put(config_of(r, d, is_set(key), t, c, z, k))

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

# Every helper is started only from an absolute path, which
# scripts/mailbend sets, never from a path relative to the working
# directory.
def helper_refusal(variable: String, program: String) -> String:
  variable ++ " must be the absolute path of " ++ program ++ " (scripts/mailbend sets it)"

def helper_path(+path: String, variable: String, program: String) -> Result<&2, &2, String, String>:
  match path:
    case SCon{'/', t}:
      Done{path}
    case _:
      Fail{helper_refusal(variable, program)}

# A helper run may print up to 128 MiB and take up to five minutes.
def run_helper(path: String, mode: String, input: String) -> IO(Proc):
  do IO<Proc>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run(path, [mode], input, 134217728, 300000)
    return proc_of(r)

# The helper gets the password through the environment, which makes the
# absolute path all the more important.
def helper_at(+path: String, mode: String, input: String) -> IO(Proc):
  match path:
    case SCon{'/', t}:
      run_helper(path, mode, input)
    case _:
      IO.pure(Proc, ProcRefused{helper_refusal("MAILBEND_TLS_HELPER", "mailbend-tls")})

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

# Dry runs
# --------

# The change a tool is about to make, as a dry run shows it: run an IMAP
# plan, send `msg` from `from` to `rcpts` (the values the envelope is built
# from) and save a Sent copy when `sent_copy` is set, or save `data` as the
# file `path`.
type Preview is Data:
  ImapPreview{plan: List<&2, I.Cmd>}
  ImapPlans{plans: List<&2, List<&2, I.Cmd>>}
  SmtpPreview{from: String, rcpts: List<&2, String>, msg: String, sent_copy: Bool}
  FilePreview{path: String, data: String}

def preview.result(kind: String, j: J.Json) -> Out:
  ok_obj([J.kv("dry_run", J.bool(True{})), J.kv(kind, j)])

# The preview of plans that each run in a session of their own, one after
# the other.
def plans_preview(ps: List<&2, List<&2, I.Cmd>>) -> List<&2, String>:
  match ps:
    case Nil{}:
      []
    case p <> t:
      List.append(&2, String, I.preview(p), plans_preview(t))

# What a dry run returns instead of making the change: the IMAP commands as
# the TLS helper would get them, the SMTP envelope or the file. A message or
# file shows only its size, and no line holds a credential: the helper logs
# in by itself. `sent_copy` states the intent under MAILBEND_SAVE_SENT; the
# real send still skips the copy when the server has filed one itself.
def preview(p: Preview) -> Out:
  match p:
    case ImapPreview{plan}:
      preview.result("imap", J.strs(I.preview(plan)))
    case ImapPlans{plans}:
      preview.result("imap", J.strs(plans_preview(plans)))
    case SmtpPreview{from, rcpts, msg, sent_copy}:
      preview.result("smtp", J.obj([
        J.kv("from", J.str(from)),
        J.kv("rcpt", J.strs(rcpts)),
        J.kv("data", J.str(C.size_note(C.byte_len(msg)))),
        J.kv("sent_copy", J.bool(sent_copy))
      ]))
    case FilePreview{path, data}:
      preview.result("file", J.obj([
        J.kv("path", J.str(path)),
        J.kv("data", J.str(C.size_note(C.byte_len(data))))
      ]))

# Every tool that changes or sends mail, or saves a file, makes its change
# here, once its read-only checks have passed: `run` makes it, and a dry
# run only shows it. `run` is an IO action, so a dry run never performs it.
def preview_or_run(dry: Bool, p: Preview, run: IO(Out)) -> IO(Out):
  match dry:
    case True{}:
      pure_out(preview(p))
    case False{}:
      run

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

# Whether a tool that changes or sends mail is only to show the change.
def dry_arg(args: J.Json) -> Bool:
  bool_arg(args, "dry_run", False{})

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

# Folder names
# ------------

def is_inbox(name: String) -> Bool:
  I.same_name(name, "INBOX")

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

# Whether `name` lies inside the folder `ancestor` (and is not that folder):
# "Mail/Sent" lies inside "Mail" when the delimiter is "/". A server with no
# delimiter has no nesting.
def inside(+delim: String, ancestor: String, name: String) -> Bool:
  Bool.not(String.is_empty(delim)) && String.starts_with(name, ancestor ++ delim)

def at_or_inside(delim: String, +ancestor: String, +name: String) -> Bool:
  String.eq(ancestor, name) || inside(delim, ancestor, name)

# The review folder
# -----------------

# Only mail_triage moves mail into the review folder (see
# Ops.review_folder), or into any folder inside it, and never out of it:
# the user reviews what is there. mail_move and mail_label may take a
# message out of it, when the user keeps it; mail_trash may not, and
# mail_delete removes messages from it only on its confirmation. Names are
# compared in lower case, as the reserved names are.

def in_review(delim: String, name: String) -> Bool:
  at_or_inside(delim, String.to_lower(Ops.review_folder()), String.to_lower(name))

# Why mail_move or mail_label cannot move mail into `dest` ("" when it can).
def review_move_problem(delim: String, dest: String) -> String:
  Bool.pick(String, in_review(delim, dest),
    "only mail_triage moves mail into \"" ++ Ops.review_folder() ++ "\", which the user reviews",
    "")

# Why mail_trash cannot move mail out of `folder` into `trash` ("" when it
# can).
def review_trash_problem(+delim: String, folder: String, trash: String) -> String:
  Bool.pick(String, in_review(delim, folder) || in_review(delim, trash),
    "mail_trash never moves mail into or out of \"" ++ Ops.review_folder() ++
      "\", which the user reviews; mail_move can take a message out of it, and mail_delete " ++
      "can remove messages from it permanently",
    "")

# Why mail_triage cannot file mail out of `folder` ("" when it can).
def source_review_problem(delim: String, folder: String) -> String:
  Bool.pick(String, in_review(delim, folder),
    "mail_triage files mail out of other folders, never out of \"" ++ Ops.review_folder() ++
      "\", which the user reviews",
    "")

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
# or names one existing selectable mailbox outside the review folder, which
# is never a role folder, nor holds one.
def invalid_override(+fs: List<&2, I.Folder>, +value: String, +variable: String) -> String:
  Bool.pick(String, in_review(delim_of(fs), value),
    variable ++ " cannot name the review folder \"" ++ Ops.review_folder() ++
      "\" or a folder inside it",
    Bool.pick(String,
      String.is_empty(value) || Maybe.is_some(&2, String, named_folder(fs, value)), "",
      variable ++ " must name one existing selectable mailbox"))

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

def summary_kvs(m: I.Msg) -> List<&2, J.Json>:
  I.Msg{uid, +flags, date, size, headers, body, _} = m
  +hs = M.headers(headers)
  [
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
  ]

def summary(m: I.Msg) -> J.Json:
  J.obj(summary_kvs(m))

def summaries(ms: List<&2, I.Msg>) -> List<&2, J.Json>:
  match ms:
    case Nil{}:
      []
    case m <> t:
      summary(m) <> summaries(t)

def msg_uid(m: I.Msg) -> U32:
  I.Msg{uid, flags, date, size, headers, body, _} = m
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

# The UIDs of `us` that are not in `seen`, each once, in order.
def unseen(us: List<&2, U32>, +seen: List<&2, U32>) -> List<&2, U32>:
  match us:
    case Nil{}:
      []
    case +u <> t:
      List.filter.put(U32, u, unseen(t, u <> seen), Bool.not(uid_in(u, seen)))

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

# What reads show
# ---------------

# What a read shows: its result, and the messages it shows, in order (none
# when it failed): those of its "messages" list, with the folders a thread
# read has resolved, or the one message mail_get read whole, up to `max`
# bytes. With Jev on, each message gets a jev object (see Read
# annotations).
type Shown is Data:
  Listed{out: Out, msgs: List<&2, I.Msg>}
  Threaded{out: Out, msgs: List<&2, I.Msg>, folders: Folders}
  Whole{out: Out, msg: I.Msg, max: U32}

def pure_shown(o: Out) -> IO(Shown):
  IO.pure(Shown, Listed{o, []})

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
) -> Shown:
  match same:
    case True{}:
      +ms = newest_first(requested(I.fetched(lines), uids))
      Listed{list_out(folder, uidv, total, summaries(ms)), ms}
    case False{}:
      Listed{Err{moved_msg()}, []}

# The fetch runs in a second session: its EXAMINE must report the same
# UIDVALIDITY as the search, or the UIDs may name other messages.
def search_headers(
  r: Run(),
  folder: String,
  +uidv: Maybe<&2, U32>,
  total: U32,
  uids: List<&2, U32>
) -> Shown:
  match r:
    case Fail{m}:
      Listed{Err{m}, []}
    case Done{+lines}:
      search_headers.if(same_uidv(uidv, I.ok_code(lines, "UIDVALIDITY")), lines, folder, uidv,
        total, uids)

def search_fetch(
  +uids: List<&2, U32>,
  +folder: String,
  uidv: Maybe<&2, U32>,
  total: U32
) -> IO(Shown):
  match uids:
    case Nil{}:
      pure_shown(list_out(folder, uidv, total, []))
    case h <> t:
      do IO<Shown>:
        r : Run() <- imap_run(Ops.plan_headers(folder, uids))
        return search_headers(r, folder, uidv, total, uids)

def search_found(r: Run(), folder: String, limit: U32) -> IO(Shown):
  match r:
    case Fail{m}:
      pure_shown(Err{m})
    case Done{+lines}:
      +uids = I.search_uids(lines)
      search_fetch(List.take(&2, U32, desc(uids), U32.to_nat(limit)), folder,
        I.ok_code(lines, "UIDVALIDITY"), U32.from_nat(List.length(&2, U32, uids)))

def search_keys(ks: Keys(), +folder: String, limit: U32) -> IO(Shown):
  match ks:
    case Fail{m}:
      pure_shown(Err{m})
    case Done{keys}:
      do IO<Shown>:
        r : Run() <- imap_run(Ops.plan_search(folder, keys))
        search_found(r, folder, limit)

def t_search(+args: J.Json) -> IO(Shown):
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
  I.Msg{uid, +flags, date, +size, headers, body, _} = m
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
  I.Msg{uid, flags, date, size, headers, body, _} = m
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

def no_message(uid: U32, folder: String) -> String:
  "no message with UID " ++ U32.show(uid) ++ " in " ++ folder

def get_msg(
  ms: List<&2, I.Msg>,
  folder: String,
  uid: U32,
  uidv: Maybe<&2, U32>,
  +max: U32
) -> Shown:
  match ms:
    case Nil{}:
      Listed{Err{no_message(uid, folder)}, []}
    case +m <> t:
      +body = msg_body(m)
      Whole{get_json(m, folder, uidv, max, body_headers(body), M.parts(body)), m, max}

def get_out(r: Run(), folder: String, +uid: U32, max: U32) -> Shown:
  match r:
    case Fail{m}:
      Listed{Err{m}, []}
    case Done{+lines}:
      get_msg(with_uid(I.fetched(lines), uid), folder, uid, I.ok_code(lines, "UIDVALIDITY"), max)

# The one UID a tool that reads a single message is given.
def single_uid(u: Uids(), tool: String) -> Result<&2, &2, String, U32>:
  match u:
    case Done{uid <> Nil{}}:
      Done{uid}
    case Done{xs}:
      Fail{tool ++ " reads one message: pass a single \"uid\""}
    case Fail{m}:
      Fail{m}

def get_uid(u: Result<&2, &2, String, U32>, +folder: String, +max: U32) -> IO(Shown):
  match u:
    case Done{+uid}:
      do IO<Shown>:
        r : Run() <- imap_run(Ops.plan_get(folder, uid, max))
        return get_out(r, folder, uid, max)
    case Fail{m}:
      pure_shown(Err{m})

def t_get(+args: J.Json) -> IO(Shown):
  get_uid(single_uid(uids_arg(args), "mail_get"), folder_arg(args),
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
) -> Shown:
  match same:
    case True{}:
      +ms = oldest_first(requested(I.fetched(lines), uids))
      Listed{new_out(folder, uidv, False{}, next, more, summaries(ms)), ms}
    case False{}:
      Listed{new_out(folder, Maybe.default(&2, U32, now, 0), True{}, 0, True{}, []), []}

# As for search: a UIDVALIDITY change between the two sessions resets the
# checkpoint instead of returning messages under stale UIDs.
def new_headers(
  r: Run(),
  folder: String,
  +uidv: U32,
  next: U32,
  more: Bool,
  uids: List<&2, U32>
) -> Shown:
  match r:
    case Fail{m}:
      Listed{Err{m}, []}
    case Done{+lines}:
      +now = I.ok_code(lines, "UIDVALIDITY")
      new_headers.if(uidv_is(now, uidv), lines, now, folder, uidv, next, more, uids)

def new_fetch(
  +uids: List<&2, U32>,
  +folder: String,
  uidv: U32,
  since: U32,
  more: Bool
) -> IO(Shown):
  match uids:
    case Nil{}:
      pure_shown(new_out(folder, uidv, False{}, since, False{}, []))
    case h <> t:
      do IO<Shown>:
        r : Run() <- imap_run(Ops.plan_headers(folder, uids))
        return new_headers(r, folder, uidv, last_or(uids, since), more, uids)

def new_reset(
  changed: Bool,
  uidv: U32,
  +uids: List<&2, U32>,
  folder: String,
  since: U32,
  +limit: U32
) -> IO(Shown):
  match changed:
    case True{}:
      pure_shown(new_out(folder, uidv, True{}, 0, True{}, []))
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
) -> IO(Shown):
  new_reset(Bool.not(U32.is_zero(known)) && Bool.not(U32.is_eq(known, uidv)), uidv, uids,
    folder, since, limit)

# When UIDVALIDITY changed, every stored UID is void: report it and restart
# the checkpoint at 0 instead of guessing which messages are new.
def new_found(r: Run(), folder: String, +since: U32, known: U32, limit: U32) -> IO(Shown):
  match r:
    case Fail{m}:
      pure_shown(Err{m})
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

def t_get_new.if(problem: String, +args: J.Json) -> IO(Shown):
  match problem:
    case SCon{h, t}:
      pure_shown(Err{SCon{h, t}})
    case SNil{}:
      +folder = folder_arg(args)
      +since = u32_arg(args, "since_uid", 0)
      do IO<Shown>:
        r : Run() <- imap_run(Ops.plan_new(folder, since))
        new_found(r, folder, since, uidv_arg(args), clamp(u32_arg(args, "limit", 50), 1, 500))

def t_get_new(+args: J.Json) -> IO(Shown):
  t_get_new.if(new_request(u32_arg(args, "since_uid", 0), uidv_arg(args)), args)

# mail_get_thread
# ---------------

# A conversation is read without changing anything: the message's summary,
# the folders (to resolve Sent), then two rounds. A round searches the
# message's folder, INBOX and the Sent folder, in one session, for the IDs
# the thread names so far (thread.bend). A second session fetches the summaries
# of the UIDs not seen yet, and only the messages whose headers name one of
# those IDs exactly are kept, since SEARCH HEADER matches substrings. There
# is no third round, so a long thread can be cut short.

# What a session found in each folder it opened, in plan order: the
# UIDVALIDITY its EXAMINE reported, the UIDs its searches found and the
# messages its fetches returned.
type Found is Data:
  Found{folder: String, uidv: Maybe<&2, U32>, uids: List<&2, U32>, msgs: List<&2, I.Msg>}

# Where a thread read stands: the IDs to search for next, those searched
# for already, the messages kept, and what each session found in each
# folder (for the UIDVALIDITY it reported).
type Threading is Data:
  Threading{
    ids: List<&2, String>,
    searched: List<&2, String>,
    nodes: List<&2, T.Node>,
    opened: List<&2, Found>
  }

# A thread read so far, or why it failed.
def Thread() -> Data:
  Result<&2, &2, String, Threading>

# Command `c`'s replies `rs` added to what its folder found: an EXAMINE
# opens the next folder, and a fetch keeps only the UIDs it asked for.
def thread_found.step(
  c: I.Cmd, rs: List<&2, I.RLine>, acc: List<&2, Found>
) -> List<&2, Found>:
  match c acc:
    case I.CExamine{mbox} _:
      Found{mbox, I.ok_code(rs, "UIDVALIDITY"), [], []} <> acc
    case I.CSearch{_} Found{f, v, us, ms} <> t:
      Found{f, v, List.append(&2, U32, us, I.search_uids(rs)), ms} <> t
    case I.CFetch{uids, _} Found{f, v, us, ms} <> t:
      Found{f, v, us, List.append(&2, I.Msg, ms, requested(I.fetched(rs), uids))} <> t
    case _ _:
      acc

def thread_found.go(
  cs: List<&2, I.Cmd>, +lines: List<&2, I.RLine>, +n: U32, acc: List<&2, Found>
) -> List<&2, Found>:
  match cs:
    case Nil{}:
      List.reverse(&2, Found, acc)
    case +c <> t:
      thread_found.go(t, lines, I.next_tag(c, n),
        thread_found.step(c, I.replies(lines, n), acc))

# What the session that ran `plan` found, folder by folder.
def thread_found(plan: List<&2, I.Cmd>, lines: List<&2, I.RLine>) -> List<&2, Found>:
  thread_found.go(plan, lines, 1, [])

# Whether `before` has the folder `mbox` with another UIDVALIDITY.
def uidv_moved(before: List<&2, Found>, +mbox: String, +uidv: Maybe<&2, U32>) -> Bool:
  match before:
    case Nil{}:
      False{}
    case Found{f, v, us, ms} <> t:
      (String.eq(f, mbox) && Bool.not(same_uidv(v, uidv))) || uidv_moved(t, mbox, uidv)

# Whether a folder of `fs` reports another UIDVALIDITY than before, so
# that its UIDs may now name other messages.
def any_uidv_moved(fs: List<&2, Found>, +before: List<&2, Found>) -> Bool:
  match fs:
    case Nil{}:
      False{}
    case Found{f, v, us, ms} <> t:
      uidv_moved(before, f, v) || any_uidv_moved(t, before)

def thread_moved_msg() -> String:
  "a folder's UIDVALIDITY changed while the thread was read, so its UIDs may name " ++
    "other messages: read the thread again"

def session_found.if(moved: Bool, fs: List<&2, Found>) -> Result<&2, &2, String, List<&2, Found>>:
  match moved:
    case True{}:
      Fail{thread_moved_msg()}
    case False{}:
      Done{fs}

# What a session found, unless it failed or a folder reported another
# UIDVALIDITY than in an earlier session (`before`).
def session_found(
  r: Run(), plan: List<&2, I.Cmd>, before: List<&2, Found>
) -> Result<&2, &2, String, List<&2, Found>>:
  match r:
    case Fail{m}:
      Fail{m}
    case Done{lines}:
      +fs = thread_found(plan, lines)
      session_found.if(any_uidv_moved(fs, before), fs)

# The UIDs of the kept messages in `mbox`.
def kept_uids(ns: List<&2, T.Node>, +mbox: String) -> List<&2, U32>:
  match ns:
    case Nil{}:
      []
    case +n <> t:
      List.filter.put(U32, T.node_uid(n), kept_uids(t, mbox), String.eq(T.node_folder(n), mbox))

def thread_wants.put(
  mbox: String, uids: List<&2, U32>, rest: List<&2, Ops.FolderUids>
) -> List<&2, Ops.FolderUids>:
  match uids:
    case Nil{}:
      rest
    case h <> t:
      Ops.FolderUids{mbox, h <> t} <> rest

# The UIDs each folder's searches found that no kept message has, each
# once; a folder with none is left out.
def thread_wants(fs: List<&2, Found>, +ns: List<&2, T.Node>) -> List<&2, Ops.FolderUids>:
  match fs:
    case Nil{}:
      []
    case Found{+f, v, us, ms} <> t:
      thread_wants.put(f, unseen(us, kept_uids(ns, f)), thread_wants(t, ns))

def msg_nodes(+mbox: String, +uidv: Maybe<&2, U32>, ms: List<&2, I.Msg>) -> List<&2, T.Node>:
  match ms:
    case Nil{}:
      []
    case m <> t:
      T.node(mbox, uidv, m) <> msg_nodes(mbox, uidv, t)

def found_nodes(fs: List<&2, Found>) -> List<&2, T.Node>:
  match fs:
    case Nil{}:
      []
    case Found{f, v, us, ms} <> t:
      List.append(&2, T.Node, msg_nodes(f, v, ms), found_nodes(t))

# A round's end, once its fetch found `fs`: the messages that name one of
# the round's IDs are kept, and the IDs they name are searched for next.
def thread_grown(st: Threading, +fs: List<&2, Found>) -> Threading:
  Threading{+ids, searched, nodes, opened} = st
  +kept = T.linked(found_nodes(fs), ids)
  +done = List.append(&2, String, searched, ids)
  Threading{
    T.next_ids(kept, done),
    done,
    List.append(&2, T.Node, nodes, kept),
    List.append(&2, Found, opened, fs)
  }

def thread_fetch.put(found: Result<&2, &2, String, List<&2, Found>>, st: Threading) -> Thread():
  match found:
    case Fail{m}:
      Fail{m}
    case Done{fs}:
      Done{thread_grown(st, fs)}

# Fetches the summaries of the UIDs a round wants and keeps the linked
# messages. When it wants none, the round ends there.
def thread_fetch(wants: List<&2, Ops.FolderUids>, st: Threading) -> IO(Thread()):
  match wants st:
    case Nil{} _:
      IO.pure(Thread(), Done{thread_grown(st, [])})
    case h <> t Threading{ids, searched, nodes, +opened}:
      +plan = Ops.plan_thread_headers(h <> t)
      do IO<Thread()>:
        r : Run() <- imap_run(plan)
        return thread_fetch.put(session_found(r, plan, opened),
          Threading{ids, searched, nodes, opened})

def thread_round.put(found: Result<&2, &2, String, List<&2, Found>>, st: Threading) -> IO(Thread()):
  match found:
    case Fail{m}:
      IO.pure(Thread(), Fail{m})
    case Done{+fs}:
      Threading{ids, searched, +nodes, opened} = st
      thread_fetch(thread_wants(fs, nodes),
        Threading{ids, searched, nodes, List.append(&2, Found, opened, fs)})

# One round: every folder searched for the IDs, then what is new fetched. A
# read with no IDs left to search for does nothing.
def thread_round(g: Thread(), folders: List<&2, String>) -> IO(Thread()):
  match g:
    case Fail{m}:
      IO.pure(Thread(), Fail{m})
    case Done{Threading{Nil{}, searched, nodes, opened}}:
      IO.pure(Thread(), Done{Threading{[], searched, nodes, opened}})
    case Done{Threading{+ids, searched, nodes, +opened}}:
      +plan = Ops.plan_thread_search(folders, T.search_keys(ids))
      do IO<Thread()>:
        r : Run() <- imap_run(plan)
        thread_round.put(session_found(r, plan, opened), Threading{ids, searched, nodes, opened})

# A message's parent as JSON: its Message-ID, or null for none.
def parent_json(id: String) -> J.Json:
  match id:
    case SNil{}:
      J.JNull{}
    case SCon{h, t}:
      J.str(SCon{h, t})

def placed_json(p: T.Placed) -> J.Json:
  T.Placed{n, parent} = p
  T.Node{folder, uidv, msg, time, id, replies_to, refs} = n
  J.obj(List.concat(&2, J.Json, [
    [J.kv("folder", J.str(folder)), J.kv("uidvalidity", maybe_num(uidv))],
    summary_kvs(msg),
    [J.kv("parent", parent_json(parent))]
  ]))

def placed_jsons(ps: List<&2, T.Placed>) -> List<&2, J.Json>:
  match ps:
    case Nil{}:
      []
    case p <> t:
      placed_json(p) <> placed_jsons(t)

def placed_msgs(ps: List<&2, T.Placed>) -> List<&2, I.Msg>:
  match ps:
    case Nil{}:
      []
    case T.Placed{T.Node{folder, uidv, msg, time, id, replies_to, refs}, parent} <> t:
      msg <> placed_msgs(t)

# A thread read's result; `fs` are the folders it resolved, and `folders`
# those it searched.
def thread_out(
  g: Thread(),
  fs: Folders,
  folders: List<&2, String>,
  mbox: String,
  uid: U32
) -> Shown:
  match g:
    case Fail{m}:
      Listed{Err{m}, []}
    case Done{Threading{ids, searched, nodes, opened}}:
      +placed = T.thread_order(nodes)
      Threaded{ok_obj([
        J.kv("folder", J.str(mbox)),
        J.kv("uid", J.num(uid)),
        J.kv("searched", J.strs(folders)),
        J.kv("messages", J.arr(placed_jsons(placed)))
      ]), placed_msgs(placed), fs}

# Whether the folder names `fs` include `f`.
def lists_folder(fs: List<&2, String>, +f: String) -> Bool:
  match fs:
    case Nil{}:
      False{}
    case x <> t:
      I.same_name(x, f) || lists_folder(t, f)

# `fs`, then the folder `f` unless `fs` lists it.
def folder_added(+fs: List<&2, String>, +f: String) -> List<&2, String>:
  List.append(&2, String, fs, List.filter.put(String, f, [], Bool.not(lists_folder(fs, f))))

def thread_folders.put(fs: List<&2, String>, sent: Maybe<&2, String>) -> List<&2, String>:
  match sent:
    case None{}:
      fs
    case Some{s}:
      folder_added(fs, s)

# The folders a thread is searched in, each once: the message's own, INBOX,
# where answers arrive, and the Sent folder when it resolves.
def thread_folders(mbox: String, sent: Maybe<&2, String>) -> List<&2, String>:
  thread_folders.put(folder_added([mbox], "INBOX"), sent)

def thread_rounds(f: Fs(), st: Threading, +mbox: String, uid: U32) -> IO(Shown):
  match f:
    case Fail{m}:
      pure_shown(Err{m})
    case Done{+fs}:
      Folders{all, drafts, trash, sent, junk, archive} = fs
      +folders = thread_folders(mbox, sent)
      do IO<Shown>:
        one : Thread() <- thread_round(Done{st}, folders)
        two : Thread() <- thread_round(one, folders)
        return thread_out(two, fs, folders, mbox, uid)

def thread_probe(r: Run(), st: Threading, mbox: String, uid: U32) -> IO(Shown):
  match r:
    case Fail{m}:
      pure_shown(Err{m})
    case Done{lines}:
      do IO<Shown>:
        f : Fs() <- folders_io(lines)
        thread_rounds(f, st, mbox, uid)

# A read that starts at the message `start`, which its session found in
# `mbox`: the IDs it names are searched for first.
def first_threading(+start: T.Node, mbox: String, uidv: Maybe<&2, U32>) -> Threading:
  Threading{T.next_ids([start], []), [], [start], [Found{mbox, uidv, [], []}]}

def thread_start.put(
  ms: List<&2, I.Msg>, +uidv: Maybe<&2, U32>, +mbox: String, uid: U32
) -> IO(Shown):
  match ms:
    case Nil{}:
      pure_shown(Err{no_message(uid, mbox)})
    case m <> t:
      do IO<Shown>:
        r : Run() <- imap_run(Ops.plan_probe())
        thread_probe(r, first_threading(T.node(mbox, uidv, m), mbox, uidv), mbox, uid)

def thread_start(r: Run(), mbox: String, +uid: U32) -> IO(Shown):
  match r:
    case Fail{m}:
      pure_shown(Err{m})
    case Done{+lines}:
      thread_start.put(with_uid(I.fetched(lines), uid), I.ok_code(lines, "UIDVALIDITY"), mbox,
        uid)

def thread_uid(u: Result<&2, &2, String, U32>, +mbox: String) -> IO(Shown):
  match u:
    case Done{+uid}:
      do IO<Shown>:
        r : Run() <- imap_run(Ops.plan_headers(mbox, [uid]))
        thread_start(r, mbox, uid)
    case Fail{m}:
      pure_shown(Err{m})

def t_get_thread(+args: J.Json) -> IO(Shown):
  thread_uid(single_uid(uids_arg(args), "mail_get_thread"), folder_arg(args))

# Asking Jev
# ==========

# With MAILBEND_TYPESAFE on, tools ask TypeSafe's Jev through these:
# mail_classify and mail_triage, the gates before a send or a permanent
# delete, and the annotations of reads.

# One request
# -----------

def jev_off(name: String) -> String:
  name ++ " is disabled: it consults TypeSafe's Jev, and MAILBEND_TYPESAFE is off"

# How one TypeSafe request ended: its answer; TypeSafe refused it (the
# helper exits with 8), which a smaller request may cure; or any other
# failure.
type Asked is Data:
  AskAnswered{body: String}
  AskRefused{msg: String}
  AskFailed{msg: String}

def refusal_detail.put(m: Maybe<&2, J.Json>, out: String) -> String:
  match m:
    case Some{J.JStr{s}}:
      s
    case Some{d}:
      J.show(d)
    case None{}:
      out

# TypeSafe's reason for a refusal: the "detail" of its answer (as JSON
# unless it is text), else the answer itself, cut to 1000 characters.
def refusal_detail(+out: String) -> String:
  detail = Maybe.bind(&2, J.Json, J.Json, J.parse(out), j => J.get(j, "detail"))
  String.take(String.trim(refusal_detail.put(detail, out)), 1000n)

# What the exit status of mailbend-typesafe means, as the start of its
# error.
def typesafe_cause(code: U32) -> String:
  match code:
    case 2:
      "configuration error: "
    case 3:
      "cannot reach TypeSafe: "
    case 7:
      "check MAILBEND_TYPESAFE_KEY_FILE: "
    case 9:
      "try again later: "
    case _:
      Bool.pick(String, signalled(code), "the TypeSafe helper was killed by a signal: ",
        "TypeSafe error: ")

def typesafe_msg(err: String) -> String:
  stderr_msg(err, "mailbend-typesafe: ")

def asked_code(code: U32, out: String, err: String) -> Asked:
  match code:
    case 0:
      AskAnswered{out}
    case 8:
      AskRefused{typesafe_msg(err) ++ ": " ++ refusal_detail(out)}
    case _:
      AskFailed{typesafe_cause(code) ++ typesafe_msg(err)}

def asked(p: Proc) -> Asked:
  match p:
    case ProcOk{code, out, err}:
      asked_code(code, out, err)
    case _:
      AskFailed{"cannot run the TypeSafe helper: " ++ proc_failure(p)}

# How often a request is tried: once, or again after an overload or a
# timeout; the helper only follows this choice. Read annotations try once,
# so a hung TypeSafe delays a read by one MAILBEND_TIMEOUT_MS at most; the
# gates, mail_classify and mail_triage retry, since a failure there stops
# the work.
type Tries is Data:
  Once{}
  Retried{}

def tries_args(t: Tries) -> List<String>:
  match t:
    case Once{}:
      ["ask", "--once"]
    case Retried{}:
      ["ask"]

# The helper may print up to 8 MiB (it caps TypeSafe's answer at 4 MiB) and
# take up to five minutes (it may retry an overloaded service twice). It is
# not run_helper, whose 128 MiB cap is for mail: this cap is a second guard.
def typesafe_run(path: Result<&2, &2, String, String>, t: Tries, body: String) -> IO(Proc):
  match path:
    case Done{p}:
      do IO<Proc>:
        r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
          Process.run(p, tries_args(t), body, 8388608, 300000)
        return proc_of(r)
    case Fail{m}:
      IO.pure(Proc, ProcRefused{m})

# Sends one request through mailbend-typesafe, the only program that reads
# the TypeSafe key.
def ask_jev(t: Tries, body: String) -> IO(Asked):
  do IO<Asked>:
    path : String <- env_or("MAILBEND_TYPESAFE_HELPER", "")
    p : Proc <- typesafe_run(
      helper_path(path, "MAILBEND_TYPESAFE_HELPER", "mailbend-typesafe"), t, body)
    return asked(p)

# Requests in turn
# ----------------

# What the requests have given so far: what Jev answered about each
# message, and a report of each request, newest first.
type Progress is Data:
  Progress{answered: List<&2, Jev.Answered>, requests: List<&2, J.Json>}

# The progress, or why the call stopped.
def Tally() -> Data:
  Result<&2, &2, String, Progress>

def progress_add(
  p: Progress,
  xs: List<&2, Jev.Answered>,
  requests: List<&2, J.Json>
) -> Progress:
  Progress{done, reqs} = p
  Progress{List.append(&2, Jev.Answered, List.reverse(&2, Jev.Answered, xs), done),
    List.append(&2, J.Json, requests, reqs)}

# A request's report: its messages, its size in bytes (MailBend's token
# estimate) and the input tokens TypeSafe counted, when it says.
def request_json(n: Nat, bytes: U32, tokens: Maybe<&2, U32>) -> J.Json:
  J.obj([
    J.kv("messages", J.num(U32.from_nat(n))),
    J.kv("bytes", J.num(bytes)),
    J.kv("input_tokens", maybe_num(tokens))
  ])

def answered.put(r: Maybe<&2, Jev.Reply>, n: Nat, bytes: U32, p: Progress) -> Tally():
  match r:
    case None{}:
      Fail{"TypeSafe's answer is not the JSON MailBend asked for"}
    case Some{Jev.Reply{xs, tokens}}:
      Done{progress_add(p, xs, [request_json(n, bytes, tokens)])}

# One request's outcome added to the progress; any failure stops the call.
# Reading an answer needs `keys`, every category option key Jev may choose.
def answered(
  r: Asked,
  +es: List<&2, Jev.Entry>,
  bytes: U32,
  keys: List<&2, String>,
  p: Progress
) -> Tally():
  match r:
    case AskAnswered{body}:
      answered.put(Jev.reply(body, es, keys), List.length(&2, Jev.Entry, es), bytes, p)
    case AskRefused{m}:
      Fail{m}
    case AskFailed{m}:
      Fail{m}

# Sends the request for `es`, unless the call has already stopped.
def ask_once(
  tries: Tries,
  +es: List<&2, Jev.Entry>,
  keys: List<&2, String>,
  t: Tally()
) -> IO(Tally()):
  match t:
    case Fail{m}:
      IO.pure(Tally(), Fail{m})
    case Done{p}:
      +body = Jev.request_body(es)
      do IO<Tally()>:
        r : Asked <- ask_jev(tries, body)
        return answered(r, es, C.utf8_len(body), keys, p)

# A refused request split once into halves, each asked on its own; a
# refusal of either stops the call.
def ask_halves(
  +tries: Tries,
  +es: List<&2, Jev.Entry>,
  +keys: List<&2, String>,
  p: Progress
) -> IO(Tally()):
  +half = Nat.div(List.length(&2, Jev.Entry, es), 2n)
  start : Tally() = Done{p}
  do IO<Tally()>:
    first : Tally() <- ask_once(tries, List.take(&2, Jev.Entry, es, half), keys, start)
    ask_once(tries, List.drop(&2, Jev.Entry, es, half), keys, first)

def ask_batch.if(
  split: Bool,
  m: String,
  tries: Tries,
  es: List<&2, Jev.Entry>,
  keys: List<&2, String>,
  p: Progress
) -> IO(Tally()):
  match split:
    case True{}:
      ask_halves(tries, es, keys, p)
    case False{}:
      IO.pure(Tally(), Fail{m})

def ask_batch.put(
  r: Asked,
  tries: Tries,
  +es: List<&2, Jev.Entry>,
  keys: List<&2, String>,
  bytes: U32,
  p: Progress
) -> IO(Tally()):
  match r:
    case AskRefused{m}:
      ask_batch.if(Nat.is_gt(List.length(&2, Jev.Entry, es), 1n), m, tries, es, keys, p)
    case _:
      IO.pure(Tally(), answered(r, es, bytes, keys, p))

# TypeSafe's 422 is a general validation error, so a refused request of two
# or more messages is split once, in case it was too large; a refusal of a
# half, or of a single message, stops the call with TypeSafe's reason.
def ask_batch(
  +tries: Tries,
  +es: List<&2, Jev.Entry>,
  keys: List<&2, String>,
  p: Progress
) -> IO(Tally()):
  +body = Jev.request_body(es)
  do IO<Tally()>:
    r : Asked <- ask_jev(tries, body)
    ask_batch.put(r, tries, es, keys, C.utf8_len(body), p)

def ask_step.put(tries: Tries, s: Jev.Step, keys: List<&2, String>, p: Progress) -> IO(Tally()):
  match s:
    case Jev.Skip{f}:
      IO.pure(Tally(), Done{progress_add(p, [Jev.Skipped{f}], [])})
    case Jev.Ask{es}:
      ask_batch(tries, es, keys, p)

def ask_step(tries: Tries, s: Jev.Step, keys: List<&2, String>, t: Tally()) -> IO(Tally()):
  match t:
    case Fail{m}:
      IO.pure(Tally(), Fail{m})
    case Done{p}:
      ask_step.put(tries, s, keys, p)

# Takes the steps in order; once the call has stopped, no further request
# is sent.
def ask_steps(
  ss: List<&2, Jev.Step>,
  +tries: Tries,
  +keys: List<&2, String>,
  t: Tally()
) -> IO(Tally()):
  match ss:
    case Nil{}:
      IO.pure(Tally(), t)
    case s <> rest:
      do IO<Tally()>:
        next : Tally() <- ask_step(tries, s, keys, t)
        ask_steps(rest, tries, keys, next)

# Every request of `steps`, from no progress; `keys` are the category
# option keys Jev may choose.
def ask_all(tries: Tries, steps: List<&2, Jev.Step>, keys: List<&2, String>) -> IO(Tally()):
  ask_steps(steps, tries, keys, Done{Progress{[], []}})

# Asks about the messages `ms` with the options `opts`, whose categories
# are `names`.
def ask_options(
  tries: Tries,
  c: Jev.Content,
  ms: List<&2, Jev.Fetched>,
  names: List<&2, String>,
  +opts: Jev.Options
) -> IO(Tally()):
  ask_all(tries, Jev.requests(c, ms, opts),
    List.append(&2, String, names, [Jev.options_none(opts)]))

# Messages to ask about
# ---------------------

# The most UIDs one call of a Jev tool asks about.
def jev_limit() -> U32:
  50

# In body mode each message is fetched up to this many bytes, of which Jev
# sees at most Jev.max_text bytes of plain text.
def jev_max() -> U32:
  262144

def jev_uids.if(over: Bool, tool: String, us: List<&2, U32>) -> Uids():
  match over:
    case True{}:
      Fail{tool ++ " takes at most " ++ U32.show(jev_limit()) ++ " UIDs per call"}
    case False{}:
      Done{asc(unseen(us, []))}

# The UIDs of a call of the Jev tool `tool`: each once, ascending.
def jev_uids(tool: String, u: Uids()) -> Uids():
  match u:
    case Fail{m}:
      Fail{m}
    case Done{+us}:
      jev_uids.if(Nat.is_gt(List.length(&2, U32, us), U32.to_nat(jev_limit())), tool, us)

# `ms` in UID order, each UID once (a server may answer twice).
def first_uids(ms: List<&2, I.Msg>, prev: U32) -> List<&2, I.Msg>:
  match ms:
    case Nil{}:
      []
    case +m <> t:
      +u = msg_uid(m)
      List.filter.put(I.Msg, m, first_uids(t, u), Bool.not(U32.is_eq(u, prev)))

# The messages of `uids` a session fetched, in UID order, each once: those
# Jev is asked about.
def jev_msgs(lines: List<&2, I.RLine>, uids: List<&2, U32>) -> List<&2, I.Msg>:
  first_uids(oldest_first(requested(I.fetched(lines), uids)), 0)

def msg_uids(ms: List<&2, I.Msg>) -> List<&2, U32>:
  match ms:
    case Nil{}:
      []
    case m <> t:
      msg_uid(m) <> msg_uids(t)

def fetched_list(ms: List<&2, I.Msg>, +max: U32) -> List<&2, Jev.Fetched>:
  match ms:
    case Nil{}:
      []
    case +m <> t:
      Jev.Fetched{Jev.facts_of(m), Jev.text_of(m, max)} <> fetched_list(t, max)

# Changing mail
# =============

# A change or send the gates blocked: why, and what they found.
def gate_blocked(reason: String, report: List<&2, J.Json>) -> Out:
  Partial{J.obj(J.kv("ok", J.bool(False{})) <> J.kv("error", J.str(reason)) <> report)}

# Change results
# --------------

def minus(xs: List<&2, U32>, +ys: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      []
    case +x <> t:
      List.filter.put(U32, x, minus(t, ys), Bool.not(uid_in(x, ys)))

def none_exist(folder: String) -> String:
  "none of these UIDs exist in " ++ folder ++ "; nothing was changed"

def changed_found.if(
  none: Bool,
  +found: List<&2, U32>,
  uids: List<&2, U32>,
  folder: String,
  kvs: List<&2, J.Json>
) -> Out:
  match none:
    case True{}:
      Err{none_exist(folder)}
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
    case I.Msg{u, flags, date, size, headers, body, _} <> t:
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

def mark_uids.run(
  +plan: List<&2, I.Cmd>,
  uids: List<&2, U32>,
  folder: String,
  mark: Mark
) -> IO(Out):
  do IO<Out>:
    p : Proc <- imap_proc(plan)
    return mark_result(p, plan, uids, folder, mark)

def mark_uids.if(
  missing: Bool,
  +uids: List<&2, U32>,
  +folder: String,
  +mark: Mark,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match missing:
    case True{}:
      pure_out(Err{uidv_missing()})
    case False{}:
      +plan = mark_plan(uids, folder, mark, uidv)
      preview_or_run(dry, ImapPreview{plan}, mark_uids.run(plan, uids, folder, mark))

def mark_uids(u: Uids(), folder: String, mark: Mark, +uidv: U32, dry: Bool) -> IO(Out):
  match u:
    case Fail{m}:
      pure_out(Err{m})
    case Done{uids}:
      mark_uids.if(U32.is_zero(uidv), uids, folder, mark, uidv, dry)

def t_mark(+args: J.Json, mark: Mark) -> IO(Out):
  mark_uids(uids_arg(args), folder_arg(args), mark, uidv_arg(args), dry_arg(args))

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

def move_plan.run(
  +plan: List<&2, I.Cmd>,
  folder: String,
  uids: List<&2, U32>,
  dest: String,
  move: Bool
) -> IO(Out):
  do IO<Out>:
    p : Proc <- imap_proc(plan)
    return moved_out(p, plan, folder, uids, dest, move)

# Why a server can take no move plan (see Ops.plan_move).
def no_move_problem() -> String:
  "the server supports neither MOVE nor UIDPLUS; refusing to move with a plain EXPUNGE, " ++
    "which could remove other messages"

def move_plan(
  +plan: List<&2, I.Cmd>,
  folder: String,
  uids: List<&2, U32>,
  dest: String,
  move: Bool,
  dry: Bool
) -> IO(Out):
  match plan:
    case Nil{}:
      pure_out(Err{no_move_problem()})
    case h <> t:
      preview_or_run(dry, ImapPreview{plan}, move_plan.run(plan, folder, uids, dest, move))

def move_caps.if(
  problem: String,
  +caps: List<&2, String>,
  +folder: String,
  +uids: List<&2, U32>,
  +dest: String,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      +move = I.has_cap(caps, "MOVE")
      move_plan(Ops.plan_move(folder, uids, dest, move, I.has_cap(caps, "UIDPLUS"), uidv),
        folder, uids, dest, move, dry)

def move_caps(
  r: Run(),
  folder: String,
  uids: List<&2, U32>,
  +dest: String,
  +uidv: U32,
  dry: Bool
) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      move_caps.if(
        first_of(uidv_problem(lines, uidv), review_move_problem(delim_of(I.folders(lines)), dest)),
        I.caps(lines), folder, uids, dest, uidv, dry)

def move_request(uidv: U32, folder: String, +dest: String) -> String:
  Bool.pick(String, String.is_empty(dest) || I.same_name(dest, folder),
    "\"destination\" must name a different folder",
    Bool.pick(String, U32.is_zero(uidv), uidv_missing(), ""))

def move_uids.if(
  problem: String,
  +folder: String,
  uids: List<&2, U32>,
  dest: String,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_preflight(folder))
        move_caps(r, folder, uids, dest, uidv, dry)

def move_uids(u: Uids(), +folder: String, +dest: String, +uidv: U32, dry: Bool) -> IO(Out):
  match u:
    case Fail{m}:
      pure_out(Err{m})
    case Done{uids}:
      move_uids.if(move_request(uidv, folder, dest), folder, uids, dest, uidv, dry)

def t_move(+args: J.Json) -> IO(Out):
  move_uids(uids_arg(args), folder_arg(args), str_arg(args, "destination", ""), uidv_arg(args),
    dry_arg(args))

def trash_into(
  same: Bool,
  +trash: String,
  +caps: List<&2, String>,
  +folder: String,
  +uids: List<&2, U32>,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match same:
    case True{}:
      pure_out(Err{
        "these messages are already in " ++ trash ++
          "; use mail_delete to remove them permanently"})
    case False{}:
      +move = I.has_cap(caps, "MOVE")
      move_plan(Ops.plan_trash(folder, uids, trash, move, I.has_cap(caps, "UIDPLUS"), uidv),
        folder, uids, trash, move, dry)

def trash_to.if(
  problem: String,
  +trash: String,
  caps: List<&2, String>,
  +folder: String,
  uids: List<&2, U32>,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      trash_into(I.same_name(trash, folder), trash, caps, folder, uids, uidv, dry)

def trash_to(
  trash: Maybe<&2, String>,
  delim: String,
  caps: List<&2, String>,
  +folder: String,
  uids: List<&2, U32>,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match trash:
    case None{}:
      pure_out(Err{"no unique selectable Trash folder: configure MAILBEND_TRASH_FOLDER"})
    case Some{+t}:
      trash_to.if(review_trash_problem(delim, folder, t), t, caps, folder, uids, uidv, dry)

def trash_fs(
  f: Fs(),
  caps: List<&2, String>,
  folder: String,
  uids: List<&2, U32>,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match f:
    case Fail{m}:
      pure_out(Err{m ++ "; nothing was changed"})
    case Done{Folders{fs, drafts, trash, sent, junk, archive}}:
      trash_to(trash, delim_of(fs), caps, folder, uids, uidv, dry)

def trash_found.if(
  problem: String,
  +lines: List<&2, I.RLine>,
  folder: String,
  uids: List<&2, U32>,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        f : Fs() <- folders_io(lines)
        trash_fs(f, I.caps(lines), folder, uids, uidv, dry)

def trash_found(
  r: Run(),
  folder: String,
  uids: List<&2, U32>,
  +uidv: U32,
  dry: Bool
) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      trash_found.if(uidv_problem(lines, uidv), lines, folder, uids, uidv, dry)

def trash_uids.if(
  missing: Bool,
  +folder: String,
  uids: List<&2, U32>,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match missing:
    case True{}:
      pure_out(Err{uidv_missing()})
    case False{}:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_preflight(folder))
        trash_found(r, folder, uids, uidv, dry)

def trash_uids(u: Uids(), folder: String, +uidv: U32, dry: Bool) -> IO(Out):
  match u:
    case Fail{m}:
      pure_out(Err{m})
    case Done{uids}:
      trash_uids.if(U32.is_zero(uidv), folder, uids, uidv, dry)

def t_trash(+args: J.Json) -> IO(Out):
  trash_uids(uids_arg(args), folder_arg(args), uidv_arg(args), dry_arg(args))

def delete_plan.run(plan: List<&2, I.Cmd>, +folder: String, uids: List<&2, U32>) -> IO(Out):
  do IO<Out>:
    r : Run() <- imap_run(plan)
    return changed_out(r, uids, folder, [
      J.kv("ok", J.bool(True{})),
      J.kv("folder", J.str(folder)),
      J.kv("permanently_deleted", J.bool(True{}))
    ])

def delete_refused(blocked: String, report: List<&2, J.Json>) -> Out:
  match blocked:
    case SNil{}:
      Err{"the server lacks UIDPLUS; refusing a plain EXPUNGE, which could remove other messages"}
    case SCon{h, t}:
      gate_blocked(SCon{h, t} ++ "; nothing was deleted", report)

# No plan means the gate blocked the delete (`blocked` says why) or the
# server lacks UIDPLUS. `report` is what the gate found, with Jev on.
def delete_plan(
  +plan: List<&2, I.Cmd>,
  blocked: String,
  report: List<&2, J.Json>,
  folder: String,
  uids: List<&2, U32>,
  dry: Bool
) -> IO(Out):
  match plan:
    case Nil{}:
      pure_out(delete_refused(blocked, report))
    case h <> t:
      do IO<Out>:
        o : Out <- preview_or_run(dry, ImapPreview{plan}, delete_plan.run(plan, folder, uids))
        return with_fields(o, report)

# The delete once the gate has decided: its plan, over the UIDs `planned`,
# comes only through Jev.delete_checked, so a veto or a failed check leaves
# it none. Of the requested `uids`, those it did not delete are reported
# missing.
def delete_decided(
  d: Jev.Decision,
  uidplus: Bool,
  +folder: String,
  planned: List<&2, U32>,
  uids: List<&2, U32>,
  confirm: String,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  Jev.Decision{+g, report} = d
  delete_plan(Jev.delete_checked(g, Ops.plan_delete(folder, planned, confirm, uidplus, uidv)),
    Jev.gate_reason(g), report, folder, uids, dry)

# What Jev's answers to the keep questions decide; TypeSafe failing blocks.
def delete_answered(t: Tally(), c: Jev.Content) -> Jev.Decision:
  match t:
    case Fail{m}:
      Jev.undecided(c, m)
    case Done{Progress{xs, reqs}}:
      Jev.decided(c, Jev.delete_concerns(List.reverse(&2, Jev.Answered, xs)), [])

# With Jev on, the keep questions are asked about each message the
# preflight fetched (`ms`) before anything is deleted; one that would keep
# a message vetoes the delete. Only those messages are deleted: a requested
# UID the preflight did not find is reported missing, so a message that
# takes it meanwhile is never deleted unseen.
def delete_ask(
  ms: List<&2, I.Msg>,
  +c: Jev.Content,
  folder: String,
  uids: List<&2, U32>,
  confirm: String,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match ms:
    case Nil{}:
      pure_out(Err{none_exist(folder)})
    case m <> t:
      +asked : List<&2, I.Msg> = m <> t
      steps = Jev.requests(c, fetched_list(asked, jev_max()), Jev.options_for(Jev.Deleting{}, []))
      do IO<Out>:
        tally : Tally() <- ask_all(Retried{}, steps, [])
        delete_decided(delete_answered(tally, c), True{}, folder, msg_uids(asked), uids, confirm,
          uidv, dry)

# Jev is asked only when the server has UIDPLUS: without it there is no
# plan, whatever a gate decides, so nothing about the messages leaves the
# machine for a delete that cannot run.
def delete_gated(
  jev: Jev.Switch,
  lines: List<&2, I.RLine>,
  uidplus: Bool,
  folder: String,
  +uids: List<&2, U32>,
  confirm: String,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match jev uidplus:
    case Jev.On{c} True{}:
      delete_ask(jev_msgs(lines, uids), c, folder, uids, confirm, uidv, dry)
    case Jev.On{c} False{}:
      delete_decided(Jev.Decision{Jev.JevOff{}, []}, False{}, folder, uids, uids, confirm, uidv,
        dry)
    case Jev.Off{} _:
      delete_decided(Jev.Decision{Jev.JevOff{}, []}, uidplus, folder, uids, uids, confirm, uidv,
        dry)

def delete_caps.if(
  problem: String,
  jev: Jev.Switch,
  +lines: List<&2, I.RLine>,
  folder: String,
  uids: List<&2, U32>,
  confirm: String,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      delete_gated(jev, lines, I.has_cap(I.caps(lines), "UIDPLUS"), folder, uids, confirm, uidv,
        dry)

def delete_caps(
  r: Run(),
  jev: Jev.Switch,
  folder: String,
  uids: List<&2, U32>,
  confirm: String,
  +uidv: U32,
  dry: Bool
) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      delete_caps.if(uidv_problem(lines, uidv), jev, lines, folder, uids, confirm, uidv, dry)

# The session before a delete; with Jev on it also fetches what Jev may see
# of each message.
def delete_preflight(jev: Jev.Switch, folder: String, uids: List<&2, U32>) -> List<&2, I.Cmd>:
  match jev:
    case Jev.Off{}:
      Ops.plan_preflight(folder)
    case Jev.On{c}:
      Ops.plan_classify(folder, uids, Jev.is_body(c), jev_max())

def delete_uids.if(
  problem: String,
  +jev: Jev.Switch,
  +folder: String,
  +uids: List<&2, U32>,
  confirm: String,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        r : Run() <- imap_run(delete_preflight(jev, folder, uids))
        delete_caps(r, jev, folder, uids, confirm, uidv, dry)

# The plan itself refuses without the confirmation word (a proven law);
# these checks only explain why before connecting.
def delete_request(confirm: String, uidv: U32) -> String:
  Bool.pick(String, Bool.not(String.eq(confirm, Ops.confirm_word())),
    "mail_delete permanently removes messages and cannot be undone; pass \"confirm\": " ++
      "\"permanently-delete\" to proceed (use mail_trash to move them to Trash instead)",
    Bool.pick(String, U32.is_zero(uidv), uidv_missing(), ""))

def delete_uids(
  u: Uids(),
  jev: Jev.Switch,
  folder: String,
  +confirm: String,
  +uidv: U32,
  dry: Bool
) -> IO(Out):
  match u:
    case Fail{m}:
      pure_out(Err{m})
    case Done{uids}:
      delete_uids.if(delete_request(confirm, uidv), jev, folder, uids, confirm, uidv, dry)

# With Jev on, a delete asks Jev about each message, so it takes no more
# UIDs than a Jev tool does.
def delete_uids_of(jev: Jev.Switch, u: Uids()) -> Uids():
  match jev:
    case Jev.Off{}:
      u
    case Jev.On{c}:
      jev_uids("mail_delete", u)

def t_delete(+args: J.Json, +jev: Jev.Switch) -> IO(Out):
  delete_uids(delete_uids_of(jev, uids_arg(args)), jev, folder_arg(args),
    str_arg(args, "confirm", ""), uidv_arg(args), dry_arg(args))

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

# Names reserved whether or not the server advertises them: the review folder,
# and the conventional role names that role resolution falls back to.
def reserved_names() -> List<&2, String>:
  Ops.review_folder() <> conventional_names()

def reserved_note() -> String:
  "INBOX, Drafts, Sent, Trash, Junk, Archive (also under their usual names), To Delete, " ++
    "and any folder configured for one of those roles or advertised with any special-use role"

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

# The role folders: those resolved for a role, and those that advertise one.
def role_names(
  fs: List<&2, I.Folder>,
  drafts: Maybe<&2, String>,
  trash: Maybe<&2, String>,
  sent: Maybe<&2, String>,
  junk: Maybe<&2, String>,
  archive: Maybe<&2, String>
) -> List<&2, String>:
  List.append(&2, String,
    maybe_name(drafts, maybe_name(trash, maybe_name(sent, maybe_name(junk,
      maybe_name(archive, []))))),
    advertised_names(fs))

# Reserved, in lower case: the role folders and the reserved names.
def guard_of(
  +fs: List<&2, I.Folder>,
  drafts: Maybe<&2, String>,
  trash: Maybe<&2, String>,
  sent: Maybe<&2, String>,
  junk: Maybe<&2, String>,
  archive: Maybe<&2, String>
) -> Guard:
  roles = role_names(fs, drafts, trash, sent, junk, archive)
  Guard{fs, lowered(List.append(&2, String, roles, reserved_names())), delim_of(fs)}

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
  create_problem.if(String.eq(name, Ops.review_folder()), g, name)

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

def folder_guarded.run(+plan: List<&2, I.Cmd>, c: FolderChange) -> IO(Out):
  do IO<Out>:
    p : Proc <- imap_proc(plan)
    return folder_out(p, plan, c)

def folder_guarded.if(
  problem: String,
  +plan: List<&2, I.Cmd>,
  c: FolderChange,
  dry: Bool
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      preview_or_run(dry, ImapPreview{plan}, folder_guarded.run(plan, c))

def folder_guarded(+g: Guard, subs: List<&2, I.Folder>, c: FolderChange, dry: Bool) -> IO(Out):
  +canonical = change_canonical(g, c)
  folder_guarded.if(change_problem(g, canonical), change_plan(g, subs, canonical), canonical,
    dry)

def folder_fs(f: Fs(), subs: List<&2, I.Folder>, c: FolderChange, dry: Bool) -> IO(Out):
  match f:
    case Fail{m}:
      pure_out(Err{m ++ "; nothing was changed"})
    case Done{folders}:
      folder_guarded(guard_for(folders), subs, c, dry)

def folder_found(r: Run(), c: FolderChange, dry: Bool) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      do IO<Out>:
        f : Fs() <- folders_io(lines)
        folder_fs(f, I.subscribed(lines), c, dry)

def folder_change.if(problem: String, c: FolderChange, dry: Bool) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_folder_scan())
        folder_found(r, c, dry)

def folder_change(+c: FolderChange, dry: Bool) -> IO(Out):
  folder_change.if(change_raw_problem(c), c, dry)

def t_create_folder(+args: J.Json) -> IO(Out):
  folder_change(FolderCreate{str_arg(args, "name", "")}, dry_arg(args))

def t_rename_folder(+args: J.Json) -> IO(Out):
  folder_change(FolderRename{str_arg(args, "from", ""), str_arg(args, "to", "")}, dry_arg(args))

# Runs the label plan unless `problem` rules it out.
def label_fs.if(
  problem: String,
  plan: List<&2, I.Cmd>,
  folder: String,
  uids: List<&2, U32>,
  label: String,
  move: Bool,
  dry: Bool
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      move_plan(plan, folder, uids, label, move, dry)

def label_fs(
  f: Fs(),
  +caps: List<&2, String>,
  +folder: String,
  +uids: List<&2, U32>,
  +label: String,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match f:
    case Fail{m}:
      pure_out(Err{m ++ "; nothing was changed"})
    case Done{folders}:
      +move = I.has_cap(caps, "MOVE")
      label_fs.if(label_problem(guard_for(folders), label),
        Ops.plan_label(folder, uids, label, move, I.has_cap(caps, "UIDPLUS"), uidv),
        folder, uids, label, move, dry)

def label_found.if(
  problem: String,
  +lines: List<&2, I.RLine>,
  folder: String,
  uids: List<&2, U32>,
  label: String,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        f : Fs() <- folders_io(lines)
        label_fs(f, I.caps(lines), folder, uids, label, uidv, dry)

def label_found(
  r: Run(),
  folder: String,
  uids: List<&2, U32>,
  label: String,
  +uidv: U32,
  dry: Bool
) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      label_found.if(uidv_problem(lines, uidv), lines, folder, uids, label, uidv, dry)

def label_uids.if(
  problem: String,
  +folder: String,
  uids: List<&2, U32>,
  label: String,
  uidv: U32,
  dry: Bool
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_preflight(folder))
        label_found(r, folder, uids, label, uidv, dry)

def label_request(uidv: U32, folder: String, +label: String) -> String:
  Bool.pick(String, String.is_empty(label) || I.same_name(label, folder),
    "\"label\" must name a folder other than the one the messages are in",
    Bool.pick(String, U32.is_zero(uidv), uidv_missing(), ""))

def label_uids(u: Uids(), +folder: String, +label: String, +uidv: U32, dry: Bool) -> IO(Out):
  match u:
    case Fail{m}:
      pure_out(Err{m})
    case Done{uids}:
      label_uids.if(label_request(uidv, folder, label), folder, uids, label, uidv, dry)

def t_label(+args: J.Json) -> IO(Out):
  label_uids(uids_arg(args), folder_arg(args), str_arg(args, "label", ""), uidv_arg(args),
    dry_arg(args))

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
      pure_att(Fail{helper_refusal("MAILBEND_ATTACH_HELPER", "mailbend-attach")})

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

# What the tools want composed; Bcc goes only into the SMTP envelope. With
# `draft` the message is saved instead of sent; with `dry` that is only shown.
# `about` is what the message answers, and `jev` whether the gates check a
# send.
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
    draft: Bool,
    dry: Bool,
    about: Jev.Context,
    jev: Jev.Switch
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

# The time in seconds since the epoch; 0 when it cannot be read.
def now_seconds() -> IO(U32):
  do IO<U32>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("/bin/date", ["+%s"], "", 64, 5000)
    return secs_of(proc_of(r))

def stamp() -> IO(Stamp):
  do IO<Stamp>:
    secs : U32 <- now_seconds()
    a : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    b : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    return stamp_of(secs, rand_of(a), rand_of(b))

def domain_of(addr: String) -> String:
  Maybe.default(&2, String, List.last(&2, String, String.split(M.addr_spec(addr), '@')),
    "mailbend.invalid")

# A saved draft keeps its Bcc header (a mail client sends it later and drops
# the header); a sent message never carries one, Bcc goes only into the
# SMTP envelope.
def draft_of(w: Want, +from: String, st: Stamp, keep_bcc: Bool) -> M.Draft:
  Want{to, cc, bcc, subject, text, irt, refs, atts, draft, dry, about, jev} = w
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
  Want{to, cc, bcc, s, x, i, r, a, d, y, o, j} = w
  List.concat(&2, String, [to, cc, bcc])

def is_draft(w: Want) -> Bool:
  Want{t, c, b, s, x, i, r, a, draft, y, o, j} = w
  draft

def want_jev(w: Want) -> Jev.Switch:
  Want{t, c, b, s, x, i, r, a, d, y, o, jev} = w
  jev

def is_dry(w: Want) -> Bool:
  Want{t, c, b, s, x, i, r, a, d, dry, o, j} = w
  dry

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

def draft_append.run(plan: List<&2, I.Cmd>, drafts: String, msgid: String) -> IO(Out):
  do IO<Out>:
    r : Run() <- imap_run(plan)
    return draft_saved(r, drafts, msgid)

def draft_append(m: Maybe<&2, String>, msg: String, msgid: String, dry: Bool) -> IO(Out):
  match m:
    case None{}:
      pure_out(Err{"no unique selectable Drafts folder: configure MAILBEND_DRAFTS_FOLDER"})
    case Some{+drafts}:
      +plan = Ops.plan_draft(drafts, msg)
      preview_or_run(dry, ImapPreview{plan}, draft_append.run(plan, drafts, msgid))

def draft_fs(f: Fs(), msg: String, msgid: String, dry: Bool) -> IO(Out):
  match f:
    case Fail{m}:
      pure_out(Err{m ++ "; no draft was saved"})
    case Done{Folders{fs, drafts, trash, sent, junk, archive}}:
      draft_append(drafts, msg, msgid, dry)

def draft_folder(r: Run(), msg: String, msgid: String, dry: Bool) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{lines}:
      do IO<Out>:
        f : Fs() <- folders_io(lines)
        draft_fs(f, msg, msgid, dry)

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
  I.Msg{uid, flags, date, size, headers, body, _} = m
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
      pure_str(helper_refusal("MAILBEND_ATTACH_HELPER", "mailbend-attach"))

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

def send_allowed.run(envelope: String, limit: U32, dir: String, day: String, s: Sent) -> IO(Out):
  do IO<Out>:
    problem : String <- reserve(limit, dir, day)
    send_allowed.if(problem, envelope, s)

# A message ready to send once the gates pass it: the bare sender and
# recipients, the message, the allowlist and daily limit it goes under,
# what its result reports, and its dry run.
type Ready is Data:
  Ready{
    from: String,
    rcpts: List<&2, String>,
    msg: String,
    allow: List<&2, String>,
    limit: U32,
    dir: String,
    day: String,
    sent: Sent,
    dry: Bool,
    preview: Preview
  }

# Why a send got no envelope: the gates blocked it (`blocked` says why), or
# else the allowlist refused a recipient.
def send_refused(
  blocked: String,
  allow: List<&2, String>,
  rcpts: List<&2, String>,
  report: List<&2, J.Json>
) -> Out:
  match blocked:
    case SNil{}:
      Err{unlisted_msg(S.refused(allow, rcpts))}
    case SCon{h, t}:
      gate_blocked(SCon{h, t} ++ "; nothing was sent (mail_save_draft can still save it as a " ++
        "draft)", report)

# The send itself: only an envelope lets it go, and only then is a place in
# the daily count reserved. A dry run reserves none and shows what the
# envelope is built from. `report` is what the gates found, with Jev on.
def send_allowed(
  envelope: Maybe<&2, String>,
  blocked: String,
  report: List<&2, J.Json>,
  r: Ready
) -> IO(Out):
  match envelope:
    case None{}:
      Ready{from, rcpts, msg, allow, limit, dir, day, s, dry, p} = r
      pure_out(send_refused(blocked, allow, rcpts, report))
    case Some{e}:
      Ready{from, rcpts, msg, allow, limit, dir, day, s, dry, p} = r
      do IO<Out>:
        o : Out <- preview_or_run(dry, p, send_allowed.run(e, limit, dir, day, s))
        return with_fields(o, report)

# The send once the gates have decided: the envelope comes only from
# Jev.outbound_checked, which gives S.outbound's only when the secret scan
# is Clean and Jev is off or vetoed nothing.
def send_checked(
  +scan: Secrets.Scan,
  +g: Jev.Gate,
  report: List<&2, J.Json>,
  +r: Ready
) -> IO(Out):
  Ready{from, rcpts, msg, allow, l, dr, dy, s, y, p} = r
  send_allowed(Jev.outbound_checked(scan, allow, g, rcpts, from, msg),
    Jev.blocked_reason(scan, g), report, r)

# With Jev on, a send reports the secret scan's result and Jev's decision.
def send_decided(+scan: Secrets.Scan, d: Jev.Decision, r: Ready) -> IO(Out):
  Jev.Decision{g, report} = d
  send_checked(scan, g, List.append(&2, J.Json, Secrets.scan_kvs(scan), report), r)

def outgoing_answered(
  a: Asked,
  c: Jev.Content,
  vs: List<&2, Jev.Veto>,
  whole: Jev.Completeness
) -> Jev.Decision:
  match a:
    case AskAnswered{body}:
      Jev.outgoing_decision(c, vs, whole, body)
    case AskRefused{m}:
      Jev.undecided(c, m)
    case AskFailed{m}:
      Jev.undecided(c, m)

# Asks Jev the veto questions `vs` about a message the secret scan passed,
# with the text `t` it may see of it.
def send_ask(
  t: Jev.Text,
  +c: Jev.Content,
  o: Jev.Outgoing,
  +vs: List<&2, Jev.Veto>,
  r: Ready
) -> IO(Out):
  Jev.Text{shown, whole} = t
  do IO<Out>:
    a : Asked <- ask_jev(Retried{}, Jev.outgoing_request(c, o, vs, shown))
    send_decided(Secrets.Clean{}, outgoing_answered(a, c, vs, whole), r)

# Jev is asked only about a message the local secret scan passed.
def send_scanned(
  scan: Secrets.Scan,
  +c: Jev.Content,
  o: Jev.Outgoing,
  vs: List<&2, Jev.Veto>,
  text: String,
  r: Ready
) -> IO(Out):
  match scan:
    case Secrets.Clean{}:
      send_ask(Jev.outgoing_text(c, text), c, o, vs, r)
    case _:
      send_decided(scan, Jev.undecided(c, "Jev was not asked: the local secret scan blocked " ++
        "the send"), r)

def attach_names(atts: List<&2, M.Attach>) -> List<&2, String>:
  match atts:
    case Nil{}:
      []
    case M.Attach{name, ctype, data} <> t:
      name <> attach_names(t)

# The header fields Jev may see of an outgoing message.
def outgoing_fields(
  from: String,
  to: List<&2, String>,
  cc: List<&2, String>,
  bcc: List<&2, String>,
  subject: String
) -> List<&2, M.Hdr>:
  [
    M.Hdr{"from", from},
    M.Hdr{"to", String.join(to, ", ")},
    M.Hdr{"cc", String.join(cc, ", ")},
    M.Hdr{"bcc", String.join(bcc, ", ")},
    M.Hdr{"subject", subject}
  ]

# The secret scan reads the header fields Jev may see, the In-Reply-To
# and References a caller may give, the body and the attachments.
def send_jev.put(
  refused: List<&2, String>,
  c: Jev.Content,
  w: Want,
  from: String,
  r: Ready
) -> IO(Out):
  match refused:
    case Nil{}:
      Want{to, cc, bcc, subject, +text, irt, refs, +atts, draft, dry, +about, jev} = w
      +fields = outgoing_fields(from, to, cc, bcc, subject)
      scan = Secrets.secret_scan(List.append(&2, M.Hdr, fields,
        [M.Hdr{"in-reply-to", irt}, M.Hdr{"references", refs}]), text, atts)
      send_scanned(scan, c, Jev.Outgoing{fields, attach_names(atts), about},
        Jev.outgoing_vetoes(about), text, r)
    case h <> t:
      pure_out(Err{unlisted_msg(h <> t)})

# With Jev on, a send passes the allowlist, then the local secret scan of
# its content, then Jev's veto questions, before its envelope is built.
def send_jev(c: Jev.Content, w: Want, from: String, +r: Ready) -> IO(Out):
  Ready{f, rcpts, m, allow, l, dr, dy, s, y, p} = r
  send_jev.put(S.refused(allow, rcpts), c, w, from, r)

def send_gated(jev: Jev.Switch, w: Want, from: String, r: Ready) -> IO(Out):
  match jev:
    case Jev.Off{}:
      send_checked(Secrets.Clean{}, Jev.JevOff{}, [], r)
    case Jev.On{c}:
      send_jev(c, w, from, r)

def send_with(cfg: Sends(), +w: Want, +from: String, +st: Stamp) -> IO(Out):
  match cfg:
    case Fail{m}:
      pure_out(Err{"configuration error: " ++ m})
    case Done{Sending{+save, allow, limit, dir}}:
      +d = draft_of(w, from, st, False{})
      +rcpts = specs(all_rcpts(w))
      +sender = M.addr_spec(from)
      +msg = M.compose(d, boundary_of(st))
      send_gated(want_jev(w), w, from, Ready{sender, rcpts, msg, allow, limit, dir, day_of(st),
        Sent{msgid_of(d), U32.from_nat(List.length(&2, String, rcpts)), save,
          draft_of(w, from, st, True{}), boundary_of(st)},
        is_dry(w), SmtpPreview{sender, rcpts, msg, save}})

def deliver_as(draft: Bool, +w: Want, +from: String, +st: Stamp) -> IO(Out):
  match draft:
    case True{}:
      +d = draft_of(w, from, st, True{})
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_probe())
        draft_folder(r, M.compose(d, boundary_of(st)), msgid_of(d), is_dry(w))
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
  draft: Bool,
  dry: Bool,
  about: Jev.Context,
  jev: Jev.Switch
) -> IO(Out):
  match a:
    case Fail{m}:
      pure_out(Err{m})
    case Done{xs}:
      do IO<Out>:
        from : String <- env_or("MAILBEND_EMAIL", "")
        with_atts.want(Want{to, cc, bcc, subject, text, irt, refs, xs, draft, dry, about, jev},
          from)

# Composes from the common arguments: to, cc, bcc, subject, body,
# in_reply_to, references and attachments ([{path, filename?, content_type?}]).
def t_compose(+args: J.Json, draft: Bool, jev: Jev.Switch) -> IO(Out):
  do IO<Out>:
    rs : List<&2, Attachment()> <- atts_read(attachments_arg(args))
    with_atts(atts_collect(rs), strs_arg(args, "to"), strs_arg(args, "cc"),
      strs_arg(args, "bcc"), str_arg(args, "subject", ""), str_arg(args, "body", ""),
      str_arg(args, "in_reply_to", ""), str_arg(args, "references", ""), draft, dry_arg(args),
      Jev.Fresh{}, jev)

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
  me: String,
  about: Jev.Context,
  jev: Jev.Switch
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
      bool_arg(args, "as_draft", False{}),
      dry_arg(args),
      about,
      jev)
    return with_fields(o, quote_fields(cut, quoted, size))

def fwd_note(+hs: List<&2, M.Hdr>) -> String:
  "\n\n---------- Forwarded message ----------\nFrom: " ++ hdr_text(hs, "from") ++
    "\nDate: " ++ hdr_text(hs, "date") ++ "\nSubject: " ++ hdr_text(hs, "subject") ++
    "\nTo: " ++ hdr_text(hs, "to") ++ "\n"

def fwd_want(
  +hs: List<&2, M.Hdr>,
  +raw: String,
  +args: J.Json,
  about: Jev.Context,
  jev: Jev.Switch
) -> IO(Out):
  do IO<Out>:
    rs : List<&2, Attachment()> <-
      atts_read_within(attachments_arg(args), (max_attachment() - C.byte_len(raw) : U32))
    with_atts(atts_cons(M.Attach{"forwarded-message.eml", "message/rfc822", raw}, atts_collect(rs)),
      strs_arg(args, "to"), strs_arg(args, "cc"), strs_arg(args, "bcc"),
      prefixed("Fwd:", hdr_text(hs, "subject")),
      str_arg(args, "body", "") ++ fwd_note(hs),
      "", "", bool_arg(args, "as_draft", False{}), dry_arg(args), about, jev)

def respond_to(
  reply: Bool,
  too_big: Bool,
  size: U32,
  +body: String,
  args: J.Json,
  me: String,
  about: Jev.Context,
  jev: Jev.Switch
) -> IO(Out):
  match reply:
    case True{}:
      reply_want(body_headers(body), M.parts(body), too_big, C.byte_len(body), size, args, me,
        about, jev)
    case False{}:
      match too_big:
        case True{}:
          pure_out(Err{"the original is larger than 25 MB and cannot be forwarded whole"})
        case False{}:
          fwd_want(body_headers(body), body, args, about, jev)

# What a reply or forward answers, for the gates: the original's header
# facts, read only with Jev on.
def respond_context(jev: Jev.Switch, reply: Bool, all: Bool, m: I.Msg) -> Jev.Context:
  match jev:
    case Jev.Off{}:
      Jev.Fresh{}
    case Jev.On{c}:
      Jev.original_context(reply, all, Jev.whole_facts(m))

# Fetches the original (read-only, PEEK), then replies (mode 0) or
# forwards (mode 1).
def orig_msg(
  ms: List<&2, I.Msg>,
  +args: J.Json,
  mode: U32,
  max: U32,
  me: String,
  +jev: Jev.Switch
) -> IO(Out):
  match ms:
    case Nil{}:
      pure_out(Err{
        "no message with UID " ++ U32.show(u32_arg(args, "uid", 0)) ++ " in " ++
          folder_arg(args)})
    case +m <> t:
      I.Msg{uid, flags, date, +size, headers, body, _} = m
      +reply = U32.is_eq(mode, 0)
      respond_to(reply, U32.is_gt(size, max), size, body, args, me,
        respond_context(jev, reply, bool_arg(args, "reply_all", False{}), m), jev)

def orig_found.if(
  stale: Bool,
  lines: List<&2, I.RLine>,
  +args: J.Json,
  mode: U32,
  max: U32,
  me: String,
  jev: Jev.Switch
) -> IO(Out):
  match stale:
    case True{}:
      pure_out(Err{stale_msg()})
    case False{}:
      orig_msg(with_uid(I.fetched(lines), u32_arg(args, "uid", 0)), args, mode, max, me, jev)

# The original is used only if its folder still has the caller's
# UIDVALIDITY (checked in the same session that fetched it).
def orig_found(
  r: Run(),
  +args: J.Json,
  mode: U32,
  max: U32,
  me: String,
  jev: Jev.Switch
) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      orig_found.if(Bool.not(uidv_is(I.ok_code(lines, "UIDVALIDITY"), uidv_arg(args))), lines,
        args, mode, max, me, jev)

def respond_request(+args: J.Json) -> String:
  Bool.pick(String, U32.is_zero(u32_arg(args, "uid", 0)),
    "\"uid\" (the message to answer) is required",
    Bool.pick(String, U32.is_zero(uidv_arg(args)), uidv_missing(), ""))

def t_respond.if(
  problem: String,
  +args: J.Json,
  mode: U32,
  +max: U32,
  jev: Jev.Switch
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        me : String <- env_or("MAILBEND_EMAIL", "")
        r : Run() <- imap_run(Ops.plan_get(folder_arg(args), u32_arg(args, "uid", 0), max))
        orig_found(r, args, mode, max, me, jev)

def t_respond(+args: J.Json, +mode: U32, jev: Jev.Switch) -> IO(Out):
  t_respond.if(respond_request(args), args, mode,
    Bool.pick(U32, U32.is_eq(mode, 0), 262144, max_attachment()), jev)

# Downloading attachments
# =======================

# Download settings
# -----------------

# Where mail_get_attachment saves files (MAILBEND_DOWNLOAD_DIR), what
# mailbend-attach keeps them apart from (MAILBEND_ATTACH_DIR, "" when unset,
# and the directories of PATH, which the helper no longer sees once it has
# dropped its environment), and the helper. Only downloads read them.
type Downloads is Data:
  Downloads{dir: String, attach_dir: String, path: String, helper: String}

# MAILBEND_DOWNLOAD_DIR: an absolute path; downloads are off without it.
def download_dir(+dir: String) -> Result<&2, &2, String, String>:
  match dir:
    case SNil{}:
      Fail{"downloads are disabled: set MAILBEND_DOWNLOAD_DIR to the directory attachments " ++
        "may be saved in"}
    case SCon{'/', t}:
      Done{dir}
    case _:
      Fail{"configuration error: MAILBEND_DOWNLOAD_DIR must be an absolute path"}

def downloads_of(
  dir: String,
  attach_dir: String,
  path: String,
  helper: String
) -> Result<&2, &2, String, Downloads>:
  do Result<&2, &2, String, Downloads>:
    d : String <- download_dir(dir)
    h : String <- helper_path(helper, "MAILBEND_ATTACH_HELPER", "mailbend-attach")
    return Downloads{d, attach_dir, path, h}

def downloads() -> IO(Result<&2, &2, String, Downloads>):
  do IO<Result<&2, &2, String, Downloads>>:
    dir : String <- env_or("MAILBEND_DOWNLOAD_DIR", "")
    attach_dir : String <- env_or("MAILBEND_ATTACH_DIR", "")
    path : String <- env_or("PATH", "")
    helper : String <- env_or("MAILBEND_ATTACH_HELPER", "")
    return downloads_of(dir, attach_dir, path, helper)

# mail_get_attachment
# -------------------

# Saves one attachment of a message as a new file in MAILBEND_DOWNLOAD_DIR.
# The message is read as mail_get reads it (EXAMINE, BODY.PEEK), whole and
# within the 25 MB that attachments may take. mailbend-attach, which holds
# no credentials, writes the file unnamed and names it only once it is
# complete, never replacing an existing file.

# What mail_get_attachment is asked: where to save, the message, which of
# its attachments (from 0, in mail_get's order), the file name to save it as
# ("" for the attachment's own), and whether only to show the file.
type Download is Data:
  Download{to: Downloads, folder: String, uid: U32, index: U32, filename: String, dry: Bool}

def index_arg(m: Maybe<&2, U32>) -> Result<&2, &2, String, U32>:
  match m:
    case Some{n}:
      Done{n}
    case None{}:
      Fail{"\"index\" must be a whole number from 0: the attachment's position in mail_get"}

def download_request(
  s: Result<&2, &2, String, Downloads>,
  +args: J.Json
) -> Result<&2, &2, String, Download>:
  do Result<&2, &2, String, Download>:
    d : Downloads <- s
    uid : U32 <- single_uid(uids_arg(args), "mail_get_attachment")
    index : U32 <- index_arg(J.as_u32(J.get(args, "index")))
    return Download{d, folder_arg(args), uid, index, str_arg(args, "filename", ""), dry_arg(args)}

def whole_body.if(cut: Bool, body: String) -> Result<&2, &2, String, String>:
  match cut:
    case True{}:
      Fail{"the message is larger than 25 MB, so its attachments cannot be saved"}
    case False{}:
      Done{body}

# The fetched message's body, if it was read whole. A body that fills the
# whole fetch window may have been cut, whatever size the server reported.
def whole_body(ms: List<&2, I.Msg>, uid: U32, folder: String) -> Result<&2, &2, String, String>:
  match ms:
    case Nil{}:
      Fail{no_message(uid, folder)}
    case m <> t:
      I.Msg{id, flags, date, size, headers, +body, _} = m
      +max = max_attachment()
      whole_body.if(U32.is_gt(size, max) || U32.is_ge(C.byte_len(body), max), body)

def attachment_found(m: Maybe<&2, M.Attach>, index: U32) -> Result<&2, &2, String, M.Attach>:
  match m:
    case Some{a}:
      Done{a}
    case None{}:
      Fail{"the message has no attachment " ++ U32.show(index) ++
        " (mail_get lists them, counting from 0)"}

def save_as.put(+name: String, ctype: String, data: String) -> Result<&2, &2, String, M.Attach>:
  match name:
    case SNil{}:
      Fail{"the attachment's file name has no usable characters: pass \"filename\""}
    case _:
      Done{M.Attach{name, ctype, data}}

# The attachment under the name to save it as: `filename`, else its own
# name, made safe by M.local_name.
def save_as(a: M.Attach, +filename: String) -> Result<&2, &2, String, M.Attach>:
  M.Attach{name, ctype, data} = a
  wanted = Bool.pick(String, String.is_empty(filename), name, filename)
  save_as.put(M.local_name(wanted), ctype, data)

def file_to_save(
  r: Run(),
  +uid: U32,
  folder: String,
  +index: U32,
  filename: String
) -> Result<&2, &2, String, M.Attach>:
  do Result<&2, &2, String, M.Attach>:
    lines : List<&2, I.RLine> <- r
    body : String <- whole_body(with_uid(I.fetched(lines), uid), uid, folder)
    a : M.Attach <- attachment_found(M.attachment_at(body, index), index)
    save_as(a, filename)

def file_path(+dir: String, +name: String) -> String:
  Bool.pick(String, String.ends_with(dir, "/"), dir ++ name, dir ++ "/" ++ name)

# mailbend-attach's answer to a save, as the tool's result.
def saved_out(p: Proc, kvs: List<&2, J.Json>) -> Out:
  match p:
    case ProcOk{code, out, err}:
      match code:
        case 0:
          ok_obj(kvs)
        case _:
          Err{"cannot save the attachment: " ++ attach_msg(err)}
    case _:
      Err{"cannot run mailbend-attach: " ++ proc_failure(p)}

def download.run(d: Downloads, a: M.Attach, folder: String, uid: U32) -> IO(Out):
  Downloads{+dir, attach_dir, path, helper} = d
  M.Attach{+name, ctype, +data} = a
  do IO<Out>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run(helper, ["save", attach_dir, dir, name, U32.show(max_attachment()), path],
        data, 4096, 60000)
    return saved_out(proc_of(r), [
      J.kv("folder", J.str(folder)),
      J.kv("uid", J.num(uid)),
      J.kv("filename", J.str(name)),
      J.kv("content_type", J.str(ctype)),
      J.kv("size", J.num(C.byte_len(data))),
      J.kv("path", J.str(file_path(dir, name)))
    ])

# The file a download saves: the attachment under its name in the directory.
def download.file(d: Downloads, a: M.Attach) -> Preview:
  Downloads{dir, attach_dir, path, helper} = d
  M.Attach{name, ctype, data} = a
  FilePreview{file_path(dir, name), data}

def download.put(
  r: Result<&2, &2, String, M.Attach>,
  +d: Downloads,
  folder: String,
  uid: U32,
  dry: Bool
) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+a}:
      preview_or_run(dry, download.file(d, a), download.run(d, a, folder, uid))

def download.fetch(q: Download) -> IO(Out):
  Download{d, +folder, +uid, index, filename, dry} = q
  do IO<Out>:
    r : Run() <- imap_run(Ops.plan_get(folder, uid, max_attachment()))
    download.put(file_to_save(r, uid, folder, index, filename), d, folder, uid, dry)

def download(r: Result<&2, &2, String, Download>) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{q}:
      download.fetch(q)

def t_get_attachment(+args: J.Json) -> IO(Out):
  do IO<Out>:
    s : Result<&2, &2, String, Downloads> <- downloads()
    download(download_request(s, args))

# Classifying with Jev
# ====================

# mail_classify
# -------------

# TypeSafe's choice takes at most 255 options, and one is the none key.
def option_limit() -> U32:
  254

# The arguments of a call: the folder, its UIDs (each once, ascending) and
# the caller's candidate folder names.
type Classify is Data:
  Classify{folder: String, uids: List<&2, U32>, candidates: List<&2, String>}

def options_problem(+n: Nat) -> String:
  Bool.pick(String, Nat.is_gt(n, U32.to_nat(option_limit())),
    "Jev chooses among at most " ++ U32.show(option_limit()) ++ " folders and candidates " ++
      "(TypeSafe takes 255 options, and one is \"none\"); there are " ++ Nat.show(n),
    "")

def candidate_note(c: String, +problem: String) -> String:
  Bool.pick(String, String.is_empty(problem), "", "candidate \"" ++ c ++ "\": " ++ problem)

def raw_candidates_problem(cs: List<&2, String>) -> String:
  match cs:
    case Nil{}:
      ""
    case +c <> t:
      first_of(candidate_note(c, raw_name_problem(c)), raw_candidates_problem(t))

# The count is checked first, so an overlong list is refused before its
# names are.
def classify_candidates(+cs: List<&2, String>) -> Result<&2, &2, String, List<&2, String>>:
  do Result<&2, &2, String, List<&2, String>>:
    counted : Unit <- checked(options_problem(List.length(&2, String, cs)))
    named : Unit <- checked(raw_candidates_problem(cs))
    return cs

def classify_request(+args: J.Json) -> Result<&2, &2, String, Classify>:
  do Result<&2, &2, String, Classify>:
    uids : List<&2, U32> <- jev_uids("mail_classify", uids_arg(args))
    cands : List<&2, String> <- classify_candidates(strs_arg(args, "candidates"))
    return Classify{folder_arg(args), uids, cands}

# The folders a message can be filed in: those that can be selected and
# are none MailBend relies on, nor inside one (as for mail_label).
def category_names(+g: Guard, fs: List<&2, I.Folder>) -> List<&2, String>:
  match fs:
    case Nil{}:
      []
    case I.Folder{+name, d, attrs} <> t:
      List.filter.put(String, name, category_names(g, t),
        selectable(attrs) && Bool.not(reserved_target(g, name)))

# The category folders, sorted.
def categories(+g: Guard) -> List<&2, String>:
  List.sort(~String, ~(a => b => String.is_le(a, b)), category_names(g, guard_fs(g)))

def canonical_names(+g: Guard, cs: List<&2, String>) -> List<&2, String>:
  match cs:
    case Nil{}:
      []
    case c <> t:
      canonical_name(g, c) <> canonical_names(g, t)

# The category question holds every folder and candidate name, and must
# leave room for a message beside it in one TypeSafe request.
def room_problem(fits: Bool) -> String:
  Bool.pick(String, fits, "",
    "the folder and candidate names are too long for one TypeSafe question: pass fewer or " ++
      "shorter candidates")

# Why Jev cannot be asked with the options `opts` for the categories
# `names` ("" when it can); `more` is checked between the number of
# options and their room.
def jev_options_problem(
  c: Jev.Content,
  names: List<&2, String>,
  opts: Jev.Options,
  more: String
) -> String:
  first_of(first_of(options_problem(List.length(&2, String, names)), more),
    room_problem(Jev.leaves_room(c, opts)))

# A candidate is a folder the caller could create: each must pass the
# checks of mail_create_folder, and appear once.
def candidates_problem(+g: Guard, cs: List<&2, String>, +seen: List<&2, String>) -> String:
  match cs:
    case Nil{}:
      ""
    case +c <> t:
      first_of(
        Bool.pick(String, List.contains(~String, ~String.eq, seen, c),
          "candidate \"" ++ c ++ "\" is listed twice", candidate_note(c, target_problem(g, c))),
        candidates_problem(g, t, c <> seen))

def classify_out(
  t: Tally(),
  c: Jev.Content,
  cands: List<&2, String>,
  none: String,
  head: List<&2, J.Json>,
  not_found: List<&2, U32>
) -> Out:
  match t:
    case Fail{m}:
      Err{m}
    case Done{Progress{xs, reqs}}:
      ok_obj(List.append(&2, J.Json, head, [
        J.kv("messages",
          J.arr(Jev.answered_jsons(List.reverse(&2, Jev.Answered, xs), c, cands, none))),
        J.kv("not_found", uids_json(not_found)),
        J.kv("requests", J.arr(List.reverse(&2, J.Json, reqs)))
      ]))

# Asks Jev about the messages found, choosing among `names` (the folders,
# then the candidates) with the options `opts`.
def classify_ask(
  +c: Jev.Content,
  names: List<&2, String>,
  +opts: Jev.Options,
  cands: List<&2, String>,
  ms: List<&2, I.Msg>,
  head: List<&2, J.Json>,
  not_found: List<&2, U32>
) -> IO(Out):
  do IO<Out>:
    t : Tally() <- ask_options(Retried{}, c, fetched_list(ms, jev_max()), names, opts)
    return classify_out(t, c, cands, Jev.options_none(opts), head, not_found)

def classify_folders.if(
  problem: String,
  c: Jev.Content,
  names: List<&2, String>,
  opts: Jev.Options,
  cands: List<&2, String>,
  ms: List<&2, I.Msg>,
  head: List<&2, J.Json>,
  not_found: List<&2, U32>
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      classify_ask(c, names, opts, cands, ms, head, not_found)

# The options come from the folders LIST gave in the same session as the
# fetch; the candidates are checked against them.
def classify_folders(
  f: Fs(),
  +lines: List<&2, I.RLine>,
  folder: String,
  +uids: List<&2, U32>,
  cands: List<&2, String>,
  +c: Jev.Content
) -> IO(Out):
  match f:
    case Fail{m}:
      pure_out(Err{m})
    case Done{folders}:
      +g = guard_for(folders)
      +cats = categories(g)
      +canon = canonical_names(g, cands)
      +ms = jev_msgs(lines, uids)
      head : List<&2, J.Json> = [
        J.kv("folder", J.str(folder)),
        J.kv("uidvalidity", maybe_num(I.ok_code(lines, "UIDVALIDITY"))),
        J.kv("content", J.str(Jev.content_name(c))),
        J.kv("categories", J.strs(cats)),
        J.kv("candidates", J.strs(canon))
      ]
      +names = List.append(&2, String, cats, canon)
      +opts = Jev.options_for(Jev.Classifying{}, names)
      problem = jev_options_problem(c, names, opts, candidates_problem(g, canon, []))
      classify_folders.if(problem, c, names, opts, canon, ms, head, minus(uids, msg_uids(ms)))

def classify_found(
  r: Run(),
  folder: String,
  uids: List<&2, U32>,
  cands: List<&2, String>,
  c: Jev.Content
) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      do IO<Out>:
        f : Fs() <- folders_io(lines)
        classify_folders(f, lines, folder, uids, cands, c)

def classify_run(r: Result<&2, &2, String, Classify>, +c: Jev.Content) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{Classify{+folder, +uids, cands}}:
      do IO<Out>:
        run : Run() <- imap_run(Ops.plan_classify(folder, uids, Jev.is_body(c), jev_max()))
        classify_found(run, folder, uids, cands, c)

# mail_classify changes nothing: one session examines the folder and
# fetches the messages' facts with BODY.PEEK, and Jev's answers are
# reported, never acted on.
def t_classify(+args: J.Json, jev: Jev.Switch) -> IO(Out):
  match jev:
    case Jev.On{c}:
      classify_run(classify_request(args), c)
    case Jev.Off{}:
      pure_out(Err{jev_off("mail_classify")})

# mail_triage
# -----------

# mail_triage files messages by the filing table (Jev.filing). It reads the
# messages and the folders as mail_classify does, adds the code's own
# vetoes (Jev.code_vetoes, and a read-only search of the Sent folder for
# mail to each sender still in question), then asks Jev about every message
# before anything moves, so a failed request moves nothing. A message that
# can still be found safe to delete (Jev.may_review) is asked about in a
# request of its own, and only those answers can send it to the review
# folder; the others are asked in batches, as mail_classify asks. Just
# before the moves, the flags of the messages bound for review are read
# again, so one flagged or answered meanwhile is kept. Each message then
# moves at most once, by the proven triage plans.

# The arguments of a call: the folder, its UIDs (each once, ascending), its
# UIDVALIDITY, and whether only to show the moves.
type Triage is Data:
  Triage{folder: String, uids: List<&2, U32>, uidv: U32, dry: Bool}

# A message to triage: what Jev may see of it, the code's vetoes, and its
# sender's address while the Sent folder is still to be searched for it.
type Pending is Data:
  Pending{fetched: Jev.Fetched, vetoes: List<&2, String>, sender: Maybe<&2, String>}

# What a call has settled before asking Jev: the call, the content sent,
# the categories and their options, the role folders (which triage never
# moves into), the server's capabilities, why the review folder cannot
# take mail ("" when it can), the messages found and the UIDs not found.
type Triaging is Data:
  Triaging{
    call: Triage,
    content: Jev.Content,
    cats: List<&2, String>,
    opts: Jev.Options,
    roles: List<&2, String>,
    caps: List<&2, String>,
    review: String,
    found: List<&2, Pending>,
    not_found: List<&2, U32>
  }

# A message as filed: what Jev answered, the delete review's verdict, the
# code's vetoes, and the action filing chose.
type Filing is Data:
  Filing{
    answered: Jev.Answered,
    verdict: Jev.Verdict,
    vetoes: List<&2, String>,
    action: Jev.Action
  }

def triage_request(+args: J.Json) -> Result<&2, &2, String, Triage>:
  +uidv = uidv_arg(args)
  do Result<&2, &2, String, Triage>:
    uids : List<&2, U32> <- jev_uids("mail_triage", uids_arg(args))
    pinned : Unit <- checked(Bool.pick(String, U32.is_zero(uidv), uidv_missing(), ""))
    return Triage{folder_arg(args), uids, uidv, dry_arg(args)}

# The role folders of `f` (see role_names).
def role_folders(f: Folders) -> List<&2, String>:
  Folders{fs, drafts, trash, sent, junk, archive} = f
  role_names(fs, drafts, trash, sent, junk, archive)

# The review folder can take mail when it exists, can be selected and is
# none of the role folders `roles`. Unlike the rules under "The review
# folder", this one needs role_names, so it comes after it.
def review_problem(f: Folders, roles: List<&2, String>) -> String:
  Folders{fs, drafts, trash, sent, junk, archive} = f
  +review = Ops.review_folder()
  Bool.pick(String, Maybe.is_none(&2, String, named_folder(fs, review)),
    "it does not exist or cannot be selected: create it with mail_create_folder",
    Bool.pick(String, Ops.named_in(roles, review),
      "it is also a special folder, which MailBend never fills", ""))

def sent_of(f: Folders) -> Maybe<&2, String>:
  Folders{fs, drafts, trash, sent, junk, archive} = f
  sent

# The values of every header field `name` (lower-case), in order.
def fields_named(hs: List<&2, M.Hdr>, +name: String) -> List<&2, String>:
  match hs:
    case Nil{}:
      []
    case M.Hdr{n, v} <> t:
      List.filter.put(String, v, fields_named(t, name), String.eq(n, name))

# The address of a message's sender, when it has exactly one that reads.
def only_sender(xs: List<&2, String>) -> Maybe<&2, String>:
  match xs:
    case +a <> Nil{}:
      Bool.pick(Maybe<&2, String>, M.addr_ok(a), Some{spec_key(a)}, None{})
    case _:
      None{}

# A message with several From fields has no sender that can be told, as
# clients may show any of them.
def sender_in(froms: List<&2, String>) -> Maybe<&2, String>:
  match froms:
    case v <> Nil{}:
      only_sender(decoded(M.addr_list(v)))
    case _:
      None{}

def sender_of(m: I.Msg) -> Maybe<&2, String>:
  I.Msg{uid, flags, date, size, headers, body, structure} = m
  sender_in(fields_named(M.headers(headers), "from"))

def pending_of.put(
  f: Jev.Fetched,
  vetoes: List<&2, String>,
  sender: Maybe<&2, String>
) -> Pending:
  match sender:
    case Some{a}:
      Pending{f, vetoes, Some{a}}
    case None{}:
      Pending{f, List.append(&2, String, vetoes, Jev.correspondence_vetoes(Jev.Unverified{})),
        None{}}

def pending_of.if(ask: Bool, f: Jev.Fetched, vetoes: List<&2, String>, m: I.Msg) -> Pending:
  match ask:
    case True{}:
      pending_of.put(f, vetoes, sender_of(m))
    case False{}:
      Pending{f, vetoes, None{}}

def pending_of.text(
  c: Jev.Content,
  f: Jev.Facts,
  t: Jev.Text,
  +vetoes: List<&2, String>,
  m: I.Msg
) -> Pending:
  Jev.Text{text, +whole} = t
  pending_of.if(Jev.may_review(c, whole, vetoes), Jev.Fetched{f, Jev.Text{text, whole}}, vetoes,
    m)

# A message with its code vetoes; its sender is looked up only while it
# can still be found safe to delete.
def pending_of(c: Jev.Content, now: U32, +m: I.Msg) -> Pending:
  +f = Jev.facts_of(m)
  pending_of.text(c, f, Jev.text_of(m, jev_max()), Jev.code_vetoes(f, now), m)

def pendings(+c: Jev.Content, +now: U32, ms: List<&2, I.Msg>) -> List<&2, Pending>:
  match ms:
    case Nil{}:
      []
    case m <> t:
      pending_of(c, now, m) <> pendings(c, now, t)

def pending_uid(p: Pending) -> U32:
  Pending{Jev.Fetched{f, t}, vetoes, sender} = p
  Jev.facts_uid(f)

# The senders still in question, each once, in order.
def senders(ps: List<&2, Pending>, +seen: List<&2, String>) -> List<&2, String>:
  match ps:
    case Nil{}:
      []
    case Pending{f, vetoes, Some{+a}} <> t:
      +fresh = Bool.not(key_in(a, seen))
      List.filter.put(String, a, senders(t, Bool.pick(List<&2, String>, fresh, a <> seen, seen)),
        fresh)
    case _ <> t:
      senders(t, seen)

# What the Sent search found for a sender: None when no Sent folder is
# known, else the addresses it found mail to.
def correspondence(written: Maybe<&2, List<&2, String>>, a: String) -> Jev.Correspondence:
  match written:
    case None{}:
      Jev.Unverified{}
    case Some{ws}:
      Bool.pick(Jev.Correspondence, key_in(a, ws), Jev.Correspondent{}, Jev.Stranger{})

def settled.put(
  sender: Maybe<&2, String>,
  f: Jev.Fetched,
  vetoes: List<&2, String>,
  written: Maybe<&2, List<&2, String>>
) -> Pending:
  match sender:
    case Some{a}:
      Pending{f, List.append(&2, String, vetoes,
        Jev.correspondence_vetoes(correspondence(written, a))), None{}}
    case None{}:
      Pending{f, vetoes, None{}}

def settled(ps: List<&2, Pending>, +written: Maybe<&2, List<&2, String>>) -> List<&2, Pending>:
  match ps:
    case Nil{}:
      []
    case Pending{f, vetoes, sender} <> t:
      settled.put(sender, f, vetoes, written) <> settled(t, written)

def settle(t: Triaging, written: Maybe<&2, List<&2, String>>) -> Triaging:
  Triaging{call, c, cats, opts, roles, caps, review, found, not_found} = t
  Triaging{call, c, cats, opts, roles, caps, review, settled(found, written), not_found}

def written_to.found(rs: List<&2, I.RLine>) -> Bool:
  Bool.not(List.is_empty(&2, U32, I.search_uids(rs)))

# The senders the Sent search found mail to, in To or in Cc: tags `n` and
# `n` + 1 search for the first of `addrs` (see plan_sent_search).
def written_to(addrs: List<&2, String>, +lines: List<&2, I.RLine>, +n: U32) -> List<&2, String>:
  match addrs:
    case Nil{}:
      []
    case a <> t:
      List.filter.put(String, a, written_to(t, lines, (n + 2 : U32)),
        written_to.found(I.replies(lines, n)) || written_to.found(I.replies(lines, (n + 1 : U32))))

# Whether a message is asked about in a request of its own.
def asked_alone(c: Jev.Content, p: Pending) -> Bool:
  Pending{Jev.Fetched{f, Jev.Text{text, whole}}, vetoes, sender} = p
  Jev.may_review(c, whole, vetoes)

# The messages asked about together (`alone` False) or one per request.
def asked_messages(+c: Jev.Content, ps: List<&2, Pending>, +alone: Bool)
  -> List<&2, Jev.Fetched>:
  match ps:
    case Nil{}:
      []
    case +p <> t:
      Pending{f, vetoes, sender} = p
      List.filter.put(Jev.Fetched, f, asked_messages(c, t, alone),
        Bool.not(Bool.xor(asked_alone(c, p), alone)))

def requests_alone(+c: Jev.Content, fs: List<&2, Jev.Fetched>, +opts: Jev.Options)
  -> List<&2, Jev.Step>:
  match fs:
    case Nil{}:
      []
    case f <> t:
      List.append(&2, Jev.Step, Jev.requests(c, [f], opts), requests_alone(c, t, opts))

# The code's vetoes of the message `uid`; a message the call did not check
# (which does not happen) counts as vetoed.
def vetoes_of(ps: List<&2, Pending>, +uid: U32) -> List<&2, String>:
  match ps:
    case Nil{}:
      ["it was not checked"]
    case +p <> t:
      Pending{f, vetoes, sender} = p
      Bool.pick(List<&2, String>, U32.is_eq(pending_uid(p), uid), vetoes, vetoes_of(t, uid))

def rechecked.put(ms: List<&2, I.Msg>, p: Pending) -> Pending:
  match ms:
    case Nil{}:
      p
    case I.Msg{uid, flags, date, size, headers, body, structure} <> t:
      Pending{f, vetoes, sender} = p
      Pending{f, List.append(&2, String, vetoes, Jev.flag_vetoes(flags)), sender}

# The messages with the vetoes of the flags read again (`ms`, the messages
# bound for review): one flagged or answered since the first read is kept.
def rechecked(ps: List<&2, Pending>, +ms: List<&2, I.Msg>) -> List<&2, Pending>:
  match ps:
    case Nil{}:
      []
    case +p <> t:
      rechecked.put(with_uid(ms, pending_uid(p)), p) <> rechecked(t, ms)

def filing_of(+x: Jev.Answered, c: Jev.Content, none: String, found: List<&2, Pending>)
  -> Filing:
  +f = Jev.answered_facts(x)
  +vetoes = vetoes_of(found, Jev.facts_uid(f))
  +a = Jev.answers_of(x)
  +v = Jev.verdict(c, Jev.facts_body(f), vetoes, a)
  Filing{x, v, vetoes, Jev.filing(v, Jev.category_of(Jev.answers_category(a), [], none))}

def answered_uid(x: Jev.Answered) -> U32:
  Jev.facts_uid(Jev.answered_facts(x))

def filings(
  xs: List<&2, Jev.Answered>,
  +c: Jev.Content,
  +none: String,
  +found: List<&2, Pending>
) -> List<&2, Filing>:
  match xs:
    case Nil{}:
      []
    case x <> t:
      filing_of(x, c, none, found) <> filings(t, c, none, found)

def placements(fs: List<&2, Filing>) -> List<&2, Ops.Placement>:
  match fs:
    case Nil{}:
      []
    case Filing{x, v, vetoes, action} <> t:
      Ops.Placement{answered_uid(x), action} <> placements(t)

# The UIDs filing sends to review.
def to_review(fs: List<&2, Filing>) -> List<&2, U32>:
  match fs:
    case Nil{}:
      []
    case Filing{x, v, vetoes, Jev.ToReview{}} <> t:
      answered_uid(x) <> to_review(t)
    case _ <> t:
      to_review(t)

def filing_jsons(
  fs: List<&2, Filing>,
  +c: Jev.Content,
  +none: String,
  +folder: String
) -> List<&2, J.Json>:
  match fs:
    case Nil{}:
      []
    case Filing{x, v, vetoes, action} <> t:
      J.obj(Jev.answered_kvs(x, c, [], none, [
        J.kv("verdict", J.str(Jev.verdict_name(v))),
        J.kv("vetoes", J.strs(vetoes)),
        J.kv("destination", maybe_str(Ops.destination(folder, action)))
      ])) <> filing_jsons(t, c, none, folder)

def uids_text(xs: List<&2, U32>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case x <> t:
      ("UID " ++ U32.show(x)) <> uids_text(t)

def review_needed_problem.if(fine: Bool, uids: List<&2, U32>, review: String) -> String:
  match fine:
    case True{}:
      ""
    case False{}:
      "Jev found " ++ String.join(uids_text(uids), ", ") ++ " safe to delete, but \"" ++
        Ops.review_folder() ++ "\" cannot take them: " ++ review

# Why the messages sent to review (`uids`) cannot go there: `review`, why
# the review folder cannot take mail.
def review_needed_problem(+uids: List<&2, U32>, +review: String) -> String:
  review_needed_problem.if(List.is_empty(&2, U32, uids) || String.is_empty(review), uids, review)

# The moves need MOVE or UIDPLUS (see plan_move), and the plan's own check
# of them must pass, which leaves no plan at all when it fails.
def moves_problem(+moving: Bool, move: Bool, uidplus: Bool, planned: Bool) -> String:
  Bool.pick(String, moving && Bool.not(move || uidplus), no_move_problem(),
    Bool.pick(String, moving && Bool.not(planned),
      "the moves failed the triage plan's own check", ""))

# Where the moves stand: the result of each move made so far (newest
# first), and whether one did not finish, which stops the rest.
type Moved is Data:
  Moved{results: List<&2, J.Json>, stopped: Bool}

def moved_error(dest: String, m: String) -> J.Json:
  J.obj([J.kv("ok", J.bool(False{})), J.kv("destination", J.str(dest)), J.kv("error", J.str(m))])

def moved_add(o: Out, dest: String, results: List<&2, J.Json>) -> Moved:
  match o:
    case Ok{j}:
      Moved{j <> results, False{}}
    case Err{m}:
      Moved{moved_error(dest, m) <> results, True{}}
    case Partial{j}:
      Moved{j <> results, True{}}

# One move, unless an earlier one did not finish.
def triage_moving.step(
  m: Ops.FolderUids,
  p: List<&2, I.Cmd>,
  folder: String,
  move: Bool,
  s: Moved
) -> IO(Moved):
  Ops.FolderUids{+dest, uids} = m
  match s:
    case Moved{results, True{}}:
      IO.pure(Moved, Moved{results, True{}})
    case Moved{results, False{}}:
      do IO<Moved>:
        o : Out <- move_plan.run(p, folder, uids, dest, move)
        return moved_add(o, dest, results)

# Runs each move's plan in turn, each in a session of its own.
def triage_moving(
  ms: List<&2, Ops.FolderUids>,
  ps: List<&2, List<&2, I.Cmd>>,
  +folder: String,
  +move: Bool,
  s: Moved
) -> IO(Moved):
  match ms:
    case Nil{}:
      IO.pure(Moved, s)
    case m <> mt:
      match ps:
        case Nil{}:
          IO.pure(Moved, s)
        case p <> pt:
          do IO<Moved>:
            next : Moved <- triage_moving.step(m, p, folder, move, s)
            triage_moving(mt, pt, folder, move, next)

# The moves' result. A move that did not finish stopped the rest: those
# before it are done, so the call is partial.
def triage_result(s: Moved) -> Out:
  match s:
    case Moved{results, False{}}:
      ok_obj([J.kv("moves", J.arr(List.reverse(&2, J.Json, results)))])
    case Moved{results, True{}}:
      Partial{J.obj([
        J.kv("ok", J.bool(False{})),
        J.kv("partial", J.bool(True{})),
        J.kv("message", J.str("a move did not finish, so the moves after it were not made; " ++
          "see moves, and check its destination before running mail_triage again")),
        J.kv("moves", J.arr(List.reverse(&2, J.Json, results)))
      ])}

def triage_filed.run(
  ms: List<&2, Ops.FolderUids>,
  ps: List<&2, List<&2, I.Cmd>>,
  folder: String,
  move: Bool
) -> IO(Out):
  do IO<Out>:
    s : Moved <- triage_moving(ms, ps, folder, move, Moved{[], False{}})
    return triage_result(s)

# The call's own fields come first in its result. A refusal still reports
# them, every message's verdict and destination included, though nothing
# moved.
def triage_filed.if(
  problem: String,
  kvs: List<&2, J.Json>,
  dry: Bool,
  ms: List<&2, Ops.FolderUids>,
  +plans: List<&2, List<&2, I.Cmd>>,
  folder: String,
  move: Bool
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(with_fields_first(Partial{J.obj([
        J.kv("ok", J.bool(False{})),
        J.kv("error", J.str(SCon{h, t} ++ "; nothing was moved"))
      ])}, kvs))
    case SNil{}:
      do IO<Out>:
        o : Out <- preview_or_run(dry, ImapPlans{plans}, triage_filed.run(ms, plans, folder, move))
        return with_fields_first(o, kvs)

# Files the messages Jev answered about (`xs`, in UID order), with the
# vetoes of the flags read again (`reread`): the review folder must be able
# to take any message sent to review, and the server must be able to move.
def triage_filed(
  xs: List<&2, Jev.Answered>,
  reqs: List<&2, J.Json>,
  reread: List<&2, I.Msg>,
  t: Triaging
) -> IO(Out):
  Triaging{Triage{+folder, uids, +uidv, dry}, +c, +cats, opts, roles, +caps, review, found,
    not_found} = t
  Jev.Options{purpose, json, +none} = opts
  +fs = filings(xs, c, none, rechecked(found, reread))
  +moves = Ops.triage_moves(folder, placements(fs))
  +move = I.has_cap(caps, "MOVE")
  +uidplus = I.has_cap(caps, "UIDPLUS")
  +plans = Ops.plan_triage(folder, cats, roles, moves, move, uidplus, uidv)
  kvs : List<&2, J.Json> = [
    J.kv("folder", J.str(folder)),
    J.kv("uidvalidity", J.num(uidv)),
    J.kv("content", J.str(Jev.content_name(c))),
    J.kv("categories", J.strs(cats)),
    J.kv("messages", J.arr(filing_jsons(fs, c, none, folder))),
    J.kv("not_found", uids_json(not_found)),
    J.kv("requests", J.arr(List.reverse(&2, J.Json, reqs)))
  ]
  problem = first_of(review_needed_problem(to_review(fs), review),
    moves_problem(Bool.not(List.is_empty(&2, Ops.FolderUids, moves)), move, uidplus,
      Bool.not(List.is_empty(&2, List<&2, I.Cmd>, plans))))
  triage_filed.if(problem, kvs, dry, moves, plans, folder, move)

def triage_reread(r: Run(), xs: List<&2, Jev.Answered>, reqs: List<&2, J.Json>, t: Triaging)
  -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{"cannot read the flags of the messages for review again (" ++ m ++
        "); nothing was moved"})
    case Done{lines}:
      triage_filed(xs, reqs, I.flag_fetches(lines), t)

def triage_review.if(
  skip: Bool,
  folder: String,
  uids: List<&2, U32>,
  xs: List<&2, Jev.Answered>,
  reqs: List<&2, J.Json>,
  t: Triaging
) -> IO(Out):
  match skip:
    case True{}:
      triage_filed(xs, reqs, [], t)
    case False{}:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_reread_flags(folder, uids))
        triage_reread(r, xs, reqs, t)

# Reads the flags of the messages bound for review again, in a short
# read-only session of their own just before the moves; there is nothing to
# read when none is, or when the review folder cannot take them (the call
# is then refused).
def triage_review(+xs: List<&2, Jev.Answered>, reqs: List<&2, J.Json>, +t: Triaging)
  -> IO(Out):
  Triaging{Triage{folder, uids, uidv, dry}, c, cats, Jev.Options{p, json, none}, roles, caps,
    review, found, not_found} = t
  +bound = to_review(filings(xs, c, none, found))
  triage_review.if(List.is_empty(&2, U32, bound) || Bool.not(String.is_empty(review)), folder,
    bound, xs, reqs, t)

def triage_answered(r: Tally(), t: Triaging) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m ++ "; nothing was moved"})
    case Done{Progress{xs, reqs}}:
      triage_review(List.sort(~Jev.Answered,
        ~(a => b => U32.is_le(answered_uid(a), answered_uid(b))), xs), reqs, t)

# Asks Jev about every message: those that can still be found safe to
# delete one per request, the others in batches.
def triage_ask(+t: Triaging) -> IO(Out):
  Triaging{call, +c, cats, +opts, roles, caps, review, +found, not_found} = t
  steps : List<&2, Jev.Step> = List.append(&2, Jev.Step,
    Jev.requests(c, asked_messages(c, found, False{}), opts),
    requests_alone(c, asked_messages(c, found, True{}), opts))
  do IO<Out>:
    r : Tally() <- ask_all(Retried{}, steps,
      List.append(&2, String, cats, [Jev.options_none(opts)]))
    triage_answered(r, t)

def triage_written(r: Run(), addrs: List<&2, String>, t: Triaging) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{"cannot search the Sent folder for mail to the senders (" ++ m ++
        "); nothing was moved"})
    case Done{lines}:
      triage_ask(settle(t, Some{written_to(addrs, lines, 2)}))

def triage_sent.put(sent: Maybe<&2, String>, +addrs: List<&2, String>, t: Triaging) -> IO(Out):
  match sent:
    case None{}:
      triage_ask(settle(t, None{}))
    case Some{box}:
      do IO<Out>:
        r : Run() <- imap_run(Ops.plan_sent_search(box, addrs))
        triage_written(r, addrs, t)

def triage_sent.if(
  no_senders: Bool,
  sent: Maybe<&2, String>,
  addrs: List<&2, String>,
  t: Triaging
) -> IO(Out):
  match no_senders:
    case True{}:
      triage_ask(t)
    case False{}:
      triage_sent.put(sent, addrs, t)

# Searches the Sent folder, read-only, for mail to each sender still in
# question; without a known Sent folder, whether the user wrote to them
# cannot be told, which vetoes the review.
def triage_sent(+t: Triaging, sent: Maybe<&2, String>) -> IO(Out):
  Triaging{call, c, cats, opts, roles, caps, review, found, not_found} = t
  +addrs = senders(found, [])
  triage_sent.if(List.is_empty(&2, String, addrs), sent, addrs, t)

def triage_folders.if(
  problem: String,
  +folders: Folders,
  +lines: List<&2, I.RLine>,
  +call: Triage,
  +c: Jev.Content,
  now: U32,
  cats: List<&2, String>,
  opts: Jev.Options
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      Triage{folder, +uids, uidv, dry} = call
      +ms = jev_msgs(lines, uids)
      +roles = role_folders(folders)
      triage_sent(Triaging{call, c, cats, opts, roles, I.caps(lines),
        review_problem(folders, roles), pendings(c, now, ms), minus(uids, msg_uids(ms))},
        sent_of(folders))

# The categories come from the folders LIST gave in the same session as the
# fetch, as for mail_classify; triage takes no candidates.
def triage_folders(f: Fs(), lines: List<&2, I.RLine>, +call: Triage, +c: Jev.Content, now: U32)
  -> IO(Out):
  match f:
    case Fail{m}:
      pure_out(Err{m ++ "; nothing was moved"})
    case Done{+folders}:
      Triage{folder, uids, uidv, dry} = call
      +g = guard_for(folders)
      +cats = categories(g)
      +opts = Jev.options_for(Jev.Classifying{}, cats)
      problem = first_of(source_review_problem(guard_delim(g), folder),
        jev_options_problem(c, cats, opts, ""))
      triage_folders.if(problem, folders, lines, call, c, now, cats, opts)

def triage_found.if(problem: String, +lines: List<&2, I.RLine>, call: Triage, c: Jev.Content)
  -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      do IO<Out>:
        f : Fs() <- folders_io(lines)
        now : U32 <- now_seconds()
        triage_folders(f, lines, call, c, now)

def triage_found(r: Run(), call: Triage, c: Jev.Content) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{+lines}:
      Triage{folder, uids, +uidv, dry} = call
      triage_found.if(uidv_problem(lines, uidv), lines, Triage{folder, uids, uidv, dry}, c)

def triage_run(r: Result<&2, &2, String, Triage>, +c: Jev.Content) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(Err{m})
    case Done{Triage{+folder, +uids, uidv, dry}}:
      do IO<Out>:
        run : Run() <- imap_run(Ops.plan_classify(folder, uids, Jev.is_body(c), jev_max()))
        triage_found(run, Triage{folder, uids, uidv, dry}, c)

# mail_triage reads like mail_classify (EXAMINE, BODY.PEEK) and then only
# moves, each message at most once, through Ops.plan_triage.
def t_triage(args: J.Json, jev: Jev.Switch) -> IO(Out):
  match jev:
    case Jev.On{c}:
      triage_run(triage_request(args), c)
    case Jev.Off{}:
      pure_out(Err{jev_off("mail_triage")})

# Read annotations
# ================

# With Jev on, mail_get, mail_search, mail_get_new and mail_get_thread add a
# jev object to each message they show, once it has been read (see Jev's
# Annotations). A list read asks in headers mode, numbering its messages by
# position, since a thread's may come from several folders and share UIDs;
# mail_get asks with the configured content. The category options are the
# folders, as for mail_classify, read in a session of their own. Whatever
# fails, the read's result is still returned, its messages unchecked.

# A read to annotate: its result's fields, whether they list the messages
# (else they are the one message read whole), the content Jev is asked
# with, and the messages as Jev may see them.
type Annotation is Data:
  Annotation{fields: J.Json, listed: Bool, content: Jev.Content, msgs: List<&2, Jev.Fetched>}

# The messages of a list read in headers mode, numbered from `n`.
def listed_fetched(ms: List<&2, I.Msg>, +n: U32) -> List<&2, Jev.Fetched>:
  match ms:
    case Nil{}:
      []
    case m <> t:
      Jev.Fetched{Jev.numbered(Jev.facts_of(m), n), Jev.Text{"", Jev.Complete{}}} <>
        listed_fetched(t, (n + 1 : U32))

# The message mail_get read whole; its text only in body mode.
def whole_fetched(c: Jev.Content, +m: I.Msg, max: U32) -> Jev.Fetched:
  match c:
    case Jev.Headers{}:
      Jev.Fetched{Jev.whole_facts(m), Jev.Text{"", Jev.Complete{}}}
    case Jev.Body{}:
      Jev.Fetched{Jev.whole_facts(m), Jev.text_of(m, max)}

def with_jev(item: J.Json, j: J.Json) -> J.Json:
  match item:
    case J.JObj{kvs}:
      J.JObj{J.chain(List.append(&2, J.Json, J.unchain(kvs), [J.kv("jev", j)]))}
    case _:
      item

# Each item with the next jev object.
def jev_items(items: List<&2, J.Json>, js: List<&2, J.Json>) -> List<&2, J.Json>:
  match items:
    case Nil{}:
      []
    case i <> t:
      match js:
        case Nil{}:
          i <> t
        case j <> u:
          with_jev(i, j) <> jev_items(t, u)

def messages_jevs.if(messages: Bool, k: String, items: J.Json, js: List<&2, J.Json>) -> J.Json:
  match messages:
    case True{}:
      J.kv(k, J.JArr{J.chain(jev_items(J.unchain(items), js))})
    case False{}:
      J.kv(k, J.JArr{items})

# A result's fields, with the jev objects `js` added in order to the items
# of its "messages" list.
def messages_jevs(kvs: List<&2, J.Json>, +js: List<&2, J.Json>) -> List<&2, J.Json>:
  match kvs:
    case Nil{}:
      []
    case J.JKv{+k, J.JArr{items}} <> t:
      messages_jevs.if(String.eq(k, "messages"), k, items, js) <> messages_jevs(t, js)
    case kv <> t:
      kv <> messages_jevs(t, js)

def jev_field(js: List<&2, J.Json>) -> List<&2, J.Json>:
  match js:
    case Nil{}:
      []
    case j <> t:
      [J.kv("jev", j)]

# The read's result with the jev objects `js` of the messages it shows.
def annotation_out(a: Annotation, js: List<&2, J.Json>) -> Out:
  Annotation{fields, listed, c, ms} = a
  match listed:
    case True{}:
      Ok{J.JObj{J.chain(messages_jevs(J.unchain(fields), js))}}
    case False{}:
      with_fields(Ok{J.JObj{fields}}, jev_field(js))

def unchecked_jsons(n: Nat, +c: Jev.Content, +reason: String) -> List<&2, J.Json>:
  match n:
    case 0n:
      []
    case 1n+k:
      Jev.unchecked_json(c, reason) <> unchecked_jsons(k, c, reason)

# Every message of the read unchecked, and why.
def annotation_unchecked(+a: Annotation, reason: String) -> Out:
  Annotation{fields, listed, c, ms} = a
  annotation_out(a, unchecked_jsons(List.length(&2, Jev.Fetched, ms), c, reason))

def annotation_answered(t: Tally(), none: String, +a: Annotation) -> Out:
  match t:
    case Fail{m}:
      annotation_unchecked(a, m)
    case Done{Progress{xs, reqs}}:
      Annotation{fields, listed, c, ms} = a
      annotation_out(a, Jev.annotation_jsons(List.reverse(&2, Jev.Answered, xs), c, none))

# Asks once, so a hung TypeSafe holds the read up for one timeout only.
def annotate.run(
  problem: String,
  names: List<&2, String>,
  +opts: Jev.Options,
  +a: Annotation
) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(annotation_unchecked(a, SCon{h, t}))
    case SNil{}:
      Annotation{fields, listed, c, ms} = a
      do IO<Out>:
        t : Tally() <- ask_options(Once{}, c, ms, names, opts)
        return annotation_answered(t, Jev.options_none(opts), a)

def annotate.ask(f: Fs(), +a: Annotation) -> IO(Out):
  match f:
    case Fail{m}:
      pure_out(annotation_unchecked(a, m))
    case Done{folders}:
      Annotation{fields, listed, c, ms} = a
      +names = categories(guard_for(folders))
      +opts = Jev.options_for(Jev.Annotating{}, names)
      annotate.run(jev_options_problem(c, names, opts, ""), names, opts, a)

def annotate.folders(r: Run(), a: Annotation) -> IO(Out):
  match r:
    case Fail{m}:
      pure_out(annotation_unchecked(a, m))
    case Done{lines}:
      do IO<Out>:
        f : Fs() <- folders_io(lines)
        annotate.ask(f, a)

# The categories come from the folders, listed in a session of their own.
def annotate.list(a: Annotation) -> IO(Out):
  do IO<Out>:
    r : Run() <- imap_run(Ops.plan_folders())
    annotate.folders(r, a)

# A read's result, annotated with Jev on when it shows any message. A
# thread read has listed the folders already.
def annotate(jev: Jev.Switch, s: Shown) -> IO(Out):
  match jev s:
    case Jev.On{c} Listed{Ok{J.JObj{fields}}, m <> t}:
      annotate.list(Annotation{fields, True{}, Jev.Headers{}, listed_fetched(m <> t, 1)})
    case Jev.On{c} Threaded{Ok{J.JObj{fields}}, m <> t, folders}:
      annotate.ask(Done{folders},
        Annotation{fields, True{}, Jev.Headers{}, listed_fetched(m <> t, 1)})
    case Jev.On{+c} Whole{Ok{J.JObj{fields}}, m, max}:
      annotate.list(Annotation{fields, False{}, c, [whole_fetched(c, m, max)]})
    case _ Listed{o, ms}:
      pure_out(o)
    case _ Threaded{o, ms, folders}:
      pure_out(o)
    case _ Whole{o, m, max}:
      pure_out(o)

def annotated(jev: Jev.Switch, read: IO(Shown)) -> IO(Out):
  do IO<Out>:
    s : Shown <- read
    annotate(jev, s)

# Dispatch
# ========

# Running a tool
# --------------

def run_op(op: Ops.Op, args: J.Json, jev: Jev.Switch) -> IO(Out):
  match op:
    case Ops.OProbe{}:
      t_probe(args)
    case Ops.OListFolders{}:
      t_folders(args)
    case Ops.OSearch{}:
      annotated(jev, t_search(args))
    case Ops.OGet{}:
      annotated(jev, t_get(args))
    case Ops.OGetNew{}:
      annotated(jev, t_get_new(args))
    case Ops.OGetThread{}:
      annotated(jev, t_get_thread(args))
    case Ops.OClassify{}:
      t_classify(args, jev)
    case Ops.OTriage{}:
      t_triage(args, jev)
    case Ops.OGetAttachment{}:
      t_get_attachment(args)
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
      t_delete(args, jev)
    case Ops.OCreateFolder{}:
      t_create_folder(args)
    case Ops.ORenameFolder{}:
      t_rename_folder(args)
    case Ops.OSaveDraft{}:
      t_compose(args, True{}, jev)
    case Ops.OSend{}:
      t_compose(args, False{}, jev)
    case Ops.OReply{}:
      t_respond(args, 0, jev)
    case Ops.OForward{}:
      t_respond(args, 1, jev)

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

def gated.if(problem: String, op: Ops.Op, args: J.Json, jev: Jev.Switch) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{SCon{h, t}})
    case SNil{}:
      run_op(op, args, jev)

def gated(+op: Ops.Op, +args: J.Json, c: Config) -> IO(Out):
  match c:
    case Config{ro, drafts, +jev}:
      gated.if(refusal(op, args, ro, drafts, Jev.is_on(jev)), op, args, jev)
    case ConfigBad{msg}:
      pure_out(Err{"configuration error: " ++ msg})

def call_op(m: Maybe<&2, Ops.Op>, name: String, args: J.Json) -> IO(Out):
  match m:
    case None{}:
      pure_out(Err{"unknown tool: " ++ name})
    case Some{op}:
      do IO<Out>:
        c : Config <- config()
        gated(op, args, c)

# The tools offered
# -----------------

# The configuration decides the tools listed (Ops.listed_names): read-only
# mode lists only the read-only tools, also when a switch is misconfigured,
# since every call then fails; drafts-only mode hides mail_send; the Jev
# tools need Jev on. Hidden tools are refused anyway if called.

def offered_items.if(keep: Bool, t: J.Json, rest: J.Json) -> J.Json:
  match keep:
    case True{}:
      J.JCons{t, rest}
    case False{}:
      rest

def offered_items(ts: J.Json, +names: List<&2, String>) -> J.Json:
  match ts:
    case J.JCons{+t, rest}:
      offered_items.if(key_in(str_arg(t, "name", ""), names), t, offered_items(rest, names))
    case _:
      J.JEnd{}

# The tool definitions in `ts` (a JSON array) named in `names`.
def offered_in(ts: J.Json, names: List<&2, String>) -> J.Json:
  match ts:
    case J.JArr{xs}:
      J.JArr{offered_items(xs, names)}
    case _:
      ts

def offered_for(ts: J.Json, c: Config) -> J.Json:
  match c:
    case Config{ro, drafts, jev}:
      offered_in(ts, Ops.listed_names(Ops.all_ops(), ro, drafts, Jev.is_on(jev)))
    case ConfigBad{msg}:
      offered_in(ts, Ops.listed_names(Ops.all_ops(), True{}, False{}, False{}))

# The tool definitions `ts` (a JSON array) that this configuration offers.
def offered_tools(ts: J.Json) -> IO(J.Json):
  do IO<J.Json>:
    c : Config <- config()
    return offered_for(ts, c)

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

def key_count(kvs: J.Json, +key: String) -> U32:
  match kvs:
    case J.JCons{J.JKv{k, v}, t}:
      (Bool.pick(U32, String.eq(k, key), 1, 0) + key_count(t, key) : U32)
    case J.JCons{v, t}:
      key_count(t, key)
    case _:
      0

def repeat_problem.go(names: J.Json, +kvs: J.Json) -> String:
  match names:
    case J.JCons{J.JKv{+k, v}, t}:
      first_of(Bool.pick(String, U32.is_gt(key_count(kvs, k), 1),
        "\"" ++ k ++ "\" is given more than once", ""), repeat_problem.go(t, kvs))
    case _:
      ""

# The first property that more than one argument names. MailBend reads the
# first of repeated members, but many JSON libraries keep the last, so a
# client could read `"dry_run": false, "dry_run": true` as a dry run that
# MailBend would run for real. Only the properties are counted, which keeps
# the work linear in the arguments; an unknown name is refused before this.
def repeat_problem(props: J.Json, kvs: J.Json) -> String:
  match props:
    case J.JObj{names}:
      repeat_problem.go(names, kvs)
    case _:
      ""

def args_obj_problem(args: J.Json, +input: J.Json, +tool: String) -> String:
  match args:
    case J.JObj{+kvs}:
      +props = object_field(input, "properties")
      first_of(args_problem(props, kvs, tool),
        first_of(repeat_problem(props, kvs),
          first_of(missing_problem(array_items(J.get(input, "required")), kvs),
            att_check(J.find(kvs, "attachments"), props, tool))))
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
