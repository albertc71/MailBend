# The SMTP envelope handed to mailbend-tls, which greets, upgrades with
# STARTTLS and authenticates before sending these lines; and the reading of
# the replies it gives back.

import Base

# `msg` as is when it already ends in CRLF, else with one appended. A def, not
# a Bool.pick, so the message is copied only when the CRLF is missing.
def ensure_crlf.if(msg: String, ended: Bool) -> String:
  match ended:
    case True{}:
      msg
    case False{}:
      msg ++ "\r\n"

def ensure_crlf(+msg: String) -> String:
  ensure_crlf.if(msg, String.ends_with(msg, "\r\n"))

# Doubles a leading '.' on every line (RFC 5321 4.5.2). `line_start` says
# whether the next char starts a line.
def dot_stuff(text: String, line_start: Bool) -> String:
  match text:
    case SNil{}:
      ""
    case SCon{'.', rest}:
      Bool.pick(String, line_start, "..", ".") ++ dot_stuff(rest, False{})
    case SCon{'\n', rest}:
      "\n" ++ dot_stuff(rest, True{})
    case SCon{char, rest}:
      SCon{char, dot_stuff(rest, False{})}

def rcpt_lines(recipients: List<&2, String>) -> String:
  match recipients:
    case Nil{}:
      ""
    case recipient <> rest:
      "RCPT TO:<" ++ recipient ++ ">\r\n" ++ rcpt_lines(rest)

# The envelope: sender and recipients are bare, already validated
# addresses; `msg` is the composed 7-bit message.
def envelope(from: String, rcpts: List<&2, String>, msg: String) -> String:
  commands = "MAIL FROM:<" ++ from ++ ">\r\n" ++ rcpt_lines(rcpts) ++ "DATA\r\n"
  body = dot_stuff(ensure_crlf(msg), True{})
  commands ++ body ++ ".\r\n"

# The recipient allowlist
# -----------------------

# An allowlist holds lower-case entries: exact addresses, and "@domain" for
# every address at exactly that domain (not its subdomains). An empty one
# allows every recipient.

# Whether the lower-case `rcpt` is the address `entry`, or at its "@domain".
def entry_allows(entry: String, rcpt: String) -> Bool:
  match entry:
    case SCon{'@', domain}:
      String.ends_with(rcpt, SCon{'@', domain})
    case _:
      String.eq(entry, rcpt)

def listed(allow: List<&2, String>, +rcpt: String) -> Bool:
  match allow:
    case Nil{}:
      False{}
    case entry <> rest:
      entry_allows(entry, rcpt) || listed(rest, rcpt)

# Whether `rcpt` has a source-route character (as in a%b@allowed.com),
# which some servers would relay on to another domain.
def source_routed(+rcpt: String) -> Bool:
  String.contains(rcpt, "%") || String.contains(rcpt, "!") || String.contains(rcpt, ":")

# Whether the bare address `rcpt` may receive mail under `allow`. With an
# allowlist, a source-routed address is refused even when it is listed.
def allowed(allow: List<&2, String>, rcpt: String) -> Bool:
  match allow:
    case Nil{}:
      True{}
    case entry <> rest:
      +low = String.to_lower(rcpt)
      Bool.not(source_routed(low)) && listed(entry <> rest, low)

def all_allowed(+allow: List<&2, String>, rcpts: List<&2, String>) -> Bool:
  match rcpts:
    case Nil{}:
      True{}
    case rcpt <> rest:
      allowed(allow, rcpt) && all_allowed(allow, rest)

# The recipients `allow` refuses, in order.
def refused(+allow: List<&2, String>, rcpts: List<&2, String>) -> List<&2, String>:
  match rcpts:
    case Nil{}:
      []
    case +rcpt <> rest:
      List.filter.put(String, rcpt, refused(allow, rest), Bool.not(allowed(allow, rcpt)))

def outbound.if(ok: Bool, rcpts: List<&2, String>, from: String, msg: String) ->
  Maybe<&2, String>:
  match ok:
    case True{}:
      Some{envelope(from, rcpts, msg)}
    case False{}:
      None{}

# The envelope for the bare addresses `rcpts`, or None when `allow` refuses
# any of them. Sending builds its envelope only here, so every RCPT TO is a
# recipient the allowlist was asked about.
def outbound(
  allow: List<&2, String>,
  +rcpts: List<&2, String>,
  from: String,
  msg: String
) -> Maybe<&2, String>:
  outbound.if(all_allowed(allow, rcpts), rcpts, from, msg)

# The trimmed `line` on a hit, else the reply `found` so far. A def, not a
# Bool.pick, so only a hit is trimmed.
def last_reply.if(line: String, found: String, hit: Bool) -> String:
  match hit:
    case True{}:
      String.trim(line)
    case False{}:
      found

# The last reply line of a transcript that starts with a 4xx/5xx code.
def last_error(lines: List<&2, String>, found: String) -> String:
  match lines:
    case Nil{}:
      found
    case +line <> rest:
      is_error = String.starts_with(line, "4") || String.starts_with(line, "5")
      last_error(rest, last_reply.if(line, found, is_error))

# The text of the last "250 " reply (the queue confirmation after DATA).
def last_ok(lines: List<&2, String>, found: String) -> String:
  match lines:
    case Nil{}:
      found
    case +line <> rest:
      is_ok = String.starts_with(line, "250 ")
      last_ok(rest, last_reply.if(line, found, is_ok))
