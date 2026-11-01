# Reply identity and incomplete-evidence boundaries on synthetic headers.

import Base
import ../../src/awaiting.bend as A
import ../../src/imap.bend as I
import ../../src/thread.bend as T
import ../../src/ops.bend as Ops

def node(uid: U32, date: String, headers: String) -> T.Node:
  T.node("Sent", Some{7}, I.Msg{uid, [], date, 0, headers, "", I.VNil{}})

def sent() -> T.Node:
  node(1, "01-Oct-2026 09:00:00 +0000", "Message-ID: <sent@x>\r\nTo: recipient@example.test\r\n")

def reply(headers: String) -> T.Node:
  node(2, "02-Oct-2026 09:00:00 +0000", headers)

def state(rs: List<&2, T.Node>, complete: Bool) -> String:
  A.status_name(A.classify(sent(), rs, complete, 1791000000))

def search(lines: List<&2, I.RLine>) -> String:
  Bool.show(Maybe.is_some(&2, List<&2, U32>, A.search(lines)))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(state([], True{}))
    IO.print(state([], False{}))
    IO.print(state([reply("In-Reply-To: <sent@x>\r\n")], True{}))
    IO.print(state([reply("References: <other@x> <sent@x>\r\n")], False{}))
    IO.print(state([reply("In-Reply-To: <sent@x.extra>\r\n")], True{}))
    IO.print(state([reply("Subject: <sent@x>\r\n")], True{}))
    IO.print(state([node(2, "01-Oct-2026 09:00:00 +0000", "In-Reply-To: <sent@x>\r\n")], True{}))
    IO.print(state([node(2, "31-Feb-2026 09:00:00 +0000", "In-Reply-To: <sent@x>\r\n")], False{}))
    IO.print(A.status_name(A.classify(node(3, "01-Oct-2026 09:00:00 +0000", "Subject: missing\r\n"), [], True{}, 1791000000)))
    IO.print(A.status_name(A.classify(node(3, "01-Oct-2026 09:00:00 +0000", "Message-ID: <a@x> <b@x>\r\n"), [], True{}, 1791000000)))
    IO.print(A.status_name(A.classify(node(3, "01-Oct-2026 09:00:00 +0000", "Message-ID: <a@x>\r\nMessage-ID: <b@x>\r\n"), [], True{}, 1791000000)))
    IO.print(Bool.show(A.date_valid(node(1, "01-Oct-2026 4294967296:00:00 +0000", ""))))
    IO.print(Bool.show(A.date_valid(node(1, "01-Oct-2026 09:4294967296:00 +0000", ""))))
    IO.print(Bool.show(A.date_valid(node(1, "01-Oct-2026 09:00:4294967296 +0000", ""))))
    IO.print(search([I.RLine{"* SEARCH", []}]))
    IO.print(search([I.RLine{"* SEARCH 1 2", []}]))
    IO.print(search([I.RLine{"* 2 EXISTS", []}, I.RLine{"* SEARCH 1", []}]))
    IO.print(search([]))
    IO.print(search([I.RLine{"* SEARCH invalid", []}]))
    IO.print(search([I.RLine{"* SEARCH 4294967296", []}]))
    IO.print(search([I.RLine{"* SEARCH 0", []}]))
    IO.print(search([I.RLine{"* SEARCH", []}, I.RLine{"* SEARCH", []}]))
    IO.print(Bool.show(I.any_writes(Ops.plan_awaiting_sent("Sent", "1-Oct-2026"))))
    IO.print(I.key_str(A.batch_key(["<a@x>", "<b@x>"])))

#|awaiting
#|unknown
#|replied
#|replied
#|awaiting
#|awaiting
#|awaiting
#|unknown
#|unknown
#|unknown
#|unknown
#|False
#|False
#|False
#|True
#|True
#|True
#|False
#|False
#|False
#|False
#|False
#|False
#|OR OR HEADER "References" "<a@x>" HEADER "In-Reply-To" "<a@x>" OR HEADER "References" "<b@x>" HEADER "In-Reply-To" "<b@x>"
