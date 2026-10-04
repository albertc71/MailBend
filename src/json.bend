import Base

# JSON values for tool arguments, tool results and MCP messages.
#
# Arrays and objects hold their items as a chain of JCons cells ending in
# JEnd, and object members are JKv items. Keeping the chain inside Json
# itself lets every walk over a value be one structurally recursive def
# (Bend has no mutual recursion). Numbers keep their source text.
type Json is Data:
  JNull{}
  JBool{b: Bool}
  JNum{raw: String}
  JStr{s: String}
  JArr{items: Json}
  JObj{items: Json}
  JCons{head: Json, tail: Json}
  JEnd{}
  JKv{key: String, val: Json}

# ---- parsing -----------------------------------------------------------------

type Tok is Data:
  TLBrace{}
  TRBrace{}
  TLBrack{}
  TRBrack{}
  TStr{s: String}
  TNum{s: String}
  TTrue{}
  TFalse{}
  TNull{}
  TColon{}
  TComma{}
  TBad{}

# Lexer states; string accumulators are reversed. `hi` holds a pending
# UTF-16 high surrogate from a \u escape, or 0.
type LexSt is Data:
  LNorm{}
  LStr{acc: String, hi: U32}
  LEsc{acc: String, hi: U32}
  LUni{acc: String, hi: U32, n: Nat, code: U32}
  LNum{acc: String}
  LWord{acc: String}
  LErr{}

type Lx is Data:
  Lx{st: LexSt, toks: List<&2, Tok>}

# Open containers with what they accept next. Arrays: 0 a value or "]"
# (just opened), 1 a value (after ","), 2 "," or "]". Objects: 0 a key or
# "}", 1 a key, 2 ":", 3 a value, 4 "," or "}".
type Frame is Data:
  FArr{rev: List<&2, Json>, need: U32}
  FObj{rev: List<&2, Json>, key: String, need: U32}

type Bld is Data:
  Bld{stack: List<&2, Frame>, done: Maybe<&2, Json>, ok: Bool}

# ---- construction ----------------------------------------------------------

def chain(xs: List<&2, Json>) -> Json:
  match xs:
    case Nil{}:
      JEnd{}
    case Con{h, t}:
      JCons{h, chain(t)}

def arr(xs: List<&2, Json>) -> Json:
  JArr{chain(xs)}

def obj(kvs: List<&2, Json>) -> Json:
  JObj{chain(kvs)}

def kv(k: String, v: Json) -> Json:
  JKv{k, v}

def str(s: String) -> Json:
  JStr{s}

def num(n: U32) -> Json:
  JNum{U32.show(n)}

def bool(b: Bool) -> Json:
  JBool{b}

def str_chain(xs: List<&2, String>) -> Json:
  match xs:
    case Nil{}:
      JEnd{}
    case Con{h, t}:
      JCons{JStr{h}, str_chain(t)}

def strs(xs: List<&2, String>) -> Json:
  JArr{str_chain(xs)}

# ---- serialization ---------------------------------------------------------

def hex_digit(+n: U32) -> Char:
  Char.from_u32(U32.add(n, Bool.pick(U32, U32.is_lt(n, 10), 48, 87)))

def esc_ctrl(ctrl: Bool, +u: U32, c: Char) -> String:
  match ctrl:
    case True{}:
      "\\u00" ++ SCon{hex_digit(U32.shrn(u, 4n)), SCon{hex_digit(U32.and(u, 15)), SNil{}}}
    case False{}:
      SCon{c, SNil{}}

def esc_char(+c: Char) -> String:
  match c:
    case '"':
      "\\\""
    case '\\':
      "\\\\"
    case '\n':
      "\\n"
    case '\r':
      "\\r"
    case '\t':
      "\\t"
    case _:
      esc_ctrl(U32.is_lt(Char.to_u32(c), 32), Char.to_u32(c), c)

def esc(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{c, t}:
      esc_char(c) ++ esc(t)

def quote(s: String) -> String:
  "\"" ++ esc(s) ++ "\""

def sep(+t: Json) -> String:
  match t:
    case JEnd{}:
      ""
    case _:
      ","

def show(j: Json) -> String:
  match j:
    case JNull{}:
      "null"
    case JBool{b}:
      Bool.pick(String, b, "true", "false")
    case JNum{raw}:
      raw
    case JStr{s}:
      quote(s)
    case JArr{items}:
      "[" ++ show(items) ++ "]"
    case JObj{items}:
      "{" ++ show(items) ++ "}"
    case JCons{h, +t}:
      show(h) ++ sep(t) ++ show(t)
    case JEnd{}:
      ""
    case JKv{k, v}:
      quote(k) ++ ":" ++ show(v)

# ---- access ------------------------------------------------------------------

def pick(hit: Bool, v: Json, rest: Maybe<&2, Json>) -> Maybe<&2, Json>:
  match hit:
    case True{}:
      Some{v}
    case False{}:
      rest

def find(+items: Json, +key: String) -> Maybe<&2, Json>:
  match items:
    case JCons{h, t}:
      match h:
        case JKv{k, v}:
          pick(String.eq(k, key), v, find(t, key))
        case _:
          find(t, key)
    case _:
      None{}

def get(+j: Json, +key: String) -> Maybe<&2, Json>:
  match j:
    case JObj{items}:
      find(items, key)
    case _:
      None{}

def as_str(m: Maybe<&2, Json>) -> Maybe<&2, String>:
  match m:
    case Some{JStr{s}}:
      Some{s}
    case _:
      None{}

def as_bool(m: Maybe<&2, Json>) -> Maybe<&2, Bool>:
  match m:
    case Some{JBool{b}}:
      Some{b}
    case _:
      None{}

def as_u32(m: Maybe<&2, Json>) -> Maybe<&2, U32>:
  match m:
    case Some{JNum{raw}}:
      U32.read(raw)
    case Some{JStr{raw}}:
      U32.read(raw)
    case _:
      None{}

def unchain(j: Json) -> List<&2, Json>:
  match j:
    case JCons{h, t}:
      h <> unchain(t)
    case _:
      []

def as_list(m: Maybe<&2, Json>) -> Maybe<&2, List<&2, Json>>:
  match m:
    case Some{JArr{items}}:
      Some{unchain(items)}
    case _:
      None{}

def is_num_char(+c: Char) -> Bool:
  Char.is_digit(c) || Char.is_eq(c, '-') || Char.is_eq(c, '+') || Char.is_eq(c, '.') || Char.is_eq(c, 'e') || Char.is_eq(c, 'E')

def word_tok(+w: String) -> Tok:
  Bool.pick(Tok, String.eq(w, "true"), TTrue{},
    Bool.pick(Tok, String.eq(w, "false"), TFalse{},
      Bool.pick(Tok, String.eq(w, "null"), TNull{}, TBad{})))

# JSON whitespace: space, tab, CR and LF only (RFC 8259).
def is_ws(+c: Char) -> Bool:
  Char.is_eq(c, ' ') || Char.is_eq(c, '\t') || Char.is_eq(c, '\r') || Char.is_eq(c, '\n')

def norm_other(+c: Char, +toks: List<&2, Tok>) -> Lx:
  Bool.pick(Lx, Char.is_digit(c) || Char.is_eq(c, '-'), Lx{LNum{SCon{c, SNil{}}}, toks},
    Bool.pick(Lx, Char.is_alpha(c), Lx{LWord{SCon{c, SNil{}}}, toks},
      Bool.pick(Lx, is_ws(c), Lx{LNorm{}, toks}, Lx{LNorm{}, TBad{} <> toks})))

def norm(+c: Char, toks: List<&2, Tok>) -> Lx:
  match c:
    case '{':
      Lx{LNorm{}, TLBrace{} <> toks}
    case '}':
      Lx{LNorm{}, TRBrace{} <> toks}
    case '[':
      Lx{LNorm{}, TLBrack{} <> toks}
    case ']':
      Lx{LNorm{}, TRBrack{} <> toks}
    case ':':
      Lx{LNorm{}, TColon{} <> toks}
    case ',':
      Lx{LNorm{}, TComma{} <> toks}
    case '"':
      Lx{LStr{SNil{}, 0}, toks}
    case _:
      norm_other(c, toks)

def flush_hi(+acc: String, +hi: U32) -> String:
  Bool.pick(String, U32.is_zero(hi), acc, SCon{Char.from_u32(65533), acc})

def in_range(+x: U32, lo: U32, hi: U32) -> Bool:
  U32.is_ge(x, lo) && U32.is_le(x, hi)

def safe_scalar(+code: U32) -> U32:
  Bool.pick(U32, in_range(code, 55296, 57343), 65533, code)

def uni_low(pair: Bool, +acc: String, +hi: U32, +code: U32) -> LexSt:
  match pair:
    case True{}:
      LStr{SCon{Char.from_u32((65536 + (hi - 55296) * 1024 + (code - 56320) : U32)), acc}, 0}
    case False{}:
      LStr{SCon{Char.from_u32(safe_scalar(code)), flush_hi(acc, hi)}, 0}

def uni_high(high: Bool, +acc: String, +hi: U32, +code: U32) -> LexSt:
  match high:
    case True{}:
      LStr{flush_hi(acc, hi), code}
    case False{}:
      uni_low(in_range(code, 56320, 57343) && Bool.not(U32.is_zero(hi)), acc, hi, code)

def uni_done(+acc: String, +hi: U32, +code: U32) -> LexSt:
  uni_high(in_range(code, 55296, 56319), acc, hi, code)

def hex_val(+c: Char) -> U32:
  +u = Char.to_u32(c)
  Bool.pick(U32, Char.is_digit(c), (u - 48 : U32),
    Bool.pick(U32, in_range(u, 97, 102), (u - 87 : U32),
      Bool.pick(U32, in_range(u, 65, 70), (u - 55 : U32), 0)))

def esc_step(+c: Char, acc: String, +hi: U32) -> LexSt:
  match c:
    case 'u':
      LUni{acc, hi, 4n, 0}
    case 'n':
      LStr{SCon{'\n', flush_hi(acc, hi)}, 0}
    case 't':
      LStr{SCon{'\t', flush_hi(acc, hi)}, 0}
    case 'r':
      LStr{SCon{'\r', flush_hi(acc, hi)}, 0}
    case 'b':
      LStr{SCon{Char.from_u32(8), flush_hi(acc, hi)}, 0}
    case 'f':
      LStr{SCon{Char.from_u32(12), flush_hi(acc, hi)}, 0}
    case '"':
      LStr{SCon{c, flush_hi(acc, hi)}, 0}
    case '\\':
      LStr{SCon{c, flush_hi(acc, hi)}, 0}
    case '/':
      LStr{SCon{c, flush_hi(acc, hi)}, 0}
    case _:
      LErr{}

def is_hex(+c: Char) -> Bool:
  +u = Char.to_u32(c)
  Char.is_digit(c) || in_range(u, 97, 102) || in_range(u, 65, 70)

# A raw control character (below U+0020) inside a string is invalid JSON.
def str_char(ctl: Bool, +c: Char, acc: String, +hi: U32) -> LexSt:
  match ctl:
    case True{}:
      LErr{}
    case False{}:
      LStr{SCon{c, flush_hi(acc, hi)}, 0}

def str_step(+c: Char, acc: String, +hi: U32, toks: List<&2, Tok>) -> Lx:
  match c:
    case '"':
      Lx{LNorm{}, TStr{String.reverse(flush_hi(acc, hi))} <> toks}
    case '\\':
      Lx{LEsc{acc, hi}, toks}
    case _:
      Lx{str_char(U32.is_lt(Char.to_u32(c), 32), c, acc, hi), toks}

def uni_digit(n: Nat, +c: Char, acc: String, +hi: U32, +code: U32) -> LexSt:
  match n:
    case 1n+0n:
      uni_done(acc, hi, (code * 16 + hex_val(c) : U32))
    case 1n+p:
      LUni{acc, hi, p, (code * 16 + hex_val(c) : U32)}
    case 0n:
      LStr{acc, hi}

# \u takes exactly four hex digits; anything else rejects the input.
def uni_hex(ok: Bool, n: Nat, +c: Char, acc: String, +hi: U32, +code: U32) -> LexSt:
  match ok:
    case True{}:
      uni_digit(n, c, acc, hi, code)
    case False{}:
      LErr{}

def uni_step(n: Nat, +c: Char, acc: String, +hi: U32, +code: U32) -> LexSt:
  uni_hex(is_hex(c), n, c, acc, hi, code)

# JSON number grammar (RFC 8259) as a state machine. States: 0 start,
# 1 after '-', 2 a leading 0, 3 integer digits, 4 after '.', 5 fraction
# digits, 6 after 'e', 7 after the exponent sign, 8 exponent digits;
# 9 is dead. 2, 3, 5 and 8 accept.
def num_next(+st: U32, +c: Char) -> U32:
  match st:
    case 0:
      Bool.pick(U32, Char.is_eq(c, '-'), 1,
        Bool.pick(U32, Char.is_eq(c, '0'), 2, Bool.pick(U32, Char.is_digit(c), 3, 9)))
    case 1:
      Bool.pick(U32, Char.is_eq(c, '0'), 2, Bool.pick(U32, Char.is_digit(c), 3, 9))
    case 2:
      Bool.pick(U32, Char.is_eq(c, '.'), 4,
        Bool.pick(U32, Char.is_eq(c, 'e') || Char.is_eq(c, 'E'), 6, 9))
    case 3:
      Bool.pick(U32, Char.is_eq(c, '.'), 4,
        Bool.pick(U32, Char.is_eq(c, 'e') || Char.is_eq(c, 'E'), 6, Bool.pick(U32, Char.is_digit(c), 3, 9)))
    case 4:
      Bool.pick(U32, Char.is_digit(c), 5, 9)
    case 5:
      Bool.pick(U32, Char.is_digit(c), 5,
        Bool.pick(U32, Char.is_eq(c, 'e') || Char.is_eq(c, 'E'), 6, 9))
    case 6:
      Bool.pick(U32, Char.is_eq(c, '+') || Char.is_eq(c, '-'), 7, Bool.pick(U32, Char.is_digit(c), 8, 9))
    case 7:
      Bool.pick(U32, Char.is_digit(c), 8, 9)
    case 8:
      Bool.pick(U32, Char.is_digit(c), 8, 9)
    case _:
      9

def num_state(+s: String, +st: U32) -> U32:
  match s:
    case SNil{}:
      st
    case SCon{c, t}:
      num_state(t, num_next(st, c))

def valid_num(+s: String) -> Bool:
  +st = num_state(s, 0)
  U32.is_eq(st, 2) || U32.is_eq(st, 3) || U32.is_eq(st, 5) || U32.is_eq(st, 8)

def num_tok(+s: String) -> Tok:
  Bool.pick(Tok, valid_num(s), TNum{s}, TBad{})

def num_step(+c: Char, +acc: String, +toks: List<&2, Tok>) -> Lx:
  Bool.pick(Lx, is_num_char(c), Lx{LNum{SCon{c, acc}}, toks}, norm(c, num_tok(String.reverse(acc)) <> toks))

def word_step(+c: Char, +acc: String, +toks: List<&2, Tok>) -> Lx:
  Bool.pick(Lx, Char.is_alpha(c), Lx{LWord{SCon{c, acc}}, toks}, norm(c, word_tok(String.reverse(acc)) <> toks))

def lex_step(+c: Char, lx: Lx) -> Lx:
  match lx:
    case Lx{LNorm{}, toks}:
      norm(c, toks)
    case Lx{LStr{acc, hi}, toks}:
      str_step(c, acc, hi, toks)
    case Lx{LEsc{acc, hi}, toks}:
      Lx{esc_step(c, acc, hi), toks}
    case Lx{LUni{acc, hi, n, code}, toks}:
      Lx{uni_step(n, c, acc, hi, code), toks}
    case Lx{LNum{acc}, toks}:
      num_step(c, acc, toks)
    case Lx{LWord{acc}, toks}:
      word_step(c, acc, toks)
    case Lx{LErr{}, toks}:
      Lx{LErr{}, toks}

def lex_end(lx: Lx) -> List<&2, Tok>:
  match lx:
    case Lx{LNorm{}, toks}:
      toks
    case Lx{LNum{acc}, toks}:
      num_tok(String.reverse(acc)) <> toks
    case Lx{LWord{acc}, toks}:
      word_tok(String.reverse(acc)) <> toks
    case Lx{_, toks}:
      TBad{} <> toks

def lex(s: String, lx: Lx) -> List<&2, Tok>:
  match s:
    case SNil{}:
      lex_end(lx)
    case SCon{c, t}:
      lex(t, lex_step(c, lx))

def close(+f: Frame) -> Json:
  match f:
    case FArr{rev, n}:
      JArr{chain(List.reverse(&2, Json, rev))}
    case FObj{rev, k, n}:
      JObj{chain(List.reverse(&2, Json, rev))}

def bad(+stack: List<&2, Frame>, +done: Maybe<&2, Json>) -> Bld:
  Bld{stack, done, False{}}

# A finished value lands in the open container, if it expects one.
def add(+v: Json, +stack: List<&2, Frame>, +done: Maybe<&2, Json>, +ok: Bool) -> Bld:
  match stack:
    case Nil{}:
      Bld{[], Some{v}, ok && Maybe.is_none(&2, Json, done)}
    case Con{FArr{rev, n}, rest}:
      Bool.pick(Bld, U32.is_lt(n, 2), Bld{FArr{v <> rev, 2} <> rest, done, ok}, bad(stack, done))
    case Con{FObj{rev, k, n}, rest}:
      Bool.pick(Bld, U32.is_eq(n, 3), Bld{FObj{JKv{k, v} <> rev, "", 4} <> rest, done, ok}, bad(stack, done))

def pop_arr(+stack: List<&2, Frame>, +done: Maybe<&2, Json>, +ok: Bool) -> Bld:
  match stack:
    case Con{FArr{rev, n}, rest}:
      Bool.pick(Bld, U32.is_eq(n, 0) || U32.is_eq(n, 2), add(close(FArr{rev, n}), rest, done, ok), bad(stack, done))
    case _:
      bad(stack, done)

def pop_obj(+stack: List<&2, Frame>, +done: Maybe<&2, Json>, +ok: Bool) -> Bld:
  match stack:
    case Con{FObj{rev, k, n}, rest}:
      Bool.pick(Bld, U32.is_eq(n, 0) || U32.is_eq(n, 4), add(close(FObj{rev, k, n}), rest, done, ok), bad(stack, done))
    case _:
      bad(stack, done)

def key_or_value(+s: String, +stack: List<&2, Frame>, +done: Maybe<&2, Json>, +ok: Bool) -> Bld:
  match stack:
    case Con{FObj{rev, k, n}, rest}:
      Bool.pick(Bld, U32.is_lt(n, 2), Bld{FObj{rev, s, 2} <> rest, done, ok}, add(JStr{s}, stack, done, ok))
    case _:
      add(JStr{s}, stack, done, ok)

def colon(+stack: List<&2, Frame>, +done: Maybe<&2, Json>, +ok: Bool) -> Bld:
  match stack:
    case Con{FObj{rev, k, n}, rest}:
      Bool.pick(Bld, U32.is_eq(n, 2), Bld{FObj{rev, k, 3} <> rest, done, ok}, bad(stack, done))
    case _:
      bad(stack, done)

def comma(+stack: List<&2, Frame>, +done: Maybe<&2, Json>, +ok: Bool) -> Bld:
  match stack:
    case Con{FArr{rev, n}, rest}:
      Bool.pick(Bld, U32.is_eq(n, 2), Bld{FArr{rev, 1} <> rest, done, ok}, bad(stack, done))
    case Con{FObj{rev, k, n}, rest}:
      Bool.pick(Bld, U32.is_eq(n, 4), Bld{FObj{rev, k, 1} <> rest, done, ok}, bad(stack, done))
    case _:
      bad(stack, done)

def bstep(+t: Tok, +stack: List<&2, Frame>, +done: Maybe<&2, Json>, +ok: Bool) -> Bld:
  match t:
    case TLBrack{}:
      Bld{FArr{[], 0} <> stack, done, ok}
    case TLBrace{}:
      Bld{FObj{[], "", 0} <> stack, done, ok}
    case TRBrack{}:
      pop_arr(stack, done, ok)
    case TRBrace{}:
      pop_obj(stack, done, ok)
    case TColon{}:
      colon(stack, done, ok)
    case TComma{}:
      comma(stack, done, ok)
    case TStr{s}:
      key_or_value(s, stack, done, ok)
    case TNum{s}:
      add(JNum{s}, stack, done, ok)
    case TTrue{}:
      add(JBool{True{}}, stack, done, ok)
    case TFalse{}:
      add(JBool{False{}}, stack, done, ok)
    case TNull{}:
      add(JNull{}, stack, done, ok)
    case TBad{}:
      bad(stack, done)

def bstep_b(+b: Bld, +t: Tok) -> Bld:
  match b:
    case Bld{stack, done, ok}:
      bstep(t, stack, done, ok)

def build(+toks: List<&2, Tok>, +b: Bld) -> Bld:
  match toks:
    case Nil{}:
      b
    case Con{t, rest}:
      build(rest, bstep_b(b, t))

def finish(+b: Bld) -> Maybe<&2, Json>:
  match b:
    case Bld{Nil{}, Some{v}, True{}}:
      Some{v}
    case _:
      None{}

def parse(s: String) -> Maybe<&2, Json>:
  tokens = List.reverse(&2, Tok, lex(s, Lx{LNorm{}, []}))
  finish(build(tokens, Bld{[], None{}, True{}}))
