# Thread-order characterization through the public entry point.

import Base
import ../../src/imap.bend as I
import ../../src/thread.bend as T
import ./reference.bend as R

def node(
  +uid: U32, time: U32, id: String, reply: List<&2, String>, refs: List<&2, String>
) -> T.Node:
  T.Node{"folder/" ++ U32.show(uid),
    Bool.pick(Maybe<&2, U32>, U32.is_eq(uid, 1), None{}, Some{uid}),
    I.Msg{uid, ["flag/:;]\n" ++ U32.show(uid)], "date/" ++ U32.show(uid), uid,
      "header/" ++ U32.show(uid), "body/:;]\n" ++ U32.show(uid),
      I.VList{[I.VAtom{U32.show(uid)}, I.VStr{"nil]"}, I.VList{[I.VNil{}]}]}},
    time, id, reply, refs}

def frame(+s: String) -> String:
  Nat.show(String.length(s)) ++ ":" ++ s

def strings(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      "]"
    case x <> t:
      frame(x) ++ strings(t)

def uidv(x: Maybe<&2, U32>) -> String:
  match x:
    case None{}:
      "none"
    case Some{v}:
      "some" ++ U32.show(v)

type ThreadIndexValueTask is Data:
  ThreadIndexValueInspect{value: I.Value}
  ThreadIndexValueClose{}

def value_tasks(
  xs: List<&2, I.Value>, acc: List<&2, ThreadIndexValueTask>
) -> List<&2, ThreadIndexValueTask>:
  match xs:
    case Nil{}:
      acc
    case x <> t:
      ThreadIndexValueInspect{x} <> value_tasks(t, acc)

def structure(fuel: Nat, todo: List<&2, ThreadIndexValueTask>) -> String:
  match fuel todo:
    case _ Nil{}:
      ""
    case 0n _:
      "EXHAUSTED"
    case 1n+f ThreadIndexValueClose{} <> t:
      "]" ++ structure(f, t)
    case 1n+f ThreadIndexValueInspect{I.VNil{}} <> t:
      "N" ++ structure(f, t)
    case 1n+f ThreadIndexValueInspect{I.VAtom{s}} <> t:
      "A" ++ frame(s) ++ structure(f, t)
    case 1n+f ThreadIndexValueInspect{I.VStr{s}} <> t:
      "S" ++ frame(s) ++ structure(f, t)
    case 1n+f ThreadIndexValueInspect{I.VList{xs}} <> t:
      "[" ++ structure(f, value_tasks(xs, ThreadIndexValueClose{} <> t))

def line(p: T.Placed) -> String:
  T.Placed{T.Node{folder, generation, I.Msg{uid, flags, date, size, headers, body, tree},
    time, id, replies, refs}, parent} = p
  String.concat([frame(folder), frame(uidv(generation)), frame(U32.show(uid)),
    strings(flags), frame(date), frame(U32.show(size)), frame(headers), frame(body),
    frame(structure(100n, [ThreadIndexValueInspect{tree}])), frame(U32.show(time)),
    frame(id), strings(replies), strings(refs),
    frame(parent)])

def lines(ps: List<&2, T.Placed>) -> String:
  match ps:
    case Nil{}:
      ""
    case p <> t:
      frame(line(p)) ++ lines(t)

def equivalent(+ns: List<&2, T.Node>) -> Bool:
  +actual = lines(T.thread_order(ns))
  +baseline = lines(R.thread_order(ns))
  String.eq(actual, baseline) && Bool.not(String.contains(actual, "EXHAUSTED")) &&
    Bool.not(String.contains(baseline, "EXHAUSTED"))

def parents(ps: List<&2, T.Placed>) -> String:
  match ps:
    case Nil{}:
      ""
    case T.Placed{n, parent} <> t:
      U32.show(T.node_uid(n)) ++ "<-" ++ parent ++ ";" ++ parents(t)


