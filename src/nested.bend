# Opt-in attached-message views. Legacy MIME readers keep their recovery policy.

import Base
import ./codec.bend as C
import ./json.bend as J
import ./mime.bend as M

type Budget is Data:
  Budget{entities: U32, parse: U32, view: U32}

type Fragment is Data:
  Fragment{plain: String, html: String, atts: List<&2, J.Json>, omissions: List<&2, String>}

type Task is Data:
  Message{raw: String, level: U32, attachment: Maybe<&2, M.Att>}
  Entity{raw: String, context: M.PartContext, level: U32, depth: Nat}
  EndMessage{headers: J.Json, parent: Fragment, alt: Bool, attachment: Maybe<&2, M.Att>}
  EndMultipart{parent: Fragment, alt: Bool}

type Walk is Data:
  Walking{todo: List<&2, Task>, current: Fragment, alt: Bool, budget: Budget}
  Finished{node: J.Json}

def problem(detail: String) -> String:
  "nested message: " ++ detail ++ "; retry without nested_message for legacy base64 retrieval"

def check(ok: Bool, detail: String) -> Result<&2, &2, String, Unit>:
  match ok:
    case True{}:
      Done{Unit{}}
    case False{}:
      Fail{problem(detail)}

def debit.if(ok: Bool, left: U32, n: U32, detail: String) -> Result<&2, &2, String, U32>:
  match ok:
    case True{}:
      Done{(left - n : U32)}
    case False{}:
      Fail{problem(detail)}

def debit(+left: U32, +n: U32, detail: String) -> Result<&2, &2, String, U32>:
  debit.if(U32.is_le(n, left), left, n, detail)

# Count with a decreasing allowance, so hostile lengths cannot wrap U32.
def debit_bytes(raw: String, left: U32) -> Result<&2, &2, String, U32>:
  match raw:
    case SNil{}:
      Done{left}
    case SCon{c, t}:
      do Result<&2, &2, String, U32>:
        next : U32 <- debit(left, 1, "aggregate parse-byte allowance exhausted")
        debit_bytes(t, next)

def parse_bytes(raw: String, b: Budget) -> Result<&2, &2, String, Budget>:
  Budget{n, p, v} = b
  do Result<&2, &2, String, Budget>:
    left : U32 <- debit_bytes(raw, p)
    return Budget{n, left, v}

# Each retained decoded scalar occupies at most four UTF-8 bytes. Reserve
# before charset/header/filename decoding; unused credit is not recycled.
def view_bytes(raw: String, left: U32) -> Result<&2, &2, String, U32>:
  match raw:
    case SNil{}:
      Done{left}
    case SCon{c, t}:
      do Result<&2, &2, String, U32>:
        next : U32 <- debit(left, 4, "UTF-8 view allowance exhausted")
        view_bytes(t, next)

def reserve_view(raw: String, b: Budget) -> Result<&2, &2, String, Budget>:
  Budget{n, p, v} = b
  do Result<&2, &2, String, Budget>:
    left : U32 <- view_bytes(raw, v)
    return Budget{n, p, left}

def entity_budget(b: Budget) -> Result<&2, &2, String, Budget>:
  Budget{n, p, v} = b
  do Result<&2, &2, String, Budget>:
    left : U32 <- debit(n, 1, "128 MIME entity limit exceeded")
    return Budget{left, p, v}

def empty() -> Fragment:
  Fragment{"", "", [], []}

def reason(+why: String, +reasons: List<&2, String>) -> List<&2, String>:
  Bool.pick(List<&2, String>, C.is_in(why, reasons), reasons,
    List.append(&2, String, reasons, [why]))

def reasons(xs: List<&2, String>, acc: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      acc
    case x <> t:
      reasons(t, reason(x, acc))

def omit(f: Fragment, why: String) -> Fragment:
  Fragment{t, h, a, o} = f
  Fragment{t, h, a, reason(why, o)}

def merge(+a: Fragment, b: Fragment, alt: Bool) -> Fragment:
  Fragment{+at, +ah, aa, ao} = a
  Fragment{+bt, +bh, ba, bo} = b
  +lost = Bool.not(alt) &&
    (M.both_filled(at, bt) || M.both_filled(ah, bh) ||
      M.both_filled(at, bh) || M.both_filled(ah, bt))
  +o = reasons(bo, ao)
  Fragment{Bool.pick(String, String.is_empty(at), bt, at),
    Bool.pick(String, String.is_empty(ah), bh, ah), List.append(&2, J.Json, aa, ba),
    Bool.pick(List<&2, String>, lost, reason("additional_readable_part", o), o)}

def strings(xs: List<&2, String>) -> List<&2, J.Json>:
  match xs:
    case Nil{}:
      []
    case s <> t:
      J.str(s) <> strings(t)

def node(hs: J.Json, f: Fragment) -> J.Json:
  Fragment{+t, h, atts, +omissions} = f
  J.obj([J.kv("headers", hs),
    J.kv("text", J.str(Bool.pick(String, String.is_empty(t), h, t))),
    J.kv("attachments", J.arr(atts)),
    J.kv("parse_complete", J.bool(List.is_empty(&2, String, omissions))),
    J.kv("omissions", J.arr(strings(omissions)))])

def att_fields(a: M.Att) -> List<&2, J.Json>:
  M.Att{name, ct, size} = a
  [J.kv("filename", J.str(name)), J.kv("content_type", J.str(ct)),
    J.kv("size", J.num(size))]

def header_fields.after(key: String, raw: String, rest: Sigma<&2, &2, List<&2, J.Json>, _ => Budget>)
  -> Result<&2, &2, String, Sigma<&2, &2, List<&2, J.Json>, _ => Budget>>:
  (fields, left) = rest
  Done{(J.kv(key, J.str(M.header_line(raw))) <> fields, left)}

def header_fields(keys: List<&2, String>, +hs: List<&2, M.Hdr>, b: Budget)
  -> Result<&2, &2, String, Sigma<&2, &2, List<&2, J.Json>, _ => Budget>>:
  match keys:
    case Nil{}:
      Done{([], b)}
    case +key <> t:
      +raw = M.header(hs, Bool.pick(String, String.eq(key, "message_id"), "message-id", key))
      do Result<&2, &2, String, Sigma<&2, &2, List<&2, J.Json>, _ => Budget>>:
        next : Budget <- reserve_view(raw, b)
        rest : Sigma<&2, &2, List<&2, J.Json>, _ => Budget> <- header_fields(t, hs, next)
        header_fields.after(key, raw, rest)

def compact.go(raw: String, +out: String) -> String:
  match raw:
    case SNil{}:
      String.reverse(out)
    case SCon{+c, t}:
      compact.go(t, Bool.pick(String, M.char_in(c, " \t\r\n"), out, SCon{c, out}))

def same.go(a: String, b: String, ok: Bool) -> Bool:
  match a b ok:
    case _ _ False{}:
      False{}
    case SNil{} SNil{} True{}:
      True{}
    case SCon{x, s} SCon{y, t} True{}:
      same.go(s, t, Char.is_eq(x, y))
    case _ _ True{}:
      False{}

def same(a: String, b: String) -> Bool:
  same.go(a, b, True{})

def qp_valid.go(raw: String, ok: Bool) -> Bool:
  match raw ok:
    case _ False{}:
      False{}
    case SNil{} True{}:
      True{}
    case SCon{'=', SCon{'\r', SCon{'\n', t}}} True{}:
      qp_valid.go(t, True{})
    case SCon{'=', SCon{'\n', t}} True{}:
      qp_valid.go(t, True{})
    case SCon{'=', SCon{a, SCon{b, t}}} True{}:
      qp_valid.go(t, M.char_in(a, "0123456789ABCDEFabcdef") &&
        M.char_in(b, "0123456789ABCDEFabcdef"))
    case SCon{'=', t} True{}:
      False{}
    case SCon{c, t} True{}:
      qp_valid.go(t, True{})

def qp_valid(raw: String) -> Bool:
  qp_valid.go(raw, True{})

def base64_groups(raw: String, +count: U32) -> Bool:
  match raw:
    case SNil{}:
      U32.is_eq(count, 0)
    case SCon{+c, t}:
      base64_groups(t, Bool.pick(U32, M.char_in(c, " \t\r\n"), count,
        ((count + 1 : U32) .&. 3 : U32)))

def decode.base64.after(+raw: String, final: Budget)
  -> Result<&2, &2, String, Sigma<&2, &2, String, _ => Budget>>:
  +decoded = C.b64_decode(raw)
  do Result<&2, &2, String, Sigma<&2, &2, String, _ => Budget>>:
    check(same(C.b64_encode(decoded, False{}), compact.go(raw, "")), "malformed inner base64")
    return (decoded, final)

def decode(encoding: String, +raw: String, b: Budget)
  -> Result<&2, &2, String, Sigma<&2, &2, String, _ => Budget>>:
  match encoding:
    case "base64":
      do Result<&2, &2, String, Sigma<&2, &2, String, _ => Budget>>:
        check(base64_groups(raw, 0), "malformed inner base64")
        copy : Budget <- parse_bytes(raw, b)
        compact : Budget <- parse_bytes(raw, copy)
        final : Budget <- parse_bytes(raw, compact)
        decode.base64.after(raw, final)
    case "quoted-printable":
      do Result<&2, &2, String, Sigma<&2, &2, String, _ => Budget>>:
        copy : Budget <- parse_bytes(raw, b)
        check(qp_valid(raw), "malformed inner quoted-printable")
        return (C.qp_decode(raw, False{}), copy)
    case _:
      do Result<&2, &2, String, Sigma<&2, &2, String, _ => Budget>>:
        check(C.is_in(encoding, ["", "7bit", "8bit", "binary"]),
          "unsupported inner Content-Transfer-Encoding")
        return (raw, b)

def trim_boundary(raw: String) -> String:
  match raw:
    case SCon{' ', t}:
      trim_boundary(t)
    case SCon{'\t', t}:
      trim_boundary(t)
    case _:
      String.reverse(raw)

def delimiter(raw: String) -> String:
  trim_boundary(String.reverse(M.strip_cr(raw)))

# Reserve each immediate child before the legacy cutter can allocate its list.
# The caller admits the whole scan and copied body before this line-by-line pass.
type Framing is Data:
  Scanning{line: String, budget: Budget, opened: Bool}
  Closed{budget: Budget}

def framing.next(close: Bool, open: Bool, rest: String, b: Budget, opened: Bool)
  -> Result<&2, &2, String, Framing>:
  match close open:
    case True{} _:
      do Result<&2, &2, String, Framing>:
        check(opened, "multipart has no opening delimiter")
        return Closed{b}
    case False{} True{}:
      do Result<&2, &2, String, Framing>:
        next : Budget <- entity_budget(b)
        return Scanning{rest, next, True{}}
    case False{} False{}:
      Done{Scanning{rest, b, opened}}

def framing.line(text: String, +bound: String, b: Budget, opened: Bool)
  -> Result<&2, &2, String, Framing>:
  +mark = delimiter(text)
  framing.next(String.eq(mark, "--" ++ bound ++ "--"),
    String.eq(mark, "--" ++ bound), "", b, opened)

def framing.finish(state: Result<&2, &2, String, Framing>)
  -> Result<&2, &2, String, Budget>:
  match state:
    case Fail{why}:
      Fail{why}
    case Done{Closed{b}}:
      Done{b}
    case Done{Scanning{line, b, opened}}:
      Fail{problem("malformed multipart framing")}

# Only the raw pattern tail drives recursion. State transitions never
# stand in for structural descent, and no whole-body line list is built.
def framing.go(raw: String, +bound: String, state: Result<&2, &2, String, Framing>)
  -> Result<&2, &2, String, Budget>:
  match raw state:
    case _ Fail{why}:
      Fail{why}
    case _ Done{Closed{b}}:
      Done{b}
    case SNil{} Done{Scanning{line, b, opened}}:
      framing.finish(framing.line(String.reverse(line), bound, b, opened))
    case SCon{'\n', t} Done{Scanning{line, b, opened}}:
      framing.go(t, bound, framing.line(String.reverse(line), bound, b, opened))
    case SCon{c, t} Done{Scanning{line, b, opened}}:
      framing.go(t, bound, Done{Scanning{SCon{c, line}, b, opened}})

def framing(raw: String, bound: String, b: Budget) -> Result<&2, &2, String, Budget>:
  framing.go(raw, bound, Done{Scanning{"", b, False{}}})

type CutStep is Data:
  CutStep{done: Bool, line: String, state: M.Cut}

def cut.line(+text: String, +bound: String, state: M.Cut) -> CutStep:
  +mark = delimiter(text)
  +close = String.eq(mark, "--" ++ bound ++ "--")
  CutStep{close, "", M.subparts.line.if(text, state, close,
    String.eq(mark, "--" ++ bound))}

def cut.finish(step: CutStep) -> List<&2, String>:
  CutStep{done, line, state} = step
  M.subparts.fin(state)

def cut.go(raw: String, +bound: String, step: CutStep) -> List<&2, String>:
  match raw step:
    case _ CutStep{True{}, line, state}:
      M.subparts.fin(state)
    case SNil{} CutStep{False{}, SNil{}, state}:
      M.subparts.fin(state)
    case SNil{} CutStep{False{}, line, state}:
      cut.finish(cut.line(String.reverse(line), bound, state))
    case SCon{'\n', t} CutStep{False{}, line, state}:
      cut.go(t, bound, cut.line(String.reverse(line), bound, state))
    case SCon{c, t} CutStep{False{}, line, state}:
      cut.go(t, bound, CutStep{False{}, SCon{c, line}, state})

def cut(raw: String, bound: String) -> List<&2, String>:
  cut.go(raw, bound, CutStep{False{}, "", M.Cut{[], [], False{}, False{}}})

def children(parts: List<&2, String>, +context: M.PartContext, +level: U32,
  +depth: Nat, tail: List<&2, Task>) -> List<&2, Task>:
  match parts:
    case Nil{}:
      tail
    case raw <> rest:
      Entity{raw, context, level, depth} <> children(rest, context, level, depth, tail)

def multipart.after(hs: List<&2, M.Hdr>, body: String, bound: String, level: U32,
  depth: Nat, todo: List<&2, Task>, current: Fragment, alt: Bool, reserved: Budget)
  -> Result<&2, &2, String, Walk>:
  +context = M.part_context(M.main_value(M.header(hs, "content-type")))
  Done{Walking{children(cut(body, bound), context, level, depth,
    EndMultipart{current, alt} <> todo), empty(),
    M.part_context.alternative(context), reserved}}

def multipart.depth(depth: Nat, hs: List<&2, M.Hdr>, +body: String, +bound: String,
  level: U32, todo: List<&2, Task>, current: Fragment, alt: Bool, b: Budget)
  -> Result<&2, &2, String, Walk>:
  match depth:
    case 0n:
      Done{Walking{todo, omit(current, "multipart_depth_limit"), alt, b}}
    case 1n+d:
      do Result<&2, &2, String, Walk>:
        scan : Budget <- parse_bytes(body, b)
        copied : Budget <- parse_bytes(body, scan)
        reserved : Budget <- framing(body, bound, copied)
        multipart.after(hs, body, bound, level, d, todo, current, alt, reserved)

def multipart(depth: Nat, +hs: List<&2, M.Hdr>, body: String, level: U32,
  todo: List<&2, Task>, current: Fragment, alt: Bool, b: Budget)
  -> Result<&2, &2, String, Walk>:
  +bound = M.boundary(hs)
  do Result<&2, &2, String, Walk>:
    check(Bool.not(String.is_empty(bound)), "multipart boundary is missing")
    multipart.depth(depth, hs, body, bound, level, todo, current, alt, b)

def is_message(+typ: String) -> Bool:
  String.eq(typ, "message/rfc822") || String.eq(typ, "message/global")

def file.message(open: Bool, a: M.Att, +bytes: String, level: U32,
  todo: List<&2, Task>, current: Fragment, +alt: Bool, b: Budget)
  -> Result<&2, &2, String, Walk>:
  match open:
    case True{}:
      do Result<&2, &2, String, Walk>:
        next : Budget <- entity_budget(b)
        admitted : Budget <- parse_bytes(bytes, next)
        return Walking{Message{bytes, (level + 1 : U32), Some{a}} <> todo,
          current, alt, admitted}
    case False{}:
      Done{Walking{todo, merge(current,
        Fragment{"", "", [J.obj(att_fields(a))], ["depth_limit"]}, alt), alt, b}}

def file(message: Bool, a: M.Att, bytes: String, +level: U32,
  todo: List<&2, Task>, current: Fragment, +alt: Bool, b: Budget)
  -> Result<&2, &2, String, Walk>:
  match message:
    case True{}:
      file.message(U32.is_lt(level, 3), a, bytes, level, todo, current, alt, b)
    case False{}:
      Done{Walking{todo, merge(current,
        Fragment{"", "", [J.obj(att_fields(a))], []}, alt), alt, b}}

def leaf.text(plain: Bool, text: String) -> Fragment:
  match plain:
    case True{}:
      Fragment{text, "", [], []}
    case False{}:
      Fragment{"", M.html_text(text), [], []}

def leaf.if(attached: Bool, ct: String, +typ: String, name: String,
  +bytes: String, level: U32, todo: List<&2, Task>, current: Fragment, +alt: Bool, b: Budget)
  -> Result<&2, &2, String, Walk>:
  match attached:
    case True{}:
      file(is_message(typ), M.Att{name, typ, C.byte_len(bytes)}, bytes, level,
        todo, current, alt, b)
    case False{}:
      do Result<&2, &2, String, Walk>:
        next : Budget <- reserve_view(bytes, b)
        return Walking{todo, merge(current,
          leaf.text(String.eq(typ, "text/plain"), M.leaf.text(ct, bytes)), alt), alt, next}

def leaf(k: M.PartKind, bytes: String, level: U32, todo: List<&2, Task>,
  current: Fragment, alt: Bool, b: Budget) -> Result<&2, &2, String, Walk>:
  M.PartKind{ct, typ, name, attached} = k
  leaf.if(attached, ct, typ, name, bytes, level, todo, current, alt, b)

def entity.multi.after(depth: Nat, hs: List<&2, M.Hdr>, decoded: Sigma<&2, &2, String, _ => Budget>,
  level: U32, todo: List<&2, Task>, current: Fragment, alt: Bool)
  -> Result<&2, &2, String, Walk>:
  (bytes, next) = decoded
  multipart(depth, hs, bytes, level, todo, current, alt, next)

def entity.multi(depth: Nat, +hs: List<&2, M.Hdr>, +body: String, level: U32,
  todo: List<&2, Task>, current: Fragment, alt: Bool, b: Budget)
  -> Result<&2, &2, String, Walk>:
  match depth:
    case 0n:
      multipart(0n, hs, "", level, todo, current, alt, b)
    case _:
      do Result<&2, &2, String, Walk>:
        admitted : Budget <- parse_bytes(body, b)
        decoded : Sigma<&2, &2, String, _ => Budget> <- decode(
          String.to_lower(String.trim(M.header(hs, "content-transfer-encoding"))), body, admitted)
        entity.multi.after(depth, hs, decoded, level, todo, current, alt)

def entity.leaf.after(+hs: List<&2, M.Hdr>, decoded: Sigma<&2, &2, String, _ => Budget>, level: U32,
  todo: List<&2, Task>, current: Fragment, alt: Bool) -> Result<&2, &2, String, Walk>:
  (bytes, next) = decoded
  +ct = M.header(hs, "content-type")
  do Result<&2, &2, String, Walk>:
    names : Budget <- reserve_view(ct, next)
    disposition : Budget <- reserve_view(M.header(hs, "content-disposition"), names)
    types : Budget <- reserve_view(ct, disposition)
    leaf(M.part_kind(hs), bytes, level, todo, current, alt, types)

def entity.if(multi: Bool, +hs: List<&2, M.Hdr>, +body: String, level: U32, depth: Nat,
  todo: List<&2, Task>, current: Fragment, alt: Bool, b: Budget)
  -> Result<&2, &2, String, Walk>:
  match multi:
    case True{}:
      entity.multi(depth, hs, body, level, todo, current, alt, b)
    case False{}:
      do Result<&2, &2, String, Walk>:
        admitted : Budget <- parse_bytes(body, b)
        decoded : Sigma<&2, &2, String, _ => Budget> <- decode(
          String.to_lower(String.trim(M.header(hs, "content-transfer-encoding"))), body, admitted)
        entity.leaf.after(hs, decoded, level, todo, current, alt)

def entity(+hs: List<&2, M.Hdr>, body: String, level: U32, depth: Nat,
  todo: List<&2, Task>, current: Fragment, alt: Bool, b: Budget)
  -> Result<&2, &2, String, Walk>:
  entity.if(String.starts_with(M.main_value(M.header(hs, "content-type")), "multipart/"),
    hs, body, level, depth, todo, current, alt, b)

def finish_message.attached(+current: Fragment, headers: J.Json, parent: Fragment,
  +alt: Bool, a: M.Att, todo: List<&2, Task>, b: Budget) -> Walk:
  Fragment{t, h, atts, omissions} = current
  attached = J.obj(List.append(&2, J.Json, att_fields(a),
    [J.kv("message", node(headers, current))]))
  Walking{todo, merge(parent, Fragment{"", "", [attached], omissions}, alt), alt, b}

def finish_message(headers: J.Json, current: Fragment, parent: Fragment,
  alt: Bool, attachment: Maybe<&2, M.Att>, todo: List<&2, Task>, b: Budget) -> Walk:
  match attachment:
    case None{}:
      Finished{node(headers, current)}
    case Some{a}:
      finish_message.attached(current, headers, parent, alt, a, todo, b)

def message.after_headers(hs: List<&2, M.Hdr>, body: String, level: U32,
  attachment: Maybe<&2, M.Att>, todo: List<&2, Task>, current: Fragment, alt: Bool,
  displayed: Sigma<&2, &2, List<&2, J.Json>, _ => Budget>) -> Result<&2, &2, String, Walk>:
  (fields, next) = displayed
  entity(hs, body, level, Nat.sub(M.multipart_limit(), 1n),
    EndMessage{J.obj(fields), current, alt, attachment} <> todo, empty(), False{}, next)

def step.message(split: M.Split, level: U32, attachment: Maybe<&2, M.Att>,
  todo: List<&2, Task>, current: Fragment, alt: Bool, b: Budget)
  -> Result<&2, &2, String, Walk>:
  M.Split{head, body} = split
  +hs = M.headers(head)
  do Result<&2, &2, String, Walk>:
    displayed : Sigma<&2, &2, List<&2, J.Json>, _ => Budget> <-
      header_fields(["from", "to", "subject", "date", "message_id"], hs, b)
    message.after_headers(hs, body, level, attachment, todo, current, alt, displayed)

def step.entity(split: M.Split, context: M.PartContext, level: U32, depth: Nat,
  todo: List<&2, Task>, current: Fragment, alt: Bool, b: Budget)
  -> Result<&2, &2, String, Walk>:
  M.Split{head, body} = split
  entity(M.part_context.headers(context, M.headers(head)), body,
    level, depth, todo, current, alt, b)

def step(task: Task, todo: List<&2, Task>, current: Fragment, alt: Bool, b: Budget)
  -> Result<&2, &2, String, Walk>:
  match task:
    case Message{raw, level, attachment}:
      step.message(M.split(raw), level, attachment, todo, current, alt, b)
    case Entity{raw, context, level, depth}:
      step.entity(M.split(raw), context, level, depth, todo, current, alt, b)
    case EndMessage{headers, parent, parent_alt, attachment}:
      Done{finish_message(headers, current, parent, parent_alt, attachment, todo, b)}
    case EndMultipart{parent, +parent_alt}:
      Done{Walking{todo, merge(parent, current, parent_alt), parent_alt, b}}

# Each of at most 128 charged entities schedules one visit and at most
# two completion frames. 385 ticks cover 384 dispatches plus the final
# result observation. This constant control fuel is not a memory bound.
def walk(fuel: Nat, r: Result<&2, &2, String, Walk>) -> Result<&2, &2, String, J.Json>:
  match fuel r:
    case 0n _:
      Fail{problem("traversal task allowance exhausted")}
    case 1n+left Fail{why}:
      Fail{why}
    case 1n+left Done{Finished{j}}:
      Done{j}
    case 1n+left Done{Walking{Nil{}, current, alt, b}}:
      Fail{problem("missing message root")}
    case 1n+left Done{Walking{task <> todo, current, alt, b}}:
      walk(left, step(task, todo, current, alt, b))

def view(+raw: String) -> Result<&2, &2, String, J.Json>:
  do Result<&2, &2, String, J.Json>:
    root : Budget <- entity_budget(Budget{128, 16777216, 16777216})
    admitted : Budget <- parse_bytes(raw, root)
    walk(385n, Done{Walking{[Message{raw, 1, None{}}], empty(), False{}, admitted}})
