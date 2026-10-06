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

# Construction
# ------------

def chain(xs: List<&2, Json>) -> Json:
  match xs:
    case []:
      JEnd{}
    case h <> t:
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
    case []:
      JEnd{}
    case h <> t:
      JCons{JStr{h}, str_chain(t)}

def strs(xs: List<&2, String>) -> Json:
  JArr{str_chain(xs)}

# Serialization
# -------------

# The lower-case hex digit for n, below 16.
def hex_digit(+n: U32) -> Char:
  Char.from_u32((n + Bool.pick(U32, U32.is_lt(n, 10), 48, 87) : U32))

# A control character (code u below U+0020) becomes \u00XX; any other c
# stays as it is.
def esc_char.if(ctrl: Bool, +u: U32, c: Char) -> String:
  match ctrl:
    case True{}:
      "\\u00" ++ SCon{hex_digit((u >> 4n : U32)),
        SCon{hex_digit((u .&. 15 : U32)), SNil{}}}
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
      +u = Char.to_u32(c)
      esc_char.if(U32.is_lt(u, 32), u, c)

def esc(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{c, t}:
      esc_char(c) ++ esc(t)

def quote(s: String) -> String:
  "\"" ++ esc(s) ++ "\""

# The separator before the rest t of a chain.
def sep(t: Json) -> String:
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

# Access
# ------

# Walks a member chain and stops at the first hit: `hit` says whether the
# member just passed had the key, and `found` holds its value.
def find.go(
  items: Json, +key: String, hit: Bool, found: Maybe<&2, Json>
) -> Maybe<&2, Json>:
  match items hit:
    case _ True{}:
      found
    case JCons{JKv{k, v}, t} False{}:
      find.go(t, key, String.eq(k, key), Some{v})
    case JCons{_, t} False{}:
      find.go(t, key, False{}, None{})
    case _ False{}:
      None{}

# The value of the first member named key.
def find(+items: Json, +key: String) -> Maybe<&2, Json>:
  find.go(items, key, False{}, None{})

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

# A number, or a string holding one.
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

# Lexer
# -----

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

# Lexer states. LNorm is between tokens, LEsc follows a backslash, and LUni
# reads the n hex digits left of a \u escape into code. Accumulators are
# reversed; `hi` holds a pending UTF-16 high surrogate from a \u escape,
# or 0.
type LexState is Data:
  LNorm{}
  LStr{acc: String, hi: U32}
  LEsc{acc: String, hi: U32}
  LUni{acc: String, hi: U32, n: Nat, code: U32}
  LNum{acc: String}
  LWord{acc: String}
  LErr{}

# The state and the tokens so far, newest first.
type Lexer is Data:
  Lexer{state: LexState, toks: List<&2, Tok>}

# JSON whitespace: space, tab, CR and LF only (RFC 8259).
def is_ws(+c: Char) -> Bool:
  Char.is_eq(c, ' ') || Char.is_eq(c, '\t') || Char.is_eq(c, '\r')
    || Char.is_eq(c, '\n')

def is_exp(+c: Char) -> Bool:
  Char.is_eq(c, 'e') || Char.is_eq(c, 'E')

# A character that may continue a number; the grammar is checked at its end.
def is_num_char(+c: Char) -> Bool:
  Char.is_digit(c) || Char.is_eq(c, '-') || Char.is_eq(c, '+')
    || Char.is_eq(c, '.') || is_exp(c)

def in_range(+x: U32, lo: U32, hi: U32) -> Bool:
  U32.is_ge(x, lo) && U32.is_le(x, hi)

# A word from its reversed letters.
def word_tok(rev: String) -> Tok:
  +w = String.reverse(rev)
  Bool.pick(Tok, String.eq(w, "true"), TTrue{},
    Bool.pick(Tok, String.eq(w, "false"), TFalse{},
      Bool.pick(Tok, String.eq(w, "null"), TNull{}, TBad{})))

# Numbers
# -------

# JSON number grammar (RFC 8259) as a state machine. States: 0 start,
# 1 after '-', 2 a leading 0, 3 integer digits, 4 after '.', 5 fraction
# digits, 6 after 'e', 7 after the exponent sign, 8 exponent digits;
# 9 is dead. 2, 3, 5 and 8 accept.

# State st on a digit, else the dead state.
def num_digit(c: Char, st: U32) -> U32:
  Bool.pick(U32, Char.is_digit(c), st, 9)

# The first integer digit: a lone 0 or the start of more digits.
def num_int(+c: Char) -> U32:
  Bool.pick(U32, Char.is_eq(c, '0'), 2, num_digit(c, 3))

def num_next(st: U32, +c: Char) -> U32:
  match st:
    case 0:
      Bool.pick(U32, Char.is_eq(c, '-'), 1, num_int(c))
    case 1:
      num_int(c)
    case 2:
      Bool.pick(U32, Char.is_eq(c, '.'), 4, Bool.pick(U32, is_exp(c), 6, 9))
    case 3:
      Bool.pick(U32, Char.is_eq(c, '.'), 4,
        Bool.pick(U32, is_exp(c), 6, num_digit(c, 3)))
    case 4:
      num_digit(c, 5)
    case 5:
      Bool.pick(U32, is_exp(c), 6, num_digit(c, 5))
    case 6:
      Bool.pick(U32, Char.is_eq(c, '+') || Char.is_eq(c, '-'), 7,
        num_digit(c, 8))
    case 7:
      num_digit(c, 8)
    case 8:
      num_digit(c, 8)
    case _:
      9

def num_state(s: String, st: U32) -> U32:
  match s:
    case SNil{}:
      st
    case SCon{c, t}:
      num_state(t, num_next(st, c))

def valid_num(s: String) -> Bool:
  +st = num_state(s, 0)
  U32.is_eq(st, 2) || U32.is_eq(st, 3) || U32.is_eq(st, 5) || U32.is_eq(st, 8)

# A number from its reversed characters.
def num_tok(rev: String) -> Tok:
  +s = String.reverse(rev)
  Bool.pick(Tok, valid_num(s), TNum{s}, TBad{})

# Between tokens
# --------------

# Starts a number or a word, skips whitespace, and rejects anything else.
def norm_other(+c: Char, +toks: List<&2, Tok>) -> Lexer:
  Bool.pick(Lexer, Char.is_digit(c) || Char.is_eq(c, '-'),
    Lexer{LNum{SCon{c, SNil{}}}, toks},
    Bool.pick(Lexer, Char.is_alpha(c), Lexer{LWord{SCon{c, SNil{}}}, toks},
      Bool.pick(Lexer, is_ws(c), Lexer{LNorm{}, toks},
        Lexer{LNorm{}, TBad{} <> toks})))

def norm_step(+c: Char, toks: List<&2, Tok>) -> Lexer:
  match c:
    case '{':
      Lexer{LNorm{}, TLBrace{} <> toks}
    case '}':
      Lexer{LNorm{}, TRBrace{} <> toks}
    case '[':
      Lexer{LNorm{}, TLBrack{} <> toks}
    case ']':
      Lexer{LNorm{}, TRBrack{} <> toks}
    case ':':
      Lexer{LNorm{}, TColon{} <> toks}
    case ',':
      Lexer{LNorm{}, TComma{} <> toks}
    case '"':
      Lexer{LStr{"", 0}, toks}
    case _:
      norm_other(c, toks)

# Strings
# -------

# The reversed string acc, with U+FFFD for a pending lone high surrogate.
def flush_hi(+acc: String, +hi: U32) -> String:
  Bool.pick(String, U32.is_zero(hi), acc, SCon{Char.from_u32(65533), acc})

# Appends c to the string, after any pending lone high surrogate.
def put(c: Char, acc: String, hi: U32) -> LexState:
  LStr{SCon{c, flush_hi(acc, hi)}, 0}

# A lone surrogate code becomes U+FFFD.
def safe_scalar(+code: U32) -> U32:
  Bool.pick(U32, in_range(code, 55296, 57343), 65533, code)

# A low surrogate completes the pending high one; any other unit stands
# alone.
def uni_low(paired: Bool, acc: String, hi: U32, code: U32) -> LexState:
  match paired:
    case True{}:
      scalar = (65536 + (hi - 55296) * 1024 + (code - 56320) : U32)
      LStr{SCon{Char.from_u32(scalar), acc}, 0}
    case False{}:
      put(Char.from_u32(safe_scalar(code)), acc, hi)

# A high surrogate waits for its low half.
def uni_high(high: Bool, acc: String, +hi: U32, +code: U32) -> LexState:
  match high:
    case True{}:
      LStr{flush_hi(acc, hi), code}
    case False{}:
      paired = in_range(code, 56320, 57343) && Bool.not(U32.is_zero(hi))
      uni_low(paired, acc, hi, code)

# A complete \u escape: one UTF-16 code unit.
def uni_unit(acc: String, hi: U32, +code: U32) -> LexState:
  uni_high(in_range(code, 55296, 56319), acc, hi, code)

# The value of c as a hex digit, if it is one.
def hex_val(+c: Char) -> Maybe<&2, U32>:
  +u = Char.to_u32(c)
  Bool.pick(Maybe<&2, U32>, Char.is_digit(c), Some{(u - 48 : U32)},
    Bool.pick(Maybe<&2, U32>, in_range(u, 97, 102), Some{(u - 87 : U32)},
      Bool.pick(Maybe<&2, U32>, in_range(u, 65, 70), Some{(u - 55 : U32)},
        None{})))

# Counts down the n digits of a \u escape; code already holds this one.
def uni_digit(n: Nat, acc: String, hi: U32, code: U32) -> LexState:
  match n:
    case 1n+0n:
      uni_unit(acc, hi, code)
    case 1n+p:
      LUni{acc, hi, p, code}
    case 0n:
      LStr{acc, hi}

# \u takes exactly four hex digits; anything else rejects the input.
def uni_step(
  digit: Maybe<&2, U32>, n: Nat, acc: String, hi: U32, code: U32
) -> LexState:
  match digit:
    case Some{d}:
      uni_digit(n, acc, hi, (code * 16 + d : U32))
    case None{}:
      LErr{}

def esc_step(+c: Char, acc: String, hi: U32) -> LexState:
  match c:
    case 'u':
      LUni{acc, hi, 4n, 0}
    case 'n':
      put('\n', acc, hi)
    case 't':
      put('\t', acc, hi)
    case 'r':
      put('\r', acc, hi)
    case 'b':
      put(Char.from_u32(8), acc, hi)
    case 'f':
      put(Char.from_u32(12), acc, hi)
    case '"':
      put(c, acc, hi)
    case '\\':
      put(c, acc, hi)
    case '/':
      put(c, acc, hi)
    case _:
      LErr{}

# A raw control character (below U+0020) inside a string is invalid JSON.
def str_step.if(ctrl: Bool, c: Char, acc: String, hi: U32) -> LexState:
  match ctrl:
    case True{}:
      LErr{}
    case False{}:
      put(c, acc, hi)

def str_step(+c: Char, acc: String, hi: U32, toks: List<&2, Tok>) -> Lexer:
  match c:
    case '"':
      Lexer{LNorm{}, TStr{String.reverse(flush_hi(acc, hi))} <> toks}
    case '\\':
      Lexer{LEsc{acc, hi}, toks}
    case _:
      Lexer{str_step.if(U32.is_lt(Char.to_u32(c), 32), c, acc, hi), toks}

# Lexing
# ------

# `more` says whether c continues the number; if not, the number ends and
# c starts the next token.
def num_step.if(
  more: Bool, c: Char, acc: String, toks: List<&2, Tok>
) -> Lexer:
  match more:
    case True{}:
      Lexer{LNum{SCon{c, acc}}, toks}
    case False{}:
      norm_step(c, num_tok(acc) <> toks)

def num_step(+c: Char, acc: String, toks: List<&2, Tok>) -> Lexer:
  num_step.if(is_num_char(c), c, acc, toks)

# `more` says whether c continues the word; if not, the word ends and c
# starts the next token.
def word_step.if(
  more: Bool, c: Char, acc: String, toks: List<&2, Tok>
) -> Lexer:
  match more:
    case True{}:
      Lexer{LWord{SCon{c, acc}}, toks}
    case False{}:
      norm_step(c, word_tok(acc) <> toks)

def word_step(+c: Char, acc: String, toks: List<&2, Tok>) -> Lexer:
  word_step.if(Char.is_alpha(c), c, acc, toks)

def lex_step(c: Char, lx: Lexer) -> Lexer:
  match lx:
    case Lexer{LNorm{}, toks}:
      norm_step(c, toks)
    case Lexer{LStr{acc, hi}, toks}:
      str_step(c, acc, hi, toks)
    case Lexer{LEsc{acc, hi}, toks}:
      Lexer{esc_step(c, acc, hi), toks}
    case Lexer{LUni{acc, hi, n, code}, toks}:
      Lexer{uni_step(hex_val(c), n, acc, hi, code), toks}
    case Lexer{LNum{acc}, toks}:
      num_step(c, acc, toks)
    case Lexer{LWord{acc}, toks}:
      word_step(c, acc, toks)
    case Lexer{LErr{}, toks}:
      Lexer{LErr{}, toks}

# The tokens, newest first; input ending inside a string or after an
# error yields a bad token.
def lex_end(lx: Lexer) -> List<&2, Tok>:
  match lx:
    case Lexer{LNorm{}, toks}:
      toks
    case Lexer{LNum{acc}, toks}:
      num_tok(acc) <> toks
    case Lexer{LWord{acc}, toks}:
      word_tok(acc) <> toks
    case Lexer{_, toks}:
      TBad{} <> toks

def lex(s: String, lx: Lexer) -> List<&2, Tok>:
  match s:
    case SNil{}:
      lex_end(lx)
    case SCon{c, t}:
      lex(t, lex_step(c, lx))

# Builder
# -------

# What an open container accepts next. Open: an item or the close (just
# opened). Item: an array value or an object key (after ","). Colon: ":"
# (after a key). Value: an object value (after ":"). Next: "," or the
# close (after an item).
type Need is Data:
  NeedOpen{}
  NeedItem{}
  NeedColon{}
  NeedValue{}
  NeedNext{}

# An open container with its items so far, newest first. An object also
# holds the key awaiting its value.
type Frame is Data:
  FArr{rev: List<&2, Json>, need: Need}
  FObj{rev: List<&2, Json>, key: String, need: Need}

# The open containers, innermost first, and the finished top-level value.
type Builder is Data:
  Builder{stack: List<&2, Frame>, done: Maybe<&2, Json>}

# The chain of a container's items, from their reversed list.
def from_rev(rev: List<&2, Json>) -> Json:
  chain(List.reverse(&2, Json, rev))

# A finished value lands in the open container, if it expects one, or
# becomes the only top-level value.
def add(
  v: Json, stack: List<&2, Frame>, done: Maybe<&2, Json>
) -> Maybe<&2, Builder>:
  match stack:
    case []:
      match done:
        case None{}:
          Some{Builder{[], Some{v}}}
        case Some{_}:
          None{}
    case FArr{rev, NeedOpen{}} <> rest:
      Some{Builder{FArr{v <> rev, NeedNext{}} <> rest, done}}
    case FArr{rev, NeedItem{}} <> rest:
      Some{Builder{FArr{v <> rev, NeedNext{}} <> rest, done}}
    case FObj{rev, k, NeedValue{}} <> rest:
      Some{Builder{FObj{JKv{k, v} <> rev, "", NeedNext{}} <> rest, done}}
    case _:
      None{}

def close_arr(
  stack: List<&2, Frame>, done: Maybe<&2, Json>
) -> Maybe<&2, Builder>:
  match stack:
    case FArr{rev, NeedOpen{}} <> rest:
      add(JArr{from_rev(rev)}, rest, done)
    case FArr{rev, NeedNext{}} <> rest:
      add(JArr{from_rev(rev)}, rest, done)
    case _:
      None{}

def close_obj(
  stack: List<&2, Frame>, done: Maybe<&2, Json>
) -> Maybe<&2, Builder>:
  match stack:
    case FObj{rev, _, NeedOpen{}} <> rest:
      add(JObj{from_rev(rev)}, rest, done)
    case FObj{rev, _, NeedNext{}} <> rest:
      add(JObj{from_rev(rev)}, rest, done)
    case _:
      None{}

# A string is a key where an object expects one, else a value.
def key_or_value(
  s: String, +stack: List<&2, Frame>, done: Maybe<&2, Json>
) -> Maybe<&2, Builder>:
  match stack:
    case FObj{rev, _, NeedOpen{}} <> rest:
      Some{Builder{FObj{rev, s, NeedColon{}} <> rest, done}}
    case FObj{rev, _, NeedItem{}} <> rest:
      Some{Builder{FObj{rev, s, NeedColon{}} <> rest, done}}
    case _:
      add(JStr{s}, stack, done)

def colon(stack: List<&2, Frame>, done: Maybe<&2, Json>) -> Maybe<&2, Builder>:
  match stack:
    case FObj{rev, k, NeedColon{}} <> rest:
      Some{Builder{FObj{rev, k, NeedValue{}} <> rest, done}}
    case _:
      None{}

def comma(stack: List<&2, Frame>, done: Maybe<&2, Json>) -> Maybe<&2, Builder>:
  match stack:
    case FArr{rev, NeedNext{}} <> rest:
      Some{Builder{FArr{rev, NeedItem{}} <> rest, done}}
    case FObj{rev, k, NeedNext{}} <> rest:
      Some{Builder{FObj{rev, k, NeedItem{}} <> rest, done}}
    case _:
      None{}

# One token's effect on the open containers; None rejects the input.
def step(
  t: Tok, stack: List<&2, Frame>, done: Maybe<&2, Json>
) -> Maybe<&2, Builder>:
  match t:
    case TLBrack{}:
      Some{Builder{FArr{[], NeedOpen{}} <> stack, done}}
    case TLBrace{}:
      Some{Builder{FObj{[], "", NeedOpen{}} <> stack, done}}
    case TRBrack{}:
      close_arr(stack, done)
    case TRBrace{}:
      close_obj(stack, done)
    case TColon{}:
      colon(stack, done)
    case TComma{}:
      comma(stack, done)
    case TStr{s}:
      key_or_value(s, stack, done)
    case TNum{s}:
      add(JNum{s}, stack, done)
    case TTrue{}:
      add(JBool{True{}}, stack, done)
    case TFalse{}:
      add(JBool{False{}}, stack, done)
    case TNull{}:
      add(JNull{}, stack, done)
    case TBad{}:
      None{}

# Feeds the tokens to the builder, stopping at the first rejection. The
# input is valid when every container closed around one top-level value.
def build(toks: List<&2, Tok>, b: Maybe<&2, Builder>) -> Maybe<&2, Json>:
  match toks b:
    case _ None{}:
      None{}
    case [] Some{Builder{[], Some{v}}}:
      Some{v}
    case [] Some{_}:
      None{}
    case t <> rest Some{Builder{stack, done}}:
      build(rest, step(t, stack, done))

def parse(s: String) -> Maybe<&2, Json>:
  toks = List.reverse(&2, Tok, lex(s, Lexer{LNorm{}, []}))
  build(toks, Some{Builder{[], None{}}})
