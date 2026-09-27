import Base
import ./codec.bend as C
import ./json.bend as J
import ./imap.bend as I
import ./mime.bend as M
import ./smtp.bend as S
import ./ops.bend as Ops

# The mail tools: JSON arguments in, JSON results out. IMAP work goes
# through the plans in ops.bend and the TLS helper; this module never reads
# MAILBEND_APP_PASSWORD (only the helper does), so no tool result can hold it.

type Out is Data:
  Ok{j: J.Json}
  Err{msg: String}

# ---- the TLS helper --------------------------------------------------------------------

type Proc is Data:
  ProcOk{code: U32, out: String, err: String}
  ProcFail{msg: String}

type Run is Data:
  RunOk{lines: List<&2, I.RLine>}
  RunErr{msg: String}

type Uids is Data:
  UidsOk{uids: List<&2, U32>}
  UidsErr{msg: String}

# ---- mail_search ----------------------------------------------------------------------------

type Keys is Data:
  KeysOk{keys: List<&2, I.Key>}
  KeysErr{msg: String}

type DateKey is Data:
  DateOk{keys: List<&2, I.Key>}
  DateBad{msg: String}

# ---- composing: attachments, stamps ----------------------------------------------------------

type AttR is Data:
  AttOk{a: M.Attach}
  AttErr{msg: String}

type Atts is Data:
  AttsOk{xs: List<&2, M.Attach>}
  AttsErr{msg: String}

# A date, a unique token (for Message-ID and the MIME boundary).
type Stamp is Data:
  Stamp{date: String, token: String}

# ---- composing: send or save as draft ------------------------------------------------------

# What the tools want composed; Bcc goes only into the SMTP envelope.
type Want is Data:
  Want{to: List<&2, String>, cc: List<&2, String>, bcc: List<&2, String>, subject: String, text: String, irt: String, refs: String, atts: List<&2, M.Attach>, draft: Bool}

# ---- environment -------------------------------------------------------------------

def env_pick(r: Result<&1, &1, U32 & String, String>, +d: String) -> String:
  match r:
    case Done{+v}:
      Bool.pick(String, String.is_empty(v), d, v)
    case Fail{e}:
      d

def env_or(+name: String, +d: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return env_pick(r, d)

def truthy(+v: String) -> Bool:
  String.eq(v, "1") || String.eq(String.to_lower(v), "true")

# MAILBEND_READ_ONLY=1 refuses every tool that could change the mailbox or
# send mail, for trying MailBend safely against a real account.
def read_only_mode() -> IO(Bool):
  do IO<Bool>:
    v : String <- env_or("MAILBEND_READ_ONLY", "")
    return truthy(v)

def proc_of(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> Proc:
  match r:
    case Done{(code, (out, err))}:
      ProcOk{code, out, err}
    case Fail{(code, msg)}:
      ProcFail{msg}

def run_helper(+path: String, +mode: String, +input: String) -> IO(Proc):
  do IO<Proc>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(path, [mode], input, 134217728, 300000)
    return proc_of(r)

# The helper gets the password through the environment, so it is only ever
# started from an absolute MAILBEND_TLS_HELPER path (scripts/mailbend sets
# it), never from a path relative to the working directory.
def helper_at(+path: String, +mode: String, +input: String) -> IO(Proc):
  match path:
    case SCon{'/', t}:
      run_helper(path, mode, input)
    case _:
      IO.pure(Proc, ProcFail{"MAILBEND_TLS_HELPER must be the absolute path of mailbend-tls (scripts/mailbend sets it)"})

def helper(+mode: String, +input: String) -> IO(Proc):
  do IO<Proc>:
    path : String <- env_or("MAILBEND_TLS_HELPER", "")
    helper_at(path, mode, input)

def strip_prefix(+s: String, +p: String) -> String:
  Bool.pick(String, String.starts_with(s, p), String.drop(s, String.length(p)), s)

# The helper's own message (its stderr never holds credentials).
def helper_msg(+err: String) -> String:
  strip_prefix(String.trim(String.join(List.reverse(&2, String, String.lines(String.trim(err))), " | ")), "mailbend-tls: ")

def helper_error(+code: U32, +err: String) -> String:
  Bool.pick(String, U32.is_eq(code, 2), "configuration error: ",
    Bool.pick(String, U32.is_eq(code, 3), "connection or TLS verification failed: ",
      Bool.pick(String, U32.is_eq(code, 4), "authentication failed (check MAILBEND_EMAIL and the app-specific password): ",
        "mail server error: "))) ++ helper_msg(err)

def stale_msg() -> String:
  "the folder's UIDVALIDITY changed since these UIDs were read, so they may name other messages; nothing was changed: search again"

def imap_code(+code: U32, +lines: List<&2, I.RLine>, +err: String) -> Run:
  Bool.pick(Run, U32.is_zero(code), RunOk{lines},
    Bool.pick(Run, U32.is_eq(code, 5) && String.contains(err, "[UIDVALIDITY "), RunErr{stale_msg()},
      Bool.pick(Run, U32.is_eq(code, 5), RunErr{"the server rejected a command: " ++ String.trim(I.first_failure(lines))},
        RunErr{helper_error(code, err)})))

def imap_result(p: Proc) -> Run:
  match p:
    case ProcFail{m}:
      RunErr{"cannot run the TLS helper: " ++ m}
    case ProcOk{code, out, err}:
      imap_code(code, I.frame(out), err)

# Runs one IMAP session: the helper logs in, runs the plan, logs out.
def imap_run(+cmds: List<&2, I.Cmd>) -> IO(Run):
  do IO<Run>:
    p : Proc <- helper("imap", I.script(cmds))
    return imap_result(p)

def smtp_code(+code: U32, +out: String, +err: String) -> Out:
  Bool.pick(Out, U32.is_zero(code), Ok{J.str(S.last_ok(String.lines(out), ""))},
    Bool.pick(Out, U32.is_eq(code, 5), Err{"the SMTP server refused the message: " ++ S.last_error(String.lines(out), "")},
      Err{helper_error(code, err)}))

def smtp_result(p: Proc) -> Out:
  match p:
    case ProcFail{m}:
      Err{"cannot run the TLS helper: " ++ m}
    case ProcOk{code, out, err}:
      smtp_code(code, out, err)

def smtp_run(+envelope: String) -> IO(Out):
  do IO<Out>:
    p : Proc <- helper("smtp", envelope)
    return smtp_result(p)

# ---- arguments ---------------------------------------------------------------------------

def str_arg(+args: J.Json, +key: String, +d: String) -> String:
  Maybe.default(&2, String, J.as_str(J.get(args, key)), d)

def bool_arg(+args: J.Json, +key: String, +d: Bool) -> Bool:
  Maybe.default(&2, Bool, J.as_bool(J.get(args, key)), d)

def u32_arg(+args: J.Json, +key: String, +d: U32) -> U32:
  Maybe.default(&2, U32, J.as_u32(J.get(args, key)), d)

def folder_arg(+args: J.Json) -> String:
  str_arg(args, "folder", "INBOX")

def clamp(+n: U32, +lo: U32, +hi: U32) -> U32:
  U32.max(lo, U32.min(n, hi))

def json_strs(+xs: List<&2, J.Json>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{J.JStr{s}, t}:
      s <> json_strs(t)
    case Con{x, t}:
      json_strs(t)

def strs_of(+m: Maybe<&2, J.Json>) -> List<&2, String>:
  match m:
    case Some{J.JStr{s}}:
      Bool.pick(List<&2, String>, String.is_empty(String.trim(s)), [], [s])
    case Some{J.JArr{items}}:
      json_strs(J.unchain(items))
    case _:
      []

# A list of strings; a single string counts as a one-element list.
def strs_arg(+args: J.Json, +key: String) -> List<&2, String>:
  strs_of(J.get(args, key))

def uid_cons(+m: Maybe<&2, U32>, +rest: Maybe<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match m:
    case Some{u}:
      match rest:
        case Some{r}:
          Bool.pick(Maybe<&2, List<&2, U32>>, U32.is_zero(u), None{}, Some{u <> r})
        case None{}:
          None{}
    case None{}:
      None{}

def uids_go(+xs: List<&2, J.Json>) -> Maybe<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Some{[]}
    case Con{x, t}:
      uid_cons(J.as_u32(Some{x}), uids_go(t))

def uids_of(+m: Maybe<&2, List<&2, U32>>) -> Uids:
  match m:
    case Some{Nil{}}:
      UidsErr{"\"uids\" must list at least one UID"}
    case Some{xs}:
      UidsOk{xs}
    case None{}:
      UidsErr{"\"uids\" must be an array of positive integer UIDs"}

def one_uid(+m: Maybe<&2, J.Json>) -> List<&2, J.Json>:
  match m:
    case Some{x}:
      [x]
    case None{}:
      []

def uids_from(+m: Maybe<&2, List<&2, J.Json>>, +args: J.Json) -> Uids:
  match m:
    case Some{xs}:
      uids_of(uids_go(xs))
    case None{}:
      uids_of(uids_go(one_uid(J.get(args, "uid"))))

# The "uids" argument (an array), or "uid" (one number).
def uids_arg(+args: J.Json) -> Uids:
  uids_from(J.as_list(J.get(args, "uids")), args)

def uids_items(+xs: List<&2, U32>) -> List<&2, J.Json>:
  match xs:
    case Nil{}:
      []
    case Con{x, t}:
      J.num(x) <> uids_items(t)

# ---- JSON helpers --------------------------------------------------------------------------

def uids_json(+xs: List<&2, U32>) -> J.Json:
  J.arr(uids_items(xs))

def maybe_str(+m: Maybe<&2, String>) -> J.Json:
  match m:
    case Some{s}:
      J.str(s)
    case None{}:
      J.JNull{}

def maybe_num(+m: Maybe<&2, U32>) -> J.Json:
  match m:
    case Some{n}:
      J.num(n)
    case None{}:
      J.JNull{}

def ok_obj(+kvs: List<&2, J.Json>) -> Out:
  Ok{J.obj(kvs)}

def pure_out(+o: Out) -> IO(Out):
  IO.pure(Out, o)

# ---- folders ----------------------------------------------------------------------------

def any_special(+fs: List<&2, I.Folder>) -> Bool:
  match fs:
    case Nil{}:
      False{}
    case Con{I.Folder{n, d, attrs}, t}:
      I.has_attr(attrs, "\\Trash") || I.has_attr(attrs, "\\Drafts") || I.has_attr(attrs, "\\Sent") || I.has_attr(attrs, "\\Junk") || I.has_attr(attrs, "\\Archive") || I.has_attr(attrs, "\\All") || I.has_attr(attrs, "\\Flagged") || any_special(t)

# A folder role from its special-use attribute. Only a server that marks no
# folder at all (no SPECIAL-USE support) falls back to the conventional
# names; otherwise an unmarked role is unknown, never guessed.
def role(+fs: List<&2, I.Folder>, +attr: String, +a: String, +b: String) -> Maybe<&2, String>:
  Bool.pick(Maybe<&2, String>, any_special(fs), I.special(fs, attr), Maybe.or(&2, String, I.named(fs, a), I.named(fs, b)))

def trash_of(+fs: List<&2, I.Folder>) -> Maybe<&2, String>:
  role(fs, "\\Trash", "Deleted Messages", "Trash")

def drafts_of(+fs: List<&2, I.Folder>) -> Maybe<&2, String>:
  role(fs, "\\Drafts", "Drafts", "Drafts")

def sent_of(+fs: List<&2, I.Folder>) -> Maybe<&2, String>:
  role(fs, "\\Sent", "Sent Messages", "Sent")

def junk_of(+fs: List<&2, I.Folder>) -> Maybe<&2, String>:
  role(fs, "\\Junk", "Junk", "Junk")

def archive_of(+fs: List<&2, I.Folder>) -> Maybe<&2, String>:
  role(fs, "\\Archive", "Archive", "Archive")

def special_json(+fs: List<&2, I.Folder>) -> J.Json:
  J.obj([J.kv("inbox", maybe_str(I.named(fs, "INBOX"))), J.kv("drafts", maybe_str(drafts_of(fs))), J.kv("sent", maybe_str(sent_of(fs))), J.kv("trash", maybe_str(trash_of(fs))), J.kv("junk", maybe_str(junk_of(fs))), J.kv("archive", maybe_str(archive_of(fs)))])

def role_of(+attrs: List<&2, String>) -> J.Json:
  Bool.pick(J.Json, I.has_attr(attrs, "\\Drafts"), J.str("drafts"),
    Bool.pick(J.Json, I.has_attr(attrs, "\\Sent"), J.str("sent"),
      Bool.pick(J.Json, I.has_attr(attrs, "\\Trash"), J.str("trash"),
        Bool.pick(J.Json, I.has_attr(attrs, "\\Junk"), J.str("junk"),
          Bool.pick(J.Json, I.has_attr(attrs, "\\Archive"), J.str("archive"),
            Bool.pick(J.Json, I.has_attr(attrs, "\\All"), J.str("all"),
              Bool.pick(J.Json, I.has_attr(attrs, "\\Flagged"), J.str("flagged"), J.JNull{})))))))

def folder_json(+f: I.Folder) -> J.Json:
  match f:
    case I.Folder{name, delim, attrs}:
      J.obj([J.kv("name", J.str(name)), J.kv("delimiter", J.str(delim)), J.kv("attributes", J.strs(attrs)), J.kv("special_use", role_of(attrs)), J.kv("selectable", J.bool(Bool.not(I.has_attr(attrs, "\\Noselect") || I.has_attr(attrs, "\\NonExistent"))))])

def folders_json(+fs: List<&2, I.Folder>) -> List<&2, J.Json>:
  match fs:
    case Nil{}:
      []
    case Con{f, t}:
      folder_json(f) <> folders_json(t)

# ---- message summaries --------------------------------------------------------------------

def has_flag(+flags: List<&2, String>, +f: String) -> Bool:
  I.has_attr(flags, f)

def hdr_text(+hs: List<&2, M.Hdr>, +name: String) -> String:
  M.decode_header(M.header(hs, name))

def summary_hs(+m: I.Msg, +hs: List<&2, M.Hdr>) -> J.Json:
  match m:
    case I.Msg{uid, flags, date, size, headers, body}:
      J.obj([J.kv("uid", J.num(uid)), J.kv("date", J.str(hdr_text(hs, "date"))), J.kv("from", J.str(hdr_text(hs, "from"))), J.kv("to", J.str(hdr_text(hs, "to"))), J.kv("cc", J.str(hdr_text(hs, "cc"))), J.kv("subject", J.str(hdr_text(hs, "subject"))), J.kv("message_id", J.str(M.header(hs, "message-id"))), J.kv("internal_date", J.str(date)), J.kv("size", J.num(size)), J.kv("flags", J.strs(flags)), J.kv("seen", J.bool(has_flag(flags, "\\Seen"))), J.kv("flagged", J.bool(has_flag(flags, "\\Flagged")))])

def summary(+m: I.Msg) -> J.Json:
  match m:
    case I.Msg{uid, flags, date, size, headers, body}:
      summary_hs(m, M.headers(headers))

def summaries(+ms: List<&2, I.Msg>) -> List<&2, J.Json>:
  match ms:
    case Nil{}:
      []
    case Con{m, t}:
      summary(m) <> summaries(t)

def msg_uid(+m: I.Msg) -> U32:
  match m:
    case I.Msg{uid, f, d, s, h, b}:
      uid

def newest_first(+ms: List<&2, I.Msg>) -> List<&2, I.Msg>:
  List.sort(~I.Msg, ~(a => b => U32.is_ge(msg_uid(a), msg_uid(b))), ms)

def oldest_first(+ms: List<&2, I.Msg>) -> List<&2, I.Msg>:
  List.sort(~I.Msg, ~(a => b => U32.is_le(msg_uid(a), msg_uid(b))), ms)

def desc(+xs: List<&2, U32>) -> List<&2, U32>:
  List.sort(~U32, ~(a => b => U32.is_ge(a, b)), xs)

def asc(+xs: List<&2, U32>) -> List<&2, U32>:
  List.sort(~U32, ~(a => b => U32.is_le(a, b)), xs)

# ---- mail_probe / mail_list_folders ----------------------------------------------------------

def probe_out(r: Run, +host: String, +email: String) -> Out:
  match r:
    case RunErr{m}:
      Err{m}
    case RunOk{+lines}:
      ok_obj([J.kv("ok", J.bool(True{})), J.kv("account", J.str(email)), J.kv("imap_host", J.str(host)), J.kv("tls_verified", J.bool(True{})), J.kv("capabilities", J.strs(I.caps(lines))), J.kv("idle", J.bool(I.has_cap(I.caps(lines), "IDLE"))), J.kv("move", J.bool(I.has_cap(I.caps(lines), "MOVE"))), J.kv("uidplus", J.bool(I.has_cap(I.caps(lines), "UIDPLUS"))), J.kv("special_use", special_json(I.folders(lines))), J.kv("folder_count", J.num(U32.from_nat(List.length(&2, I.Folder, I.folders(lines)))))])

def t_probe(+args: J.Json) -> IO(Out):
  do IO<Out>:
    r : Run <- imap_run(Ops.plan_probe())
    host : String <- env_or("MAILBEND_IMAP_HOST", "imap.mail.me.com")
    email : String <- env_or("MAILBEND_EMAIL", "")
    return probe_out(r, host, email)

def folders_out(r: Run) -> Out:
  match r:
    case RunErr{m}:
      Err{m}
    case RunOk{+lines}:
      ok_obj([J.kv("folders", J.arr(folders_json(I.folders(lines))))])

def t_folders(+args: J.Json) -> IO(Out):
  do IO<Out>:
    r : Run <- imap_run(Ops.plan_folders())
    return folders_out(r)

def str_key(+args: J.Json, +name: String) -> List<&2, I.Key>:
  +v = str_arg(args, name, "")
  Bool.pick(List<&2, I.Key>, String.is_empty(v), [],
    Bool.pick(List<&2, I.Key>, String.eq(name, "from"), [I.KFrom{v}],
      Bool.pick(List<&2, I.Key>, String.eq(name, "to"), [I.KTo{v}],
        Bool.pick(List<&2, I.Key>, String.eq(name, "cc"), [I.KCc{v}],
          Bool.pick(List<&2, I.Key>, String.eq(name, "subject"), [I.KSubject{v}],
            Bool.pick(List<&2, I.Key>, String.eq(name, "body"), [I.KBody{v}], [I.KText{v}]))))))

def flag_keys(+args: J.Json) -> List<&2, I.Key>:
  List.concat(&2, I.Key, [
    Bool.pick(List<&2, I.Key>, bool_arg(args, "unseen", False{}), [I.KUnseen{}], []),
    Bool.pick(List<&2, I.Key>, bool_arg(args, "seen", False{}), [I.KSeen{}], []),
    Bool.pick(List<&2, I.Key>, bool_arg(args, "flagged", False{}), [I.KFlagged{}], [])])

def date_key_of(+m: Maybe<&2, String>, +name: String) -> DateKey:
  match m:
    case Some{d}:
      DateOk{Bool.pick(List<&2, I.Key>, String.eq(name, "since"), [I.KSince{d}], [I.KBefore{d}])}
    case None{}:
      DateBad{"\"" ++ name ++ "\" must be a date like 2026-02-01"}

def date_key(+args: J.Json, +name: String) -> DateKey:
  +v = str_arg(args, name, "")
  Bool.pick(DateKey, String.is_empty(v), DateOk{[]}, date_key_of(I.imap_date(v), name))

def keys_join(+a: DateKey, +b: DateKey, +rest: List<&2, I.Key>) -> Keys:
  match a:
    case DateBad{m}:
      KeysErr{m}
    case DateOk{ka}:
      match b:
        case DateBad{m}:
          KeysErr{m}
        case DateOk{kb}:
          KeysOk{List.concat(&2, I.Key, [rest, ka, kb])}

def keys_of(+args: J.Json) -> Keys:
  keys_join(date_key(args, "since"), date_key(args, "before"),
    List.concat(&2, I.Key, [str_key(args, "from"), str_key(args, "to"), str_key(args, "cc"), str_key(args, "subject"), str_key(args, "body"), str_key(args, "text"), flag_keys(args)]))

def list_out(+folder: String, +uidv: Maybe<&2, U32>, +total: U32, +ms: List<&2, J.Json>) -> Out:
  ok_obj([J.kv("folder", J.str(folder)), J.kv("uidvalidity", maybe_num(uidv)), J.kv("total", J.num(total)), J.kv("messages", J.arr(ms))])

def uid_in(+u: U32, +uids: List<&2, U32>) -> Bool:
  match uids:
    case Nil{}:
      False{}
    case Con{x, t}:
      U32.is_eq(u, x) || uid_in(u, t)

# The FETCH responses for the requested UIDs only (a server may add
# unsolicited ones, e.g. flag updates).
def requested(+ms: List<&2, I.Msg>, +uids: List<&2, U32>) -> List<&2, I.Msg>:
  match ms:
    case Nil{}:
      []
    case Con{m, t}:
      List.append(&2, I.Msg, Bool.pick(List<&2, I.Msg>, uid_in(msg_uid(m), uids), [m], []), requested(t, uids))

# ---- flags ---------------------------------------------------------------------------------

# ---- UID checks -------------------------------------------------------------------------------

def uidv_is(+have: Maybe<&2, U32>, +want: U32) -> Bool:
  match have:
    case Some{n}:
      U32.is_eq(n, want)
    case None{}:
      False{}

def same_uidv(+a: Maybe<&2, U32>, +b: Maybe<&2, U32>) -> Bool:
  match a:
    case Some{x}:
      uidv_is(b, x)
    case None{}:
      Maybe.is_none(&2, U32, b)

def moved_msg() -> String:
  "the folder's UIDVALIDITY changed between the search and the fetch, so these UIDs may name other messages; search again"

# The fetch runs in a second session: its EXAMINE must report the same
# UIDVALIDITY as the search, or the UIDs may name other messages.
def search_headers(r: Run, +folder: String, +uidv: Maybe<&2, U32>, +total: U32, +uids: List<&2, U32>) -> Out:
  match r:
    case RunErr{m}:
      Err{m}
    case RunOk{+lines}:
      Bool.pick(Out, same_uidv(uidv, I.ok_code(lines, "UIDVALIDITY")),
        list_out(folder, uidv, total, summaries(newest_first(requested(I.fetched(lines), uids)))),
        Err{moved_msg()})

def search_fetch(+uids: List<&2, U32>, +folder: String, +uidv: Maybe<&2, U32>, +total: U32) -> IO(Out):
  match uids:
    case Nil{}:
      pure_out(list_out(folder, uidv, total, []))
    case Con{h, t}:
      do IO<Out>:
        r : Run <- imap_run(Ops.plan_headers(folder, uids))
        return search_headers(r, folder, uidv, total, uids)

def search_found(r: Run, +folder: String, +limit: U32) -> IO(Out):
  match r:
    case RunErr{m}:
      pure_out(Err{m})
    case RunOk{+lines}:
      search_fetch(List.take(&2, U32, desc(I.search_uids(lines)), U32.to_nat(limit)), folder, I.ok_code(lines, "UIDVALIDITY"), U32.from_nat(List.length(&2, U32, I.search_uids(lines))))

def search_keys(+ks: Keys, +folder: String, +limit: U32) -> IO(Out):
  match ks:
    case KeysErr{m}:
      pure_out(Err{m})
    case KeysOk{keys}:
      do IO<Out>:
        r : Run <- imap_run(Ops.plan_search(folder, keys))
        search_found(r, folder, limit)

def t_search(+args: J.Json) -> IO(Out):
  search_keys(keys_of(args), folder_arg(args), clamp(u32_arg(args, "limit", 20), 1, 200))

def atts_json(+xs: List<&2, M.Att>) -> List<&2, J.Json>:
  match xs:
    case Nil{}:
      []
    case Con{M.Att{n, t, s}, r}:
      J.obj([J.kv("filename", J.str(n)), J.kv("content_type", J.str(t)), J.kv("size", J.num(s))]) <> atts_json(r)

# ---- mail_get --------------------------------------------------------------------------------

def get_json(+m: I.Msg, +folder: String, +uidv: Maybe<&2, U32>, +max: U32, +hs: List<&2, M.Hdr>, +p: M.Parts) -> Out:
  match m:
    case I.Msg{uid, flags, date, size, headers, body}:
      match p:
        case M.Parts{text, html, atts}:
          ok_obj([J.kv("folder", J.str(folder)), J.kv("uid", J.num(uid)), J.kv("uidvalidity", maybe_num(uidv)), J.kv("flags", J.strs(flags)), J.kv("seen", J.bool(has_flag(flags, "\\Seen"))), J.kv("internal_date", J.str(date)), J.kv("size", J.num(size)), J.kv("truncated", J.bool(U32.is_gt(size, max))),
            J.kv("from", J.str(hdr_text(hs, "from"))), J.kv("to", J.str(hdr_text(hs, "to"))), J.kv("cc", J.str(hdr_text(hs, "cc"))), J.kv("reply_to", J.str(hdr_text(hs, "reply-to"))), J.kv("subject", J.str(hdr_text(hs, "subject"))), J.kv("date", J.str(hdr_text(hs, "date"))), J.kv("message_id", J.str(M.header(hs, "message-id"))), J.kv("in_reply_to", J.str(M.header(hs, "in-reply-to"))), J.kv("references", J.str(M.header(hs, "references"))),
            J.kv("text", J.str(Bool.pick(String, String.is_empty(text), M.html_text(html), text))), J.kv("html_available", J.bool(Bool.not(String.is_empty(html)))), J.kv("attachments", J.arr(atts_json(atts)))])

def msg_body(+m: I.Msg) -> String:
  match m:
    case I.Msg{uid, f, d, s, h, body}:
      body

# The FETCH response for `uid` (a server may also send unsolicited FETCHes).
def with_uid(+ms: List<&2, I.Msg>, +uid: U32) -> List<&2, I.Msg>:
  match ms:
    case Nil{}:
      []
    case Con{m, t}:
      Bool.pick(List<&2, I.Msg>, U32.is_eq(msg_uid(m), uid), [m], with_uid(t, uid))

def get_msg(+ms: List<&2, I.Msg>, +folder: String, +uid: U32, +uidv: Maybe<&2, U32>, +max: U32) -> Out:
  match ms:
    case Nil{}:
      Err{"no message with UID " ++ U32.show(uid) ++ " in " ++ folder}
    case Con{m, t}:
      get_json(m, folder, uidv, max, M.headers(M.head_of(M.split(msg_body(m)))), M.parts(msg_body(m)))

def get_out(r: Run, +folder: String, +uid: U32, +max: U32) -> Out:
  match r:
    case RunErr{m}:
      Err{m}
    case RunOk{+lines}:
      get_msg(with_uid(I.fetched(lines), uid), folder, uid, I.ok_code(lines, "UIDVALIDITY"), max)

def get_uid(+u: Uids, +folder: String, +max: U32) -> IO(Out):
  match u:
    case UidsOk{Con{uid, Nil{}}}:
      do IO<Out>:
        r : Run <- imap_run(Ops.plan_get(folder, uid, max))
        return get_out(r, folder, uid, max)
    case UidsOk{xs}:
      pure_out(Err{"mail_get reads one message: pass a single \"uid\""})
    case UidsErr{m}:
      pure_out(Err{m})

def t_get(+args: J.Json) -> IO(Out):
  get_uid(uids_arg(args), folder_arg(args), clamp(u32_arg(args, "max_bytes", 262144), 1024, 16777216))

# ---- mail_get_new ---------------------------------------------------------------------------

def above(+xs: List<&2, U32>, +since: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      []
    case Con{x, t}:
      List.append(&2, U32, Bool.pick(List<&2, U32>, U32.is_gt(x, since), [x], []), above(t, since))

def last_or(+xs: List<&2, U32>, +d: U32) -> U32:
  Maybe.default(&2, U32, List.last(&2, U32, xs), d)

def new_out(+folder: String, +uidv: U32, +changed: Bool, +next: U32, +more: Bool, +ms: List<&2, J.Json>) -> Out:
  ok_obj([J.kv("folder", J.str(folder)), J.kv("uidvalidity", J.num(uidv)), J.kv("uidvalidity_changed", J.bool(changed)), J.kv("next_since_uid", J.num(next)), J.kv("has_more", J.bool(more)), J.kv("messages", J.arr(ms))])

# As for search: a UIDVALIDITY change between the two sessions resets the
# checkpoint instead of returning messages under stale UIDs.
def new_headers(r: Run, +folder: String, +uidv: U32, +next: U32, +more: Bool, +uids: List<&2, U32>) -> Out:
  match r:
    case RunErr{m}:
      Err{m}
    case RunOk{+lines}:
      Bool.pick(Out, uidv_is(I.ok_code(lines, "UIDVALIDITY"), uidv),
        new_out(folder, uidv, False{}, next, more, summaries(oldest_first(requested(I.fetched(lines), uids)))),
        new_out(folder, Maybe.default(&2, U32, I.ok_code(lines, "UIDVALIDITY"), 0), True{}, 0, True{}, []))

def new_fetch(+uids: List<&2, U32>, +folder: String, +uidv: U32, +since: U32, +more: Bool) -> IO(Out):
  match uids:
    case Nil{}:
      pure_out(new_out(folder, uidv, False{}, since, False{}, []))
    case Con{h, t}:
      do IO<Out>:
        r : Run <- imap_run(Ops.plan_headers(folder, uids))
        return new_headers(r, folder, uidv, last_or(uids, since), more, uids)

def new_reset(+changed: Bool, +uidv: U32, +uids: List<&2, U32>, +folder: String, +since: U32, +limit: U32) -> IO(Out):
  match changed:
    case True{}:
      pure_out(new_out(folder, uidv, True{}, 0, True{}, []))
    case False{}:
      new_fetch(List.take(&2, U32, uids, U32.to_nat(limit)), folder, uidv, since, Nat.is_gt(List.length(&2, U32, uids), U32.to_nat(limit)))

def new_check(+uidv: U32, +uids: List<&2, U32>, +folder: String, +since: U32, +known: U32, +limit: U32) -> IO(Out):
  new_reset(Bool.not(U32.is_zero(known)) && Bool.not(U32.is_eq(known, uidv)), uidv, uids, folder, since, limit)

# When UIDVALIDITY changed, every stored UID is void: report it and restart
# the checkpoint at 0 instead of guessing which messages are new.
def new_found(r: Run, +folder: String, +since: U32, +known: U32, +limit: U32) -> IO(Out):
  match r:
    case RunErr{m}:
      pure_out(Err{m})
    case RunOk{+lines}:
      new_check(Maybe.default(&2, U32, I.ok_code(lines, "UIDVALIDITY"), 0), asc(above(I.search_uids(lines), since)), folder, since, known, limit)

# A checkpoint is a UID together with its UIDVALIDITY: a UID alone could
# belong to a recreated folder and skip or repeat messages.
def new_request(+since: U32, +known: U32) -> String:
  Bool.pick(String, Bool.not(U32.is_zero(since)) && U32.is_zero(known), "\"uidvalidity\" is required with \"since_uid\": pass the uidvalidity returned with that checkpoint", "")

def new_asked(+problem: String, +args: J.Json) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{problem})
    case SNil{}:
      do IO<Out>:
        r : Run <- imap_run(Ops.plan_new(folder_arg(args), u32_arg(args, "since_uid", 0)))
        new_found(r, folder_arg(args), u32_arg(args, "since_uid", 0), u32_arg(args, "uidvalidity", 0), clamp(u32_arg(args, "limit", 50), 1, 500))

def t_get_new(+args: J.Json) -> IO(Out):
  new_asked(new_request(u32_arg(args, "since_uid", 0), u32_arg(args, "uidvalidity", 0)), args)

# The preflight's early check (the plans check again in the changing session).
def uidv_problem(+lines: List<&2, I.RLine>, +want: U32, +folder: String) -> String:
  Bool.pick(String, uidv_is(I.ok_code(lines, "UIDVALIDITY"), want), "", stale_msg())

def uidv_arg(+args: J.Json) -> U32:
  u32_arg(args, "uidvalidity", 0)

def uidv_missing() -> String:
  "\"uidvalidity\" is required: pass the value mail_search or mail_get returned with these UIDs, so stale UIDs can never change other messages"

def minus(+xs: List<&2, U32>, +ys: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      []
    case Con{x, t}:
      List.append(&2, U32, Bool.pick(List<&2, U32>, uid_in(x, ys), [], [x]), minus(t, ys))

# The result of a change: which requested UIDs existed when it ran (the
# guard's UID SEARCH) and which did not. If none existed, nothing changed.
def changed_of(+lines: List<&2, I.RLine>, +uids: List<&2, U32>, +folder: String, +kvs: List<&2, J.Json>) -> Out:
  +found = asc(I.search_uids(lines))
  Bool.pick(Out, List.is_empty(&2, U32, found), Err{"none of these UIDs exist in " ++ folder ++ "; nothing was changed"},
    ok_obj(List.append(&2, J.Json, kvs, [J.kv("changed", uids_json(found)), J.kv("missing", uids_json(minus(uids, found)))])))

def changed_out(r: Run, +uids: List<&2, U32>, +folder: String, +kvs: List<&2, J.Json>) -> Out:
  match r:
    case RunErr{m}:
      Err{m}
    case RunOk{+lines}:
      changed_of(lines, uids, folder, kvs)

# ---- flags ---------------------------------------------------------------------------------------

def mark_go(+uids: List<&2, U32>, +folder: String, +seen: Bool, +uidv: U32) -> IO(Out):
  do IO<Out>:
    r : Run <- imap_run(Ops.plan_mark(folder, uids, seen, uidv))
    return changed_out(r, uids, folder, [J.kv("ok", J.bool(True{})), J.kv("folder", J.str(folder)), J.kv("seen", J.bool(seen))])

def mark_checked(+missing: Bool, +uids: List<&2, U32>, +folder: String, +seen: Bool, +uidv: U32) -> IO(Out):
  match missing:
    case True{}:
      pure_out(Err{uidv_missing()})
    case False{}:
      mark_go(uids, folder, seen, uidv)

def mark_uids(+u: Uids, +folder: String, +seen: Bool, +uidv: U32) -> IO(Out):
  match u:
    case UidsErr{m}:
      pure_out(Err{m})
    case UidsOk{uids}:
      mark_checked(U32.is_zero(uidv), uids, folder, seen, uidv)

def t_mark(+args: J.Json, +seen: Bool) -> IO(Out):
  mark_uids(uids_arg(args), folder_arg(args), seen, uidv_arg(args))

# ---- move / trash / delete -------------------------------------------------------------------

def method_name(+move: Bool) -> String:
  Bool.pick(String, move, "UID MOVE", "UID COPY + UID EXPUNGE")

def move_plan(+plan: List<&2, I.Cmd>, +folder: String, +uids: List<&2, U32>, +dest: String, +move: Bool) -> IO(Out):
  match plan:
    case Nil{}:
      pure_out(Err{"the server supports neither MOVE nor UIDPLUS; refusing to move with a plain EXPUNGE, which could remove other messages"})
    case Con{h, t}:
      do IO<Out>:
        r : Run <- imap_run(plan)
        return changed_out(r, uids, folder, [J.kv("ok", J.bool(True{})), J.kv("folder", J.str(folder)), J.kv("destination", J.str(dest)), J.kv("method", J.str(method_name(move)))])

def move_if(+problem: String, +caps: List<&2, String>, +folder: String, +uids: List<&2, U32>, +dest: String, +uidv: U32) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{problem})
    case SNil{}:
      move_plan(Ops.plan_move(folder, uids, dest, I.has_cap(caps, "MOVE"), I.has_cap(caps, "UIDPLUS"), uidv), folder, uids, dest, I.has_cap(caps, "MOVE"))

def move_caps(r: Run, +folder: String, +uids: List<&2, U32>, +dest: String, +uidv: U32) -> IO(Out):
  match r:
    case RunErr{m}:
      pure_out(Err{m})
    case RunOk{+lines}:
      move_if(uidv_problem(lines, uidv, folder), I.caps(lines), folder, uids, dest, uidv)

# Whether two names denote the same mailbox; INBOX is case-insensitive in
# IMAP, other names are compared as given.
def same_mailbox(+a: String, +b: String) -> Bool:
  String.eq(a, b) || (String.eq(String.to_upper(a), "INBOX") && String.eq(String.to_upper(b), "INBOX"))

def move_request(+uidv: U32, +folder: String, +dest: String) -> String:
  Bool.pick(String, String.is_empty(dest) || same_mailbox(dest, folder), "\"destination\" must name a different folder",
    Bool.pick(String, U32.is_zero(uidv), uidv_missing(), ""))

def move_asked(+problem: String, +folder: String, +uids: List<&2, U32>, +dest: String, +uidv: U32) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{problem})
    case SNil{}:
      do IO<Out>:
        r : Run <- imap_run(Ops.plan_preflight(folder))
        move_caps(r, folder, uids, dest, uidv)

def move_uids(+u: Uids, +folder: String, +dest: String, +uidv: U32) -> IO(Out):
  match u:
    case UidsErr{m}:
      pure_out(Err{m})
    case UidsOk{uids}:
      move_asked(move_request(uidv, folder, dest), folder, uids, dest, uidv)

def t_move(+args: J.Json) -> IO(Out):
  move_uids(uids_arg(args), folder_arg(args), str_arg(args, "destination", ""), uidv_arg(args))

def trash_into(+same: Bool, +t: String, +caps: List<&2, String>, +folder: String, +uids: List<&2, U32>, +uidv: U32) -> IO(Out):
  match same:
    case True{}:
      pure_out(Err{"these messages are already in " ++ t ++ "; use mail_delete to remove them permanently"})
    case False{}:
      move_plan(Ops.plan_trash(folder, uids, t, I.has_cap(caps, "MOVE"), I.has_cap(caps, "UIDPLUS"), uidv), folder, uids, t, I.has_cap(caps, "MOVE"))

def trash_to(+trash: Maybe<&2, String>, +caps: List<&2, String>, +folder: String, +uids: List<&2, U32>, +uidv: U32) -> IO(Out):
  match trash:
    case None{}:
      pure_out(Err{"no Trash folder: the server marks none as \\Trash (and names are only used on servers without special-use folders)"})
    case Some{t}:
      trash_into(same_mailbox(t, folder), t, caps, folder, uids, uidv)

def trash_if(+problem: String, +lines: List<&2, I.RLine>, +folder: String, +uids: List<&2, U32>, +uidv: U32) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{problem})
    case SNil{}:
      trash_to(trash_of(I.folders(lines)), I.caps(lines), folder, uids, uidv)

def trash_found(r: Run, +folder: String, +uids: List<&2, U32>, +uidv: U32) -> IO(Out):
  match r:
    case RunErr{m}:
      pure_out(Err{m})
    case RunOk{+lines}:
      trash_if(uidv_problem(lines, uidv, folder), lines, folder, uids, uidv)

def trash_checked(+missing: Bool, +folder: String, +uids: List<&2, U32>, +uidv: U32) -> IO(Out):
  match missing:
    case True{}:
      pure_out(Err{uidv_missing()})
    case False{}:
      do IO<Out>:
        r : Run <- imap_run(Ops.plan_preflight(folder))
        trash_found(r, folder, uids, uidv)

def trash_uids(+u: Uids, +folder: String, +uidv: U32) -> IO(Out):
  match u:
    case UidsErr{m}:
      pure_out(Err{m})
    case UidsOk{uids}:
      trash_checked(U32.is_zero(uidv), folder, uids, uidv)

def t_trash(+args: J.Json) -> IO(Out):
  trash_uids(uids_arg(args), folder_arg(args), uidv_arg(args))

def delete_plan(+plan: List<&2, I.Cmd>, +folder: String, +uids: List<&2, U32>) -> IO(Out):
  match plan:
    case Nil{}:
      pure_out(Err{"the server lacks UIDPLUS; refusing a plain EXPUNGE, which could remove other messages"})
    case Con{h, t}:
      do IO<Out>:
        r : Run <- imap_run(plan)
        return changed_out(r, uids, folder, [J.kv("ok", J.bool(True{})), J.kv("folder", J.str(folder)), J.kv("permanently_deleted", J.bool(True{}))])

def delete_if(+problem: String, +caps: List<&2, String>, +folder: String, +uids: List<&2, U32>, +confirm: String, +uidv: U32) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{problem})
    case SNil{}:
      delete_plan(Ops.plan_delete(folder, uids, confirm, I.has_cap(caps, "UIDPLUS"), uidv), folder, uids)

def delete_caps(r: Run, +folder: String, +uids: List<&2, U32>, +confirm: String, +uidv: U32) -> IO(Out):
  match r:
    case RunErr{m}:
      pure_out(Err{m})
    case RunOk{+lines}:
      delete_if(uidv_problem(lines, uidv, folder), I.caps(lines), folder, uids, confirm, uidv)

def delete_asked(+problem: String, +folder: String, +uids: List<&2, U32>, +confirm: String, +uidv: U32) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{problem})
    case SNil{}:
      do IO<Out>:
        r : Run <- imap_run(Ops.plan_preflight(folder))
        delete_caps(r, folder, uids, confirm, uidv)

# The plan itself refuses without the confirmation word (a proven law);
# these checks only explain why before connecting.
def delete_request(+confirm: String, +uidv: U32) -> String:
  Bool.pick(String, Bool.not(String.eq(confirm, Ops.confirm_word())), "mail_delete permanently removes messages and cannot be undone; pass \"confirm\": \"permanently-delete\" to proceed (use mail_trash to move them to Trash instead)",
    Bool.pick(String, U32.is_zero(uidv), uidv_missing(), ""))

def delete_uids(+u: Uids, +folder: String, +confirm: String, +uidv: U32) -> IO(Out):
  match u:
    case UidsErr{m}:
      pure_out(Err{m})
    case UidsOk{uids}:
      delete_asked(delete_request(confirm, uidv), folder, uids, confirm, uidv)

def t_delete(+args: J.Json) -> IO(Out):
  delete_uids(uids_arg(args), folder_arg(args), str_arg(args, "confirm", ""), uidv_arg(args))

def bytes_str(+xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, t}:
      SCon{C.chr(x), bytes_str(t)}

def basename(+path: String) -> String:
  Maybe.default(&2, String, List.last(&2, String, String.split(path, '/')), path)

def ext_type(+name: String) -> String:
  +n = String.to_lower(name)
  Bool.pick(String, String.ends_with(n, ".pdf"), "application/pdf",
    Bool.pick(String, String.ends_with(n, ".txt") || String.ends_with(n, ".md") || String.ends_with(n, ".log"), "text/plain",
      Bool.pick(String, String.ends_with(n, ".csv"), "text/csv",
        Bool.pick(String, String.ends_with(n, ".html") || String.ends_with(n, ".htm"), "text/html",
          Bool.pick(String, String.ends_with(n, ".json"), "application/json",
            Bool.pick(String, String.ends_with(n, ".png"), "image/png",
              Bool.pick(String, String.ends_with(n, ".jpg") || String.ends_with(n, ".jpeg"), "image/jpeg",
                Bool.pick(String, String.ends_with(n, ".gif"), "image/gif",
                  Bool.pick(String, String.ends_with(n, ".zip"), "application/zip",
                    Bool.pick(String, String.ends_with(n, ".eml"), "message/rfc822", "application/octet-stream"))))))))))

def max_attachment() -> U32:
  26214400

def pure_att(+a: AttR) -> IO(AttR):
  IO.pure(AttR, a)

def att_proc(+p: Proc, +name: String, +ctype: String) -> AttR:
  match p:
    case ProcFail{m}:
      AttErr{"cannot run mailbend-attach: " ++ m}
    case ProcOk{code, out, err}:
      Bool.pick(AttR, U32.is_zero(code), AttOk{M.Attach{name, ctype, out}}, AttErr{strip_prefix(helper_msg(err), "mailbend-attach: ")})

# `budget` is what is left of the 25 MB all attachments may take together;
# the reader refuses a file larger than that before reading it.
def att_read(+helper: String, +dir: String, +path: String, +name: String, +ctype: String, +budget: U32) -> IO(AttR):
  do IO<AttR>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(helper, [dir, path, U32.show(budget)], "", 60000000, 60000)
    return att_proc(proc_of(r), name, ctype)

def att_at(+helper: String, +dir: String, +path: String, +name: String, +ctype: String, +budget: U32) -> IO(AttR):
  match helper:
    case SCon{'/', t}:
      att_read(helper, dir, path, name, ctype, budget)
    case _:
      pure_att(AttErr{"MAILBEND_ATTACH_HELPER must be the absolute path of mailbend-attach (scripts/mailbend sets it)"})

# Attachments come only from MAILBEND_ATTACH_DIR and are off without it: an
# agent tricked by a message must not mail out files such as
# /proc/self/environ (which holds the app password) or ~/.ssh keys. They are
# read by mailbend-attach, a separate program that holds no credentials: it
# opens the file beneath that directory with no symlinks allowed and checks
# the opened descriptor itself, so a path swapped mid-way cannot redirect
# the read.
def att_dir(+dir: String, +path: String, +name: String, +ctype: String, +budget: U32) -> IO(AttR):
  match dir:
    case SNil{}:
      pure_att(AttErr{"attachments are disabled: set MAILBEND_ATTACH_DIR to the directory whose files may be attached"})
    case SCon{h, t}:
      do IO<AttR>:
        helper : String <- env_or("MAILBEND_ATTACH_HELPER", "")
        att_at(helper, dir, path, name, ctype, budget)

def att_path(+missing: Bool, +path: String, +name: String, +ctype: String, +budget: U32) -> IO(AttR):
  match missing:
    case True{}:
      pure_att(AttErr{"each attachment needs a \"path\""})
    case False{}:
      do IO<AttR>:
        dir : String <- env_or("MAILBEND_ATTACH_DIR", "")
        att_dir(dir, path, name, ctype, budget)

def att_named(+path: String, +name: String, +ctype: String, +budget: U32) -> IO(AttR):
  att_path(String.is_empty(path), path, name, ctype, budget)

def att_one(+a: J.Json, +budget: U32) -> IO(AttR):
  att_named(str_arg(a, "path", ""), str_arg(a, "filename", basename(str_arg(a, "path", ""))), str_arg(a, "content_type", ext_type(str_arg(a, "filename", basename(str_arg(a, "path", ""))))), budget)

def max_attachments() -> U32:
  32

# Bytes in a byte string (one char per byte), counted in a U32.
def byte_count(s: String, +n: U32) -> U32:
  match s:
    case SNil{}:
      n
    case SCon{c, t}:
      byte_count(t, (n + 1 : U32))

def att_size(+a: AttR) -> U32:
  match a:
    case AttOk{M.Attach{n, c, data}}:
      byte_count(data, 0)
    case AttErr{m}:
      0

def att_ok(+a: AttR) -> Bool:
  match a:
    case AttOk{x}:
      True{}
    case AttErr{m}:
      False{}

def att_gated(+too_many: Bool, +spent: Bool, +a: J.Json, +budget: U32) -> IO(AttR):
  match too_many:
    case True{}:
      pure_att(AttErr{"at most 32 attachments"})
    case False{}:
      match spent:
        case True{}:
          pure_att(AttErr{"attachments may total at most 25 MB"})
        case False{}:
          att_one(a, budget)

# Reads the next attachment only while everything before it was read, the
# 25 MB total budget is not spent and there are at most 32; once one fails
# the rest are never read (a placeholder keeps the first error first).
def att_gate(+go: Bool, +n: U32, +a: J.Json, +budget: U32) -> IO(AttR):
  match go:
    case False{}:
      pure_att(AttErr{"not read"})
    case True{}:
      att_gated(U32.is_ge(n, max_attachments()), U32.is_zero(budget), a, budget)

def atts_go(+xs: List<&2, J.Json>, +go: Bool, +n: U32, +budget: U32) -> IO(List<&2, AttR>):
  match xs:
    case Nil{}:
      IO.pure(List<&2, AttR>, [])
    case Con{a, t}:
      do IO<List<&2, AttR>>:
        +o : AttR <- att_gate(go, n, a, budget)
        rest : List<&2, AttR> <- atts_go(t, go && att_ok(o), (n + 1 : U32), (budget - att_size(o) : U32))
        return o <> rest

def atts_read(+xs: List<&2, J.Json>) -> IO(List<&2, AttR>):
  atts_go(xs, True{}, 0, max_attachment())

def atts_cons(+a: M.Attach, +rest: Atts) -> Atts:
  match rest:
    case AttsOk{xs}:
      AttsOk{a <> xs}
    case AttsErr{m}:
      AttsErr{m}

def atts_collect(+rs: List<&2, AttR>) -> Atts:
  match rs:
    case Nil{}:
      AttsOk{[]}
    case Con{AttErr{m}, t}:
      AttsErr{m}
    case Con{AttOk{a}, t}:
      atts_cons(a, atts_collect(t))

def hexd(+n: U32) -> String:
  SCon{C.chr(Bool.pick(U32, U32.is_lt(n, 10), (n + 48 : U32), (n + 87 : U32))), SNil{}}

def hex8(+n: U32) -> String:
  String.concat([hexd((n >> 28n : U32)), hexd(((n >> 24n) .&. 15 : U32)), hexd(((n >> 20n) .&. 15 : U32)), hexd(((n >> 16n) .&. 15 : U32)), hexd(((n >> 12n) .&. 15 : U32)), hexd(((n >> 8n) .&. 15 : U32)), hexd(((n >> 4n) .&. 15 : U32)), hexd((n .&. 15 : U32))])

def secs_of(p: Proc) -> U32:
  match p:
    case ProcOk{code, out, err}:
      Maybe.default(&2, U32, U32.read(String.trim(out)), 0)
    case ProcFail{m}:
      0

def rand_of(r: Result<&1, &1, U32 & String, U32>) -> U32:
  match r:
    case Done{n}:
      n
    case Fail{e}:
      0

def stamp_of(+secs: U32, +a: U32, +b: U32) -> Stamp:
  Stamp{M.rfc5322_date(secs), hex8(secs) ++ "." ++ hex8(a) ++ hex8(b)}

def stamp() -> IO(Stamp):
  do IO<Stamp>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("/bin/date", ["+%s"], "", 64, 5000)
    a : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    b : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    return stamp_of(secs_of(proc_of(r)), rand_of(a), rand_of(b))

def domain_of(+addr: String) -> String:
  Maybe.default(&2, String, List.last(&2, String, String.split(M.addr_spec(addr), '@')), "mailbend.invalid")

# A saved draft keeps its Bcc header (a mail client sends it later and drops
# the header); a sent message never carries one, Bcc goes only into the
# SMTP envelope.
def draft_of(+w: Want, +from: String, +st: Stamp, +keep_bcc: Bool) -> M.Draft:
  match w:
    case Want{to, cc, bcc, subject, text, irt, refs, atts, d}:
      match st:
        case Stamp{date, token}:
          M.Draft{from, to, cc, Bool.pick(List<&2, String>, keep_bcc, bcc, []), subject, text, date, "<" ++ token ++ "@" ++ domain_of(from) ++ ">", irt, refs, atts}

def msgid_of(+d: M.Draft) -> String:
  match d:
    case M.Draft{f, t, c, bc, s, x, dt, msgid, i, r, a}:
      msgid

def boundary_of(+st: Stamp) -> String:
  match st:
    case Stamp{d, token}:
      "mailbend-" ++ token

def all_rcpts(+w: Want) -> List<&2, String>:
  match w:
    case Want{to, cc, bcc, s, x, i, r, a, d}:
      List.concat(&2, String, [to, cc, bcc])

def is_draft(+w: Want) -> Bool:
  match w:
    case Want{t, c, b, s, x, i, r, a, draft}:
      draft

def specs(+xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{x, t}:
      M.addr_spec(x) <> specs(t)

# "[APPENDUID <uidvalidity> <uid>]" in the APPEND's tagged OK.
def appenduid(+ws: List<&2, String>) -> J.Json:
  match ws:
    case Con{code, Con{v, Con{uid, Nil{}}}}:
      Bool.pick(J.Json, String.eq(String.to_upper(code), "APPENDUID"), maybe_num(U32.read(uid)), J.JNull{})
    case _:
      J.JNull{}

def appended_uid(+lines: List<&2, I.RLine>) -> J.Json:
  appenduid(String.split(I.resp_code(I.status_text(lines, 1)), ' '))

def draft_saved(r: Run, +drafts: String, +msgid: String) -> Out:
  match r:
    case RunErr{m}:
      Err{m}
    case RunOk{+lines}:
      ok_obj([J.kv("ok", J.bool(True{})), J.kv("saved_to", J.str(drafts)), J.kv("uid", appended_uid(lines)), J.kv("message_id", J.str(msgid))])

def draft_append(+m: Maybe<&2, String>, +msg: String, +msgid: String) -> IO(Out):
  match m:
    case None{}:
      pure_out(Err{"no Drafts folder: the server marks none as \\Drafts (and names are only used on servers without special-use folders)"})
    case Some{drafts}:
      do IO<Out>:
        r : Run <- imap_run(Ops.plan_draft(drafts, msg))
        return draft_saved(r, drafts, msgid)

def draft_folder(r: Run, +msg: String, +msgid: String) -> IO(Out):
  match r:
    case RunErr{m}:
      pure_out(Err{m})
    case RunOk{+lines}:
      draft_append(drafts_of(I.folders(lines)), msg, msgid)

def sent_out(+o: Out, +msgid: String, +n: U32) -> Out:
  match o:
    case Err{m}:
      Err{m}
    case Ok{reply}:
      ok_obj([J.kv("ok", J.bool(True{})), J.kv("sent", J.bool(True{})), J.kv("message_id", J.str(msgid)), J.kv("recipients", J.num(n)), J.kv("server_reply", reply)])

def deliver_as(+draft: Bool, +w: Want, +from: String, +st: Stamp) -> IO(Out):
  match draft:
    case True{}:
      do IO<Out>:
        r : Run <- imap_run(Ops.plan_probe())
        draft_folder(r, M.compose(draft_of(w, from, st, True{}), boundary_of(st)), msgid_of(draft_of(w, from, st, True{})))
    case False{}:
      do IO<Out>:
        o : Out <- smtp_run(S.envelope(M.addr_spec(from), specs(all_rcpts(w)), M.compose(draft_of(w, from, st, False{}), boundary_of(st))))
        return sent_out(o, msgid_of(draft_of(w, from, st, False{})), U32.from_nat(List.length(&2, String, all_rcpts(w))))

def deliver(+w: Want, +from: String, +st: Stamp) -> IO(Out):
  deliver_as(is_draft(w), w, from, st)

def check_want(+w: Want, +from: String) -> String:
  Bool.pick(String, Bool.not(M.addr_ok(from)), "MAILBEND_EMAIL is not a valid address",
    Bool.pick(String, Bool.not(M.all_addrs_ok(all_rcpts(w))), "every recipient must be an address like name@example.com or \"Name <name@example.com>\"",
      Bool.pick(String, List.is_empty(&2, String, all_rcpts(w)) && Bool.not(is_draft(w)), "at least one recipient (to, cc or bcc) is needed", "")))

def compose_checked(+problem: String, +w: Want, +from: String) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{problem})
    case SNil{}:
      do IO<Out>:
        st : Stamp <- stamp()
        deliver(w, from, st)

def compose_go(+w: Want, +from: String) -> IO(Out):
  compose_checked(check_want(w, from), w, from)

def with_atts(+a: Atts, +to: List<&2, String>, +cc: List<&2, String>, +bcc: List<&2, String>, +subject: String, +text: String, +irt: String, +refs: String, +draft: Bool) -> IO(Out):
  match a:
    case AttsErr{m}:
      pure_out(Err{m})
    case AttsOk{xs}:
      do IO<Out>:
        from : String <- env_or("MAILBEND_EMAIL", "")
        compose_go(Want{to, cc, bcc, subject, text, irt, refs, xs, draft}, from)

# Composes from the common arguments: to, cc, bcc, subject, body,
# in_reply_to, references and attachments ([{path, filename?, content_type?}]).
def t_compose(+args: J.Json, +draft: Bool) -> IO(Out):
  do IO<Out>:
    rs : List<&2, AttR> <- atts_read(Maybe.default(&2, List<&2, J.Json>, J.as_list(J.get(args, "attachments")), []))
    with_atts(atts_collect(rs), strs_arg(args, "to"), strs_arg(args, "cc"), strs_arg(args, "bcc"), str_arg(args, "subject", ""), str_arg(args, "body", ""), str_arg(args, "in_reply_to", ""), str_arg(args, "references", ""), draft)

# ---- reply / forward -------------------------------------------------------------------------

def prefixed(+p: String, +subject: String) -> String:
  Bool.pick(String, String.starts_with(String.to_lower(String.trim(subject)), String.to_lower(p)), subject, p ++ " " ++ subject)

def quote_lines(+ls: List<&2, String>) -> String:
  match ls:
    case Nil{}:
      ""
    case Con{l, t}:
      "> " ++ l ++ "\n" ++ quote_lines(t)

def not_me(+xs: List<&2, String>, +me: String) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{x, t}:
      List.append(&2, String, Bool.pick(List<&2, String>, String.eq(String.to_lower(M.addr_spec(x)), String.to_lower(me)), [], [x]), not_me(t, me))

def addr_push(+cur: String, +acc: List<&2, String>) -> List<&2, String>:
  +a = String.trim(String.reverse(cur))
  Bool.pick(List<&2, String>, String.is_empty(a), acc, a <> acc)

def addr_split(+s: String, +cur: String, +q: Bool, +depth: U32, +esc: Bool, +acc: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      List.reverse(&2, String, addr_push(cur, acc))
    case SCon{c, t}:
      +cut = Bool.not(esc) && Bool.not(q) && U32.is_zero(depth) && Char.is_eq(c, ',')
      +open = Bool.not(esc) && Bool.not(q) && Char.is_eq(c, '(')
      +close = Bool.not(esc) && Bool.not(q) && Char.is_eq(c, ')') && Bool.not(U32.is_zero(depth))
      addr_split(t, Bool.pick(String, cut, "", SCon{c, cur}),
        Bool.pick(Bool, Bool.not(esc) && U32.is_zero(depth) && Char.is_eq(c, '"'), Bool.not(q), q),
        Bool.pick(U32, open, (depth + 1 : U32), Bool.pick(U32, close, (depth - 1 : U32), depth)),
        Bool.not(esc) && (q || Bool.not(U32.is_zero(depth))) && Char.is_eq(c, '\\'),
        Bool.pick(List<&2, String>, cut, addr_push(cur, acc), acc))

# Splits a header address list at commas outside quoted strings and
# "(comments)", honouring "\\" escapes in both.
def addr_list(+s: String) -> List<&2, String>:
  addr_split(s, "", False{}, 0, False{}, [])

def body_text(+p: M.Parts) -> String:
  match p:
    case M.Parts{text, html, a}:
      Bool.pick(String, String.is_empty(text), M.html_text(html), text)

def decoded(+xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{x, t}:
      M.decode_header(x) <> decoded(t)

# The addresses of a header, split before RFC 2047 decoding (a decoded name
# may contain commas).
def hdr_addrs(+hs: List<&2, M.Hdr>, +name: String) -> List<&2, String>:
  decoded(addr_list(M.header(hs, name)))

def reply_to(+hs: List<&2, M.Hdr>) -> List<&2, String>:
  hdr_addrs(hs, Bool.pick(String, String.is_empty(M.header(hs, "reply-to")), "from", "reply-to"))

# Replies read only the first 256 KB of the original; when it is larger the
# quote says so instead of silently quoting a truncated copy.
def cut_note(+cut: Bool) -> String:
  Bool.pick(String, cut, "> [the original is larger than 256 KB and only its start was read, so this quote may be incomplete]\n", "")

def reply_want(+hs: List<&2, M.Hdr>, +p: M.Parts, +cut: Bool, +args: J.Json, +me: String) -> IO(Out):
  do IO<Out>:
    rs : List<&2, AttR> <- atts_read(Maybe.default(&2, List<&2, J.Json>, J.as_list(J.get(args, "attachments")), []))
    with_atts(atts_collect(rs),
      reply_to(hs),
      Bool.pick(List<&2, String>, bool_arg(args, "reply_all", False{}), not_me(List.append(&2, String, hdr_addrs(hs, "to"), hdr_addrs(hs, "cc")), me), []),
      strs_arg(args, "bcc"),
      prefixed("Re:", hdr_text(hs, "subject")),
      str_arg(args, "body", "") ++ "\n\nOn " ++ hdr_text(hs, "date") ++ ", " ++ hdr_text(hs, "from") ++ " wrote:\n" ++ quote_lines(String.lines(body_text(p))) ++ cut_note(cut),
      M.header(hs, "message-id"),
      String.trim(M.header(hs, "references") ++ " " ++ M.header(hs, "message-id")),
      bool_arg(args, "as_draft", False{}))

def fwd_note(+hs: List<&2, M.Hdr>) -> String:
  "\n\n---------- Forwarded message ----------\nFrom: " ++ hdr_text(hs, "from") ++ "\nDate: " ++ hdr_text(hs, "date") ++ "\nSubject: " ++ hdr_text(hs, "subject") ++ "\nTo: " ++ hdr_text(hs, "to") ++ "\n"

def fwd_want(+hs: List<&2, M.Hdr>, +raw: String, +args: J.Json) -> IO(Out):
  do IO<Out>:
    rs : List<&2, AttR> <- atts_read(Maybe.default(&2, List<&2, J.Json>, J.as_list(J.get(args, "attachments")), []))
    with_atts(atts_cons(M.Attach{"forwarded-message.eml", "message/rfc822", raw}, atts_collect(rs)),
      strs_arg(args, "to"), strs_arg(args, "cc"), strs_arg(args, "bcc"),
      prefixed("Fwd:", hdr_text(hs, "subject")),
      str_arg(args, "body", "") ++ fwd_note(hs),
      "", "", bool_arg(args, "as_draft", False{}))

def respond_to(+reply: Bool, +too_big: Bool, +body: String, +args: J.Json, +me: String) -> IO(Out):
  match reply:
    case True{}:
      reply_want(M.headers(M.head_of(M.split(body))), M.parts(body), too_big, args, me)
    case False{}:
      match too_big:
        case True{}:
          pure_out(Err{"the original is larger than 25 MB and cannot be forwarded whole"})
        case False{}:
          fwd_want(M.headers(M.head_of(M.split(body))), body, args)

# Fetches the original (read-only, PEEK), then replies (mode 0) or
# forwards (mode 1).
def orig_msg(+ms: List<&2, I.Msg>, +args: J.Json, +mode: U32, +max: U32, +me: String) -> IO(Out):
  match ms:
    case Nil{}:
      pure_out(Err{"no message with UID " ++ U32.show(u32_arg(args, "uid", 0)) ++ " in " ++ folder_arg(args)})
    case Con{I.Msg{uid, flags, date, size, headers, body}, t}:
      respond_to(U32.is_eq(mode, 0), U32.is_gt(size, max), body, args, me)

def orig_checked(+stale: Bool, +lines: List<&2, I.RLine>, +args: J.Json, +mode: U32, +max: U32, +me: String) -> IO(Out):
  match stale:
    case True{}:
      pure_out(Err{stale_msg()})
    case False{}:
      orig_msg(with_uid(I.fetched(lines), u32_arg(args, "uid", 0)), args, mode, max, me)

# The original is used only if its folder still has the caller's
# UIDVALIDITY (checked in the same session that fetched it).
def orig_found(r: Run, +args: J.Json, +mode: U32, +max: U32, +me: String) -> IO(Out):
  match r:
    case RunErr{m}:
      pure_out(Err{m})
    case RunOk{+lines}:
      orig_checked(Bool.not(uidv_is(I.ok_code(lines, "UIDVALIDITY"), uidv_arg(args))), lines, args, mode, max, me)

def respond_request(+args: J.Json) -> String:
  Bool.pick(String, U32.is_zero(u32_arg(args, "uid", 0)), "\"uid\" (the message to answer) is required",
    Bool.pick(String, U32.is_zero(uidv_arg(args)), uidv_missing(), ""))

def respond_asked(+problem: String, +args: J.Json, +mode: U32, +max: U32) -> IO(Out):
  match problem:
    case SCon{h, t}:
      pure_out(Err{problem})
    case SNil{}:
      do IO<Out>:
        me : String <- env_or("MAILBEND_EMAIL", "")
        r : Run <- imap_run(Ops.plan_get(folder_arg(args), u32_arg(args, "uid", 0), max))
        orig_found(r, args, mode, max, me)

def t_respond(+args: J.Json, +mode: U32) -> IO(Out):
  respond_asked(respond_request(args), args, mode, Bool.pick(U32, U32.is_eq(mode, 0), 262144, max_attachment()))

# ---- dispatch ----------------------------------------------------------------------------------

def run_op(+op: Ops.Op, +args: J.Json) -> IO(Out):
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
      t_mark(args, True{})
    case Ops.OMarkUnread{}:
      t_mark(args, False{})
    case Ops.OMove{}:
      t_move(args)
    case Ops.OTrash{}:
      t_trash(args)
    case Ops.ODelete{}:
      t_delete(args)
    case Ops.OSaveDraft{}:
      t_compose(args, True{})
    case Ops.OSend{}:
      t_compose(args, False{})
    case Ops.OReply{}:
      t_respond(args, 0)
    case Ops.OForward{}:
      t_respond(args, 1)

def gate(+refuse: Bool, +op: Ops.Op, +args: J.Json) -> IO(Out):
  match refuse:
    case True{}:
      pure_out(Err{Ops.name(op) ++ " is disabled: MAILBEND_READ_ONLY is set"})
    case False{}:
      run_op(op, args)

def gated(+op: Ops.Op, +args: J.Json, +ro: Bool) -> IO(Out):
  gate(ro && Bool.not(Ops.is_read_only(op)), op, args)

def call_op(+m: Maybe<&2, Ops.Op>, +name: String, +args: J.Json) -> IO(Out):
  match m:
    case None{}:
      pure_out(Err{"unknown tool: " ++ name})
    case Some{op}:
      do IO<Out>:
        ro : Bool <- read_only_mode()
        gated(op, args, ro)

# Runs the named tool with its JSON arguments.
def call(+name: String, +args: J.Json) -> IO(Out):
  call_op(Ops.from_name(name), name, args)
