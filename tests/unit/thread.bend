# Threads: message ID parsing, the searches and their exact confirmation,
# the IDs a next round searches for, and the order and parents of a thread,
# with missing parents, cycles and shared IDs in broken headers.

import Base
import ../../src/imap.bend as I
import ../../src/thread.bend as T

def ids(xs: List<&2, String>) -> String:
  "[" ++ String.join(xs, ",") ++ "]"

def node(folder: String, uid: U32, date: String, headers: String) -> T.Node:
  T.node(folder, Some{7}, I.Msg{uid, [], date, 0, headers, "", I.VNil{}})

def placed_line(p: T.Placed) -> String:
  T.Placed{+n, parent} = p
  T.node_folder(n) ++ "/" ++ U32.show(T.node_uid(n)) ++ "<-" ++ parent

def order_lines(ps: List<&2, T.Placed>) -> List<&2, String>:
  match ps:
    case Nil{}:
      []
    case p <> t:
      placed_line(p) <> order_lines(t)

def order(ns: List<&2, T.Node>) -> String:
  String.join(order_lines(T.thread_order(ns)), " ")

def early() -> String:
  "01-Oct-2026 09:00:00 +0000"

def later() -> String:
  "01-Oct-2026 10:00:00 +0000"

def latest() -> String:
  "01-Oct-2026 11:00:00 +0000"

# The IDs <r1@x> to <rN@x>, then `acc`.
def many_refs(+n: Nat, acc: List<&2, String>) -> List<&2, String>:
  match n:
    case 0n:
      acc
    case 1n+p:
      many_refs(p, ("<r" ++ Nat.show(1n+p) ++ "@x>") <> acc)

# The number of IDs and the first four.
def show_next(+xs: List<&2, String>) -> String:
  Nat.show(List.length(&2, String, xs)) ++ " " ++ ids(List.take(&2, String, xs, 4n))

# The length of each ID.
def id_lengths(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      " " ++ Nat.show(String.length(x)) ++ id_lengths(t)

# A reply to <a@x> whose References name `n` IDs no message has before it.
# The node is built directly: the interpreter that runs the unit tests
# overflows its stack parsing a header this long, unlike the compiled tool.
def long_reply(n: Nat) -> T.Node:
  T.Node{"INBOX", Some{7}, I.Msg{6, [], early(), 0, "", "", I.VNil{}}, I.internal_seconds(early()),
    "<z@x>", ["<a@x>"], many_refs(n, ["<a@x>"])}

# A reply to <b@x>, which replies to <a@x>.
def reply() -> T.Node:
  node("INBOX", 3, early(),
    "Message-ID: <c@x>\r\nIn-Reply-To: <b@x>\r\nReferences: <a@x> <b@x>\r\n")

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("ids")
    IO.print(ids(T.msg_ids("<a@x> (a comment) <b@y>")))
    IO.print(ids(T.msg_ids("")))
    IO.print(ids(T.msg_ids("<> junk <")))
    IO.print(ids(T.msg_ids("<a <b@y> <c@z")))
    IO.print("keys")
    IO.print(I.keys_str(T.search_keys(["<a@x>", "<b@y>"])))
    IO.print("linked")
    IO.print(Bool.show(T.is_linked(reply(), ["<c@x>"])))
    IO.print(Bool.show(T.is_linked(reply(), ["<b@x>"])))
    IO.print(Bool.show(T.is_linked(reply(), ["<a@x>"])))
    IO.print(Bool.show(T.is_linked(reply(), ["<A@X>"])))
    IO.print(Bool.show(T.is_linked(reply(), ["<a@x.evil>", "a@x"])))
    IO.print(Bool.show(T.is_linked(node("INBOX", 4, early(), "Subject: Re: x\r\n"), [""])))
    IO.print("next")
    IO.print(ids(T.next_ids([reply()], [])))
    IO.print(ids(T.next_ids([reply(), reply()], ["<b@x>"])))
    IO.print(ids(T.next_ids([node("INBOX", 5, early(), "Subject: none\r\n")], [])))
    IO.print(show_next(T.next_ids([long_reply(20000n)], ["<r19999@x>"])))
    IO.print(order([node("INBOX", 1, early(), "Message-ID: <a@x>\r\n"), long_reply(20000n)]))
    IO.print("lengths" ++ id_lengths(T.next_ids([node("INBOX", 7, early(),
      "Message-ID: <café@x>\r\nIn-Reply-To: <" ++ String.repeat("a", 997n) ++ "@x>\r\n" ++
      "References: <" ++ String.repeat("b", 994n) ++ "@x>\r\n")], [])))
    IO.print("order")
    IO.print(order([
      node("INBOX", 2, latest(), "Message-ID: <c@x>\r\nIn-Reply-To: <b@x>\r\n"),
      node("INBOX", 1, early(), "Message-ID: <a@x>\r\n"),
      node("Sent", 1, later(),
        "Message-ID: <b@x>\r\nIn-Reply-To: <a@x>\r\nReferences: <a@x>\r\n")
    ]))
    IO.print(order([
      node("INBOX", 9, "01-Oct-2026 10:00:00 +0200", "Message-ID: <early@x>\r\n"),
      node("INBOX", 8, early(), "Message-ID: <tie2@x>\r\n"),
      node("INBOX", 2, early(), "Message-ID: <tie1@x>\r\n")
    ]))
    IO.print("parents")
    IO.print(order([
      node("INBOX", 1, early(), "Message-ID: <a@x>\r\n"),
      node("INBOX", 2, later(),
        "Message-ID: <b@x>\r\nIn-Reply-To: <gone@x>\r\nReferences: <a@x> <gone@x>\r\n"),
      node("INBOX", 3, latest(), "Message-ID: <c@x>\r\nReferences: <missing@x>\r\n")
    ]))
    IO.print(order([
      node("INBOX", 1, early(), "Message-ID: <a@x>\r\n"),
      node("INBOX", 2, later(), "Message-ID: <b@x>\r\nReferences: <a@x>\r\n"),
      node("INBOX", 3, latest(),
        "Message-ID: <c@x>\r\nIn-Reply-To: <a@x>\r\nReferences: <a@x> <b@x>\r\n")
    ]))
    IO.print(order([node("INBOX", 1, early(), "Message-ID: <a@x>\r\nIn-Reply-To: <a@x>\r\n")]))
    IO.print("cycles")
    IO.print(order([
      node("INBOX", 1, early(), "Message-ID: <a@x>\r\nIn-Reply-To: <b@x>\r\n"),
      node("INBOX", 2, later(), "Message-ID: <b@x>\r\nIn-Reply-To: <a@x>\r\n")
    ]))
    IO.print(order([
      node("INBOX", 1, early(), "Message-ID: <a@x>\r\nIn-Reply-To: <c@x>\r\n"),
      node("INBOX", 2, later(), "Message-ID: <b@x>\r\nIn-Reply-To: <a@x>\r\n"),
      node("INBOX", 3, latest(), "Message-ID: <c@x>\r\nIn-Reply-To: <b@x>\r\n")
    ]))
    IO.print("shared IDs")
    IO.print(order([
      node("INBOX", 1, early(), "Message-ID: <x@a>\r\nIn-Reply-To: <y@a>\r\n"),
      node("INBOX", 3, later(), "Message-ID: <x@a>\r\n"),
      node("INBOX", 2, latest(), "Message-ID: <y@a>\r\nIn-Reply-To: <x@a>\r\n")
    ]))
    IO.print(order([
      node("INBOX", 1, early(), "Subject: no ID\r\n"),
      node("INBOX", 2, later(), "Subject: no ID either\r\nIn-Reply-To: <a@x>\r\n"),
      node("INBOX", 3, latest(), "Message-ID: <a@x>\r\n")
    ]))
    IO.print(order([]))

#|ids
#|[<a@x>,<b@y>]
#|[]
#|[]
#|[<b@y>]
#|keys
#|HEADER "Message-ID" "<a@x>" HEADER "References" "<a@x>" HEADER "In-Reply-To" "<a@x>" HEADER "Message-ID" "<b@y>" HEADER "References" "<b@y>" HEADER "In-Reply-To" "<b@y>"
#|linked
#|True
#|True
#|True
#|False
#|False
#|False
#|next
#|[<c@x>,<b@x>,<a@x>]
#|[<c@x>,<a@x>]
#|[]
#|50 [<z@x>,<a@x>,<r20000@x>,<r19998@x>]
#|INBOX/1<- INBOX/6<-<a@x>
#|lengths 998
#|order
#|INBOX/1<- Sent/1<-<a@x> INBOX/2<-<b@x>
#|INBOX/9<- INBOX/2<- INBOX/8<-
#|parents
#|INBOX/1<- INBOX/2<-<a@x> INBOX/3<-
#|INBOX/1<- INBOX/2<-<a@x> INBOX/3<-<a@x>
#|INBOX/1<-
#|cycles
#|INBOX/1<-<b@x> INBOX/2<-
#|INBOX/1<-<c@x> INBOX/2<-<a@x> INBOX/3<-
#|shared IDs
#|INBOX/1<- INBOX/3<- INBOX/2<-<x@a>
#|INBOX/1<- INBOX/2<-<a@x> INBOX/3<-
#|
