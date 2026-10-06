# Threads: which fetched messages belong to one conversation, and in what
# order, from their Message-ID, In-Reply-To and References alone. Nothing is
# grouped by subject, so no message joins a thread by a guess.

import Base
import ./codec.bend as C
import ./imap.bend as I
import ./mime.bend as M

# Message IDs
# -----------

# The ID whose text is `rev` (reversed), "<" and ">" put back, before `acc`;
# an empty "<>" is dropped.
def msg_ids.put(rev: String, acc: List<&2, String>) -> List<&2, String>:
  match rev:
    case SNil{}:
      acc
    case SCon{c, t}:
      ("<" ++ String.reverse(SCon{c, t}) ++ ">") <> acc

# Walks a header value: `open` says an ID has started, `rev` holds its text
# so far (reversed) and `acc` the IDs found (reversed). A "<" starts a new ID
# and drops an unterminated one.
def msg_ids.go(
  s: String, open: Bool, rev: String, acc: List<&2, String>
) -> List<&2, String>:
  match s open:
    case SNil{} _:
      List.reverse(&2, String, acc)
    case SCon{'<', t} _:
      msg_ids.go(t, True{}, "", acc)
    case SCon{'>', t} True{}:
      msg_ids.go(t, False{}, "", msg_ids.put(rev, acc))
    case SCon{c, t} True{}:
      msg_ids.go(t, True{}, SCon{c, rev}, acc)
    case SCon{c, t} False{}:
      msg_ids.go(t, False{}, rev, acc)

# The "<...>" message IDs of a header value, in order. Text outside the
# angle brackets, such as comments, is skipped.
def msg_ids(v: String) -> List<&2, String>:
  msg_ids.go(v, False{}, "", [])

# Whether `id` is one of `ids`, compared exactly.
def is_in(id: String, ids: List<&2, String>) -> Bool:
  List.contains(~String, ~String.eq, ids, id)

# Messages
# --------

# A fetched message as threads see it: its folder and that folder's
# UIDVALIDITY, the message, its INTERNALDATE in seconds, its Message-ID (""
# when it has none), and the IDs its In-Reply-To and References name.
type Node is Data:
  Node{
    folder: String,
    uidv: Maybe<&2, U32>,
    msg: I.Msg,
    time: U32,
    id: String,
    replies_to: List<&2, String>,
    refs: List<&2, String>
  }

def first_id(ids: List<&2, String>) -> String:
  match ids:
    case Nil{}:
      ""
    case id <> t:
      id

def node(folder: String, uidv: Maybe<&2, U32>, +m: I.Msg) -> Node:
  I.Msg{uid, flags, date, size, headers, body, _} = m
  +hs = M.headers(headers)
  Node{
    folder,
    uidv,
    m,
    I.internal_seconds(date),
    first_id(msg_ids(M.header(hs, "message-id"))),
    msg_ids(M.header(hs, "in-reply-to")),
    msg_ids(M.header(hs, "references"))
  }

def node_id(n: Node) -> String:
  Node{folder, uidv, msg, time, id, replies_to, refs} = n
  id

def node_folder(n: Node) -> String:
  Node{folder, uidv, msg, time, id, replies_to, refs} = n
  folder

def node_uid(n: Node) -> U32:
  Node{folder, uidv, msg, time, id, replies_to, refs} = n
  I.Msg{uid, flags, date, size, headers, body, _} = msg
  uid

def node_time(n: Node) -> U32:
  Node{folder, uidv, msg, time, id, replies_to, refs} = n
  time

# The most IDs a round searches for. Each costs three searches per folder.
def max_ids() -> Nat:
  50n

# A message's References from the last, at most max_ids() of them: no round
# searches for more, the nearest are the likely parents, and a long header
# costs no more than that.
def last_refs(refs: List<&2, String>) -> List<&2, String>:
  List.take(&2, String, List.reverse(&2, String, refs), max_ids())

# The IDs a message could have as its parent, in the order threads try
# them: In-Reply-To first, then References from the last.
def parent_ids(n: Node) -> List<&2, String>:
  Node{folder, uidv, msg, time, id, replies_to, refs} = n
  List.append(&2, String, List.take(&2, String, replies_to, 1n), last_refs(refs))

def own_id(id: String) -> List<&2, String>:
  match id:
    case SNil{}:
      []
    case SCon{h, t}:
      [SCon{h, t}]

# Every ID a message names, nearest first: its own, those its In-Reply-To
# names, then its References from the last.
def named_ids(n: Node) -> List<&2, String>:
  Node{folder, uidv, msg, time, id, replies_to, refs} = n
  List.concat(&2, String, [own_id(id), replies_to, last_refs(refs)])

# Searching
# ---------

# A thread is searched for by ID: messages with the ID as their Message-ID,
# and messages whose References or In-Reply-To name it. The server matches
# substrings, so is_linked confirms each message found.

def search_keys(ids: List<&2, String>) -> List<&2, I.Key>:
  match ids:
    case Nil{}:
      []
    case +id <> t:
      I.KHeader{"Message-ID", id} <> I.KHeader{"References", id}
        <> I.KHeader{"In-Reply-To", id} <> search_keys(t)

def any_in(xs: List<&2, String>, +ids: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      is_in(x, ids) || any_in(t, ids)

# Whether a message's own ID, In-Reply-To or References names one of `ids`
# exactly.
def is_linked(n: Node, ids: List<&2, String>) -> Bool:
  any_in(named_ids(n), ids)

# The messages that name one of `ids` exactly.
def linked(ns: List<&2, Node>, +ids: List<&2, String>) -> List<&2, Node>:
  match ns:
    case Nil{}:
      []
    case +n <> t:
      List.filter.put(Node, n, linked(t, ids), is_linked(n, ids))

def named_by(ns: List<&2, Node>) -> List<&2, String>:
  match ns:
    case Nil{}:
      []
    case n <> t:
      List.append(&2, String, named_ids(n), named_by(t))

# Whether an ID can be searched for: plain ASCII, so the search needs no
# charset, and no longer than a header line may be (998 bytes, RFC 5322).
# A server could refuse any other, and with it the whole read.
def is_searchable(+id: String) -> Bool:
  C.is_plain(id) && Nat.is_le(String.length(id), 998n)

# The first `room` IDs of `ids` that can be searched for and are not in
# `seen`, each once. It stops once `room` is spent, and `seen` grows only by
# the IDs taken, so a long References costs no more than it needs.
def next_ids.go(
  ids: List<&2, String>, +seen: List<&2, String>, +room: Nat
) -> List<&2, String>:
  match ids room:
    case Nil{} _:
      []
    case _ 0n:
      []
    case +id <> t 1n+r:
      +new = is_searchable(id) && Bool.not(is_in(id, seen))
      List.filter.put(String, id,
        next_ids.go(t, Bool.pick(List<&2, String>, new, id <> seen, seen),
          Bool.pick(Nat, new, r, 1n+r)),
        new)

# The IDs to search for next: those the messages name and no round has
# searched for, each once, nearest first, at most max_ids().
def next_ids(ns: List<&2, Node>, searched: List<&2, String>) -> List<&2, String>:
  next_ids.go(named_by(ns), searched, max_ids())

# Order
# -----

# A message placed in its thread, with the Message-ID of its parent there
# ("" for none).
type Placed is Data:
  Placed{node: Node, parent: String}

# Whether `a` comes no later than `b`: by date, then by UID.
def no_later(+a: Node, +b: Node) -> Bool:
  +ta = node_time(a)
  +tb = node_time(b)
  U32.is_lt(ta, tb) || (U32.is_eq(ta, tb) && U32.is_le(node_uid(a), node_uid(b)))

# The parent of the message `id` among the messages placed so far; "" when
# it is not placed or has none. Threads are short, so the search walks them
# all.
def placed_parent(ps: List<&2, Placed>, +id: String) -> String:
  match ps:
    case Nil{}:
      ""
    case Placed{n, parent} <> t:
      Bool.pick(String, String.eq(node_id(n), id), parent, placed_parent(t, id))

# Whether following parents from `at` leads to `target`, through the
# messages placed so far; `hit` says whether `at` is `target`. An empty `at`
# names no message, so a walk ends there even when `target` has no ID.
# `fuel` bounds the walk.
def reaches(
  fuel: Nat, at: String, hit: Bool, +ps: List<&2, Placed>, +target: String
) -> Bool:
  match fuel at hit:
    case _ SNil{} _:
      False{}
    case _ SCon{h, t} True{}:
      True{}
    case 0n SCon{h, t} False{}:
      False{}
    case 1n+f SCon{h, t} False{}:
      +next = placed_parent(ps, SCon{h, t})
      reaches(f, next, String.eq(next, target), ps, target)

# Walks `cands` until one is a message of the thread (`present`) other than
# `self`: `hit` says whether the candidate `c` before them was.
def parent_in.go(
  cands: List<&2, String>, hit: Bool, c: String, +present: List<&2, String>, +self: String
) -> String:
  match cands hit:
    case _ True{}:
      c
    case Nil{} False{}:
      ""
    case +d <> t False{}:
      parent_in.go(t, is_in(d, present) && Bool.not(String.eq(d, self)), d, present, self)

# The first of `cands` that is a message of the thread (`present`) other
# than `self`; "" for none. The walk stops at the first hit.
def parent_in(
  cands: List<&2, String>, present: List<&2, String>, self: String
) -> String:
  parent_in.go(cands, False{}, "", present, self)

# Whether `id` is the ID of two or more messages of the thread (`ids`),
# given whether one came before (`once`).
def is_shared(ids: List<&2, String>, +id: String, +once: Bool) -> Bool:
  match ids:
    case Nil{}:
      False{}
    case x <> t:
      +hit = String.eq(x, id)
      (hit && once) || is_shared(t, id, hit || once)

# Places `n` after the messages `ps` placed so far. It takes its parent
# unless following that parent's own parents leads back to it, or another
# message has its ID, which leaves no way to tell which of them a parent is.
def thread_order.step(
  +n: Node, +present: List<&2, String>, fuel: Nat, +ps: List<&2, Placed>
) -> List<&2, Placed>:
  +id = node_id(n)
  +p = parent_in(parent_ids(n), present, id)
  cut = reaches(fuel, p, String.eq(p, id), ps, id) || is_shared(present, id, False{})
  Placed{n, Bool.pick(String, cut, "", p)} <> ps

# Places the messages oldest first; `ps` holds those placed (reversed).
def thread_order.go(
  ns: List<&2, Node>, +present: List<&2, String>, +fuel: Nat, ps: List<&2, Placed>
) -> List<&2, Placed>:
  match ns:
    case Nil{}:
      List.reverse(&2, Placed, ps)
    case n <> t:
      thread_order.go(t, present, fuel, thread_order.step(n, present, fuel, ps))

# The Message-IDs of the messages, leaving out those that have none.
def ids_of(ns: List<&2, Node>) -> List<&2, String>:
  match ns:
    case Nil{}:
      []
    case n <> t:
      List.append(&2, String, own_id(node_id(n)), ids_of(t))

# The thread in order, oldest first (by INTERNALDATE, then UID). Each
# message's parent is the message its In-Reply-To names, else the last
# message its References names, if the thread has it. Broken headers can
# form a cycle of parents: it is cut at the first repeat, so the newest
# message of the cycle loses its parent. A message whose Message-ID another
# message also has gets no parent, so shared IDs form no cycle either.
def thread_order(ns: List<&2, Node>) -> List<&2, Placed>:
  +sorted = List.sort(~Node, ~(a => b => no_later(a, b)), ns)
  fuel = (List.length(&2, Node, sorted) + 1n : Nat)
  thread_order.go(sorted, ids_of(sorted), fuel, [])
