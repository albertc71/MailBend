# Retained order implementation from 5ff799d094fd08078391c33218dc2a9ef598494b.
# Only Node/Placed and unchanged node accessors are qualified through T.

import Base
import ../../src/codec.bend as C
import ../../src/thread.bend as T

# Whether `a` comes no later than `b`: by date, then by UID.
def no_later(+a: T.Node, +b: T.Node) -> Bool:
  +ta = T.node_time(a)
  +tb = T.node_time(b)
  U32.is_lt(ta, tb) || (U32.is_eq(ta, tb) && U32.is_le(T.node_uid(a), T.node_uid(b)))

# Walks `ps` until a message placed is `id`: `hit` says whether the one
# before them was, and `parent` is its parent.
def placed_parent.go(ps: List<&2, T.Placed>, hit: Bool, parent: String, +id: String) -> String:
  match ps hit:
    case _ True{}:
      parent
    case Nil{} False{}:
      ""
    case T.Placed{n, p} <> t False{}:
      placed_parent.go(t, String.eq(T.node_id(n), id), p, id)

# The parent of the message `id` among the messages placed so far; "" when
# it is not placed or has none. The walk stops at the first hit.
def placed_parent(ps: List<&2, T.Placed>, id: String) -> String:
  placed_parent.go(ps, False{}, "", id)

# Whether following parents from `at` leads to `target`, through the
# messages placed so far; `hit` says whether `at` is `target`. An empty `at`
# names no message, so a walk ends there even when `target` has no ID.
# `fuel` bounds the walk.
def reaches(
  fuel: Nat, at: String, hit: Bool, +ps: List<&2, T.Placed>, +target: String
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
      parent_in.go(t, C.is_in(d, present) && Bool.not(String.eq(d, self)), d, present, self)

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
  +n: T.Node, +present: List<&2, String>, fuel: Nat, +ps: List<&2, T.Placed>
) -> List<&2, T.Placed>:
  +id = T.node_id(n)
  +p = parent_in(T.parent_ids(n), present, id)
  cut = reaches(fuel, p, String.eq(p, id), ps, id) || is_shared(present, id, False{})
  T.Placed{n, Bool.pick(String, cut, "", p)} <> ps

# Places the messages oldest first; `ps` holds those placed (reversed).
def thread_order.go(
  ns: List<&2, T.Node>, +present: List<&2, String>, +fuel: Nat, ps: List<&2, T.Placed>
) -> List<&2, T.Placed>:
  match ns:
    case Nil{}:
      List.reverse(&2, T.Placed, ps)
    case n <> t:
      thread_order.go(t, present, fuel, thread_order.step(n, present, fuel, ps))

# The Message-IDs of the messages, leaving out those that have none.
def ids_of(ns: List<&2, T.Node>) -> List<&2, String>:
  match ns:
    case Nil{}:
      []
    case n <> t:
      List.append(&2, String, T.own_id(T.node_id(n)), ids_of(t))

# The thread in order, oldest first (by INTERNALDATE, then UID). Each
# message's parent is the message its In-Reply-To names, else the last
# message its References names, if the thread has it. Broken headers can
# form a cycle of parents: it is cut at the first repeat, so the newest
# message of the cycle loses its parent. A message whose Message-ID another
# message also has gets no parent, so shared IDs form no cycle either.
def thread_order(ns: List<&2, T.Node>) -> List<&2, T.Placed>:
  +sorted = List.sort(~T.Node, ~(a => b => no_later(a, b)), ns)
  fuel = (List.length(&2, T.Node, sorted) + 1n : Nat)
  thread_order.go(sorted, ids_of(sorted), fuel, [])

