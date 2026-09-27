import Base

# The SMTP envelope handed to mailbend-tls, which greets, upgrades with
# STARTTLS and authenticates before sending these lines.

def ensure_crlf(+msg: String) -> String:
  Bool.pick(String, String.ends_with(msg, "\r\n"), msg, msg ++ "\r\n")

# Doubles a leading '.' on every line (RFC 5321 4.5.2). `bol` says whether
# the next char starts a line.
def dot_stuff(+s: String, +bol: Bool) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'.', t}:
      Bool.pick(String, bol, "..", ".") ++ dot_stuff(t, False{})
    case SCon{'\n', t}:
      "\n" ++ dot_stuff(t, True{})
    case SCon{c, t}:
      SCon{c, dot_stuff(t, False{})}

def rcpt_lines(+rcpts: List<&2, String>) -> String:
  match rcpts:
    case Nil{}:
      ""
    case Con{r, t}:
      "RCPT TO:<" ++ r ++ ">\r\n" ++ rcpt_lines(t)

# The envelope: sender and recipients are bare, already validated
# addresses; `msg` is the composed 7-bit message.
def envelope(+from: String, +rcpts: List<&2, String>, +msg: String) -> String:
  "MAIL FROM:<" ++ from ++ ">\r\n" ++ rcpt_lines(rcpts) ++ "DATA\r\n" ++ dot_stuff(ensure_crlf(msg), True{}) ++ ".\r\n"

# The last reply line of a transcript that starts with a 4xx/5xx code.
def last_error(+lines: List<&2, String>, +found: String) -> String:
  match lines:
    case Nil{}:
      found
    case Con{l, t}:
      last_error(t, Bool.pick(String, String.starts_with(l, "4") || String.starts_with(l, "5"), String.trim(l), found))

# The text of the last "250 " reply (the queue confirmation after DATA).
def last_ok(+lines: List<&2, String>, +found: String) -> String:
  match lines:
    case Nil{}:
      found
    case Con{l, t}:
      last_ok(t, Bool.pick(String, String.starts_with(l, "250 "), String.trim(l), found))
