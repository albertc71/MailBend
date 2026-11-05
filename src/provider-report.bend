# Fixed provider facts for public diagnostic reports. No server text escapes.

import Base
import ./json.bend as J
import ./imap.bend as I
import ./policy.bend as Policy

def capability_allowlist() -> List<&2, String>:
  ["IMAP4REV1", "UIDPLUS", "MOVE", "CONDSTORE", "X-GM-EXT-1", "IMAP4REV2",
    "ACL", "APPENDLIMIT", "AUTH=PLAIN", "AUTH=LOGIN", "AUTH=XOAUTH2", "AUTH=OAUTHBEARER",
    "BINARY", "CATENATE", "CHILDREN", "COMPRESS=DEFLATE", "CONTEXT=SEARCH", "CONTEXT=SORT",
    "CREATE-SPECIAL-USE", "ENABLE", "ESEARCH", "ESORT", "FILTERS", "I18NLEVEL=1",
    "I18NLEVEL=2", "ID", "IDLE", "LANGUAGE", "LIST-EXTENDED", "LIST-MYRIGHTS",
    "LIST-STATUS", "LITERAL+", "LITERAL-", "LOGIN-REFERRALS", "LOGINDISABLED",
    "MAILBOX-REFERRALS", "METADATA", "METADATA-SERVER", "MULTIAPPEND", "NAMESPACE",
    "NOTIFY", "OBJECTID", "PREVIEW", "QRESYNC", "QUOTA", "QUOTA=RES-STORAGE",
    "QUOTA=RES-MESSAGE", "QUOTA=RES-MAILBOX", "QUOTA=RES-ANNOTATION-STORAGE",
    "QUOTASET", "RIGHTS=KXTE", "SASL-IR", "SAVEDATE", "SEARCH=FUZZY", "SEARCHRES",
    "SORT", "SORT=DISPLAY", "SPECIAL-USE", "STARTTLS", "STATUS=SIZE",
    "THREAD=ORDEREDSUBJECT", "THREAD=REFERENCES", "UIDONLY", "UNSELECT", "URLAUTH",
    "URLAUTH=BINARY", "URL-PARTIAL", "UTF8=ACCEPT", "UTF8=ONLY", "WITHIN"]

def allowed_tokens(allowed: List<&2, String>, +tokens: List<&2, String>) -> List<&2, String>:
  match allowed:
    case Nil{}:
      []
    case +token <> t:
      List.filter.put(String, token, allowed_tokens(t, tokens),
        List.contains(~String, ~String.eq, tokens, token))

def unknown_count(tokens: List<&2, String>, +allowed: List<&2, String>) -> U32:
  match tokens:
    case Nil{}:
      0
    case +token <> t:
      extra = Bool.pick(U32, String.is_empty(token) ||
        List.contains(~String, ~String.eq, allowed, token), 0, 1)
      (extra + unknown_count(t, allowed) : U32)

def capabilities(+cs: List<&2, String>) -> J.Json:
  +allowed = capability_allowlist()
  J.obj([J.kv("tokens", J.strs(allowed_tokens(allowed, cs))),
    J.kv("unknown_count", J.num(unknown_count(cs, allowed)))])

def candidate_method(fs: List<&2, I.Folder>, method: String) -> String:
  match fs:
    case I.Folder{name, delim, attrs} <> Nil{}:
      Bool.pick(String, Policy.selectable(attrs), method, "unresolved")
    case a <> b <> t:
      "ambiguous"
    case _:
      "unresolved"

def role_method.named(marked: List<&2, I.Folder>, fs: List<&2, I.Folder>,
  attr: String, a: String, b: String) -> String:
  match marked:
    case Nil{}:
      candidate_method(Policy.role_candidates(fs, attr, a, b, False{}), "name")
    case _:
      candidate_method(marked, "advertised")

def role_method.choose(unset: Bool, +fs: List<&2, I.Folder>, override: String,
  +attr: String, +a: String, +b: String) -> String:
  match unset:
    case True{}:
      role_method.named(Policy.role_candidates(fs, attr, a, b, True{}), fs, attr, a, b)
    case False{}:
      candidate_method(Policy.override_candidates(fs, override), "override")

def role_method(fs: List<&2, I.Folder>, +override: String, attr: String, a: String, b: String) -> String:
  role_method.choose(String.is_empty(override), fs, override, attr, a, b)

def roles(+fs: List<&2, I.Folder>, drafts: String, trash: String, sent: String,
  junk: String, archive: String) -> J.Json:
  J.obj([
    J.kv("inbox", J.str(candidate_method(Policy.override_candidates(fs, "INBOX"), "name"))),
    J.kv("drafts", J.str(role_method(fs, drafts, "\\Drafts", Policy.drafts_name(), Policy.drafts_name()))),
    J.kv("trash", J.str(role_method(fs, trash, "\\Trash", Policy.trash_name(), Policy.deleted_messages_name()))),
    J.kv("sent", J.str(role_method(fs, sent, "\\Sent", Policy.sent_name(), Policy.sent_messages_name()))),
    J.kv("junk", J.str(role_method(fs, junk, "\\Junk", Policy.junk_name(), Policy.junk_name()))),
    J.kv("archive", J.str(role_method(fs, archive, "\\Archive", Policy.archive_name(), Policy.archive_name())))])

def smtp_count_lines(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case +h <> t:
      List.filter.put(String, String.drop(h, 16n), smtp_count_lines(t),
        String.starts_with(h, "smtp_auth_other "))

def smtp_mechanisms(allowed: List<&2, String>, +lines: List<&2, String>) -> List<&2, String>:
  match allowed:
    case Nil{}:
      []
    case +h <> t:
      List.filter.put(String, h, smtp_mechanisms(t, lines),
        List.contains(~String, ~String.eq, lines, "smtp_auth " ++ h))

def smtp_count.parsed(n: Maybe<&2, U32>, raw: String, lines: List<&2, String>) -> J.Json:
  match n:
    case Some{+count}:
      Bool.pick(J.Json, String.eq(raw, U32.show(count)),
        J.obj([J.kv("mechanisms", J.strs(smtp_mechanisms(
          ["PLAIN", "LOGIN", "XOAUTH2", "OAUTHBEARER"], lines))),
          J.kv("unknown_count", J.num(count))]), J.JNull{})
    case None{}:
      J.JNull{}

def smtp_count(counts: List<&2, String>, lines: List<&2, String>) -> J.Json:
  match counts:
    case +raw <> Nil{}:
      smtp_count.parsed(U32.read(raw), raw, lines)
    case _:
      J.JNull{}

def smtp(out: String) -> J.Json:
  +lines = String.lines(out)
  smtp_count(smtp_count_lines(lines), lines)

type Facts is Data:
  Facts{capabilities: J.Json, roles: J.Json, smtp: J.Json}

def empty() -> Facts:
  Facts{J.JNull{}, J.JNull{}, J.JNull{}}

def facts_json(facts: Facts, version: String) -> J.Json:
  Facts{caps, roles, smtp} = facts
  J.obj([J.kv("mailbend_version", J.str(version)),
    J.kv("imap_capabilities", caps), J.kv("roles", roles), J.kv("smtp_auth", smtp)])

def add(j: J.Json, facts: Facts, version: String) -> J.Json:
  match j:
    case J.JObj{items}:
      J.JObj{J.JCons{J.kv("server_facts", facts_json(facts, version)), items}}
    case _:
      j
