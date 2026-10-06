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
