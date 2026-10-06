# SMTP envelope: CRLF ending, dot-stuffing, RCPT lines and reply scanning.
import Base
import ../../src/smtp.bend as S

# Shows CR and LF as "\r" and "\n" so expectations stay on one line.
def vis(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\r', t}:
      "\\r" ++ vis(t)
    case SCon{'\n', t}:
      "\\n" ++ vis(t)
    case SCon{c, t}:
      SCon{c, vis(t)}

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("[" ++ vis(S.ensure_crlf("")) ++ "] [" ++ vis(S.ensure_crlf("a")) ++ "]")
    IO.print(vis(S.ensure_crlf("a\r\n")) ++ " " ++ vis(S.ensure_crlf("a\n")) ++ " " ++ vis(S.ensure_crlf("a\r")))
    IO.print("[" ++ S.dot_stuff("", True{}) ++ "] " ++ S.dot_stuff(".", True{}) ++ " " ++ S.dot_stuff(".", False{}))
    IO.print(vis(S.dot_stuff(".a\n.b\n..c\nx.y\n.", True{})))
    IO.print(vis(S.dot_stuff(".a\r\n.\r\nb.\r\n", False{})))
    IO.print("[" ++ S.rcpt_lines([]) ++ "]")
    IO.print(vis(S.rcpt_lines(["a@x.com", "b@y.com"])))
    IO.print(vis(S.envelope("me@x.com", ["a@y.com"], "Subject: hi\r\n\r\n.\r\nbye")))
    IO.print(vis(S.envelope("", [], "")))
    IO.print(vis(S.envelope("me@x.com", ["a@y.com", "b@z.com"], "..x\r\n")))
    IO.print(S.last_error(String.lines("220 hi\n250 ok\n550 5.1.1 no such user \r\n421 bye\n250 fine"), "none"))
    IO.print(S.last_error(String.lines("220 hi\n 550 indented\n250 ok"), "none"))
    IO.print("[" ++ S.last_error([], "") ++ "] " ++ S.last_error(["4"], "x") ++ " " ++ S.last_error(["5xx"], "x"))
    IO.print(S.last_ok(String.lines("220 hi\n250-PIPELINING\n250 OK queued as 12 \r\n354 go\n 250 indented"), "none"))
    IO.print(S.last_ok(String.lines("220 hi\n250\n250-x\n550 no"), "none"))
    IO.print("[" ++ S.last_ok([], "") ++ "] [" ++ S.last_ok(["250 "], "x") ++ "]")

#|[\r\n] [a\r\n]
#|a\r\n a\n\r\n a\r\r\n
#|[] .. .
#|..a\n..b\n...c\nx.y\n..
#|.a\r\n..\r\nb.\r\n
#|[]
#|RCPT TO:<a@x.com>\r\nRCPT TO:<b@y.com>\r\n
#|MAIL FROM:<me@x.com>\r\nRCPT TO:<a@y.com>\r\nDATA\r\nSubject: hi\r\n\r\n..\r\nbye\r\n.\r\n
#|MAIL FROM:<>\r\nDATA\r\n\r\n.\r\n
#|MAIL FROM:<me@x.com>\r\nRCPT TO:<a@y.com>\r\nRCPT TO:<b@z.com>\r\nDATA\r\n...x\r\n.\r\n
#|421 bye
#|none
#|[] 4 5xx
#|250 OK queued as 12
#|none
#|[] [250]
