import Base

# The SMTP envelope handed to mailbend-tls, which greets, upgrades with
# STARTTLS and authenticates before sending these lines.

def ensure_crlf(+msg: String) -> String:
  Bool.pick(String, String.ends_with(msg, "\r\n"), msg, msg ++ "\r\n")

# Doubles a leading '.' on every line (RFC 5321 4.5.2). `line_start` says whether
# the next char starts a line.
def dot_stuff(+text: String, +line_start: Bool) -> String:
  match text:
    case SNil{}:
      ""
    case SCon{'.', rest}:
      Bool.pick(String, line_start, "..", ".") ++ dot_stuff(rest, False{})
    case SCon{'\n', rest}:
      "\n" ++ dot_stuff(rest, True{})
    case SCon{char, rest}:
      SCon{char, dot_stuff(rest, False{})}

def rcpt_lines(+recipients: List<&2, String>) -> String:
  match recipients:
    case Nil{}:
      ""
    case Con{recipient, rest}:
      "RCPT TO:<" ++ recipient ++ ">\r\n" ++ rcpt_lines(rest)

# The envelope: sender and recipients are bare, already validated
# addresses; `msg` is the composed 7-bit message.
def envelope(+from: String, +rcpts: List<&2, String>, +msg: String) -> String:
  commands = "MAIL FROM:<" ++ from ++ ">\r\n" ++ rcpt_lines(rcpts) ++ "DATA\r\n"
  body = dot_stuff(ensure_crlf(msg), True{})
  commands ++ body ++ ".\r\n"

# The last reply line of a transcript that starts with a 4xx/5xx code.
def last_error(+lines: List<&2, String>, +found: String) -> String:
  match lines:
    case Nil{}:
      found
    case Con{+line, rest}:
      is_error = String.starts_with(line, "4") || String.starts_with(line, "5")
      last_error(rest, Bool.pick(String, is_error, String.trim(line), found))

# The text of the last "250 " reply (the queue confirmation after DATA).
def last_ok(+lines: List<&2, String>, +found: String) -> String:
  match lines:
    case Nil{}:
      found
    case Con{+line, rest}:
      last_ok(rest, Bool.pick(String, String.starts_with(line, "250 "), String.trim(line), found))
