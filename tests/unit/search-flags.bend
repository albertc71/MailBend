# Fixed wire and cursor expectations for validated structured flags.
import Base
import ../../src/json.bend as J
import ../../src/imap.bend as I
import ../../src/tools.bend as Tools
import ../../src/search-cursor.bend as SC

def rendered(r: Tools.Keys()) -> String:
  match r:
    case Done{keys}:
      I.search_args(keys)
    case Fail{message}:
      message

def query(s: String) -> String:
  rendered(Tools.keys_of(Maybe.default(&2, J.Json, J.parse(s), J.JNull{})))

def accepted(r: SC.ResultCursor()) -> String:
  match r:
    case Done{c}:
      "accepted"
    case Fail{m}:
      "refused"

def main() -> IO(Unit):
  +old = SC.binding("INBOX", query("{}"))
  +answered = SC.binding("INBOX", query("{\"answered\":true}"))
  +unanswered = SC.binding("INBOX", query("{\"answered\":false}"))
  +draft = SC.binding("INBOX", query("{\"draft\":true}"))
  +undraft = SC.binding("INBOX", query("{\"draft\":false}"))
  do IO<Unit>:
    IO.print(I.key_str(I.KAnswered{}))
    IO.print(I.key_str(I.KUnanswered{}))
    IO.print(I.key_str(I.KDraft{}))
    IO.print(I.key_str(I.KUndraft{}))
    IO.print(query("{}"))
    IO.print(query("{\"draft\":true}"))
    IO.print(query("{\"draft\":false}"))
    IO.print(query("{\"answered\":true}"))
    IO.print(query("{\"answered\":true,\"draft\":true}"))
    IO.print(query("{\"answered\":true,\"draft\":false}"))
    IO.print(query("{\"answered\":false}"))
    IO.print(query("{\"answered\":false,\"draft\":true}"))
    IO.print(query("{\"answered\":false,\"draft\":false}"))
    IO.print(query("{\"draft\":false,\"answered\":true}"))
    IO.print(query("{\"subject\":\"needle\",\"unseen\":true,\"flagged\":false,\"answered\":false,\"draft\":true,\"since\":\"2026-02-01\",\"before\":\"2026-03-01\"}"))
    IO.print(query("{\"seen\":true,\"unseen\":true,\"since\":\"bad\",\"before\":\"bad\",\"answered\":false}"))
    IO.print(query("{\"seen\":true,\"unseen\":true,\"before\":\"bad\",\"draft\":true}"))
    IO.print(query("{\"seen\":true,\"unseen\":true,\"answered\":true}"))
    IO.print(SC.token(old, 7, 2))
    IO.print(accepted(SC.read(Some{J.str("s1:7:2:[\"INBOX\",\"ALL\"]")}, old)))
    IO.print(accepted(SC.read(Some{J.str(SC.token(answered, 7, 2))}, unanswered)))
    IO.print(accepted(SC.read(Some{J.str(SC.token(answered, 7, 2))}, old)))
    IO.print(accepted(SC.read(Some{J.str(SC.token(old, 7, 2))}, answered)))
    IO.print(accepted(SC.read(Some{J.str(SC.token(draft, 7, 2))}, undraft)))
    IO.print(accepted(SC.read(Some{J.str(SC.token(draft, 7, 2))}, old)))
    IO.print(accepted(SC.read(Some{J.str(SC.token(old, 7, 2))}, draft)))
    IO.print(Bool.show(SC.fits(String.join(List.replicate(String, 4000n, "x"), ""), SC.max_binding_chars())))
    IO.print(Bool.show(SC.fits(String.join(List.replicate(String, 4001n, "x"), ""), SC.max_binding_chars())))
    IO.print(Bool.show(SC.fits(String.join(List.replicate(String, 4096n, "x"), ""), SC.max_token_chars())))
    IO.print(Bool.show(SC.fits(String.join(List.replicate(String, 4097n, "x"), ""), SC.max_token_chars())))

    IO.print(J.show(J.str(query("{\"subject\":\"x\\\" UID STORE 1 +FLAGS (\\\\Deleted)\",\"answered\":false}"))))
    IO.print(J.show(J.str(query("{\"text\":\"Café\",\"draft\":false}"))))

#|ANSWERED
#|UNANSWERED
#|DRAFT
#|UNDRAFT
#|ALL
#|DRAFT
#|UNDRAFT

#|ANSWERED
#|ANSWERED DRAFT
#|ANSWERED UNDRAFT
#|UNANSWERED
#|UNANSWERED DRAFT
#|UNANSWERED UNDRAFT
#|ANSWERED UNDRAFT
#|SUBJECT "needle" UNSEEN UNFLAGGED UNANSWERED DRAFT SINCE 1-Feb-2026 BEFORE 1-Mar-2026
#|"since" must be a date like 2026-02-01
#|"before" must be a date like 2026-02-01
#|"seen" and "unseen" contradict each other; use opposite values or omit one
#|s1:7:2:["INBOX","ALL"]
#|accepted
#|refused
#|refused
#|refused
#|refused
#|refused
#|refused
#|True
#|False
#|True
#|False
#|"SUBJECT \"x\\\" UID STORE 1 +FLAGS (\\\\Deleted)\" UNANSWERED"
#|"CHARSET UTF-8 TEXT {5}\r\nCafé UNDRAFT"
