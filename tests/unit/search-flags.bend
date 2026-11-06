# Structured search flags compile to canonical IMAP criteria and cursor bindings.

import Base
import ../../src/json.bend as J
import ../../src/imap.bend as I
import ../../src/tools.bend as T
import ../../src/search-cursor.bend as SC

def keys(k: T.Keys()) -> String:
  match k:
    case Done{ks}:
      I.search_args(ks)
    case Fail{m}:
      "error " ++ m

def criteria(s: String) -> String:
  keys(T.keys_of(Maybe.default(&2, J.Json, J.parse(s), J.JNull{})))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(I.search_args([I.KAnswered{}, I.KUnanswered{}, I.KDraft{}, I.KUndraft{}]))
    IO.print(criteria("{}"))
    IO.print(criteria("{\"answered\":true}"))
    IO.print(criteria("{\"answered\":false}"))
    IO.print(criteria("{\"unanswered\":true}"))
    IO.print(criteria("{\"unanswered\":false}"))
    IO.print(criteria("{\"answered\":true,\"unanswered\":false}"))
    IO.print(criteria("{\"answered\":false,\"unanswered\":true}"))
    IO.print(criteria("{\"answered\":true,\"unanswered\":true}"))
    IO.print(criteria("{\"answered\":false,\"unanswered\":false}"))
    IO.print(criteria("{\"draft\":true}"))
    IO.print(criteria("{\"draft\":false}"))
    IO.print(criteria("{\"answered\":true,\"draft\":false}"))
    IO.print(criteria(String.concat([
      "{\"from\":\"carol\",\"seen\":false,\"unseen\":true,\"flagged\":false,",
      "\"answered\":true,\"unanswered\":false,\"draft\":true,",
      "\"since\":\"2026-09-22\",\"before\":\"2026-09-24\"}"])))
    IO.print(SC.binding("INBOX", criteria("{\"answered\":false}")))
    IO.print(SC.binding("INBOX", criteria("{\"unanswered\":true}")))
    IO.print(SC.binding("INBOX", criteria("{\"answered\":false,\"unanswered\":true}")))
    IO.print(SC.binding("INBOX", criteria("{\"draft\":false}")))

#|ANSWERED UNANSWERED DRAFT UNDRAFT
#|ALL
#|ANSWERED
#|UNANSWERED
#|UNANSWERED
#|ANSWERED
#|ANSWERED
#|UNANSWERED
#|error "answered" and "unanswered" contradict each other; use opposite values or omit one
#|error "answered" and "unanswered" contradict each other; use opposite values or omit one
#|DRAFT
#|UNDRAFT
#|ANSWERED UNDRAFT
#|FROM "carol" UNSEEN UNFLAGGED ANSWERED DRAFT SINCE 22-Sep-2026 BEFORE 24-Sep-2026
#|["INBOX","UNANSWERED"]
#|["INBOX","UNANSWERED"]
#|["INBOX","UNANSWERED"]
#|["INBOX","UNDRAFT"]
