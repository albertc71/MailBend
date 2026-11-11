# Strict, command-scoped evidence for the opt-in folder overview.

import Base
import ./codec.bend as C
import ./imap.bend as I
import ./policy.bend as Policy

type UnknownReason is Data:
  NotSelectable{}
  NotReturned{}
  InvalidResponse{}
  CommandFailed{}
  NotAttempted{}
  CapabilityChanged{}
  HelperFailure{}
  ScopeChanged{}
  ResultLimit{}

type Modseq is Data:
  Unsupported{}
  NotPersistent{}
  Highest{decimal: String}

type Count is Data:
  Unknown{reason: UnknownReason}
  Known{messages: U32, unseen: U32, uidnext: U32, uidvalidity: U32, modseq: Modseq}

type Entry is Data:
  Entry{folder: I.Folder, count: Count}

type Method is Data:
  NoCounts{}
  ListStatus{}
  Status{}

type Reason is Data:
  Complete{}
  IncompleteStatus{}
  CapabilityLost{}
  ScopeLost{}
  Refused{}
  HelperLost{}
  TooLarge{}

type Overview is Data:
  Overview{entries: List<&2, Entry>, method: Method, reason: Reason}

type Discovery is Data:
  Discovery{caps: List<&2, String>, folders: List<&2, I.Folder>}

# Only one parenthesized list is legal in LIST and STATUS responses.
# Atoms remain atoms, including NIL when it is a mailbox name.
type Mode is Data:
  Space{}
  Atom{}
  Quoted{}
  Escaped{}
  End{}

type Value is Data:
  VAtom{text: String}
  VQuoted{text: String}
  VLiteral{text: String}
  VList{items: List<&2, Value>}

type Lexer is Data:
  Lexer{mode: Mode, word: String, root: List<&2, Value>,
    nested: List<&2, Value>, inside: Bool, literals: List<&2, String>}

def atom_char(+c: Char) -> Bool:
  I.quota_atom(c) || Char.is_eq(c, '\\')

def atom_text(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      I.quota_atom(c) && atom_text(t)

def lexer_push(inside: Bool, mode: Mode, v: Value, root: List<&2, Value>,
  nested: List<&2, Value>, literals: List<&2, String>) -> Lexer:
  match inside:
    case True{}:
      Lexer{mode, "", root, v <> nested, True{}, literals}
    case False{}:
      Lexer{mode, "", v <> root, nested, False{}, literals}

def lexer_close(q: Lexer) -> Maybe<&2, Lexer>:
  match q:
    case Lexer{mode, word, root, nested, True{}, literals}:
      Some{Lexer{End{}, "", VList{List.reverse(&2, Value, nested)} <> root,
        [], False{}, literals}}
    case _:
      None{}

def lexer_open(inside: Bool, root: List<&2, Value>, literals: List<&2, String>)
  -> Maybe<&2, Lexer>:
  match inside:
    case True{}:
      None{}
    case False{}:
      Some{Lexer{Space{}, "", root, [], True{}, literals}}

def lexer_literal(literals: List<&2, String>, inside: Bool,
  root: List<&2, Value>, nested: List<&2, Value>) -> Maybe<&2, Lexer>:
  match literals:
    case h <> t:
      Some{lexer_push(inside, End{}, VLiteral{h}, root, nested, t)}
    case Nil{}:
      None{}

def lexer_other(literal: Bool, +c: Char, root: List<&2, Value>,
  nested: List<&2, Value>, inside: Bool, literals: List<&2, String>) -> Maybe<&2, Lexer>:
  match literal:
    case True{}:
      lexer_literal(literals, inside, root, nested)
    case False{}:
      Bool.pick(Maybe<&2, Lexer>, atom_char(c),
        Some{Lexer{Atom{}, SCon{c, SNil{}}, root, nested, inside, literals}}, None{})

def lexer_plain(c: Char, q: Lexer) -> Maybe<&2, Lexer>:
  Lexer{mode, word, root, nested, inside, literals} = q
  match c:
    case ' ':
      Some{Lexer{Space{}, "", root, nested, inside, literals}}
    case ')':
      lexer_close(Lexer{mode, word, root, nested, inside, literals})
    case '(':
      lexer_open(inside, root, literals)
    case '"':
      Some{Lexer{Quoted{}, "", root, nested, inside, literals}}
    case +c:
      lexer_other(Char.is_eq(c, I.lit_mark()), c, root, nested, inside, literals)

def lexer_step(+c: Char, q: Lexer) -> Maybe<&2, Lexer>:
  match q:
    case Lexer{Space{}, word, root, nested, inside, literals}:
      lexer_plain(c, Lexer{Space{}, word, root, nested, inside, literals})
    case Lexer{End{}, word, root, nested, inside, literals}:
      match c:
        case ' ':
          Some{Lexer{Space{}, "", root, nested, inside, literals}}
        case ')':
          lexer_close(Lexer{End{}, word, root, nested, inside, literals})
        case _:
          None{}
    case Lexer{Atom{}, word, root, nested, inside, literals}:
      match c:
        case ' ':
          Some{lexer_push(inside, Space{}, VAtom{String.reverse(word)}, root, nested, literals)}
        case ')':
          lexer_close(lexer_push(inside, End{}, VAtom{String.reverse(word)}, root, nested, literals))
        case +c:
          Bool.pick(Maybe<&2, Lexer>, atom_char(c),
            Some{Lexer{Atom{}, SCon{c, word}, root, nested, inside, literals}}, None{})
    case Lexer{Quoted{}, word, root, nested, inside, literals}:
      match c:
        case '"':
          Some{lexer_push(inside, End{}, VQuoted{String.reverse(word)}, root, nested, literals)}
        case '\\':
          Some{Lexer{Escaped{}, word, root, nested, inside, literals}}
        case +c:
          Bool.pick(Maybe<&2, Lexer>, C.between(C.u(c), 32, 126),
            Some{Lexer{Quoted{}, SCon{c, word}, root, nested, inside, literals}}, None{})
    case Lexer{Escaped{}, word, root, nested, inside, literals}:
      Bool.pick(Maybe<&2, Lexer>, Char.is_eq(c, '"') || Char.is_eq(c, '\\'),
        Some{Lexer{Quoted{}, SCon{c, word}, root, nested, inside, literals}}, None{})

def lexer_finish(q: Lexer) -> Maybe<&2, List<&2, Value>>:
  match q:
    case Lexer{Atom{}, word, root, _, False{}, Nil{}}:
      Some{List.reverse(&2, Value, VAtom{String.reverse(word)} <> root)}
    case Lexer{Space{}, _, root, _, False{}, Nil{}}:
      Some{List.reverse(&2, Value, root)}
    case Lexer{End{}, _, root, _, False{}, Nil{}}:
      Some{List.reverse(&2, Value, root)}
    case _:
      None{}

def lexer_go(s: String, q: Maybe<&2, Lexer>) -> Maybe<&2, List<&2, Value>>:
  match s q:
    case SNil{} Some{q}:
      lexer_finish(q)
    case SCon{c, t} Some{q}:
      lexer_go(t, lexer_step(c, q))
    case _ None{}:
      None{}

def tokens(text: String, literals: List<&2, String>) -> Maybe<&2, List<&2, Value>>:
  lexer_go(text, Some{Lexer{Space{}, "", [], [], False{}, literals}})

def scalars_valid(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+c, t}:
      +n = C.u(c)
      C.between(n, 32, 1114111) && Bool.not(C.between(n, 127, 159)) &&
        Bool.not(C.between(n, 55296, 57343)) && scalars_valid(t)

def inbox_name(s: String) -> Bool:
  match s:
    case SCon{+i, SCon{+n, SCon{+b, SCon{+o, SCon{+x, SNil{}}}}}}:
      (Char.is_eq(i, 'I') || Char.is_eq(i, 'i')) &&
        (Char.is_eq(n, 'N') || Char.is_eq(n, 'n')) &&
        (Char.is_eq(b, 'B') || Char.is_eq(b, 'b')) &&
        (Char.is_eq(o, 'O') || Char.is_eq(o, 'o')) &&
        (Char.is_eq(x, 'X') || Char.is_eq(x, 'x'))
    case _:
      False{}

def canonical_name(+wire: String) -> Maybe<&2, String>:
  +name = I.mutf7_decode(wire)
  valid = Bool.not(String.is_empty(name)) && U32.is_le(C.utf8_len(name), 1024) &&
    scalars_valid(name) && String.eq(I.mutf7_encode(name), wire)
  Bool.pick(Maybe<&2, String>, valid,
    Some{Bool.pick(String, inbox_name(name), "INBOX", name)}, None{})

def atom_name(valid: Bool, s: String) -> Maybe<&2, String>:
  match valid:
    case True{}:
      canonical_name(s)
    case False{}:
      None{}

def name_value(v: Value) -> Maybe<&2, String>:
  match v:
    case VQuoted{s}:
      canonical_name(s)
    case VLiteral{s}:
      canonical_name(s)
    case VAtom{+s}:
      atom_name(atom_text(s), s)
    case _:
      None{}

def delimiter(v: Value) -> Maybe<&2, String>:
  match v:
    case VAtom{s}:
      Bool.pick(Maybe<&2, String>, String.eq(String.to_upper(s), "NIL"), Some{""}, None{})
    case VQuoted{SCon{+c, SNil{}}}:
      Bool.pick(Maybe<&2, String>, C.between(C.u(c), 32, 126), Some{SCon{c, SNil{}}}, None{})
    case _:
      None{}

def attribute(+s: String) -> Bool:
  match s:
    case SCon{'\\', +t}:
      Bool.not(String.is_empty(t)) && atom_text(t)
    case _:
      False{}

def attribute_put(valid: Bool, s: String, rest: Maybe<&2, List<&2, String>>)
  -> Maybe<&2, List<&2, String>>:
  match valid rest:
    case True{} Some{rest}:
      Some{s <> rest}
    case _ _:
      None{}

def attributes(vs: List<&2, Value>) -> Maybe<&2, List<&2, String>>:
  match vs:
    case Nil{}:
      Some{[]}
    case VAtom{+s} <> t:
      attribute_put(attribute(s), s, attributes(t))
    case _:
      None{}

def folder_parts(attrs: Maybe<&2, List<&2, String>>, delim: Maybe<&2, String>,
  name: Maybe<&2, String>) -> Maybe<&2, I.Folder>:
  match attrs delim name:
    case Some{attrs} Some{delim} Some{name}:
      Some{I.Folder{name, delim, attrs}}
    case _ _ _:
      None{}

def folder(vs: Maybe<&2, List<&2, Value>>) -> Maybe<&2, I.Folder>:
  match vs:
    case Some{VList{attrs} <> d <> n <> Nil{}}:
      folder_parts(attributes(attrs), delimiter(d), name_value(n))
    case _:
      None{}

def first_word(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{' ', t}:
      ""
    case SCon{'\t', t}:
      ""
    case SCon{'\r', t}:
      ""
    case SCon{'\n', t}:
      ""
    case SCon{c, t}:
      SCon{c, first_word(t)}

def kind(text: String) -> String:
  match text:
    case SCon{'*', body}:
      String.to_upper(first_word(String.trim(body)))
    case _:
      ""

def window(lines: List<&2, I.RLine>, +tag: String, stop: Bool) -> List<&2, I.RLine>:
  match lines stop:
    case Nil{} _:
      []
    case _ True{}:
      []
    case I.RLine{+text, lits} <> t False{}:
      +last = String.starts_with(text, tag)
      List.filter.put(I.RLine, I.RLine{text, lits}, window(t, tag, last), Bool.not(last))

def replies(lines: List<&2, I.RLine>, +n: U32) -> List<&2, I.RLine>:
  window(I.after_line(lines, I.tag((n - 1 : U32)) ++ " ", U32.is_eq(n, 1)),
    I.tag(n) ++ " ", False{})

def has_name(fs: List<&2, I.Folder>, +name: String) -> Bool:
  match fs:
    case Nil{}:
      False{}
    case I.Folder{other, _, _} <> t:
      String.eq(other, name) || has_name(t, name)

def listed_put(found: Maybe<&2, I.Folder>, fs: List<&2, I.Folder>, left: U32)
  -> Maybe<&2, List<&2, I.Folder>>:
  match found:
    case Some{+f}:
      I.Folder{+name, _, _} = f
      Bool.pick(Maybe<&2, List<&2, I.Folder>>, U32.is_gt(left, 0) && Bool.not(has_name(fs, name)),
        Some{f <> fs}, None{})
    case None{}:
      None{}

type ListStep is Data:
  ListStep{folders: Maybe<&2, List<&2, I.Folder>>, left: U32}

def list_line(+text: String, lits: List<&2, String>) -> Maybe<&2, I.Folder>:
  Bool.pick(Maybe<&2, I.Folder>, I.upper_starts(text, "* LIST "),
    folder(tokens(String.drop(text, 7n), lits)), None{})

def listed_step(hit: Bool, text: String, lits: List<&2, String>,
  fs: List<&2, I.Folder>, +left: U32) -> ListStep:
  match hit:
    case True{}:
      ListStep{listed_put(list_line(text, lits), fs, left),
        (left - 1 : U32)}
    case False{}:
      ListStep{Some{fs}, left}

def listed_go(lines: List<&2, I.RLine>, fs: Maybe<&2, List<&2, I.Folder>>, left: U32)
  -> Maybe<&2, List<&2, I.Folder>>:
  match lines fs:
    case Nil{} Some{fs}:
      Some{List.reverse(&2, I.Folder, fs)}
    case I.RLine{+text, lits} <> t Some{fs}:
      ListStep{next, left} = listed_step(String.eq(kind(text), "LIST"), text, lits, fs, left)
      listed_go(t, next, left)
    case _ None{}:
      None{}

def listed(lines: List<&2, I.RLine>) -> Maybe<&2, List<&2, I.Folder>>:
  listed_go(lines, Some{[]}, 100)

def cap_words(vs: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match vs:
    case Nil{}:
      Some{[]}
    case +s <> t:
      attribute_put(Bool.not(String.is_empty(s)) && atom_text(s), String.to_upper(s), cap_words(t))

def cap_line(+text: String, lits: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match lits:
    case Nil{}:
      Bool.pick(Maybe<&2, List<&2, String>>, I.upper_starts(text, "* CAPABILITY ") &&
        Bool.not(String.is_empty(String.drop(text, 13n))),
        cap_words(String.split(String.drop(text, 13n), ' ')), None{})
    case _:
      None{}

def cap_step(hit: Bool, seen: Bool, text: String, lits: List<&2, String>,
  found: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match hit seen:
    case True{} False{}:
      cap_line(text, lits)
    case True{} True{}:
      None{}
    case False{} _:
      found

def caps_go(lines: List<&2, I.RLine>, found: Maybe<&2, List<&2, String>>, +seen: Bool)
  -> Maybe<&2, List<&2, String>>:
  match lines:
    case Nil{}:
      found
    case I.RLine{+text, lits} <> t:
      +hit = String.eq(kind(text), "CAPABILITY")
      caps_go(t, cap_step(hit, seen, text, lits, found), seen || hit)

def caps(+lines: List<&2, I.RLine>) -> Maybe<&2, List<&2, String>>:
  Bool.pick(Maybe<&2, List<&2, String>>, String.eq(I.status(lines, 1), "OK"),
    caps_go(replies(lines, 1), None{}, False{}), None{})

def discovery_parts(caps: Maybe<&2, List<&2, String>>, ok: Bool,
  fs: Maybe<&2, List<&2, I.Folder>>) -> Maybe<&2, Discovery>:
  match caps ok fs:
    case Some{caps} True{} Some{fs}:
      Some{Discovery{caps, fs}}
    case _ _ _:
      None{}

def discovery(+lines: List<&2, I.RLine>) -> Maybe<&2, Discovery>:
  discovery_parts(caps(lines), String.eq(I.status(lines, 2), "OK"), listed(replies(lines, 2)))

def folder_name(f: I.Folder) -> String:
  I.Folder{name, _, _} = f
  name

def sorted(fs: List<&2, I.Folder>) -> List<&2, I.Folder>:
  List.sort(~I.Folder, ~(a => b => String.is_le(folder_name(a), folder_name(b))), fs)

def selectable_names(fs: List<&2, I.Folder>) -> List<&2, String>:
  match fs:
    case Nil{}:
      []
    case I.Folder{name, _, attrs} <> t:
      List.filter.put(String, name, selectable_names(t), Policy.selectable(attrs))

# Identity is parsed separately so malformed counter data can invalidate
# its own mailbox without discarding another mailbox's valid evidence.
def name_prefix(s: String, q: Maybe<&2, Lexer>) -> Maybe<&2, String>:
  match s q:
    case _ Some{Lexer{End{}, _, v <> Nil{}, _, False{}, _}}:
      name_value(v)
    case SNil{} Some{Lexer{Atom{}, word, Nil{}, _, False{}, _}}:
      name_value(VAtom{String.reverse(word)})
    case SCon{' ', t} Some{Lexer{Atom{}, word, Nil{}, _, False{}, _}}:
      name_value(VAtom{String.reverse(word)})
    case SCon{c, t} Some{q}:
      name_prefix(t, lexer_step(c, q))
    case _ _:
      None{}

def digits(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      C.between(C.u(c), 48, 57) && digits(t)

def trim_zero(s: String) -> String:
  match s:
    case SNil{}:
      "0"
    case SCon{'0', t}:
      trim_zero(t)
    case _:
      s

def decimal(+s: String) -> Maybe<&2, String>:
  Bool.pick(Maybe<&2, String>, Bool.not(String.is_empty(s)) && digits(s), Some{trim_zero(s)}, None{})

def decimal_le(+value: String, +limit: String) -> Bool:
  +n = U32.from_nat(String.length(value))
  +bound = U32.from_nat(String.length(limit))
  U32.is_lt(n, bound) || (U32.is_eq(n, bound) && String.is_le(value, limit))

type Field is Data:
  Field{key: String, value: String}

def field_named(fs: List<&2, Field>, +want: String) -> Maybe<&2, String>:
  match fs:
    case Nil{}:
      None{}
    case Field{key, value} <> t:
      Bool.pick(Maybe<&2, String>, String.eq(key, want), Some{value}, field_named(t, want))

def fields_put(+key: String, value: Maybe<&2, String>, rest: Maybe<&2, List<&2, Field>>,
  modseq: Bool) -> Maybe<&2, List<&2, Field>>:
  match value rest:
    case Some{value} Some{+rest}:
      allowed = String.eq(key, "MESSAGES") || String.eq(key, "UNSEEN") ||
        String.eq(key, "UIDNEXT") || String.eq(key, "UIDVALIDITY") ||
        (modseq && String.eq(key, "HIGHESTMODSEQ"))
      Bool.pick(Maybe<&2, List<&2, Field>>, allowed && Bool.not(Maybe.is_some(&2, String,
        field_named(rest, key))), Some{Field{key, value} <> rest}, None{})
    case _ _:
      None{}

def fields(vs: List<&2, Value>, +modseq: Bool) -> Maybe<&2, List<&2, Field>>:
  match vs:
    case Nil{}:
      Some{[]}
    case VAtom{key} <> VAtom{value} <> t:
      fields_put(String.to_upper(key), decimal(value), fields(t, modseq), modseq)
    case _:
      None{}

def field_num(value: Maybe<&2, String>) -> Maybe<&2, U32>:
  match value:
    case Some{s}:
      I.quota_number(I.VAtom{s})
    case None{}:
      None{}

def modseq_value(requested: Bool, value: Maybe<&2, String>) -> Maybe<&2, Modseq>:
  match requested value:
    case False{} None{}:
      Some{Unsupported{}}
    case True{} Some{+s}:
      Bool.pick(Maybe<&2, Modseq>, decimal_le(s, "9223372036854775807"),
        Some{Bool.pick(Modseq, String.eq(s, "0"), NotPersistent{}, Highest{s})}, None{})
    case _ _:
      None{}

def known_parts(m: Maybe<&2, U32>, u: Maybe<&2, U32>, next: Maybe<&2, U32>,
  uidv: Maybe<&2, U32>, modseq: Maybe<&2, Modseq>) -> Maybe<&2, Count>:
  match m u next uidv modseq:
    case Some{+m} Some{+u} Some{+next} Some{+uidv} Some{modseq}:
      Bool.pick(Maybe<&2, Count>, U32.is_le(u, m) && U32.is_gt(next, 0) && U32.is_gt(uidv, 0),
        Some{Known{m, u, next, uidv, modseq}}, None{})
    case _ _ _ _ _:
      None{}

def count_fields(fs: Maybe<&2, List<&2, Field>>, modseq: Bool) -> Maybe<&2, Count>:
  match fs:
    case Some{+fs}:
      known_parts(field_num(field_named(fs, "MESSAGES")), field_num(field_named(fs, "UNSEEN")),
        field_num(field_named(fs, "UIDNEXT")), field_num(field_named(fs, "UIDVALIDITY")),
        modseq_value(modseq, field_named(fs, "HIGHESTMODSEQ")))
    case None{}:
      None{}

def count_values(vs: Maybe<&2, List<&2, Value>>, +modseq: Bool) -> Maybe<&2, Count>:
  match vs:
    case Some{name <> VList{pairs} <> Nil{}}:
      count_fields(fields(pairs, modseq), modseq)
    case _:
      None{}

type Record is Data:
  Record{name: Maybe<&2, String>, count: Maybe<&2, Count>}

def status_record(valid: Bool, +text: String, +lits: List<&2, String>, modseq: Bool) -> Record:
  match valid:
    case True{}:
      Record{name_prefix(text, Some{Lexer{Space{}, "", [], [], False{}, lits}}),
        count_values(tokens(text, lits), modseq)}
    case False{}:
      Record{None{}, None{}}

def record_put(hit: Bool, +text: String, lits: List<&2, String>,
  modseq: Bool, rest: List<&2, Record>) -> List<&2, Record>:
  match hit:
    case True{}:
      status_record(I.upper_starts(text, "* STATUS "), String.drop(text, 9n), lits, modseq) <> rest
    case False{}:
      rest

def records(lines: List<&2, I.RLine>, +modseq: Bool) -> List<&2, Record>:
  match lines:
    case Nil{}:
      []
    case I.RLine{+text, lits} <> t:
      record_put(String.eq(kind(text), "STATUS"), text, lits, modseq, records(t, modseq))

def record_assigned(r: Record, fs: List<&2, I.Folder>) -> Bool:
  match r:
    case Record{Some{name}, _}:
      has_name(fs, name)
    case _:
      False{}

def assigned(rs: List<&2, Record>, +fs: List<&2, I.Folder>) -> Bool:
  match rs:
    case Nil{}:
      True{}
    case r <> t:
      record_assigned(r, fs) && assigned(t, fs)

def record_named(r: Record, want: String) -> Bool:
  match r:
    case Record{Some{name}, _}:
      String.eq(name, want)
    case _:
      False{}

def matching(rs: List<&2, Record>, +want: String) -> List<&2, Record>:
  match rs:
    case Nil{}:
      []
    case +r <> t:
      List.filter.put(Record, r, matching(t, want), record_named(r, want))

def matched(rs: List<&2, Record>) -> Count:
  match rs:
    case Nil{}:
      Unknown{NotReturned{}}
    case Record{_, Some{count}} <> Nil{}:
      count
    case _:
      Unknown{InvalidResponse{}}

def unknown_count(selectable: Bool, reason: UnknownReason) -> Count:
  Bool.pick(Count, selectable, Unknown{reason}, Unknown{NotSelectable{}})

def unknown_entries(fs: List<&2, I.Folder>, +reason: UnknownReason) -> List<&2, Entry>:
  match fs:
    case Nil{}:
      []
    case +f <> t:
      I.Folder{_, _, attrs} = f
      Entry{f, unknown_count(Policy.selectable(attrs), reason)} <> unknown_entries(t, reason)

def evidence_count(selectable: Bool, valid: Bool, rs: List<&2, Record>, name: String) -> Count:
  match selectable valid:
    case False{} _:
      Unknown{NotSelectable{}}
    case True{} False{}:
      Unknown{InvalidResponse{}}
    case True{} True{}:
      matched(matching(rs, name))

def evidence_entries(fs: List<&2, I.Folder>, +rs: List<&2, Record>, +valid: Bool)
  -> List<&2, Entry>:
  match fs:
    case Nil{}:
      []
    case +f <> t:
      I.Folder{name, _, attrs} = f
      Entry{f, evidence_count(Policy.selectable(attrs), valid, rs, name)} <> evidence_entries(t, rs, valid)

def all_known(es: List<&2, Entry>) -> Bool:
  match es:
    case Nil{}:
      True{}
    case Entry{_, Known{m, u, n, v, q}} <> t:
      all_known(t)
    case Entry{_, Unknown{NotSelectable{}}} <> t:
      all_known(t)
    case _:
      False{}

def same_bool(a: Bool, +b: Bool) -> Bool:
  Bool.pick(Bool, a, b, Bool.not(b))

def same_scope(a: List<&2, I.Folder>, b: List<&2, I.Folder>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case I.Folder{x, _, attrs} <> xs I.Folder{y, _, other} <> ys:
      String.eq(x, y) && same_bool(Policy.selectable(attrs), Policy.selectable(other)) && same_scope(xs, ys)
    case _ _:
      False{}

def scope_matches(fs: List<&2, I.Folder>, other: Maybe<&2, List<&2, I.Folder>>) -> Bool:
  match other:
    case Some{other}:
      same_scope(fs, sorted(other))
    case None{}:
      False{}

def overview(+es: List<&2, Entry>, method: Method) -> Overview:
  Overview{es, method, Bool.pick(Reason, all_known(es), Complete{}, IncompleteStatus{})}

def failed(fs: List<&2, I.Folder>, method: Method, unknown: UnknownReason, reason: Reason) -> Overview:
  Overview{unknown_entries(fs, unknown), method, reason}

def fast_evidence(scope_ok: Bool, +fs: List<&2, I.Folder>, +rs: List<&2, Record>) -> Overview:
  match scope_ok:
    case False{}:
      failed(fs, ListStatus{}, ScopeChanged{}, ScopeLost{})
    case True{}:
      overview(evidence_entries(fs, rs, assigned(rs, fs)), ListStatus{})

def fast_result(ok: Bool, +fs: List<&2, I.Folder>, +lines: List<&2, I.RLine>, modseq: Bool)
  -> Overview:
  match ok:
    case False{}:
      failed(fs, ListStatus{}, CommandFailed{}, Refused{})
    case True{}:
      +segment = replies(lines, 2)
      fast_evidence(scope_matches(fs, listed(segment)), fs, records(segment, modseq))

def single_count(status: String, +f: I.Folder, +rs: List<&2, Record>) -> Count:
  match status:
    case "OK":
      I.Folder{name, _, _} = f
      evidence_count(True{}, assigned(rs, [f]), rs, name)
    case "NO":
      Unknown{CommandFailed{}}
    case "BAD":
      Unknown{CommandFailed{}}
    case _:
      Unknown{NotAttempted{}}

type BatchStep is Data:
  BatchStep{entry: Entry, next: U32}

def batch_step(selectable: Bool, f: I.Folder, +lines: List<&2, I.RLine>, +n: U32,
  modseq: Bool) -> BatchStep:
  match selectable:
    case False{}:
      BatchStep{Entry{f, Unknown{NotSelectable{}}}, n}
    case True{}:
      +f = f
      BatchStep{Entry{f, single_count(I.status(lines, n), f, records(replies(lines, n), modseq))},
        (n + 1 : U32)}

def batch_entries(fs: List<&2, I.Folder>, +lines: List<&2, I.RLine>, n: U32, +modseq: Bool)
  -> List<&2, Entry>:
  match fs:
    case Nil{}:
      []
    case +f <> t:
      I.Folder{_, _, attrs} = f
      BatchStep{entry, next} = batch_step(Policy.selectable(attrs), f, lines, n, modseq)
      entry <> batch_entries(t, lines, next, modseq)

def batch_result(refused: Bool, es: List<&2, Entry>) -> Overview:
  match refused:
    case True{}:
      Overview{es, Status{}, Refused{}}
    case False{}:
      overview(es, Status{})

def selected_method(fast: Bool) -> Method:
  Bool.pick(Method, fast, ListStatus{}, Status{})

def capabilities_match(cs: Maybe<&2, List<&2, String>>, fast: Bool, modseq: Bool) -> Bool:
  match cs:
    case Some{+cs}:
      (Bool.not(fast) || I.has_cap(cs, "LIST-STATUS")) &&
        (Bool.not(modseq) || I.has_cap(cs, "CONDSTORE"))
    case None{}:
      False{}

def count_evidence(cap_ok: Bool, fast: Bool, fs: List<&2, I.Folder>,
  +lines: List<&2, I.RLine>, modseq: Bool, refused: Bool) -> Overview:
  match cap_ok fast:
    case False{} +fast:
      failed(fs, selected_method(fast), CapabilityChanged{}, CapabilityLost{})
    case True{} True{}:
      fast_result(String.eq(I.status(lines, 2), "OK"), fs, lines, modseq)
    case True{} False{}:
      batch_result(refused, batch_entries(fs, lines, 2, modseq))

def count_code(usable: Bool, refused: Bool, +fs: List<&2, I.Folder>, +fast: Bool,
  +modseq: Bool, out: String) -> Overview:
  match usable:
    case False{}:
      failed(fs, selected_method(fast), HelperFailure{}, HelperLost{})
    case True{}:
      +lines = I.frame(out)
      count_evidence(capabilities_match(caps(lines), fast, modseq), fast, fs, lines, modseq, refused)

def count_result(p: Policy.Proc, fs: List<&2, I.Folder>, fast: Bool, modseq: Bool) -> Overview:
  match p:
    case Policy.ProcOk{+code, out, _}:
      count_code(U32.is_eq(code, 0) || U32.is_eq(code, 5), U32.is_eq(code, 5), fs, fast, modseq, out)
    case _:
      failed(fs, selected_method(fast), HelperFailure{}, HelperLost{})

def unknown_name(reason: UnknownReason) -> String:
  match reason:
    case NotSelectable{}:
      "not_selectable"
    case NotReturned{}:
      "not_returned"
    case InvalidResponse{}:
      "invalid_response"
    case CommandFailed{}:
      "command_failed"
    case NotAttempted{}:
      "not_attempted"
    case CapabilityChanged{}:
      "capability_changed"
    case HelperFailure{}:
      "helper_failure"
    case ScopeChanged{}:
      "scope_changed"
    case ResultLimit{}:
      "result_limit"

def method_name(method: Method) -> String:
  match method:
    case NoCounts{}:
      "none"
    case ListStatus{}:
      "list_status"
    case Status{}:
      "status"

def reason_name(reason: Reason) -> String:
  match reason:
    case Complete{}:
      ""
    case IncompleteStatus{}:
      "incomplete_status"
    case CapabilityLost{}:
      "capability_changed"
    case ScopeLost{}:
      "scope_changed"
    case Refused{}:
      "command_failed"
    case HelperLost{}:
      "helper_failure"
    case TooLarge{}:
      "result_limit"

def complete(reason: Reason) -> Bool:
  match reason:
    case Complete{}:
      True{}
    case _:
      False{}

def entry_folders(es: List<&2, Entry>) -> List<&2, I.Folder>:
  match es:
    case Nil{}:
      []
    case Entry{f, _} <> t:
      f <> entry_folders(t)

def result_limit(result: Overview) -> Overview:
  Overview{entries, method, _} = result
  failed(entry_folders(entries), method, ResultLimit{}, TooLarge{})
