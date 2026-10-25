# Validated BODYSTRUCTURE sections and complete transfer decoding.

import Base
import ./imap.bend as I
import ./mime.bend as M
import ./codec.bend as C

type Part is Data:
  Part{path: List<&2, U32>, ct: String, cd: String, encoding: String, size: U32}

type Pending is Data:
  Pending{path: List<&2, U32>, body: I.Value}

type Walk is Data:
  Walking{todo: List<&2, Pending>, found: List<&2, Part>}
  Bad{}

def check(ok: Bool, why: String) -> Result<&2, &2, String, Unit>:
  match ok:
    case True{}:
      Done{Unit{}}
    case False{}:
      Fail{why}

def children(xs: List<&2, I.Value>, +prefix: List<&2, U32>, +n: U32) -> List<&2, Pending>:
  match xs:
    case I.VList{ys} <> t:
      Pending{List.append(&2, U32, prefix, [n]), I.VList{ys}} <>
        children(t, prefix, (n + 1 : U32))
    case _:
      []

def encoding_ok(+s: String) -> Bool:
  String.eq(s, "7bit") || String.eq(s, "8bit") || String.eq(s, "binary") ||
    String.eq(s, "base64") || String.eq(s, "quoted-printable")

def single.put(
  meta: Maybe<&2, I.BodyPart>, size: Maybe<&2, U32>, path: List<&2, U32>,
  encoding: String, todo: List<&2, Pending>, found: List<&2, Part>
) -> Walk:
  match meta size:
    case Some{I.BodyPart{ct, cd}} Some{n}:
      Walking{todo, Part{path, ct, cd, encoding, n} <> found}
    case _ _:
      Bad{}

def single.if(
  valid: Bool, +xs: List<&2, I.Value>, path: List<&2, U32>, encoding: String,
  todo: List<&2, Pending>, found: List<&2, Part>
) -> Walk:
  match valid:
    case True{}:
      single.put(I.single_part(xs), U32.read(I.Value.text(I.nth(xs, 6n))),
        path, encoding, todo, found)
    case False{}:
      Bad{}

def multipart_ok(xs: List<&2, I.Value>) -> Bool:
  match xs:
    case I.VList{ys} <> t:
      multipart_ok(t)
    case I.VStr{s} <> t:
      Bool.not(String.is_empty(s))
    case _:
      False{}

def multipart.put(ok: Bool, xs: List<&2, I.Value>, path: List<&2, U32>,
  todo: List<&2, Pending>, found: List<&2, Part>) -> Walk:
  match ok:
    case True{}:
      Walking{List.append(&2, Pending, children(xs, path, 1), todo), found}
    case False{}:
      Bad{}

def walk.if(
  multi: Bool, +xs: List<&2, I.Value>, +path: List<&2, U32>,
  todo: List<&2, Pending>, found: List<&2, Part>
) -> Walk:
  match multi:
    case True{}:
      multipart.put(multipart_ok(xs), xs, path, todo, found)
    case False{}:
      +enc = String.to_lower(I.Value.text(I.nth(xs, 5n)))
      p = Bool.pick(List<&2, U32>, List.is_empty(&2, U32, path), [1], path)
      single.if(encoding_ok(enc), xs, p, enc, todo, found)

def walk.step(p: Pending, todo: List<&2, Pending>, found: List<&2, Part>) -> Walk:
  match p:
    case Pending{path, I.VList{+xs}}:
      walk.if(I.is_multipart(xs), xs, path, todo, found)
    case _:
      Bad{}

def walk(fuel: Nat, w: Walk) -> Result<&2, &2, String, List<&2, Part>>:
  match fuel w:
    case _ Bad{}:
      Fail{"malformed or unsupported BODYSTRUCTURE"}
    case _ Walking{Nil{}, found}:
      Done{List.reverse(&2, Part, found)}
    case 0n _:
      Fail{"BODYSTRUCTURE exceeds 128 parts or levels"}
    case 1n+f Walking{p <> todo, found}:
      walk(f, walk.step(p, todo, found))

def parts(v: I.Value) -> Result<&2, &2, String, List<&2, Part>>:
  walk(128n, Walking{[Pending{[], v}], []})

def kind(p: Part) -> M.PartKind:
  Part{path, ct, cd, encoding, size} = p
  M.part_kind([M.Hdr{"content-type", ct}, M.Hdr{"content-disposition", cd}])

def is_file.kind(k: M.PartKind) -> Bool:
  M.PartKind{ct, typ, name, file} = k
  file

def is_file(p: Part) -> Bool:
  is_file.kind(kind(p))

def path(p: Part) -> List<&2, U32>:
  Part{p, ct, cd, encoding, size} = p
  p

def matches.kind(k: M.PartKind, p: Part, +wanted: String) -> Bool:
  M.PartKind{ct, +typ, name, file} = k
  String.eq(I.section_str(path(p)), wanted) || (Bool.not(file) &&
    ((String.eq(wanted, "text") && String.eq(typ, "text/plain")) ||
     (String.eq(wanted, "html") && String.eq(typ, "text/html"))))

def matches(+p: Part, wanted: String) -> Bool:
  matches.kind(kind(p), p, wanted)

def select.if(ok: Bool, p: Part, rest: Maybe<&2, Part>) -> Maybe<&2, Part>:
  match ok:
    case True{}:
      Some{p}
    case False{}:
      rest

# Caller text is compared only with generated numeric paths (or text/html),
# never parsed into or interpolated in an IMAP command. Noncanonical paths fail.
def select(xs: List<&2, Part>, +wanted: String) -> Maybe<&2, Part>:
  match xs:
    case Nil{}:
      None{}
    case +p <> t:
      select.if(matches(p, wanted), p, select(t, wanted))

# Canonical base64 roundtrip rejects garbage, bad padding and partial groups.
# MIME whitespace is permitted between base64 digits. The walks below are
# loops over a reversed accumulator: an image part is past what a
# cons-recursive walk can hold on the interpreter's stack.
def compact.go(s: String, +acc: String) -> String:
  match s:
    case SNil{}:
      String.reverse(acc)
    case SCon{+c, t}:
      compact.go(t, Bool.pick(String, M.char_in(c, " \t\r\n"), acc, SCon{c, acc}))

def compact(s: String) -> String:
  compact.go(s, "")

# `ok` is false once an escape was not two hex digits.
def qp_ok.go(s: String, ok: Bool) -> Bool:
  match s ok:
    case _ False{}:
      False{}
    case SNil{} True{}:
      True{}
    case SCon{'=', SCon{'\r', SCon{'\n', t}}} True{}:
      qp_ok.go(t, True{})
    case SCon{'=', SCon{'\n', t}} True{}:
      qp_ok.go(t, True{})
    case SCon{'=', SCon{a, SCon{b, t}}} True{}:
      qp_ok.go(t, M.char_in(a, "0123456789abcdefABCDEF") &&
        M.char_in(b, "0123456789abcdefABCDEF"))
    case SCon{'=', t} True{}:
      False{}
    case SCon{c, t} True{}:
      qp_ok.go(t, True{})

def qp_ok(s: String) -> Bool:
  qp_ok.go(s, True{})

# String.eq rebuilds both strings on its way back, so it is not a loop.
def same.go(a: String, b: String, ok: Bool) -> Bool:
  match a b ok:
    case _ _ False{}:
      False{}
    case SNil{} SNil{} True{}:
      True{}
    case SCon{x, s} SCon{y, t} True{}:
      same.go(s, t, U32.is_eq(C.u(x), C.u(y)))
    case _ _ True{}:
      False{}

def same(a: String, b: String) -> Bool:
  same.go(a, b, True{})

def decode.if(b64: Bool, qp: Bool, +raw: String) -> Result<&2, &2, String, String>:
  match b64 qp:
    case True{} _:
      +bytes = C.b64_decode(raw)
      do Result<&2, &2, String, String>:
        check(same(C.b64_encode(bytes, False{}), compact(raw)),
          "incomplete or malformed base64 part")
        return bytes
    case False{} True{}:
      do Result<&2, &2, String, String>:
        check(qp_ok(raw), "incomplete or malformed quoted-printable part")
        return C.qp_decode(raw, False{})
    case False{} False{}:
      Done{raw}

def decode(p: Part, +raw: String, max: U32) -> Result<&2, &2, String, String>:
  Part{path, ct, cd, +encoding, +size} = p
  do Result<&2, &2, String, String>:
    check(U32.is_lt(size, max) && U32.is_eq(C.byte_len(raw), size),
      "incomplete part: size exceeds window or literal differs from BODYSTRUCTURE")
    decode.if(String.eq(encoding, "base64"), String.eq(encoding, "quoted-printable"), raw)

# Read only the exact section and origin requested, from the requested UID.
def value(xs: List<&2, I.Value>, +key: String) -> Maybe<&2, String>:
  match xs:
    case I.VAtom{+k} <> I.VStr{s} <> t:
      Bool.pick(Maybe<&2, String>, String.eq(String.to_upper(k), key),
        Some{s}, value(t, key))
    case k <> v <> t:
      value(t, key)
    case _:
      None{}

def response.if(ok: Bool, items: List<&2, I.Value>, key: String) -> Maybe<&2, String>:
  match ok:
    case True{}:
      value(items, key)
    case False{}:
      None{}

def message_uid(m: I.Msg) -> U32:
  I.Msg{id, flags, date, size, headers, body, st} = m
  id

def response(vs: List<&2, I.Value>, uid: U32, key: String) -> Maybe<&2, String>:
  match vs:
    case n <> I.VAtom{+f} <> I.VList{+items} <> Nil{}:
      id = message_uid(I.msg_pairs(items, I.msg_empty()))
      response.if(String.eq(String.to_upper(f), "FETCH") && U32.is_eq(id, uid), items, key)
    case _:
      None{}

def fetched.put(a: Maybe<&2, String>, b: Maybe<&2, String>) -> Maybe<&2, String>:
  match a:
    case Some{s}:
      Some{s}
    case None{}:
      b

def fetched(lines: List<&2, I.RLine>, +uid: U32, +key: String) -> Maybe<&2, String>:
  match lines:
    case Nil{}:
      None{}
    case I.RLine{text, lits} <> t:
      fetched.put(response(I.tokens(String.drop(text, 2n), lits), uid, key),
        fetched(t, uid, key))
