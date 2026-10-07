# The pure parts of the mail tools: switches, helper results, argument
# parsing, dry runs, role resolution, folder guards, flag and move results,
# composing, the schema checks and reading threads. IO paths are left to the
# end-to-end suite.

import Base
import ../../src/codec.bend as C
import ../../src/json.bend as J
import ../../src/imap.bend as I
import ../../src/mime.bend as M
import ../../src/ops.bend as Ops
import ../../src/schema.bend as Schema
import ../../src/tools.bend as T
import ../../src/jev.bend as Jev
import ../../src/thread.bend as Th

# Showing values
# --------------

def show_out(o: T.Out) -> String:
  match o:
    case T.Ok{j}:
      "ok " ++ J.show(j)
    case T.Err{m}:
      "err " ++ m
    case T.Partial{j}:
      "partial " ++ J.show(j)

def show_u32s(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      U32.show(x) ++ " " ++ show_u32s(t)

def show_maybe_u32s(m: Maybe<&2, List<&2, U32>>) -> String:
  match m:
    case Some{xs}:
      "[" ++ show_u32s(xs) ++ "]"
    case None{}:
      "none"

def show_maybe(m: Maybe<&2, String>) -> String:
  match m:
    case Some{s}:
      s
    case None{}:
      "none"

def show_bool(b: Bool) -> String:
  Bool.show(b)

def show_flag(f: T.Flag) -> String:
  match f:
    case T.FlagOn{}:
      "on"
    case T.FlagOff{}:
      "off"
    case T.FlagBad{m}:
      "bad " ++ m

def show_switch(s: Jev.Switch) -> String:
  match s:
    case Jev.Off{}:
      "off"
    case Jev.On{c}:
      Jev.content_name(c)

def show_config(c: T.Config) -> String:
  match c:
    case T.Config{ro, drafts, jev}:
      "config " ++ Bool.show(ro) ++ " " ++ Bool.show(drafts) ++ " " ++ show_switch(jev)
    case T.ConfigBad{m}:
      "bad " ++ m

# The configuration of the read-only and drafts-only switches alone.
def switches(r: T.Flag, d: T.Flag) -> String:
  show_config(T.config.put(T.config_of(r, d, False{}, T.FlagOff{}, "", T.FlagOff{}, "")))

# The configuration of the TypeSafe settings alone.
def typesafe(key_set: Bool, t: T.Flag, content: String, zr: T.Flag, key: String) -> String:
  show_config(T.config.put(T.config_of(T.FlagOff{}, T.FlagOff{}, key_set, t, content, zr, key)))

def show_proc(p: T.Proc) -> String:
  match p:
    case T.ProcOk{code, out, err}:
      "ok " ++ U32.show(code) ++ " " ++ out ++ " " ++ err
    case T.ProcRefused{m}:
      "refused " ++ m
    case T.ProcFail{code, m}:
      "fail " ++ U32.show(code) ++ " " ++ m

def show_msgs(ms: List<&2, I.Msg>) -> String:
  match ms:
    case Nil{}:
      ""
    case I.Msg{uid, flags, date, size, headers, body, _} <> t:
      U32.show(uid) ++ " " ++ show_msgs(t)

# A read's result, then the messages it shows to be annotated.
def show_shown(s: T.Shown) -> String:
  match s:
    case T.Listed{o, ms}:
      show_out(o) ++ " | shown " ++ show_msgs(ms)
    case T.Threaded{o, ms, T.Folders{fs, drafts, trash, sent, junk, archive}}:
      show_out(o) ++ " | shown " ++ show_msgs(ms) ++ "with the folders, Sent " ++
        Maybe.default(&2, String, sent, "unknown")
    case T.Whole{o, m, max}:
      show_out(o) ++ " | whole " ++ show_msgs([m]) ++ U32.show(max)

def show_change(c: T.FolderChange) -> String:
  match c:
    case T.FolderCreate{name}:
      "create " ++ name
    case T.FolderRename{from, to}:
      "rename " ++ from ++ " -> " ++ to

def show_line_endings(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\r', t}:
      "\\r" ++ show_line_endings(t)
    case SCon{'\n', t}:
      "\\n" ++ show_line_endings(t)
    case SCon{c, t}:
      SCon{c, show_line_endings(t)}

def json(s: String) -> J.Json:
  Maybe.default(&2, J.Json, J.parse(s), J.JNull{})

# The internal success-or-error wrappers
# --------------------------------------

def show_uids(u: T.Uids()) -> String:
  match u:
    case Done{xs}:
      "uids " ++ show_u32s(xs)
    case Fail{m}:
      "error " ++ m

def show_str(r: Result<&2, &2, String, String>) -> String:
  match r:
    case Done{x}:
      "ok " ++ x
    case Fail{m}:
      "error " ++ m

def show_names(r: Result<&2, &2, String, List<&2, String>>) -> String:
  match r:
    case Done{xs}:
      "names " ++ String.join(xs, ",")
    case Fail{m}:
      "error " ++ m

def show_keys(k: T.Keys()) -> String:
  match k:
    case Done{keys}:
      show_line_endings(I.script([I.CSearch{keys}]))
    case Fail{m}:
      "error " ++ m

def show_attach(a: M.Attach) -> String:
  M.Attach{name, ctype, data} = a
  name ++ "|" ++ ctype ++ "|" ++ data

def show_att(a: T.Attachment()) -> String:
  match a:
    case Done{x}:
      "att " ++ show_attach(x)
    case Fail{m}:
      "error " ++ m

def show_attaches(xs: List<&2, M.Attach>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      show_attach(x) ++ ";" ++ show_attaches(t)

def show_atts(a: T.Attachments()) -> String:
  match a:
    case Done{xs}:
      "atts " ++ show_attaches(xs)
    case Fail{m}:
      "error " ++ m

# Environment switches and the TLS helper
# ---------------------------------------

def check_switches() -> IO(Unit):
  do IO<Unit>:
    IO.print(T.env_pick(Done{""}, "d") ++ " " ++ T.env_pick(Done{"v"}, "d") ++ " " ++
      T.env_pick(Fail{(2, "unset")}, "d"))
    IO.print(String.join([
      show_flag(T.flag_value("X", "")),
      show_flag(T.flag_value("X", "0")),
      show_flag(T.flag_value("X", "FALSE")),
      show_flag(T.flag_value("X", "1")),
      show_flag(T.flag_value("X", "True")),
      show_flag(T.flag_value("X", "yes")),
      show_flag(T.flag_value("X", " 1"))], "|"))
    IO.print(String.join([
      switches(T.FlagOn{}, T.FlagOff{}),
      switches(T.FlagOff{}, T.FlagOn{}),
      switches(T.FlagBad{"r"}, T.FlagBad{"d"}),
      switches(T.FlagOn{}, T.FlagBad{"d"}),
      switches(T.FlagOff{}, T.FlagOff{})], "|"))
    IO.print(typesafe(False{}, T.FlagOn{}, "", T.FlagOff{}, "/k"))
    IO.print(typesafe(False{}, T.FlagOn{}, "Headers", T.FlagOff{}, "/k"))
    IO.print(typesafe(False{}, T.FlagOn{}, "BODY", T.FlagOn{}, "/k"))
    IO.print(typesafe(False{}, T.FlagOff{}, "body", T.FlagOn{}, ""))
    IO.print(typesafe(True{}, T.FlagOff{}, "", T.FlagOff{}, ""))
    IO.print(typesafe(True{}, T.FlagOn{}, "", T.FlagOff{}, "/k"))
    IO.print(typesafe(False{}, T.FlagOn{}, "body", T.FlagOff{}, "/k"))
    IO.print(typesafe(False{}, T.FlagOff{}, "body", T.FlagOff{}, ""))
    IO.print(typesafe(False{}, T.FlagOff{}, "full", T.FlagOff{}, ""))
    IO.print(typesafe(False{}, T.FlagOn{}, "", T.FlagOff{}, "k"))
    IO.print(typesafe(False{}, T.FlagOn{}, "", T.FlagOff{}, ""))
    IO.print(typesafe(False{}, T.FlagBad{"t"}, "", T.FlagOff{}, "/k"))
    IO.print(typesafe(False{}, T.FlagOff{}, "", T.FlagBad{"z"}, ""))
    IO.print(show_bool(T.is_set(Done{""})) ++ " " ++ show_bool(T.is_set(Fail{(2, "unset")})))

def check_helper() -> IO(Unit):
  do IO<Unit>:
    IO.print(String.join([
      show_bool(T.never_started(1)), show_bool(T.never_started(2)),
      show_bool(T.never_started(3)), show_bool(T.never_started(26)),
      show_bool(T.never_started(110))], " "))
    IO.print(String.join([
      show_proc(T.proc_of(Done{(0, ("out", "err"))})),
      show_proc(T.proc_of(Fail{(2, "no such file")})),
      show_proc(T.proc_of(Fail{(110, "timed out")}))], "|"))
    IO.print("[" ++ T.proc_failure(T.ProcOk{0, "o", "e"}) ++ "] " ++
      T.proc_failure(T.ProcRefused{"refused"}) ++ " " ++ T.proc_failure(T.ProcFail{5, "lost"}))
    IO.print(String.join([
      show_bool(T.helper_lost(T.ProcOk{0, "", ""})),
      show_bool(T.helper_lost(T.ProcOk{137, "", ""})),
      show_bool(T.helper_lost(T.ProcRefused{"m"})),
      show_bool(T.helper_lost(T.ProcFail{110, "m"}))], " "))
    IO.print(T.strip_prefix("mailbend-tls: x", "mailbend-tls: ") ++ "|" ++
      T.strip_prefix("y", "mailbend-tls: "))
    IO.print(T.helper_msg("mailbend-tls: first\nsecond\n") ++ "|" ++ T.helper_msg("  plain  "))
    IO.print(show_str(T.helper_path("/bin/x", "MAILBEND_X", "x")) ++ "|" ++
      show_str(T.helper_path("bin/x", "MAILBEND_X", "x")))
    IO.print(T.helper_error(1, "e1"))
    IO.print(T.helper_error(2, "e2"))
    IO.print(T.helper_error(3, "e3"))
    IO.print(T.helper_error(4, "e4"))
    IO.print(T.helper_error(5, "e5"))
    IO.print(T.helper_error(128, "e128"))
    IO.print(T.helper_error(130, "e130"))

def failed_transcript() -> String:
  "L OK in\r\na1 OK done\r\n* SEARCH 3\r\na2 NO [TRYCREATE] no such mailbox\r\nZ OK bye\r\n"

def check_runs() -> IO(Unit):
  do IO<Unit>:
    IO.print("[" ++ T.run_failure(T.imap_code(0, I.frame(failed_transcript()), "")) ++ "]")
    IO.print(T.run_failure(T.imap_code(5, I.frame(failed_transcript()), "x [UIDVALIDITY 9] y")))
    IO.print(T.run_failure(T.imap_code(5, I.frame(failed_transcript()), "")))
    IO.print(T.run_failure(T.imap_code(3, I.frame(failed_transcript()), "mailbend-tls: bad cert")))
    IO.print(show_out(T.changed_out(T.imap_code(0, I.frame(failed_transcript()), ""), [3, 4],
      "INBOX", [])))
    IO.print(T.run_failure(T.imap_result(T.ProcRefused{"no path"})))
    IO.print(T.run_failure(T.imap_result(T.ProcFail{110, "timed out"})))
    IO.print(T.run_failure(T.imap_result(T.ProcOk{4, "", "mailbend-tls: login refused"})))
    IO.print(
      Nat.show(List.length(&2, I.RLine, T.proc_lines(T.ProcOk{0, failed_transcript(), ""}))) ++
        " " ++ Nat.show(List.length(&2, I.RLine, T.proc_lines(T.ProcFail{1, "x"}))))
    IO.print(show_bool(T.ok_at(I.frame(failed_transcript()), 1)) ++ " " ++
      show_bool(T.ok_at(I.frame(failed_transcript()), 2)) ++ " " ++
      show_bool(T.ok_at(I.frame(failed_transcript()), 3)))
    IO.print(show_out(T.smtp_code(0, "250 2.1.0 ok\r\n250 2.0.0 queued as X\r\n221 bye\r\n", "")))
    IO.print(show_out(T.smtp_code(5, "250 ok\r\n550 5.1.1 no such user\r\n", "")))
    IO.print(show_out(T.smtp_code(3, "", "mailbend-tls: tls failed")))
    IO.print(show_out(T.smtp_result(T.ProcRefused{"no path"})))
    IO.print(show_out(T.smtp_result(T.ProcOk{0, "250 sent\r\n", ""})))

# Dry runs
# --------

# What a dry run returns for each kind of change: the IMAP lines (an APPEND
# shows only its size), the SMTP envelope's sender and recipients with the
# message's size and whether a Sent copy would be saved, or the file's path
# and size; and the dry_run argument.
def check_dry_runs() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_out(T.preview(T.ImapPreview{[
      I.CCapability{},
      I.CSelect{"INBOX"},
      I.CExpect{I.uidv_line(7)},
      I.CStore{[3], True{}, I.FDeleted{}},
      I.CExpunge{[3]},
      I.CAppend{"Drafts", [I.FDraft{}], "secret body\r\n"}
    ]})))
    IO.print(show_out(T.preview(T.SmtpPreview{"me@my.org", ["a@x.com", "b@y.com"],
      "Subject: s\r\n\r\nsecret body\r\n", True{}})))
    IO.print(show_out(T.preview(T.SmtpPreview{"me@my.org", ["a@x.com"], "", False{}})))
    IO.print(show_out(T.preview(T.FilePreview{"/dl/all.bin", C.bytes_str([0, 200, 255])})))
    IO.print(show_bool(T.dry_arg(json("{\"dry_run\":true}"))) ++ " " ++
      show_bool(T.dry_arg(json("{\"dry_run\":false}"))) ++ " " ++ show_bool(T.dry_arg(json("{}"))))

# Arguments
# ---------

def check_arguments() -> IO(Unit):
  +args = json("{\"s\":\"v\",\"b\":true,\"n\":7,\"folder\":\"Work\",\"neg\":-1}")
  do IO<Unit>:
    IO.print(T.str_arg(args, "s", "d") ++ " " ++ T.str_arg(args, "n", "d") ++ " " ++
      T.str_arg(args, "x", "d") ++ " " ++ show_bool(T.bool_arg(args, "b", False{})) ++ " " ++
      show_bool(T.bool_arg(args, "s", False{})) ++ " " ++ U32.show(T.u32_arg(args, "n", 1)) ++
      " " ++ U32.show(T.u32_arg(args, "neg", 1)) ++ " " ++ T.folder_arg(args) ++ " " ++
      T.folder_arg(json("{}")))
    IO.print(U32.show(T.clamp(0, 1, 200)) ++ " " ++ U32.show(T.clamp(50, 1, 200)) ++ " " ++
      U32.show(T.clamp(999, 1, 200)))
    IO.print(String.join([
      String.join(T.strs_arg(json("{\"to\":\"a@x\"}"), "to"), ","),
      String.join(T.strs_arg(json("{\"to\":\"  \"}"), "to"), ","),
      String.join(T.strs_arg(json("{\"to\":[\"a@x\",3,\"b@y\"]}"), "to"), ","),
      String.join(T.strs_arg(json("{\"to\":5}"), "to"), ","),
      String.join(T.strs_arg(json("{}"), "to"), ",")], "|"))
    IO.print(String.join([
      show_maybe_u32s(T.uids_from.go(J.unchain(json("[3,4]")))),
      show_maybe_u32s(T.uids_from.go(J.unchain(json("[3,0]")))),
      show_maybe_u32s(T.uids_from.go(J.unchain(json("[\"3\"]")))),
      show_maybe_u32s(T.uids_from.go(J.unchain(json("[]"))))], "|"))
    IO.print(show_uids(T.uids_arg(json("{\"uids\":[3,4]}"))))
    IO.print(show_uids(T.uids_arg(json("{\"uids\":[]}"))))
    IO.print(show_uids(T.uids_arg(json("{\"uids\":[3,-1]}"))))
    IO.print(show_uids(T.uids_arg(json("{\"uid\":7}"))))
    IO.print(show_uids(T.uids_arg(json("{\"uids\":\"3\",\"uid\":8}"))))
    IO.print(show_uids(T.uids_arg(json("{}"))))
    IO.print(J.show(T.uids_json([3, 4])) ++ " " ++ J.show(T.maybe_str(Some{"a"})) ++ " " ++
      J.show(T.maybe_str(None{})) ++ " " ++ J.show(T.maybe_strs(Some{["a", "b"]})) ++ " " ++
      J.show(T.maybe_strs(None{})) ++ " " ++ J.show(T.maybe_num(Some{9})) ++ " " ++
      J.show(T.maybe_num(None{})))

# Folders and their roles
# -----------------------

def folders() -> List<&2, I.Folder>:
  [
    I.Folder{"INBOX", "/", ["\\HasNoChildren"]},
    I.Folder{"Deleted Messages", "/", ["\\Trash"]},
    I.Folder{"Trash", "/", []},
    I.Folder{"Sent Messages", "/", []},
    I.Folder{"Drafts", "/", ["\\Noselect"]},
    I.Folder{"Junk", "/", ["\\HasNoChildren"]},
    I.Folder{"Spam", "/", ["\\Junk", "\\NonExistent"]},
    I.Folder{"Archive", "/", ["\\Archive"]},
    I.Folder{"Archive2", "/", ["\\Archive"]},
    I.Folder{"Work", "/", ["\\Flagged"]},
    I.Folder{"Notes", "/", []}
  ]

def check_roles() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_bool(T.recognized_role(["\\HasChildren", "\\ALL"])) ++ " " ++
      show_bool(T.recognized_role(["\\HasChildren"])) ++ " " ++
      show_bool(T.selectable(["\\noselect"])) ++ " " ++
      show_bool(T.selectable(["\\NonExistent"])) ++ " " ++ show_bool(T.selectable([])))
    IO.print(String.join([
      show_maybe(T.resolved_role(folders(), "", "\\Trash", "Trash", "Deleted Messages")),
      show_maybe(T.resolved_role(folders(), "", "\\Sent", "Sent", "Sent Messages")),
      show_maybe(T.resolved_role(folders(), "", "\\Drafts", "Drafts", "Drafts")),
      show_maybe(T.resolved_role(folders(), "", "\\Junk", "Junk", "Junk")),
      show_maybe(T.resolved_role(folders(), "", "\\Archive", "Archive", "Archive"))], "|"))
    IO.print(show_maybe(T.resolved_role(folders(), "Notes", "\\Drafts", "Drafts", "Drafts")) ++
      "|" ++ show_maybe(T.resolved_role(folders(), "Nope", "\\Drafts", "Drafts", "Drafts")) ++
      "|" ++ show_maybe(T.resolved_role(folders(), "inbox", "\\Drafts", "Drafts", "Drafts")) ++
      "|" ++ show_maybe(T.resolved_role(folders(), "", "\\Trash", "Trash", "Trash")))
    IO.print("[" ++ T.invalid_override(folders(), "", "MAILBEND_X") ++ "] [" ++
      T.invalid_override(folders(), "Notes", "MAILBEND_X") ++ "] " ++
      T.invalid_override(folders(), "Drafts", "MAILBEND_X"))
    IO.print(show_out(T.probe_fs(T.validate_overrides(folders(), "", "", "", "", ""),
      I.frame("* CAPABILITY IMAP4rev1 MOVE IDLE\r\na1 OK\r\n"), "imap.example.com", "me@x")))
    IO.print(show_out(T.probe_fs(
      T.validate_overrides(folders(), "Notes", "", "", "Junk", "Archive2"), [], "h", "me@x")))
    IO.print(show_out(T.folders_fs(T.validate_overrides(folders(), "", "Nope", "", "Bad", ""))))
    IO.print(show_out(T.folders_fs(T.validate_overrides(folders(), "", "", "", "Spam", ""))))
    IO.print(show_out(T.folders_fs(T.validate_overrides(T.merge_folders(
      [I.Folder{"Sent Messages", "/", ["\\Sent"]}, I.Folder{"inbox", "/", ["\\Marked"]},
        I.Folder{"New", ".", ["\\All"]}],
      [I.Folder{"INBOX", "/", ["\\HasNoChildren", "\\Marked"]},
        I.Folder{"Sent Messages", "/", []}]),
      "", "", "", "", ""))))
    IO.print(String.join(T.conventional_names(), ",") ++ " " ++
      show_maybe(T.unique_folder([I.Folder{"A", "/", ["\\Noselect"]}])) ++ " " ++
      show_maybe(T.unique_folder([I.Folder{"A", "/", []}, I.Folder{"B", "/", []}])))

# Search, fetch and new mail
# --------------------------

def raw_message() -> String:
  String.concat([
    "From: =?UTF-8?Q?Jos=C3=A9?= <jose@example.com>\r\n",
    "To: me@x.com\r\n",
    "Subject: Lunch\r\n",
    "Date: Mon, 1 Feb 2026 10:00:00 +0000\r\n",
    "Message-ID: <m1@example.com>\r\n",
    "\r\n",
    "Hello\r\nthere\r\n"])

def html_message() -> String:
  String.concat([
    "From: a@x.com\r\n",
    "Subject: Hi\r\n",
    "Content-Type: text/html\r\n",
    "\r\n",
    "<p>Hi &amp; bye</p>\r\n"])

def message(uid: U32, +body: String) -> I.Msg:
  I.Msg{uid, ["\\Seen"], "1-Feb-2026 10:00:00 +0000", 300, body, body, I.VNil{}}

def headers_transcript(uidv: U32) -> String:
  String.concat([
    "L OK in\r\n",
    "* OK [UIDVALIDITY " ++ U32.show(uidv) ++ "] ok\r\n",
    "a1 OK [READ-ONLY] examined\r\n",
    "* 1 FETCH (UID 5 FLAGS (\\Seen))\r\n",
    "* 1 FETCH (UID 5 FLAGS (\\Seen) INTERNALDATE \"1-Feb-2026 10:00:00 +0000\"",
    " RFC822.SIZE 42 BODY[HEADER.FIELDS (SUBJECT)] {16}\r\nSubject: Lunch\r\n)\r\n",
    "* 2 FETCH (UID 9 FLAGS ())\r\n",
    "* 3 FETCH (UID 4 FLAGS (\\Flagged))\r\n",
    "* 3 FETCH (UID 4 FLAGS (\\Flagged) INTERNALDATE \"2-Feb-2026 10:00:00 +0000\"",
    " RFC822.SIZE 7 BODY[HEADER.FIELDS (SUBJECT)] {13}\r\nSubject: Hi\r\n",
    " BODY[]<0> {17}\r\nSubject: Hi\r\n\r\nyo)\r\n",
    "a2 OK fetched\r\n",
    "Z OK bye\r\n"])

def check_search() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_keys(T.keys_of(json("{}"))))
    IO.print(show_keys(T.keys_of(json(String.concat([
      "{\"before\":\"2026-03-01\",\"since\":\"2026-02-01\",\"from\":\"a\",\"to\":\"b\",",
      "\"cc\":\"c\",\"subject\":\"s\",\"body\":\"y\",\"text\":\"t\",\"unseen\":true,",
      "\"seen\":true,\"flagged\":true}"])))))
    IO.print(show_keys(T.keys_of(json("{\"since\":\"bad\",\"before\":\"worse\"}"))))
    IO.print(show_keys(T.keys_of(json("{\"since\":\"2026-02-01\",\"before\":\"worse\"}"))))
    IO.print(show_keys(T.keys_of(json("{\"from\":\"\",\"unseen\":false}"))))
    IO.print(show_msgs(T.requested([message(5, ""), message(9, ""), message(4, "")], [4, 5])) ++
      "|" ++ show_msgs(T.newest_first([message(5, ""), message(9, ""), message(4, "")])) ++
      "|" ++ show_msgs(T.oldest_first([message(5, ""), message(9, ""), message(4, "")])) ++
      "|" ++ show_u32s(T.desc([3, 9, 1])) ++ "|" ++ show_u32s(T.asc([3, 9, 1])) ++
      "|" ++ show_bool(T.uid_in(3, [1, 3])) ++ " " ++ show_bool(T.uid_in(2, [1, 3])))
    IO.print(show_shown(T.search_headers(T.imap_code(0, I.frame(headers_transcript(7)), ""),
      "INBOX", Some{7}, 12, [4, 5])))
    IO.print(show_shown(T.search_headers(T.imap_code(0, I.frame(headers_transcript(8)), ""),
      "INBOX", Some{7}, 12, [4, 5])))
    IO.print(show_shown(T.search_headers(T.imap_code(3, [], "mailbend-tls: down"),
      "INBOX", Some{7}, 12, [4, 5])))
    IO.print(J.show(T.summary(message(5, raw_message()))))

def check_get() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_shown(T.get_msg([message(5, raw_message())], "INBOX", 5, Some{7}, 262144)))
    IO.print(show_shown(T.get_msg([message(6, html_message())], "INBOX", 6, None{}, 100)))
    IO.print(show_shown(T.get_msg([], "Work", 8, Some{7}, 100)))
    IO.print(show_msgs(T.with_uid([message(9, "x"), message(5, ""), message(5, "y")], 5, True{})) ++
      "|" ++ show_msgs(T.with_uid([message(9, "x"), message(5, "")], 5, True{})) ++
      "|" ++ show_msgs(T.with_uid([message(5, "")], 5, False{})))
    IO.print(show_shown(T.get_out(T.imap_code(0, I.frame(headers_transcript(7)), ""), "INBOX", 4,
      1000)))
    IO.print(show_shown(T.get_out(T.imap_code(0, I.frame(headers_transcript(7)), ""), "INBOX", 8,
      1000)))
    IO.print(show_shown(T.get_out(T.imap_code(0, I.frame(headers_transcript(7)), ""), "INBOX", 9,
      1000)))

def check_new() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_u32s(T.above([3, 9, 5, 2], 3)) ++ "|" ++ U32.show(T.last_or([4, 5], 1)) ++ " " ++
      U32.show(T.last_or([], 1)))
    IO.print("[" ++ T.new_request(0, 0) ++ "] [" ++ T.new_request(5, 7) ++ "] " ++
      T.new_request(5, 0))
    IO.print(show_shown(T.new_headers(T.imap_code(0, I.frame(headers_transcript(7)), ""),
      "INBOX", 7, 9, True{}, [4, 5])))
    IO.print(show_shown(T.new_headers(T.imap_code(0, I.frame(headers_transcript(8)), ""),
      "INBOX", 7, 9, False{}, [4, 5])))
    IO.print(show_shown(T.new_headers(T.imap_code(2, [], "bad config"), "INBOX", 7, 9, False{},
      [4, 5])))

# UID checks and change results
# -----------------------------

def check_changes() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_bool(T.uidv_is(Some{7}, 7)) ++ " " ++ show_bool(T.uidv_is(Some{7}, 8)) ++ " " ++
      show_bool(T.uidv_is(None{}, 0)) ++ " " ++ show_bool(T.same_uidv(Some{7}, Some{7})) ++ " " ++
      show_bool(T.same_uidv(Some{7}, None{})) ++ " " ++ show_bool(T.same_uidv(None{}, None{})))
    IO.print("[" ++ T.uidv_problem(I.frame(headers_transcript(7)), 7) ++ "] " ++
      T.uidv_problem(I.frame(headers_transcript(7)), 8))
    IO.print(T.uidv_missing())
    IO.print(show_u32s(T.minus([5, 3, 4, 3], [3])))
    IO.print(show_out(T.changed_found([], [3], "INBOX", [])))
    IO.print(show_out(T.changed_found([3], [4, 3, 5], "INBOX", [J.kv("ok", J.bool(True{}))])))
    IO.print(show_out(T.changed_of(I.frame("* SEARCH 5 3\r\na1 OK\r\n"), [3, 4, 5], "Work", [])))
    IO.print(show_out(T.changed_out(T.imap_code(5, I.frame(failed_transcript()), ""), [3],
      "INBOX", [])))

# Flags and colours
# -----------------

def show_marks(m: T.Mark) -> String:
  J.show(J.obj(T.mark_kvs("INBOX", m)))

def show_colour(m: Maybe<&2, I.Colour>) -> String:
  match m:
    case Some{c}:
      I.colour_name(c)
    case None{}:
      "none"

# A coloured flag change's session on UIDs 3 and 4 (only 3 exists): the
# SELECT with `perm`, its PERMANENTFLAGS line ("" for none), the guard's
# search, then `rest`, the answers from the first STORE (a3) on.
def flag_transcript(perm: String, rest: String) -> String:
  "L OK in\r\n" ++ perm ++ "a1 OK [READ-WRITE] selected\r\n* SEARCH 3\r\na2 OK searched\r\n" ++
    rest

# Every STORE and the FETCH answered OK, the FETCH reporting `flags`.
def all_stored(flags: String) -> String:
  "a3 OK\r\na4 OK\r\na5 OK\r\na6 OK\r\n" ++ flags ++ "a7 OK fetched\r\nZ OK bye\r\n"

def blue_plan() -> List<&2, I.Cmd>:
  Ops.plan_flag("INBOX", [3, 4], Some{I.ColBlue{}}, 7)

def flag_out(p: T.Proc, plan: List<&2, I.Cmd>, mark: T.Mark) -> String:
  show_out(T.flag_out(p, plan, [3, 4], "INBOX", mark))

def permanent_all() -> String:
  "* OK [PERMANENTFLAGS (\\Flagged \\*)] ok\r\n"

def fetched_flags(flags: String) -> String:
  "* 1 FETCH (UID 3 FLAGS (" ++ flags ++ "))\r\n"

# The result of flagging UIDs 3 and 4 blue, from the helper's run `p`.
def blue(p: T.Proc) -> String:
  flag_out(p, blue_plan(), T.MarkFlag{Some{I.ColBlue{}}})

def check_flags() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_marks(T.MarkSeen{True{}}) ++ " " ++ show_marks(T.MarkSeen{False{}}) ++ " " ++
      show_marks(T.MarkFlag{Some{I.ColRed{}}}) ++ " " ++ show_marks(T.MarkUnflag{}))
    IO.print(show_colour(T.mark_colour(T.MarkFlag{Some{I.ColGrey{}}})) ++ " " ++
      show_colour(T.mark_colour(T.MarkFlag{None{}})) ++ " " ++
      show_colour(T.mark_colour(T.MarkUnflag{})))
    IO.print(
      show_bool(T.shows_colour(["\\Flagged", "$MailFlagBit2"], I.colour_bits(I.ColBlue{}))) ++
      " " ++ show_bool(T.shows_colour(["$MailFlagBit2"], I.colour_bits(I.ColBlue{}))) ++
      " " ++ show_bool(T.shows_colour(["\\Flagged", "$MailFlagBit0"], I.colour_bits(I.ColRed{}))) ++
      " " ++ show_bool(T.colour_permanent(["\\Flagged", "\\*"])) ++
      " " ++ show_bool(T.colour_permanent(["\\Flagged"])) ++
      " " ++ show_bool(T.colour_permanent(["\\*"])) ++
      " " ++ show_bool(T.colour_permanent(["\\Flagged", "$MailFlagBit0", "$MailFlagBit1",
        "$MailFlagBit2"])) ++
      " " ++ show_bool(T.session_only(None{})) ++
      " " ++ show_bool(T.session_only(Some{["\\Flagged"]})))
    IO.print(J.show(T.kept_json(True{}, True{})) ++ " " ++ J.show(T.kept_json(False{}, True{})) ++
      " " ++ J.show(T.kept_json(False{}, False{})))
    IO.print(String.join(T.store_changes(blue_plan(), 1, I.frame(flag_transcript("",
      "a3 OK\r\na4 NO\r\n")), T.Acked{}), ",") ++ "|" ++
      String.join(T.store_changes(blue_plan(), 1, I.frame(flag_transcript("",
      "a3 OK\r\na4 NO\r\n")), T.Unanswered{False{}}), ",") ++ "|" ++
      String.join(T.store_changes(blue_plan(), 1, I.frame(flag_transcript("",
      "a3 OK\r\n")), T.Unanswered{False{}}), ",") ++ "|" ++
      String.join(T.store_changes(blue_plan(), 1, [], T.Unanswered{True{}}), ","))
    IO.print(T.changes_text([]) ++ "|" ++ T.changes_text(["+\\Flagged", "-$MailFlagBit0"]))
    IO.print(T.cut_text(True{}, [], []))
    IO.print(T.cut_text(False{}, ["+\\Flagged"], []))
    IO.print(blue(T.ProcOk{0, flag_transcript(permanent_all(),
      all_stored(fetched_flags("\\Flagged $MailFlagBit2"))), ""}))
    IO.print(blue(T.ProcOk{0, flag_transcript(permanent_all(),
      all_stored(fetched_flags("\\Flagged $MailFlagBit0"))), ""}))
    IO.print(blue(T.ProcOk{0, flag_transcript("",
      all_stored(fetched_flags("\\Flagged $MailFlagBit2"))), ""}))
    IO.print(blue(T.ProcOk{0, flag_transcript("* OK [PERMANENTFLAGS (\\Flagged)] ok\r\n",
      all_stored(fetched_flags("\\Flagged $MailFlagBit2"))), ""}))
    IO.print(blue(T.ProcOk{0, flag_transcript(permanent_all(), all_stored("")), ""}))
    IO.print(blue(T.ProcOk{5, flag_transcript("", "a3 OK\r\na4 NO keyword refused\r\nZ OK bye\r\n"),
      ""}))
    IO.print(blue(T.ProcOk{5, flag_transcript("", "a3 OK\r\na4 OK\r\na5 OK\r\na6 OK\r\na7 NO\r\n"),
      ""}))
    IO.print(blue(T.ProcFail{110, "timed out"}))
    IO.print(blue(T.ProcOk{5, "L OK in\r\na1 OK\r\n* SEARCH\r\na2 OK\r\na3 NO\r\nZ OK bye\r\n",
      ""}))
    IO.print(blue(T.ProcOk{5, "L OK in\r\na1 OK\r\na2 NO [UIDVALIDITY 9]\r\nZ OK bye\r\n",
      "[UIDVALIDITY 9]"}))
    IO.print(flag_out(T.ProcOk{0, String.concat(["L OK in\r\na1 OK\r\n* SEARCH 3\r\na2 OK\r\n",
      "a3 OK\r\n", fetched_flags("\\Seen \\Flagged"), "a4 OK\r\nZ OK bye\r\n"]), ""},
      Ops.plan_flag("INBOX", [3, 4], None{}, 7), T.MarkFlag{None{}}))
    IO.print(flag_out(T.ProcOk{0, flag_transcript("", all_stored(fetched_flags(""))), ""},
      Ops.plan_unflag("INBOX", [3, 4], 7), T.MarkUnflag{}))
    IO.print(show_out(T.mark_result(
      T.ProcOk{0, "L OK\r\na1 OK\r\n* SEARCH 4\r\na2 OK\r\na3 OK\r\n", ""},
      Ops.plan_mark("INBOX", [3, 4], True{}, 7), [3, 4], "INBOX", T.MarkSeen{True{}})))

# Moves, trash, delete and labels
# -------------------------------

def copy_plan() -> List<&2, I.Cmd>:
  Ops.plan_move("INBOX", [3], "Work", False{}, True{}, 7)

def move_plan() -> List<&2, I.Cmd>:
  Ops.plan_move("INBOX", [3], "Work", True{}, True{}, 7)

def copy_transcript(rest: String) -> String:
  "L OK\r\na1 OK\r\n* OK [UIDVALIDITY 7]\r\na2 OK\r\n* SEARCH 3\r\na3 OK\r\n" ++ rest

def moved(p: T.Proc, plan: List<&2, I.Cmd>, move: Bool) -> String:
  show_out(T.moved_out(p, plan, "INBOX", [3], "Work", move))

def check_moves() -> IO(Unit):
  do IO<Unit>:
    IO.print(T.method_name(True{}) ++ "|" ++ T.method_name(False{}) ++ " " ++
      show_bool(T.has_copy(copy_plan())) ++ " " ++ show_bool(T.has_copy(move_plan())))
    IO.print(
      show_bool(T.copy_unfinished(copy_plan(), I.frame(copy_transcript("a4 OK\r\n")))) ++ " " ++
      show_bool(T.copy_unfinished(copy_plan(), I.frame(copy_transcript("a4 NO\r\n")))) ++ " " ++
      show_bool(T.copy_unfinished(copy_plan(), I.frame(copy_transcript(
        "a4 OK\r\na5 OK\r\na6 OK\r\n")))) ++ " " ++
      show_bool(T.interrupted(copy_plan(), T.ProcFail{110, "x"})) ++ " " ++
      show_bool(T.interrupted(move_plan(), T.ProcFail{110, "x"})) ++ " " ++
      show_bool(T.interrupted(copy_plan(), T.ProcRefused{"x"})))
    IO.print(moved(T.ProcOk{0, "L OK\r\na1 OK\r\n* SEARCH 3\r\na2 OK\r\na3 OK\r\n", ""},
      move_plan(), True{}))
    IO.print(moved(T.ProcOk{0, copy_transcript("a4 OK\r\na5 OK\r\na6 OK\r\n"), ""}, copy_plan(),
      False{}))
    IO.print(moved(T.ProcOk{5, copy_transcript("a4 OK\r\na5 NO cannot\r\n"), ""}, copy_plan(),
      False{}))
    IO.print(moved(T.ProcOk{5, copy_transcript("a4 NO [OVERQUOTA] full\r\n"), ""}, copy_plan(),
      False{}))
    IO.print(moved(T.ProcFail{110, "timed out"}, copy_plan(), False{}))
    IO.print(moved(T.ProcRefused{"not absolute"}, copy_plan(), False{}))
    IO.print("[" ++ T.move_request(7, "INBOX", "Work") ++ "] " ++
      T.move_request(7, "INBOX", "inbox") ++ " | " ++ T.move_request(7, "INBOX", "") ++ " | " ++
      T.move_request(0, "INBOX", "Work"))
    IO.print("[" ++ T.label_request(7, "INBOX", "Work") ++ "] " ++
      T.label_request(7, "Work", "Work") ++ " | " ++ T.label_request(0, "INBOX", "Work"))
    IO.print("[" ++ T.delete_request("permanently-delete", 7) ++ "] " ++
      T.delete_request("yes", 7) ++ " | " ++ T.delete_request("permanently-delete", 0))
    IO.print("[" ++ T.respond_request(json("{\"uid\":3,\"uidvalidity\":7}")) ++ "] " ++
      T.respond_request(json("{\"uidvalidity\":7}")) ++ " | " ++
      T.respond_request(json("{\"uid\":3}")))
    IO.print(show_bool(I.same_name("Inbox", "INBOX")) ++ " " ++
      show_bool(I.same_name("work", "Work")))

# Folder creation, renaming and labels
# ------------------------------------

def guarded_folders() -> List<&2, I.Folder>:
  [
    I.Folder{"INBOX", "/", []},
    I.Folder{"Drafts", "/", ["\\Drafts"]},
    I.Folder{"Bin", "/", ["\\Trash"]},
    I.Folder{"Archive", "/", []},
    I.Folder{"Archive/2024", "/", []},
    I.Folder{"Work", "/", []},
    I.Folder{"Work/Sub", "/", []},
    I.Folder{"Work/Gone", "/", ["\\NonExistent"]},
    I.Folder{"Team/Sub", "/", []},
    I.Folder{"Projects", "/", []},
    I.Folder{"Locked", "/", ["\\Noselect"]},
    I.Folder{"Mail", "/", []},
    I.Folder{"Mail/Kept", "/", []}
  ]

def guard() -> T.Guard:
  T.guard_of(guarded_folders(), Some{"Drafts"}, Some{"Bin"}, None{}, None{}, Some{"Mail/Kept"})

def flat_guard() -> T.Guard:
  T.guard_of([I.Folder{"INBOX", "", []}, I.Folder{"A", "", []}], None{}, None{}, None{}, None{},
    None{})

def problem(s: String) -> String:
  "[" ++ s ++ "]"

def check_guard() -> IO(Unit):
  do IO<Unit>:
    IO.print(String.join(T.guard_reserved(guard()), ",") ++ " " ++ T.guard_delim(guard()) ++
      " [" ++ T.guard_delim(flat_guard()) ++ "] " ++
      T.delim_of([I.Folder{"A", ".", []}, I.Folder{"INBOX", "/", []}]) ++ " " ++
      T.delim_of([I.Folder{"A", "", []}, I.Folder{"B", ".", []}]))
    IO.print(String.join([
      show_bool(T.reserved_target(guard(), "inbox")),
      show_bool(T.reserved_target(guard(), "INBOX/x")),
      show_bool(T.reserved_target(guard(), "drafts/x")),
      show_bool(T.reserved_target(guard(), "Archive/x")),
      show_bool(T.reserved_target(guard(), "Mail")),
      show_bool(T.reserved_target(guard(), "Work")),
      show_bool(T.reserved_source(guard(), "Mail")),
      show_bool(T.reserved_source(guard(), "Work"))], " "))
    IO.print(String.join(T.levels("/", "a/b//c"), "|") ++ " " ++
      String.join(T.levels("", "a/b"), "|") ++ " " ++
      show_bool(T.has_empty_level(["a", ""])) ++ " " ++
      show_bool(T.has_empty_level(["a"])) ++ " [" ++ T.parent_of("/", "a/b/c") ++ "] [" ++
      T.parent_of("/", "a") ++ "] [" ++
      T.parent_of("", "a/b") ++ "]")
    IO.print(T.canonical_name(guard(), "inbox/x") ++ " " ++
      T.canonical_name(guard(), "Work/inbox") ++ " " ++ T.canonical_name(guard(), "inbox") ++
      " " ++ T.canonical_name(flat_guard(), "inbox"))
    IO.print(problem(T.raw_name_problem("")) ++
      problem(T.raw_name_problem(C.bytes_str([97, 1]))) ++ problem(T.raw_name_problem("ok")))
    IO.print(problem(T.shape_problem(flat_guard(), "a/b")) ++
      problem(T.shape_problem(flat_guard(), "a.b")) ++
      problem(T.shape_problem(flat_guard(), "ab")) ++
      problem(T.shape_problem(guard(), "a//b")) ++
      problem(T.shape_problem(guard(), "/a")) ++
      problem(T.shape_problem(guard(), "a/b")))
    IO.print(problem(T.create_problem(guard(), "Work")))
    IO.print(problem(T.create_problem(guard(), "To Delete")))
    IO.print(problem(T.create_problem(guard(), "Work/To Delete")))
    IO.print(problem(T.create_problem(guard(), "Drafts/x")))
    IO.print(problem(T.create_problem(guard(), "Nope/x")))
    IO.print(problem(T.create_problem(guard(), "Work/New")))
    IO.print(problem(T.create_problem(guard(), "Mail/Kept/x")))
    IO.print(problem(T.rename_problem(guard(), "Nope", "Other")))
    IO.print(problem(T.rename_problem(guard(), "Mail", "Post")))
    IO.print(problem(T.rename_problem(guard(), "Work", "Work/Inner")))
    IO.print(problem(T.rename_problem(guard(), "Work", "Projects")))
    IO.print(problem(T.rename_problem(guard(), "Work", "Team")))
    IO.print(problem(T.rename_problem(guard(), "Work", "Projects/Work")))
    IO.print(problem(T.rename_problem(guard(), "Work", "Drafts/Work")))
    IO.print(problem(T.label_problem(guard(), "Nope")))
    IO.print(problem(T.label_problem(guard(), "Locked")))
    IO.print(problem(T.label_problem(guard(), "Bin")))
    IO.print(problem(T.label_problem(guard(), "Work")))
    IO.print(problem(T.change_raw_problem(T.FolderRename{"", "x"})) ++
      problem(T.change_raw_problem(T.FolderRename{"x", ""})) ++
      problem(T.change_raw_problem(T.FolderCreate{"x"})))
    IO.print(problem(T.change_problem(guard(), T.FolderCreate{"Work"})) ++
      problem(T.change_problem(guard(), T.FolderRename{"Work", "Fresh"})))
    IO.print(show_change(T.change_canonical(guard(), T.FolderCreate{"inbox/x"})) ++ " | " ++
      show_change(T.change_canonical(guard(), T.FolderRename{"inbox/a", "inbox/b"})))
    IO.print(String.join(T.subscribed_tree("/", "Work", guarded_folders(),
      [I.Folder{"Work", "/", []}, I.Folder{"Work/Gone", "/", []}, I.Folder{"Work/Sub", "/", []},
        I.Folder{"Projects", "/", []}]), ","))
    IO.print(show_line_endings(I.script(T.change_plan(guard(), [I.Folder{"Work/Sub", "/", []}],
      T.FolderRename{"Work", "Fresh"}))))
    IO.print(show_line_endings(I.script(T.change_plan(guard(), [], T.FolderCreate{"New"}))))
    IO.print(T.change_verb(T.FolderCreate{"a"}) ++ " " ++
      T.change_verb(T.FolderRename{"a", "b"}) ++ " " ++
      J.show(J.obj(T.change_result(T.FolderCreate{"a"}))) ++ " " ++
      J.show(J.obj(T.change_result(T.FolderRename{"a", "b"}))))

def rename_plan() -> List<&2, I.Cmd>:
  Ops.plan_rename("Work", "Fresh", ["Work", "Work/Sub"])

def folder_out(p: T.Proc, plan: List<&2, I.Cmd>, c: T.FolderChange) -> String:
  show_out(T.folder_out(p, plan, c))

def check_folder_results() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_out(T.folder_done(True{}, True{}, T.FolderCreate{"New"}, "")))
    IO.print(show_out(T.folder_done(False{}, False{}, T.FolderCreate{"New"}, "refused")))
    IO.print(show_out(T.folder_done(True{}, False{}, T.FolderRename{"A", "B"}, "refused")))
    IO.print(
      show_bool(T.folder_unanswered(T.ProcOk{5, "L OK\r\na1 OK\r\nZ OK\r\n", ""})) ++ " " ++
      show_bool(T.folder_unanswered(T.ProcOk{5, "L OK\r\na1 OK\r\na2 NO\r\n", ""})) ++ " " ++
      show_bool(T.folder_unanswered(T.ProcOk{3, "", ""})) ++ " " ++
      show_bool(T.folder_unanswered(T.ProcFail{110, "x"})) ++ " " ++
      show_bool(T.folder_unanswered(T.ProcRefused{"x"})))
    IO.print(folder_out(T.ProcOk{0, "L OK\r\na1 OK\r\na2 OK\r\na3 OK\r\n", ""},
      Ops.plan_create("New"), T.FolderCreate{"New"}))
    IO.print(folder_out(T.ProcOk{5, "L OK\r\na1 OK\r\na2 OK\r\na3 NO\r\n", ""},
      Ops.plan_create("New"), T.FolderCreate{"New"}))
    IO.print(folder_out(T.ProcOk{5, "L OK\r\na1 OK\r\na2 NO [ALREADYEXISTS] exists\r\n", ""},
      Ops.plan_create("New"), T.FolderCreate{"New"}))
    IO.print(folder_out(T.ProcFail{110, "timed out"}, Ops.plan_create("New"),
      T.FolderCreate{"New"}))
    IO.print(folder_out(T.ProcRefused{"not absolute"}, Ops.plan_create("New"),
      T.FolderCreate{"New"}))
    IO.print(folder_out(T.ProcOk{5, "L OK\r\na1 OK\r\na2 OK\r\na3 OK\r\na4 OK\r\na5 NO\r\n", ""},
      rename_plan(), T.FolderRename{"Work", "Fresh"}))
    IO.print(folder_out(T.ProcOk{5, "L OK\r\na1 OK\r\na2 OK\r\na3 NO\r\n", ""},
      rename_plan(), T.FolderRename{"Work", "Fresh"}))

# Composing
# ---------

def want(to: List<&2, String>, bcc: List<&2, String>, draft: Bool) -> T.Want:
  T.Want{to, ["c@y.com"], bcc, "Subject", "Body", "<irt@x>", "<r@x>", [], draft, False{},
    Jev.Fresh{}, Jev.Off{}}

def check_drafts(+st: T.Stamp, +w: T.Want) -> IO(Unit):
  T.Stamp{date, token} = st
  do IO<Unit>:
    IO.print(date ++ " " ++ token ++ " " ++ T.boundary_of(st))
    IO.print(T.msgid_of(T.draft_of(w, "me@my.org", st, True{})) ++ " " ++
      String.join(T.all_rcpts(w), ",") ++ " " ++ show_bool(T.is_draft(w)) ++ " " ++
      String.join(T.specs(T.all_rcpts(w)), ","))
    IO.print(show_line_endings(M.compose(T.draft_of(w, "me@my.org", st, True{}), "B")))
    IO.print(show_line_endings(M.compose(T.draft_of(w, "me@my.org", st, False{}), "B")))

def check_compose() -> IO(Unit):
  do IO<Unit>:
    IO.print(C.bytes_str([72, 105]) ++ " " ++ T.basename("/a/b/c.txt") ++ " " ++
      T.basename("c") ++ " [" ++ T.basename("/a/") ++ "]")
    IO.print(String.join([
      T.ext_type("a.PDF"), T.ext_type("a.txt"), T.ext_type("a.md"), T.ext_type("a.log"),
      T.ext_type("a.csv"), T.ext_type("a.html"), T.ext_type("a.htm"), T.ext_type("a.json"),
      T.ext_type("a.png"), T.ext_type("a.jpg"), T.ext_type("a.JPEG"), T.ext_type("a.gif"),
      T.ext_type("a.zip"), T.ext_type("a.eml"), T.ext_type("a.doc"), T.ext_type("pdf")], ","))
    IO.print(show_att(T.att_proc(T.ProcOk{0, "data", ""}, "a.txt", "text/plain")) ++ " | " ++
      show_att(T.att_proc(T.ProcOk{3, "", "mailbend-tls: mailbend-attach: too big\n"}, "a",
        "b")) ++
      " | " ++ show_att(T.att_proc(T.ProcRefused{"no path"}, "a", "b")) ++ " | " ++
      show_att(T.att_proc(T.ProcFail{110, "timed out"}, "a", "b")))
    IO.print(U32.show(C.byte_len("héllo")) ++ " " ++
      U32.show(T.att_size(Done{M.Attach{"a", "b", "xyz"}})) ++ " " ++
      U32.show(T.att_size(Fail{"x"})) ++ " " ++
      show_bool(T.att_ok(Done{M.Attach{"a", "b", ""}})) ++ " " ++
      show_bool(T.att_ok(Fail{"x"})))
    IO.print(show_atts(T.atts_collect([Done{M.Attach{"a", "t", "1"}},
      Done{M.Attach{"b", "t", "2"}}])))
    IO.print(show_atts(T.atts_collect([Done{M.Attach{"a", "t", "1"}}, Fail{"first"},
      Fail{"not read"}])))
    IO.print(show_atts(T.atts_cons(M.Attach{"f", "message/rfc822", "raw"}, T.atts_collect([]))) ++
      " | " ++ show_atts(T.atts_cons(M.Attach{"f", "t", "raw"}, Fail{"bad"})))
    IO.print(SCon{C.hex_low(0), SCon{C.hex_low(9), SCon{C.hex_low(10), SCon{C.hex_low(15),
      SNil{}}}}} ++ " " ++ C.hex8(0) ++ " " ++
      C.hex8(3735928559) ++ " " ++ C.hex8(4294967295) ++ " " ++ C.hex8(305419896))
    IO.print(U32.show(T.secs_of(T.ProcOk{0, " 1700000000\n", ""})) ++ " " ++
      U32.show(T.secs_of(T.ProcOk{0, "x", ""})) ++ " " ++
      U32.show(T.secs_of(T.ProcRefused{"x"})) ++
      " " ++ U32.show(T.rand_of(Done{5})) ++ " " ++ U32.show(T.rand_of(Fail{(1, "x")})))
    IO.print(T.domain_of("A <a@Example.com>") ++ " " ++ T.domain_of("bad"))
    check_drafts(T.stamp_of(1700000000, 1, 255), want(["A <a@x.com>"], ["b@z.com"], False{}))
    IO.print(
      J.show(T.appended_uid(I.frame("L OK\r\na1 OK [APPENDUID 7 42] done\r\n"))) ++ " " ++
      J.show(T.appended_uid(I.frame("L OK\r\na1 OK done\r\n"))) ++ " " ++
      J.show(T.appenduid(["appenduid", "1", "x"])))
    IO.print(show_out(T.draft_saved(
      T.imap_code(0, I.frame("L OK\r\na1 OK [APPENDUID 7 42] done\r\n"), ""), "Drafts", "<m@x>")))
    IO.print(show_out(T.sent_out(T.Ok{J.str("250 ok")}, "<m@x>", 2)) ++ " | " ++
      show_out(T.sent_out(T.Err{"refused"}, "<m@x>", 2)) ++ " | " ++
      show_out(T.sent_out(T.Partial{J.JNull{}}, "<m@x>", 2)))
    IO.print(problem(T.check_want(want(["a@x.com"], [], False{}), "bad")) ++
      problem(T.check_want(want(["nope"], [], False{}), "me@my.org")) ++
      problem(T.check_want(T.Want{[], [], [], "", "", "", "", [], False{}, False{}, Jev.Fresh{},
        Jev.Off{}}, "me@my.org")) ++
      problem(T.check_want(T.Want{[], [], [], "", "", "", "", [], True{}, False{}, Jev.Fresh{},
        Jev.Off{}}, "me@my.org")) ++
      problem(T.check_want(want(["a@x.com"], [], False{}), "me@my.org")))

# Replies and forwards
# --------------------

def reply_headers() -> List<&2, M.Hdr>:
  M.headers(String.concat([
    "From: Ann <ann@x.com>\r\n",
    "To: =?UTF-8?Q?Jos=C3=A9?= <jose@x.com>, \"Doe, J\" <j@x.com>\r\n",
    "Cc: k@y.com\r\n",
    "Reply-To: list@x.com\r\n",
    "Subject: Plans\r\n",
    "Date: Mon, 1 Feb 2026 10:00:00 +0000\r\n"]))

def check_reply_headers(+hs: List<&2, M.Hdr>) -> IO(Unit):
  do IO<Unit>:
    IO.print(String.join(T.hdr_addrs(hs, "to"), "|") ++ " " ++
      String.join(T.reply_to(hs), "|") ++ " " ++
      String.join(T.reply_to(M.headers("From: a@x\r\n")), "|") ++ " " ++
      String.join(T.decoded(["=?UTF-8?Q?Caf=C3=A9?=", "x"]), "|"))
    IO.print(show_line_endings(T.fwd_note(hs)))

def check_reply() -> IO(Unit):
  do IO<Unit>:
    IO.print(T.prefixed("Re:", "hello") ++ "|" ++ T.prefixed("Re:", " RE: hello") ++ "|" ++
      T.prefixed("Fwd:", "fwd: x") ++ "|" ++ T.prefixed("Re:", ""))
    IO.print(show_line_endings(T.quote_lines(["a", "", "b"])) ++ "|" ++ T.quote_lines([]))
    IO.print(T.spec_key("A <A@X.com>") ++ " " ++
      String.join(T.spec_keys(["B@y", "c <C@z>"]), ",") ++ " " ++
      show_bool(C.is_in("b@y", ["a", "b@y"])) ++ " " ++ show_bool(C.is_in("b", [])))
    IO.print(String.join(T.fresh(["A <a@x>", "a@X", "b@y", "C <c@z>", "B@Y"], ["c@z"]), "|"))
    IO.print(M.readable_text(M.Parts{"plain", "<b>html</b>", []}) ++ "|" ++
      M.readable_text(M.Parts{"", "<p>Hi &amp; bye</p>", []}) ++ "|" ++
      M.readable_text(M.Parts{"", "", []}))
    check_reply_headers(reply_headers())
    IO.print(T.cut_note(True{}) ++ "[" ++ T.cut_note(False{}) ++ "]")
    IO.print(
      show_out(T.with_fields(T.Ok{J.obj([J.kv("a", J.num(1))])}, T.quote_fields(True{}, 10, 20))) ++
      " | " ++ show_out(T.with_fields(T.Err{"x"}, [J.kv("b", J.num(2))])) ++ " | " ++
      show_out(T.with_fields(T.Ok{J.str("s")}, [J.kv("b", J.num(2))])))

# Dispatch and the tools offered
# ------------------------------

def names_of(ts: List<&2, J.Json>) -> List<&2, String>:
  match ts:
    case Nil{}:
      []
    case t <> rest:
      T.str_arg(t, "name", "") <> names_of(rest)

def tool_names(ts: J.Json) -> String:
  match ts:
    case J.JArr{xs}:
      String.join(names_of(J.unchain(xs)), ",")
    case _:
      "not an array"

def tool_defs() -> J.Json:
  json(Schema.tool_defs())

# Whether a configuration lists the tool named `n`.
def listed(n: String, ro: Bool, drafts: Bool, jev: Bool) -> Bool:
  C.is_in(n, Ops.listed_names(Ops.all_ops(), ro, drafts, jev))

def check_dispatch() -> IO(Unit):
  do IO<Unit>:
    IO.print(String.join([
      show_bool(T.sends(Ops.OSend{}, json("{}"))),
      show_bool(T.sends(Ops.OReply{}, json("{}"))),
      show_bool(T.sends(Ops.OReply{}, json("{\"as_draft\":true}"))),
      show_bool(T.sends(Ops.OForward{}, json("{\"as_draft\":false}"))),
      show_bool(T.sends(Ops.OSaveDraft{}, json("{}")))], " "))
    IO.print(problem(T.refusal(Ops.OGet{}, json("{}"), True{}, True{}, False{})) ++
      problem(T.refusal(Ops.OTrash{}, json("{}"), True{}, False{}, True{})) ++
      problem(T.refusal(Ops.OForward{}, json("{}"), False{}, True{}, True{})) ++
      problem(T.refusal(Ops.OForward{}, json("{\"as_draft\":true}"), False{}, True{}, False{})) ++
      problem(T.refusal(Ops.OSend{}, json("{}"), True{}, True{}, True{})))
    IO.print(problem(T.refusal(Ops.OClassify{}, json("{}"), False{}, False{}, False{})) ++
      problem(T.refusal(Ops.OClassify{}, json("{}"), True{}, True{}, True{})))
    IO.print(show_bool(listed("mail_get", True{}, False{}, False{})) ++ " " ++
      show_bool(listed("mail_trash", True{}, False{}, False{})) ++ " " ++
      show_bool(listed("mail_send", False{}, True{}, False{})) ++ " " ++
      show_bool(listed("mail_reply", False{}, True{}, False{})) ++ " " ++
      show_bool(listed("mail_classify", False{}, False{}, False{})) ++ " " ++
      show_bool(listed("mail_classify", True{}, False{}, True{})) ++ " " ++
      show_bool(listed("mail_nope", False{}, False{}, True{})) ++ " " ++
      show_bool(C.is_in("b", ["a", "b"])) ++ " " ++ show_bool(C.is_in("b", [])))
    IO.print(tool_names(T.offered_for(tool_defs(), T.Config{False{}, False{}, Jev.Off{}})))
    IO.print(tool_names(T.offered_for(tool_defs(), T.Config{True{}, False{}, Jev.Off{}})))
    IO.print(tool_names(T.offered_for(tool_defs(), T.Config{False{}, True{}, Jev.Off{}})))
    IO.print(tool_names(T.offered_for(tool_defs(), T.ConfigBad{"x"})))
    IO.print(J.show(T.offered_for(J.str("x"), T.Config{True{}, True{}, Jev.Off{}})))
    IO.print(tool_names(T.offered_for(tool_defs(),
      T.Config{False{}, False{}, Jev.On{Jev.Headers{}}})))
    IO.print(tool_names(T.offered_for(tool_defs(), T.Config{True{}, False{}, Jev.On{Jev.Body{}}})))

# Arguments checked against the schema
# ------------------------------------

def schema(+tool: String, args: String) -> String:
  problem(T.schema_problem(T.tool_input(tool), json(args), tool))

def check_schema() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_bool(Maybe.is_none(&2, J.Json, T.tool_input("nope"))) ++ " " ++
      show_bool(C.all_digits("")) ++ " " ++ show_bool(C.all_digits("12a")) ++ " " ++
      show_bool(T.int_raw("-5")) ++ " " ++ show_bool(T.int_raw("5.0")) ++ " " ++
      show_bool(T.int_raw("1e3")))
    IO.print(String.join([
      show_bool(T.prim_ok("string", J.str("x"))),
      show_bool(T.prim_ok("integer", json("3"))),
      show_bool(T.prim_ok("integer", json("3.5"))),
      show_bool(T.prim_ok("boolean", json("true"))),
      show_bool(T.prim_ok("object", json("{}"))),
      show_bool(T.prim_ok("array", json("[]"))),
      show_bool(T.prim_ok("string", J.JNull{})),
      show_bool(T.value_ok("array", "string", J.str("a@x"))),
      show_bool(T.value_ok("array", "integer", J.str("3"))),
      show_bool(T.value_ok("array", "integer", json("[1,2]"))),
      show_bool(T.value_ok("array", "integer", json("[1,\"2\"]")))], " "))
    IO.print(String.join([
      T.type_words("boolean", ""), T.type_words("integer", ""), T.type_words("string", ""),
      T.type_words("object", ""), T.type_words("array", "string"),
      T.type_words("array", "object")], "|"))
    IO.print(T.required_msg("uidvalidity"))
    IO.print(T.required_msg("confirm") ++ " | " ++ T.required_msg("uid"))
    IO.print(schema("nope", "{\"x\":1}") ++ schema("mail_probe", "{}") ++
      schema("mail_get", "{\"uid\":3}"))
    IO.print(schema("mail_get", "[]"))
    IO.print(schema("mail_get", "{\"uid\":3,\"bogus\":1}"))
    IO.print(schema("mail_get", "{\"uid\":\"3\"}"))
    IO.print(schema("mail_get", "{}"))
    IO.print(schema("mail_trash", "{\"uids\":[3]}"))
    IO.print(schema("mail_delete", "{\"uids\":[3],\"uidvalidity\":7}"))
    IO.print(schema("mail_reply",
      "{\"uid\":3,\"uidvalidity\":7,\"body\":\"b\",\"as_draft\":\"true\"}"))
    IO.print(schema("mail_trash", "{\"uids\":[3],\"uidvalidity\":7,\"dry_run\":false,\"dry_run\":true}") ++
      schema("mail_trash", "{\"dry_run\":true,\"uids\":[3],\"uidvalidity\":7,\"dry_run\":false}") ++
      schema("mail_get", "{\"uid\":3,\"bogus\":1,\"bogus\":2}"))
    IO.print(schema("mail_send", "{\"to\":\"a@x\",\"subject\":\"s\",\"body\":\"b\"}"))
    IO.print(schema("mail_send", "{\"to\":[\"a@x\",1],\"subject\":\"s\",\"body\":\"b\"}"))
    IO.print(schema("mail_send", String.concat([
      "{\"to\":\"a@x\",\"subject\":\"s\",\"body\":\"b\",",
      "\"attachments\":[{\"path\":\"a\"},{\"path\":\"b\",\"bogus\":1}]}"])))
    IO.print(schema("mail_send", String.concat([
      "{\"to\":\"a@x\",\"subject\":\"s\",\"body\":\"b\",",
      "\"attachments\":[\"a\",{\"path\":3}]}"])))

# Sending
# -------

def show_sends(s: T.Sends()) -> String:
  match s:
    case Done{T.Sending{save, allow, limit, dir}}:
      Bool.show(save) ++ " [" ++ String.join(allow, ",") ++ "] " ++ U32.show(limit) ++ " [" ++
        dir ++ "]"
    case Fail{m}:
      "error " ++ m

def sends(save: String, allow: String, max: String, dir: String) -> String:
  show_sends(T.sending_of(save, allow, max, dir, "", "/home/u"))

def header_msg(headers: String) -> I.Msg:
  I.Msg{1, [], "", 0, headers, "", I.VNil{}}

def check_sending() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_sends(T.sending_of("", "", "", "", "", "")))
    IO.print(sends("1", " Bob@X.com , @Example.ORG", "5", ""))
    IO.print(show_sends(T.sending_of("true", "", "", "/st", "/xdg", "/home/u")) ++ " " ++
      show_sends(T.sending_of("", "", "", "", "/xdg", "/home/u")) ++ " " ++
      show_sends(T.sending_of("", "", "", "", "rel", "rel")))
    IO.print(sends("yes", "", "", ""))
    IO.print(sends("", "a@x.com,", "", ""))
    IO.print(sends("", "Bob <b@x.com>", "", ""))
    IO.print(sends("", "@", "", "") ++ " | " ++ sends("", "x.com", "", "") ++ " | " ++
      sends("", "@a@b", "", ""))
    IO.print(sends("", "", "0", "") ++ " | " ++ sends("", "", "-1", "") ++ " | " ++
      sends("", "", "ten", "") ++ " | " ++ sends("", "", "99999999999", ""))
    IO.print(sends("", "", "", "state"))
    IO.print(sends("on", "bad", "0", "state"))
    IO.print("[" ++ T.reservation(T.ProcOk{0, "ok 3\n", ""}, 5) ++ "]")
    IO.print(T.reservation(T.ProcOk{0, "full 5\n", ""}, 5))
    IO.print(T.reservation(T.ProcOk{0, "ok", ""}, 5))
    IO.print(T.reservation(T.ProcOk{2, "", "mailbend-attach: cannot lock the send counter\n"}, 5))
    IO.print(T.reservation(T.ProcFail{110, "timed out"}, 5))
    IO.print(T.unlisted_msg(["a@x.com", "b%c@y.com"]))
    IO.print(String.join([
      show_bool(T.has_msg_id([header_msg("Message-ID:  <a@x>  \r\n\r\n")], "<a@x>")),
      show_bool(T.has_msg_id([header_msg("Message-ID: <a@x.y>\r\n\r\n")], "<a@x>")),
      show_bool(T.has_msg_id([header_msg(""), header_msg("message-id: <a@x>\r\n\r\n")], "<a@x>")),
      show_bool(T.has_msg_id([], "<a@x>"))], " "))
    IO.print(T.sent_copy.fin(Done{[]}, "Sent") ++ " | " ++ T.sent_copy.fin(Fail{"no"}, "Sent"))

# Threads
# -------

# Two keys in each of two folders: INBOX finds 4 2, then 2 9; Sent finds
# nothing, then 1.
def thread_search_plan() -> List<&2, I.Cmd>:
  Ops.plan_thread_search(["INBOX", "Sent"], [I.KAll{}, I.KSeen{}])

def thread_search_transcript() -> String:
  String.concat([
    "* OK [UIDVALIDITY 7] ok\r\na1 OK\r\n* SEARCH 4 2\r\na2 OK\r\n* SEARCH 2 9\r\na3 OK\r\n",
    "* OK [UIDVALIDITY 8] ok\r\na4 OK\r\n* SEARCH\r\na5 OK\r\n* SEARCH 1\r\na6 OK\r\n"])

def show_found(fs: List<&2, T.Found>) -> String:
  match fs:
    case Nil{}:
      ""
    case T.Found{f, v, us, ms} <> t:
      f ++ " " ++ J.show(T.maybe_num(v)) ++ " [" ++ show_u32s(us) ++ "] "
        ++ Nat.show(List.length(&2, I.Msg, ms)) ++ " | " ++ show_found(t)

def show_session(r: Result<&2, &2, String, List<&2, T.Found>>) -> String:
  match r:
    case Fail{m}:
      "err " ++ m
    case Done{fs}:
      show_found(fs)

def show_wants(ws: List<&2, Ops.FolderUids>) -> String:
  match ws:
    case Nil{}:
      ""
    case Ops.FolderUids{f, us} <> t:
      f ++ " [" ++ show_u32s(us) ++ "] | " ++ show_wants(t)

def search_found(before: List<&2, T.Found>) -> Result<&2, &2, String, List<&2, T.Found>>:
  T.session_found(Done{I.frame(thread_search_transcript())}, thread_search_plan(), before)

def thread_fs() -> T.Folders:
  T.Folders{[], None{}, None{}, Some{"Sent"}, None{}, None{}}

def check_thread() -> IO(Unit):
  do IO<Unit>:
    IO.print(String.join(T.thread_folders("INBOX", Some{"Sent Messages"}), ",") ++ " | " ++
      String.join(T.thread_folders("Sent Messages", Some{"Sent Messages"}), ",") ++ " | " ++
      String.join(T.thread_folders("inbox", Some{"INBOX"}), ",") ++ " | " ++
      String.join(T.thread_folders("INBOX", None{}), ",") ++ " | " ++
      String.join(T.thread_folders("Archive", None{}), ","))
    IO.print(show_session(search_found([])))
    IO.print(show_session(search_found([T.Found{"INBOX", Some{7}, [], []}])))
    IO.print(show_session(search_found([T.Found{"Sent", Some{9}, [], []}])))
    IO.print(show_session(search_found([T.Found{"INBOX", None{}, [], []}])))
    IO.print(show_session(T.session_found(Fail{"down"}, thread_search_plan(), [])))
    IO.print(show_wants(T.thread_wants(T.thread_found(thread_search_plan(),
      I.frame(thread_search_transcript())),
      [Th.node("INBOX", Some{7}, I.Msg{4, [], "", 0, "", "", I.VNil{}})])))
    IO.print(show_found(T.thread_found(Ops.plan_thread_headers([Ops.FolderUids{"INBOX", [4, 5]}]),
      I.frame(headers_transcript(7)))))
    IO.print(show_shown(T.thread_out(Done{T.Threading{[], [], [
      Th.node("INBOX", Some{7}, header_msg("Message-ID: <b@x>\r\nIn-Reply-To: <a@x>\r\n")),
      Th.node("Sent", None{}, header_msg("Message-ID: <a@x>\r\n"))], []}}, thread_fs(),
      ["INBOX", "Sent"], "INBOX", 1)))
    IO.print(show_shown(T.thread_out(Fail{"down"}, thread_fs(), ["INBOX"], "INBOX", 1)))

# mail_classify
# -------------

def show_asked(a: T.Asked) -> String:
  match a:
    case T.AskAnswered{body}:
      "answered " ++ body
    case T.AskRefused{m}:
      "refused " ++ m
    case T.AskFailed{m}:
      "failed " ++ m

def asked(code: U32, out: String, err: String) -> String:
  show_asked(T.asked(T.ProcOk{code, out, err}))

def answered_uids(xs: List<&2, Jev.Answered>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      []
    case x <> t:
      T.answered_uid(x) <> answered_uids(t)

def show_tally(t: T.Tally()) -> String:
  match t:
    case Done{T.Progress{xs, reqs}}:
      "progress " ++ show_u32s(answered_uids(xs)) ++ " " ++ J.show(J.arr(reqs))
    case Fail{m}:
      "stopped " ++ m

def many_uids(n: Nat) -> List<&2, U32>:
  match n:
    case Zero{}:
      []
    case Succ{+k}:
      U32.from_nat(n) <> many_uids(k)

def many_names(n: Nat) -> List<&2, String>:
  match n:
    case Zero{}:
      []
    case Succ{+k}:
      ("F" ++ Nat.show(n)) <> many_names(k)

def classify_msg(uid: U32) -> I.Msg:
  I.Msg{uid, [], "", 0, "", "", I.VNil{}}

# A FETCH response for `uid` with these header fields and no message text.
def fetched_msg(uid: U32, headers: String) -> I.Msg:
  I.Msg{uid, [], "", 0, headers, "", I.VNil{}}

def body_msg(uid: U32) -> I.Msg:
  I.Msg{uid, [], "", 0, "x", "x", I.VNil{}}

def keys() -> List<&2, String>:
  ["Work", "none"]

def skipped(uid: U32) -> Jev.Answered:
  Jev.Skipped{Jev.facts_of(classify_msg(uid))}

def check_classify() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_uids(T.jev_uids("mail_classify", Done{[5, 3, 5, 1]})) ++ "|" ++
      show_uids(T.jev_uids("mail_classify", Done{many_uids(50n)})) ++ "|" ++
      show_uids(T.jev_uids("mail_classify", Done{many_uids(51n)})) ++ "|" ++
      show_uids(T.jev_uids("mail_triage", Done{many_uids(51n)})) ++ "|" ++
      show_uids(T.jev_uids("mail_classify", Fail{"no uids"})))
    IO.print(show_names(T.classify_candidates(["Ideas", "Ideas/2026"])))
    IO.print(show_names(T.classify_candidates(["Ideas", ""])))
    IO.print(show_names(T.classify_candidates(["Ideas", "a\tb"])))
    IO.print(show_names(T.classify_candidates(many_names(255n))))
    IO.print(String.join(T.category_names(guard(), guarded_folders()), ","))
    IO.print(String.join(T.canonical_names(guard(), ["inbox/Kids", "Ideas"]), ","))
    IO.print(problem(T.candidates_problem(guard(), ["Ideas", "Work/New", "INBOX/Kids"], [])))
    IO.print(problem(T.candidates_problem(guard(), ["Work"], [])))
    IO.print(problem(T.candidates_problem(guard(), ["Ideas", "Ideas"], [])))
    IO.print(problem(T.candidates_problem(guard(), ["Bin/Old"], [])))
    IO.print(problem(T.candidates_problem(guard(), ["Nope/New"], [])))
    IO.print(problem(T.options_problem(254n)) ++ problem(T.options_problem(255n)))
    IO.print(problem(T.room_problem(True{})) ++ problem(T.room_problem(False{})))
    IO.print(show_u32s(T.msg_uids(T.first_uids(T.oldest_first([fetched_msg(3, ""),
      fetched_msg(3, "x"), fetched_msg(1, "x"), fetched_msg(3, "x"), fetched_msg(4, ""),
      fetched_msg(2, "x")]), 0, False{}))) ++ "|" ++
      show_u32s(T.msg_uids(T.first_uids([fetched_msg(1, "x"), body_msg(2), body_msg(2)], 0,
        True{}))))
    IO.print(asked(0, "{\"answers\":{}}", ""))
    IO.print(asked(8, "{\"detail\":\"bad question\"}",
      "mailbend-typesafe: TypeSafe refused the request (HTTP 422)\n"))
    IO.print(asked(8, "{\"detail\":[{\"loc\":[\"body\"],\"msg\":\"bad\"}]}",
      "mailbend-typesafe: TypeSafe refused the request (HTTP 422)\n"))
    IO.print(asked(8, "  not json  ", "mailbend-typesafe: TypeSafe refused the request (HTTP 400)"))
    IO.print(Nat.show(String.length(T.refusal_detail(String.repeat("x", 1500n)))))
    IO.print(asked(2, "", "mailbend-typesafe: MAILBEND_TYPESAFE_KEY_FILE is not set\n"))
    IO.print(asked(3, "", "mailbend-typesafe: cannot reach api.typesafe.ai (system DNS; refused)"))
    IO.print(asked(7, "{\"detail\":\"bad key\"}",
      "mailbend-typesafe: TypeSafe rejected the key (HTTP 401)"))
    IO.print(asked(9, "", "mailbend-typesafe: TypeSafe timed out, after retries"))
    IO.print(asked(6, "", "mailbend-typesafe: internal error"))
    IO.print(asked(137, "", ""))
    IO.print(show_asked(T.asked(T.ProcRefused{"no such file"})))
    IO.print(J.show(T.request_json(2n, 100, None{})) ++ " " ++
      J.show(T.request_json(1n, 9, Some{7})))
    IO.print(show_tally(T.answered(T.AskAnswered{"not json"}, [], 10, keys(),
      T.Progress{[], []})))
    IO.print(show_tally(T.answered(T.AskRefused{"no"}, [], 10, keys(), T.Progress{[], []})))
    IO.print(show_tally(T.answered(T.AskAnswered{"{\"answers\":{}}"}, [], 10, keys(),
      T.Progress{[skipped(1)], []})))
    IO.print(show_out(T.classify_out(Done{T.progress_add(T.progress_add(T.Progress{[], []},
      [skipped(1), skipped(2)], [J.str("r1")]), [skipped(3)], [J.str("r2")])},
      Jev.Headers{}, [], "none", [J.kv("folder", J.str("INBOX"))], [9])))
    IO.print(show_out(T.classify_out(Fail{"stopped"}, Jev.Headers{}, [], "none", [], [])))
    IO.print(T.jev_off("mail_classify"))

# mail_triage
# -----------

def review_folders(trash: Maybe<&2, String>) -> T.Folders:
  T.Folders{[I.Folder{"INBOX", "/", []}, I.Folder{"To Delete", "/", []}], None{}, trash, None{},
    None{}, None{}}

def pending(uid: U32, sender: Maybe<&2, String>) -> T.Pending:
  T.Pending{Jev.Fetched{Jev.facts_of(classify_msg(uid)), Jev.Text{"", Jev.Complete{}}}, [],
    sender}

def review_problem_of(f: T.Folders) -> String:
  +g = f
  problem(T.review_problem(g, T.role_folders(g)))

# The flags a UID FETCH reports for UID 2, as the re-read of flags gets them.
def reread() -> List<&2, I.Msg>:
  I.flag_fetches(I.frame("* 1 FETCH (UID 2 FLAGS (\\Seen \\Answered))\r\na1 OK\r\n"))

def vetoes_line(ps: List<&2, T.Pending>) -> String:
  match ps:
    case Nil{}:
      ""
    case T.Pending{f, vetoes, sender} <> t:
      "[" ++ String.join(vetoes, ",") ++ "]" ++ vetoes_line(t)

def sender_line(m: Maybe<&2, String>) -> String:
  match m:
    case Some{a}:
      a
    case None{}:
      "none"

def check_triage() -> IO(Unit):
  do IO<Unit>:
    IO.print(problem(T.review_move_problem("/", "To Delete")) ++
      problem(T.review_move_problem("/", "to delete/Old")) ++
      problem(T.review_move_problem("/", "Work/To Delete")) ++
      problem(T.review_move_problem("/", "INBOX")))
    IO.print(problem(T.review_trash_problem("/", "To Delete", "Deleted Messages")) ++
      problem(T.review_trash_problem("/", "INBOX", "to delete/x")) ++
      problem(T.review_trash_problem("/", "INBOX", "Deleted Messages")))
    IO.print(problem(T.source_review_problem("/", "To Delete")) ++
      problem(T.source_review_problem("/", "INBOX")))
    IO.print(problem(T.invalid_override(folders(), "To Delete", "MAILBEND_X")) ++
      problem(T.invalid_override(folders(), "to delete/Old", "MAILBEND_X")) ++
      problem(T.invalid_override(folders(), "To Deleted", "MAILBEND_X")))
    IO.print(review_problem_of(review_folders(None{})) ++
      review_problem_of(review_folders(Some{"To Delete"})) ++
      review_problem_of(T.Folders{[I.Folder{"INBOX", "/", []}, I.Folder{"to delete", "/",
        ["\\Archive"]}, I.Folder{"To Delete", "/", []}], None{}, None{}, None{}, None{}, None{}}) ++
      review_problem_of(T.Folders{[I.Folder{"INBOX", "/", []}], None{}, None{}, None{},
        None{}, None{}}))
    IO.print(String.join(T.fields_named(M.headers("From: a@x\r\nTo: c@z\r\nfrom: b@y\r\n"),
      "from"), ","))
    IO.print(sender_line(T.sender_in(["Ann <a@x.org>"])) ++ " " ++
      sender_line(T.sender_in(["a@x.org", "b@y.org"])) ++ " " ++
      sender_line(T.sender_in(["a@x.org, b@y.org"])) ++ " " ++ sender_line(T.sender_in([])))
    IO.print(String.join(T.senders([pending(1, Some{"a@x"}), pending(2, None{}),
      pending(3, Some{"b@y"}), pending(4, Some{"a@x"})], []), ","))
    IO.print(String.join(T.written_to(["a@x", "b@y", "c@z"],
      I.frame("a1 OK\r\n* SEARCH\r\na2 OK\r\n* SEARCH 4 9\r\na3 OK\r\n* SEARCH\r\n" ++
        "a4 OK\r\n* SEARCH\r\na5 OK\r\n* SEARCH\r\na6 OK\r\n* SEARCH 2\r\na7 OK\r\n"), 2),
      ","))
    IO.print(vetoes_line(T.rechecked([pending(1, None{}), pending(2, None{})], reread())) ++
      " " ++ vetoes_line(T.rechecked([pending(2, None{})], [])))
    IO.print(vetoes_line(T.rechecked([pending(2, None{})], I.flag_fetches(I.frame(
      "* 1 FETCH (UID 2 FLAGS (\\Seen))\r\n* 1 FETCH (UID 2 FLAGS (\\Seen \\Flagged))\r\n" ++
      "a1 OK\r\n")))))
    IO.print(String.join(Jev.correspondence_vetoes(T.correspondence(None{}, "a@x")), ",") ++
      "|" ++ String.join(Jev.correspondence_vetoes(T.correspondence(Some{["a@x"]}, "a@x")), ",") ++
      "|" ++ String.join(Jev.correspondence_vetoes(T.correspondence(Some{["b@y"]}, "a@x")), ","))
    IO.print(String.join(T.vetoes_of([pending(1, None{})], 1), ",") ++ "|" ++
      String.join(T.vetoes_of([pending(1, None{})], 2), ","))
    IO.print(problem(T.review_needed_problem([3, 4], "it does not exist")) ++
      problem(T.review_needed_problem([], "it does not exist")) ++
      problem(T.review_needed_problem([3], "")))
    IO.print(problem(T.moves_problem(True{}, False{}, False{}, True{})) ++
      problem(T.moves_problem(True{}, False{}, True{}, False{})) ++
      problem(T.moves_problem(True{}, True{}, False{}, True{})) ++
      problem(T.moves_problem(False{}, False{}, False{}, False{})))
    IO.print(show_out(T.triage_result(T.Moved{[], False{}})))
    IO.print(show_out(T.triage_result(T.Moved{[T.moved_error("To Delete", "lost"),
      J.str("first")], True{}})))
    IO.print(show_out(T.with_fields_first(T.Ok{J.obj([J.kv("moves", J.arr([]))])},
      [J.kv("folder", J.str("INBOX"))])))
    IO.print(show_out(T.with_fields_first(T.Partial{J.obj([J.kv("ok", J.bool(False{}))])},
      [J.kv("folder", J.str("INBOX"))])))
    IO.print(show_out(T.with_fields_first(T.Err{"no"}, [J.kv("folder", J.str("INBOX"))])))
    IO.print(T.jev_off("mail_triage"))

def main() -> IO(Unit):
  do IO<Unit>:
    check_switches()
    check_helper()
    check_runs()
    check_dry_runs()
    check_arguments()
    check_roles()
    check_search()
    check_get()
    check_new()
    check_changes()
    check_flags()
    check_moves()
    check_guard()
    check_folder_results()
    check_compose()
    check_reply()
    check_dispatch()
    check_schema()
    check_sending()
    check_thread()
    check_classify()
    check_triage()

#|d v d
#|off|off|off|on|on|bad X must be 1, true, 0, false or empty|bad X must be 1, true, 0, false or empty
#|config True False off|config False True off|bad r|bad d|config False False off
#|config False False headers
#|config False False headers
#|config False False body
#|config False False off
#|bad MAILBEND_TYPESAFE_API_KEY must not be set: put the TypeSafe key in a file readable only by you and set MAILBEND_TYPESAFE_KEY_FILE to its absolute path
#|bad MAILBEND_TYPESAFE_API_KEY must not be set: put the TypeSafe key in a file readable only by you and set MAILBEND_TYPESAFE_KEY_FILE to its absolute path
#|bad MAILBEND_TYPESAFE_CONTENT=body sends message text to TypeSafe and needs MAILBEND_TYPESAFE_ZERO_RETENTION=1, the operator's statement that the TypeSafe account has a zero-retention plan
#|bad MAILBEND_TYPESAFE_CONTENT=body sends message text to TypeSafe and needs MAILBEND_TYPESAFE_ZERO_RETENTION=1, the operator's statement that the TypeSafe account has a zero-retention plan
#|bad MAILBEND_TYPESAFE_CONTENT must be headers, body or empty
#|bad MAILBEND_TYPESAFE_KEY_FILE must be the absolute path of the TypeSafe key file when MAILBEND_TYPESAFE is on
#|bad MAILBEND_TYPESAFE_KEY_FILE must be the absolute path of the TypeSafe key file when MAILBEND_TYPESAFE is on
#|bad t
#|bad z
#|True False
#|True True False True False
#|ok 0 out err|refused no such file|fail 110 timed out
#|[] refused lost
#|False True False True
#|x|y
#|second | mailbend-tls: first|plain
#|ok /bin/x|error MAILBEND_X must be the absolute path of x (scripts/mailbend sets it)
#|mail server error: e1
#|configuration error: e2
#|connection or TLS verification failed: e3
#|authentication failed (check MAILBEND_EMAIL and the app-specific password): e4
#|mail server error: e5
#|mail server error: e128
#|the TLS helper was killed by a signal: e130
#|[]
#|the folder's UIDVALIDITY changed since these UIDs were read, so they may name other messages; nothing was changed: search again
#|the server rejected a command: a2 NO [TRYCREATE] no such mailbox
#|connection or TLS verification failed: bad cert
#|ok {"changed":[3],"missing":[4]}
#|cannot run the TLS helper: no path
#|cannot run the TLS helper: timed out
#|authentication failed (check MAILBEND_EMAIL and the app-specific password): login refused
#|5 0
#|True False False
#|ok "250 2.0.0 queued as X"
#|err the SMTP server refused the message: 550 5.1.1 no such user
#|err connection or TLS verification failed: tls failed
#|err cannot run the TLS helper: no path
#|ok "250 sent"
#|ok {"dry_run":true,"imap":["a1 CAPABILITY","a2 SELECT \"INBOX\"","=EXPECT * OK [UIDVALIDITY 7]","a3 UID STORE 3 +FLAGS.SILENT (\\Deleted)","a4 UID EXPUNGE 3","a5 APPEND \"Drafts\" (\\Draft) <13 bytes>"]}
#|ok {"dry_run":true,"smtp":{"from":"me@my.org","rcpt":["a@x.com","b@y.com"],"data":"<27 bytes>","sent_copy":true}}
#|ok {"dry_run":true,"smtp":{"from":"me@my.org","rcpt":["a@x.com"],"data":"<0 bytes>","sent_copy":false}}
#|ok {"dry_run":true,"file":{"path":"/dl/all.bin","data":"<3 bytes>"}}
#|True False False
#|v d d True False 7 1 Work INBOX
#|1 50 200
#|a@x||a@x,b@y||
#|[]|[]|[]|[]
#|uids 3 4 
#|error "uids" must list at least one UID
#|error "uids" must be an array of positive integer UIDs
#|uids 7 
#|uids 8 
#|error "uids" must list at least one UID
#|[3,4] "a" null ["a","b"] null 9 null
#|True False False False True
#|Deleted Messages|Sent Messages|none|none|none
#|Notes|none|INBOX|Deleted Messages
#|[] [] MAILBEND_X must name one existing selectable mailbox
#|ok {"ok":true,"account":"me@x","imap_host":"imap.example.com","tls_verified":true,"capabilities":["IMAP4REV1","MOVE","IDLE"],"idle":true,"move":true,"uidplus":false,"special_use":{"inbox":"INBOX","drafts":null,"sent":"Sent Messages","trash":"Deleted Messages","junk":null,"archive":null},"folder_count":11}
#|ok {"ok":true,"account":"me@x","imap_host":"h","tls_verified":true,"capabilities":[],"idle":false,"move":false,"uidplus":false,"special_use":{"inbox":"INBOX","drafts":"Notes","sent":"Sent Messages","trash":"Deleted Messages","junk":"Junk","archive":"Archive2"},"folder_count":11}
#|err MAILBEND_TRASH_FOLDER must name one existing selectable mailbox
#|err MAILBEND_JUNK_FOLDER must name one existing selectable mailbox
#|ok {"folders":[{"name":"INBOX","delimiter":"/","attributes":["\\HasNoChildren","\\Marked"],"special_use":null,"selectable":true},{"name":"Sent Messages","delimiter":"/","attributes":["\\Sent"],"special_use":"sent","selectable":true},{"name":"New","delimiter":".","attributes":["\\All"],"special_use":"all","selectable":true}]}
#|Drafts,Trash,Deleted Messages,Sent,Sent Messages,Junk,Archive none none
#|a1 UID SEARCH ALL\r\n
#|a1 UID SEARCH FROM "a" TO "b" CC "c" SUBJECT "s" BODY "y" TEXT "t" UNSEEN SEEN FLAGGED SINCE 1-Feb-2026 BEFORE 1-Mar-2026\r\n
#|error "since" must be a date like 2026-02-01
#|error "before" must be a date like 2026-02-01
#|a1 UID SEARCH ALL\r\n
#|5 4 |9 5 4 |4 5 9 |9 3 1 |1 3 9 |True False
#|ok {"folder":"INBOX","uidvalidity":7,"total":12,"messages":[{"uid":5,"date":"","from":"","to":"","cc":"","subject":"Lunch","message_id":"","internal_date":"1-Feb-2026 10:00:00 +0000","size":42,"flags":["\\Seen"],"seen":true,"flagged":false},{"uid":4,"date":"","from":"","to":"","cc":"","subject":"Hi","message_id":"","internal_date":"2-Feb-2026 10:00:00 +0000","size":7,"flags":["\\Flagged"],"seen":false,"flagged":true}]} | shown 5 4 
#|err the folder's UIDVALIDITY changed between the search and the fetch, so these UIDs may name other messages; search again | shown 
#|err connection or TLS verification failed: down | shown 
#|{"uid":5,"date":"Mon, 1 Feb 2026 10:00:00 +0000","from":"José <jose@example.com>","to":"me@x.com","cc":"","subject":"Lunch","message_id":"<m1@example.com>","internal_date":"1-Feb-2026 10:00:00 +0000","size":300,"flags":["\\Seen"],"seen":true,"flagged":false}
#|ok {"folder":"INBOX","uid":5,"uidvalidity":7,"flags":["\\Seen"],"seen":true,"internal_date":"1-Feb-2026 10:00:00 +0000","size":300,"truncated":false,"from":"José <jose@example.com>","to":"me@x.com","cc":"","reply_to":"","subject":"Lunch","date":"Mon, 1 Feb 2026 10:00:00 +0000","message_id":"<m1@example.com>","in_reply_to":"","references":"","text":"Hello\nthere\n","html_available":false,"attachments":[]} | whole 5 262144
#|ok {"folder":"INBOX","uid":6,"uidvalidity":null,"flags":["\\Seen"],"seen":true,"internal_date":"1-Feb-2026 10:00:00 +0000","size":300,"truncated":true,"from":"a@x.com","to":"","cc":"","reply_to":"","subject":"Hi","date":"","message_id":"","in_reply_to":"","references":"","text":" Hi & bye \n","html_available":true,"attachments":[]} | whole 6 100
#|err no message with UID 8 in Work | shown 
#|5 ||
#|ok {"folder":"INBOX","uid":4,"uidvalidity":7,"flags":["\\Flagged"],"seen":false,"internal_date":"2-Feb-2026 10:00:00 +0000","size":7,"truncated":false,"from":"","to":"","cc":"","reply_to":"","subject":"Hi","date":"","message_id":"","in_reply_to":"","references":"","text":"yo","html_available":false,"attachments":[]} | whole 4 1000
#|err no message with UID 8 in INBOX | shown 
#|err no message with UID 9 in INBOX | shown 
#|9 5 |5 1
#|[] [] "uidvalidity" is required with "since_uid": pass the uidvalidity returned with that checkpoint
#|ok {"folder":"INBOX","uidvalidity":7,"uidvalidity_changed":false,"next_since_uid":9,"has_more":true,"messages":[{"uid":4,"date":"","from":"","to":"","cc":"","subject":"Hi","message_id":"","internal_date":"2-Feb-2026 10:00:00 +0000","size":7,"flags":["\\Flagged"],"seen":false,"flagged":true},{"uid":5,"date":"","from":"","to":"","cc":"","subject":"Lunch","message_id":"","internal_date":"1-Feb-2026 10:00:00 +0000","size":42,"flags":["\\Seen"],"seen":true,"flagged":false}]} | shown 4 5 
#|ok {"folder":"INBOX","uidvalidity":8,"uidvalidity_changed":true,"next_since_uid":0,"has_more":true,"messages":[]} | shown 
#|err configuration error: bad config | shown 
#|True False False True False True
#|[] the folder's UIDVALIDITY changed since these UIDs were read, so they may name other messages; nothing was changed: search again
#|"uidvalidity" is required: pass the value mail_search or mail_get returned with these UIDs, so stale UIDs can never change other messages
#|5 4 
#|err none of these UIDs exist in INBOX; nothing was changed
#|ok {"ok":true,"changed":[3],"missing":[4,5]}
#|ok {"changed":[3,5],"missing":[4]}
#|err the server rejected a command: a2 NO [TRYCREATE] no such mailbox
#|{"ok":true,"folder":"INBOX","seen":true} {"ok":true,"folder":"INBOX","seen":false} {"ok":true,"folder":"INBOX","flagged":true} {"ok":true,"folder":"INBOX","flagged":false}
#|grey none none
#|True False False True False False True False True
#|false "unverified" true
#|+\Flagged||-$MailFlagBit0|+\Flagged,-$MailFlagBit0,-$MailFlagBit1,+$MailFlagBit2
#|nothing|+\Flagged, -$MailFlagBit0
#|the server acknowledged every flag and colour change, but the run did not finish, so the flags were not read back. A retry is idempotent
#|the flag change stopped part-way, so the flag and colour changes may be incomplete (acknowledged: +\Flagged; may have run unanswered: nothing). A retry is idempotent, but a server that refused a store may refuse it again
#|ok {"ok":true,"folder":"INBOX","flagged":true,"flags":[{"uid":3,"flags":["\\Flagged","$MailFlagBit2"]}],"colour":"blue","colour_kept":true,"colour_not_kept":[],"changed":[3],"missing":[4]}
#|ok {"ok":true,"folder":"INBOX","flagged":true,"flags":[{"uid":3,"flags":["\\Flagged","$MailFlagBit0"]}],"colour":"blue","colour_kept":false,"colour_not_kept":[3],"changed":[3],"missing":[4]}
#|ok {"ok":true,"folder":"INBOX","flagged":true,"flags":[{"uid":3,"flags":["\\Flagged","$MailFlagBit2"]}],"colour":"blue","colour_kept":"unverified","colour_not_kept":[],"changed":[3],"missing":[4]}
#|ok {"ok":true,"folder":"INBOX","flagged":true,"flags":[{"uid":3,"flags":["\\Flagged","$MailFlagBit2"]}],"colour":"blue","colour_kept":false,"colour_not_kept":[3],"changed":[3],"missing":[4]}
#|ok {"ok":true,"folder":"INBOX","flagged":true,"flags":[{"uid":3,"flags":null}],"colour":"blue","colour_kept":"unverified","colour_not_kept":[],"changed":[3],"missing":[4]}
#|partial {"ok":false,"partial":true,"folder":"INBOX","acknowledged":["+\\Flagged"],"unconfirmed":[],"message":"the flag change stopped part-way, so the flag and colour changes may be incomplete (acknowledged: +\\Flagged; may have run unanswered: nothing). A retry is idempotent, but a server that refused a store may refuse it again (the server rejected a command: a4 NO keyword refused)"}
#|partial {"ok":false,"partial":true,"folder":"INBOX","acknowledged":["+\\Flagged","-$MailFlagBit0","-$MailFlagBit1","+$MailFlagBit2"],"unconfirmed":[],"message":"the server acknowledged every flag and colour change, but the run did not finish, so the flags were not read back. A retry is idempotent (the server rejected a command: a7 NO)"}
#|partial {"ok":false,"partial":true,"folder":"INBOX","acknowledged":[],"unconfirmed":["+\\Flagged","-$MailFlagBit0","-$MailFlagBit1","+$MailFlagBit2"],"message":"the flag change stopped part-way, so the flag and colour changes may be incomplete (acknowledged: nothing; may have run unanswered: +\\Flagged, -$MailFlagBit0, -$MailFlagBit1, +$MailFlagBit2). A retry is idempotent, but a server that refused a store may refuse it again (cannot run the TLS helper: timed out)"}
#|err the server rejected a command: a3 NO
#|err the folder's UIDVALIDITY changed since these UIDs were read, so they may name other messages; nothing was changed: search again
#|ok {"ok":true,"folder":"INBOX","flagged":true,"flags":[{"uid":3,"flags":["\\Seen","\\Flagged"]}],"changed":[3],"missing":[4]}
#|ok {"ok":true,"folder":"INBOX","flagged":false,"flags":[{"uid":3,"flags":[]}],"changed":[3],"missing":[4]}
#|ok {"ok":true,"folder":"INBOX","seen":true,"changed":[4],"missing":[3]}
#|UID MOVE|UID COPY + UID EXPUNGE True False
#|True False False True False False
#|ok {"ok":true,"folder":"INBOX","destination":"Work","method":"UID MOVE","changed":[3],"missing":[]}
#|ok {"ok":true,"folder":"INBOX","destination":"Work","method":"UID COPY + UID EXPUNGE","changed":[3],"missing":[]}
#|partial {"ok":false,"partial":true,"folder":"INBOX","destination":"Work","method":"UID COPY + UID EXPUNGE","message":"the move was cut off and may have copied the messages to Work: they may now be in both INBOX and Work; check the destination before retrying (the server rejected a command: a5 NO cannot)"}
#|err the server rejected a command: a4 NO [OVERQUOTA] full
#|partial {"ok":false,"partial":true,"folder":"INBOX","destination":"Work","method":"UID COPY + UID EXPUNGE","message":"the move was cut off and may have copied the messages to Work: they may now be in both INBOX and Work; check the destination before retrying (cannot run the TLS helper: timed out)"}
#|err cannot run the TLS helper: not absolute
#|[] "destination" must name a different folder | "destination" must name a different folder | "uidvalidity" is required: pass the value mail_search or mail_get returned with these UIDs, so stale UIDs can never change other messages
#|[] "label" must name a folder other than the one the messages are in | "uidvalidity" is required: pass the value mail_search or mail_get returned with these UIDs, so stale UIDs can never change other messages
#|[] mail_delete permanently removes messages and cannot be undone; pass "confirm": "permanently-delete" to proceed (use mail_trash to move them to Trash instead) | "uidvalidity" is required: pass the value mail_search or mail_get returned with these UIDs, so stale UIDs can never change other messages
#|[] "uid" (the message to answer) is required | "uidvalidity" is required: pass the value mail_search or mail_get returned with these UIDs, so stale UIDs can never change other messages
#|True False
#|drafts,bin,mail/kept,drafts,bin,to delete,drafts,trash,deleted messages,sent,sent messages,junk,archive / [] / .
#|True False True True False False True False
#|a|b||c a/b True False [a/b] [] []
#|INBOX/x Work/inbox INBOX INBOX
#|[a folder name cannot be empty][a folder name cannot contain control characters][]
#|[cannot tell the server's hierarchy delimiter (LIST reports none), so "a/b" cannot be checked as a nested name][cannot tell the server's hierarchy delimiter (LIST reports none), so "a.b" cannot be checked as a nested name][]["a//b" has an empty level: a folder name cannot start or end with the delimiter "/" or repeat it]["/a" has an empty level: a folder name cannot start or end with the delimiter "/" or repeat it][]
#|[a folder named "Work" already exists]
#|[]
#|[]
#|["Drafts/x" is, or lies inside, a folder MailBend relies on: INBOX, Drafts, Sent, Trash, Junk, Archive (also under their usual names), To Delete, and any folder configured for one of those roles or advertised with any special-use role]
#|[the parent folder "Nope" does not exist; create it first]
#|[]
#|["Mail/Kept/x" is, or lies inside, a folder MailBend relies on: INBOX, Drafts, Sent, Trash, Junk, Archive (also under their usual names), To Delete, and any folder configured for one of those roles or advertised with any special-use role]
#|[no folder is named "Nope"]
#|["Mail" is, or contains, a folder MailBend relies on, so it cannot be renamed: INBOX, Drafts, Sent, Trash, Junk, Archive (also under their usual names), To Delete, and any folder configured for one of those roles or advertised with any special-use role]
#|[a folder cannot be renamed to itself or into itself]
#|[a folder named "Projects" already exists]
#|[renaming would turn the subfolder "Work/Sub" into "Team/Sub": a folder named "Team/Sub" already exists]
#|[]
#|["Drafts/Work" is, or lies inside, a folder MailBend relies on: INBOX, Drafts, Sent, Trash, Junk, Archive (also under their usual names), To Delete, and any folder configured for one of those roles or advertised with any special-use role]
#|[the label folder "Nope" does not exist: create it with mail_create_folder]
#|[the label folder "Locked" cannot be selected]
#|["Bin" is, or lies inside, a folder MailBend relies on: INBOX, Drafts, Sent, Trash, Junk, Archive (also under their usual names), To Delete, and any folder configured for one of those roles or advertised with any special-use role]
#|[]
#|[a folder name cannot be empty][a folder name cannot be empty][]
#|[a folder named "Work" already exists][]
#|create INBOX/x | rename inbox/a -> INBOX/b
#|Work,Work/Sub
#|a1 CAPABILITY\r\na2 RENAME "Work" "Fresh"\r\na3 SUBSCRIBE "Fresh/Sub"\r\na4 UNSUBSCRIBE "Work/Sub"\r\n
#|a1 CAPABILITY\r\na2 CREATE "New"\r\na3 SUBSCRIBE "New"\r\n
#|created renamed {"ok":true,"folder":"a"} {"ok":true,"from":"a","to":"b"}
#|ok {"ok":true,"folder":"New","subscribed":true}
#|ok {"ok":true,"folder":"New","subscribed":false,"note":"the folder was created, but updating its subscriptions failed (refused); some clients may not show it until it is subscribed. Do not retry"}
#|ok {"ok":true,"from":"A","to":"B","subscribed":false,"note":"the folder was renamed, but dropping its old subscriptions failed (refused); the old names may still be listed as subscribed. Do not retry"}
#|True False False True False
#|ok {"ok":true,"folder":"New","subscribed":true}
#|ok {"ok":true,"folder":"New","subscribed":false,"note":"the folder was created, but updating its subscriptions failed (the server rejected a command: a3 NO); some clients may not show it until it is subscribed. Do not retry"}
#|err the server rejected a command: a2 NO [ALREADYEXISTS] exists
#|err the folder may have been created; list the folders before retrying (cannot run the TLS helper: timed out)
#|err cannot run the TLS helper: not absolute
#|ok {"ok":true,"from":"Work","to":"Fresh","subscribed":false,"note":"the folder was renamed, but dropping its old subscriptions failed (the server rejected a command: a5 NO); the old names may still be listed as subscribed. Do not retry"}
#|ok {"ok":true,"from":"Work","to":"Fresh","subscribed":false,"note":"the folder was renamed, but updating its subscriptions failed (the server rejected a command: a3 NO); some clients may not show it until it is subscribed. Do not retry"}
#|Hi c.txt c []
#|application/pdf,text/plain,text/plain,text/plain,text/csv,text/html,text/html,application/json,image/png,image/jpeg,image/jpeg,image/gif,application/zip,message/rfc822,application/octet-stream,application/octet-stream
#|att a.txt|text/plain|data | error too big | error cannot run mailbend-attach: no path | error cannot run mailbend-attach: timed out
#|5 3 0 True False
#|atts a|t|1;b|t|2;
#|error first
#|atts f|message/rfc822|raw; | error bad
#|09af 00000000 deadbeef ffffffff 12345678
#|1700000000 0 0 5 0
#|Example.com bad
#|Tue, 14 Nov 2023 22:13:20 +0000 6553f100.00000001000000ff mailbend-6553f100.00000001000000ff
#|<6553f100.00000001000000ff@my.org> A <a@x.com>,c@y.com,b@z.com False a@x.com,c@y.com,b@z.com
#|From: me@my.org\r\nTo: "A" <a@x.com>\r\nCc: c@y.com\r\nBcc: b@z.com\r\nSubject: Subject\r\nDate: Tue, 14 Nov 2023 22:13:20 +0000\r\nMessage-ID: <6553f100.00000001000000ff@my.org>\r\nIn-Reply-To: <irt@x>\r\nReferences: <r@x>\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nBody
#|From: me@my.org\r\nTo: "A" <a@x.com>\r\nCc: c@y.com\r\nSubject: Subject\r\nDate: Tue, 14 Nov 2023 22:13:20 +0000\r\nMessage-ID: <6553f100.00000001000000ff@my.org>\r\nIn-Reply-To: <irt@x>\r\nReferences: <r@x>\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nBody
#|42 null null
#|ok {"ok":true,"saved_to":"Drafts","uid":42,"message_id":"<m@x>"}
#|ok {"ok":true,"sent":true,"message_id":"<m@x>","recipients":2,"server_reply":"250 ok"} | err refused | partial null
#|[MAILBEND_EMAIL is not a valid address][every recipient must be an address like name@example.com or "Name <name@example.com>"][at least one recipient (to, cc or bcc) is needed][][]
#|Re: hello| RE: hello|fwd: x|Re: 
#|> a\n> \n> b\n|
#|a@x.com b@y,c@z True False
#|A <a@x>|b@y
#|plain| Hi & bye |
#|José <jose@x.com>|"Doe, J" <j@x.com> list@x.com a@x Café|x
#|\n\n---------- Forwarded message ----------\nFrom: Ann <ann@x.com>\nDate: Mon, 1 Feb 2026 10:00:00 +0000\nSubject: Plans\nTo: José <jose@x.com>, "Doe, J" <j@x.com>\n
#|> [the original is larger than 256 KB and only its start was read, so this quote may be incomplete]
#|[]
#|ok {"a":1,"quoted_original_truncated":true,"quoted_bytes":10,"original_bytes":20} | err x | ok "s"
#|True True False True False
#|[][mail_trash is disabled: MAILBEND_READ_ONLY is set][mail_forward would send mail, which MAILBEND_DRAFTS_ONLY forbids: use mail_save_draft, or as_draft for a reply or forward][][mail_send is disabled: MAILBEND_READ_ONLY is set]
#|[mail_classify is disabled: it consults TypeSafe's Jev, and MAILBEND_TYPESAFE is off][]
#|True False False True False True False True False
#|mail_probe,mail_list_folders,mail_search,mail_get,mail_get_new,mail_get_thread,mail_get_attachment,mail_mark_read,mail_mark_unread,mail_flag,mail_unflag,mail_move,mail_label,mail_trash,mail_delete,mail_create_folder,mail_rename_folder,mail_save_draft,mail_send,mail_reply,mail_forward
#|mail_probe,mail_list_folders,mail_search,mail_get,mail_get_new,mail_get_thread
#|mail_probe,mail_list_folders,mail_search,mail_get,mail_get_new,mail_get_thread,mail_get_attachment,mail_mark_read,mail_mark_unread,mail_flag,mail_unflag,mail_move,mail_label,mail_trash,mail_delete,mail_create_folder,mail_rename_folder,mail_save_draft,mail_reply,mail_forward
#|mail_probe,mail_list_folders,mail_search,mail_get,mail_get_new,mail_get_thread
#|"x"
#|mail_probe,mail_list_folders,mail_search,mail_get,mail_get_new,mail_get_thread,mail_classify,mail_triage,mail_get_attachment,mail_mark_read,mail_mark_unread,mail_flag,mail_unflag,mail_move,mail_label,mail_trash,mail_delete,mail_create_folder,mail_rename_folder,mail_save_draft,mail_send,mail_reply,mail_forward
#|mail_probe,mail_list_folders,mail_search,mail_get,mail_get_new,mail_get_thread,mail_classify
#|True True False True False False
#|True True False True True True False True False True False
#|true or false|an integer|a string|an object|a string or an array of strings|an array of objects
#|"uidvalidity" is required: pass the value mail_search or mail_get returned with these UIDs, so stale UIDs can never change other messages
#|"confirm" is required: it must be exactly "permanently-delete" | "uid" is required
#|[][][]
#|[the arguments must be a JSON object]
#|[unknown argument "bogus" for mail_get]
#|["uid" must be an integer]
#|["uid" is required]
#|["uidvalidity" is required: pass the value mail_search or mail_get returned with these UIDs, so stale UIDs can never change other messages]
#|["confirm" is required: it must be exactly "permanently-delete"]
#|["as_draft" must be true or false]
#|["dry_run" is given more than once]["dry_run" is given more than once][unknown argument "bogus" for mail_get]
#|[]
#|["to" must be a string or an array of strings]
#|[unknown argument "bogus" for mail_send attachments]
#|["attachments" must be an array of objects]
#|False [] 0 []
#|True [bob@x.com,@example.org] 5 [/home/u/.local/state/mailbend]
#|True [] 0 [/st] False [] 0 [/xdg/mailbend] False [] 0 []
#|error MAILBEND_SAVE_SENT must be 1, true, 0, false or empty
#|error MAILBEND_ALLOWED_RECIPIENTS: "" is neither an address like name@example.com nor a domain like @example.com
#|error MAILBEND_ALLOWED_RECIPIENTS: "bob <b@x.com>" is neither an address like name@example.com nor a domain like @example.com
#|error MAILBEND_ALLOWED_RECIPIENTS: "@" is neither an address like name@example.com nor a domain like @example.com | error MAILBEND_ALLOWED_RECIPIENTS: "x.com" is neither an address like name@example.com nor a domain like @example.com | error MAILBEND_ALLOWED_RECIPIENTS: "@a@b" is neither an address like name@example.com nor a domain like @example.com
#|error MAILBEND_MAX_SENDS_PER_DAY must be a positive whole number | error MAILBEND_MAX_SENDS_PER_DAY must be a positive whole number | error MAILBEND_MAX_SENDS_PER_DAY must be a positive whole number | error MAILBEND_MAX_SENDS_PER_DAY must be a positive whole number
#|error MAILBEND_STATE_DIR must be an absolute path
#|error MAILBEND_SAVE_SENT must be 1, true, 0, false or empty
#|[]
#|the daily send limit is reached: MAILBEND_MAX_SENDS_PER_DAY allows 5 per day (UTC)
#|mailbend-attach gave an unexpected count
#|cannot count this send for MAILBEND_MAX_SENDS_PER_DAY: cannot lock the send counter
#|cannot run mailbend-attach: timed out
#|MAILBEND_ALLOWED_RECIPIENTS does not allow sending to a@x.com, b%c@y.com; nothing was sent
#|True False True False
#|saved to Sent | failed or unconfirmed (check Sent before saving again): no
#|INBOX,Sent Messages | Sent Messages,INBOX | inbox | INBOX | Archive,INBOX
#|INBOX 7 [4 2 2 9 ] 0 | Sent 8 [1 ] 0 | 
#|INBOX 7 [4 2 2 9 ] 0 | Sent 8 [1 ] 0 | 
#|err a folder's UIDVALIDITY changed while the thread was read, so its UIDs may name other messages: read the thread again
#|err a folder's UIDVALIDITY changed while the thread was read, so its UIDs may name other messages: read the thread again
#|err down
#|INBOX [2 9 ] | Sent [1 ] | 
#|INBOX 7 [] 2 | 
#|ok {"folder":"INBOX","uid":1,"searched":["INBOX","Sent"],"messages":[{"folder":"INBOX","uidvalidity":7,"uid":1,"date":"","from":"","to":"","cc":"","subject":"","message_id":"<b@x>","internal_date":"","size":0,"flags":[],"seen":false,"flagged":false,"parent":"<a@x>"},{"folder":"Sent","uidvalidity":null,"uid":1,"date":"","from":"","to":"","cc":"","subject":"","message_id":"<a@x>","internal_date":"","size":0,"flags":[],"seen":false,"flagged":false,"parent":null}]} | shown 1 1 with the folders, Sent Sent
#|err down | shown 
#|uids 1 3 5 |uids 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 |error mail_classify takes at most 50 UIDs per call|error mail_triage takes at most 50 UIDs per call|error no uids
#|names Ideas,Ideas/2026
#|error candidate "": a folder name cannot be empty
#|error candidate "a	b": a folder name cannot contain control characters
#|error Jev chooses among at most 254 folders and candidates (TypeSafe takes 255 options, and one is "none"); there are 255
#|Work,Work/Sub,Team/Sub,Projects,Mail
#|INBOX/Kids,Ideas
#|[]
#|[candidate "Work": a folder named "Work" already exists]
#|[candidate "Ideas" is listed twice]
#|[candidate "Bin/Old": "Bin/Old" is, or lies inside, a folder MailBend relies on: INBOX, Drafts, Sent, Trash, Junk, Archive (also under their usual names), To Delete, and any folder configured for one of those roles or advertised with any special-use role]
#|[candidate "Nope/New": the parent folder "Nope" does not exist; create it first]
#|[][Jev chooses among at most 254 folders and candidates (TypeSafe takes 255 options, and one is "none"); there are 255]
#|[][the folder and candidate names are too long for one TypeSafe question: pass fewer or shorter candidates]
#|1 2 3 |2 
#|answered {"answers":{}}
#|refused TypeSafe refused the request (HTTP 422): bad question
#|refused TypeSafe refused the request (HTTP 422): [{"loc":["body"],"msg":"bad"}]
#|refused TypeSafe refused the request (HTTP 400): not json
#|1000
#|failed configuration error: MAILBEND_TYPESAFE_KEY_FILE is not set
#|failed cannot reach TypeSafe: cannot reach api.typesafe.ai (system DNS; refused)
#|failed check MAILBEND_TYPESAFE_KEY_FILE: TypeSafe rejected the key (HTTP 401)
#|failed try again later: TypeSafe timed out, after retries
#|failed TypeSafe error: internal error
#|failed the TypeSafe helper was killed by a signal: 
#|failed cannot run the TypeSafe helper: no such file
#|{"messages":2,"bytes":100,"input_tokens":null} {"messages":1,"bytes":9,"input_tokens":7}
#|stopped TypeSafe's answer is not the JSON MailBend asked for
#|stopped no
#|progress 1  [{"messages":0,"bytes":10,"input_tokens":null}]
#|ok {"folder":"INBOX","messages":[{"uid":1,"category":null,"jev":{"status":"unchecked","model":"jev-1.13.0","content":"headers","derived_from_untrusted_content":true,"decision":"proceeded","reasons":["its header fields alone exceed what one TypeSafe request may hold"],"signals":{}}},{"uid":2,"category":null,"jev":{"status":"unchecked","model":"jev-1.13.0","content":"headers","derived_from_untrusted_content":true,"decision":"proceeded","reasons":["its header fields alone exceed what one TypeSafe request may hold"],"signals":{}}},{"uid":3,"category":null,"jev":{"status":"unchecked","model":"jev-1.13.0","content":"headers","derived_from_untrusted_content":true,"decision":"proceeded","reasons":["its header fields alone exceed what one TypeSafe request may hold"],"signals":{}}}],"not_found":[9],"requests":["r1","r2"]}
#|err stopped
#|mail_classify is disabled: it consults TypeSafe's Jev, and MAILBEND_TYPESAFE is off
#|[only mail_triage moves mail into "To Delete", which the user reviews][only mail_triage moves mail into "To Delete", which the user reviews][][]
#|[mail_trash never moves mail into or out of "To Delete", which the user reviews; mail_move can take a message out of it, and mail_delete can remove messages from it permanently][mail_trash never moves mail into or out of "To Delete", which the user reviews; mail_move can take a message out of it, and mail_delete can remove messages from it permanently][]
#|[mail_triage files mail out of other folders, never out of "To Delete", which the user reviews][]
#|[MAILBEND_X cannot name the review folder "To Delete" or a folder inside it][MAILBEND_X cannot name the review folder "To Delete" or a folder inside it][MAILBEND_X must name one existing selectable mailbox]
#|[][it is also a special folder, which MailBend never fills][it is also a special folder, which MailBend never fills][it does not exist or cannot be selected: create it with mail_create_folder]
#|a@x,b@y
#|a@x.org none none none
#|a@x,b@y
#|a@x,c@z
#|[][it has been answered] []
#|[it is flagged]
#|whether the user has written to its sender cannot be told|the user has written to its sender|
#||it was not checked
#|[Jev found UID 3, UID 4 safe to delete, but "To Delete" cannot take them: it does not exist][][]
#|[the server supports neither MOVE nor UIDPLUS; refusing to move with a plain EXPUNGE, which could remove other messages][the moves failed the triage plan's own check][][]
#|ok {"moves":[]}
#|partial {"ok":false,"partial":true,"message":"a move did not finish, so the moves after it were not made; see moves, and check its destination before running mail_triage again","moves":["first",{"ok":false,"destination":"To Delete","error":"lost"}]}
#|ok {"folder":"INBOX","moves":[]}
#|partial {"folder":"INBOX","ok":false}
#|err no
#|mail_triage is disabled: it consults TypeSafe's Jev, and MAILBEND_TYPESAFE is off
