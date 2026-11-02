# Every unit-test composition is a named input, exported to the independent parser.

import Base
import ../src/mime.bend as M
import ../src/codec.bend as C
import ../src/tools.bend as T
import ../src/jev.bend as Jev

type Case is Data:
  Attachment{}
  Injection{}
  Mixed{}
  Empty{}
  Unicode{}
  LiteralShort{}
  LiteralNested{}
  AsciiWords{}
  Ascii69{}
  Ascii70{}
  Ascii77{}
  Ascii79{}
  Ascii900{}
  ThreadTokens{}
  ReferenceTokens{}
  LongReferences{}
  MalformedIds{}
  ReferenceExact{}
  ReferenceOver{}
  ReferencesExact{}
  MandatoryOver{}
  IdGrammar{}
  KeptBcc{}
  HiddenBcc{}
  Utf8Text{}
  BoundaryCollision{}
  RawMessage{}
  HostileOriginal{}
  LiteralDisplay{}
  LongDisplay{}
  AsciiText{}
  NonUtf8Text{}
  LongUnicodeFilename{}
  LongAsciiFilename{}
  ShortAsciiFilename{}
  QuotedSemicolonFilename{}
  BackslashFilename{}
  ControlFilename{}
  LiteralFilename{}

def long_refs() -> String:
  "<root@x> " ++ String.repeat("<middle@x> ", 120n) ++ "<last1@x> <last2@x>"

def long_id(n: Nat, c: String) -> String:
  "<" ++ String.repeat(c, n) ++ "@x>"

def ordinary(subject: String, irt: String, refs: String) -> M.Draft:
  M.Draft{"a@x", ["b@y"], [], [], subject, "body", "D", "<m@x>", irt, refs, []}

def filename_draft(name: String) -> M.Draft:
  M.Draft{"a@example.invalid", ["b@example.invalid"], [], [], "Filename compatibility", "body", "Sat, 31 Oct 2026 12:00:00 +0000", "<filename@corpus.invalid>", "", "", [M.Attach{name, "application/octet-stream", C.utf8_encode("café😀")}]}

def tool_draft(keep: Bool) -> M.Draft:
  w : T.Want = T.Want{["A <a@x.com>"], ["c@y.com"], ["b@z.com"], "Subject", "Body", "<irt@x>",
    "<r@x>", [], False{}, False{}, Jev.Fresh{}, Jev.Off{}}
  T.draft_of(w, "me@my.org", T.stamp_of(1700000000, 1, 255), keep)

def draft(c: Case) -> M.Draft:
  match c:
    case Attachment{}:
      M.Draft{"Tester <tester@example.com>", ["José Q <jose@example.com>", "b@example.com"], [], [], "Résumé attached", "Line one\nligne deux é\n", "Sun, 27 Sep 2026 03:19:30 +0000", "<1@example.com>", "", "", [M.Attach{"notes.txt", "text/plain", "hello"}]}
    case Injection{}:
      M.Draft{"t@example.com", ["a@example.com"], [], [], "s", "b", "d", "<1@x>", "<x@y>\r\nBcc: evil@example.com", "", [M.Attach{"f.txt", "text/plain\r\nX-Evil: 1", "hi"}]}
    case Mixed{}:
      M.Draft{"Zoë Ñ <z@example.com>", [], ["c1@example.com", "\"Doe, J\" <j@x.com>", "<bare@x.com>"], ["hidden@example.com"], "plain subject", "a\rb\nc\r\nd=e é", "D", "<m@x>", "  <p@x>\r\n ", "<r1@x>  <r2@x>\t<r3@x>", [M.Attach{"résumé.pdf", "Application/PDF", "%PDF\u{FF}"}, M.Attach{"bad.bin", "x", ""}, M.Attach{"m.eml", "message/rfc822", "Subject: \u{E9}\r\n\r\nhi"}]}
    case Empty{}:
      M.Draft{"a@b.c", ["x@y.z"], [], [], "", "", "D", "<i@x>", "", "", []}
    case Unicode{}:
      ordinary(String.repeat("é", 80n), "", "")
    case LiteralShort{}:
      ordinary("=?x?=", "", "")
    case LiteralNested{}:
      ordinary("Re: =?UTF-8?B?SGFja2Vk?=", "", "")
    case AsciiWords{}:
      ordinary(String.repeat("one two ", 20n) ++ "end", "", "")
    case Ascii69{}:
      ordinary(String.repeat("a", 69n), "", "")
    case Ascii70{}:
      ordinary(String.repeat("a", 70n), "", "")
    case Ascii77{}:
      ordinary(String.repeat("a", 77n), "", "")
    case Ascii79{}:
      ordinary(String.repeat("a", 79n), "", "")
    case Ascii900{}:
      ordinary(String.repeat("a", 900n), "", "")
    case ThreadTokens{}:
      ordinary("s", "<a@x> (by relay)", "(note) <root@x> junk <a@x>")
    case ReferenceTokens{}:
      ordinary("s", "", "(note) <root@x> junk <a@x>")
    case LongReferences{}:
      ordinary("s", "", long_refs())
    case MalformedIds{}:
      ordinary("s", "(fake <comment@x>) <a@x> <bad> <two@@x> <space @x> <\u{E9}@x> <open", "")
    case ReferenceExact{}:
      ordinary("s", "", long_id(982n, "a"))
    case ReferenceOver{}:
      ordinary("s", "", long_id(983n, "a"))
    case ReferencesExact{}:
      ordinary("s", "", long_id(496n, "a") ++ " " ++ long_id(481n, "b"))
    case MandatoryOver{}:
      ordinary("s", "<reply@x>", long_id(336n, "a") ++ " " ++ long_id(336n, "b") ++ " " ++ long_id(336n, "c"))
    case IdGrammar{}:
      ordinary("s", "<bad<inner@x>> <a..b@x> <a@.x> <ok@[127.0.0.1]> <ok@[IPv6:abcd::1]> (nested (fake <n@x>)) \"quote <q@x>\" <end@x>", "")
    case KeptBcc{}:
      tool_draft(True{})
    case HiddenBcc{}:
      tool_draft(False{})
    case Utf8Text{}:
      M.Draft{"José <a@example.invalid>", ["b@example.invalid"], [], [], "UTF-8 attachment", "body", "Sat, 31 Oct 2026 12:00:00 +0000", "<utf8@corpus.invalid>", "", "", [M.Attach{"café.txt", "text/plain", C.utf8_encode("café")}]}
    case BoundaryCollision{}:
      M.Draft{"a@example.invalid", ["b@example.invalid"], [], [], "Attached original", "body", "Sat, 31 Oct 2026 12:00:00 +0000", "<collision@corpus.invalid>", "", "", [M.Attach{"original.eml", "message/rfc822", "Subject: original\r\n\r\n--B\r\nbody"}]}
    case RawMessage{}:
      M.Draft{"a@example.invalid", ["b@example.invalid"], [], [], "Attached original", "body", "Sat, 31 Oct 2026 12:00:00 +0000", "<raw@corpus.invalid>", "", "", [M.Attach{"original.eml", "message/rfc822", "Subject: original\r\n\r\nbody\r\n"}]}
    case HostileOriginal{}:
      M.Draft{"a@example.invalid", ["b@example.invalid"], [], [], "Hostile original preserved", "body", "Sat, 31 Oct 2026 12:00:00 +0000", "<hostile@corpus.invalid>", "", "", [M.Attach{"hostile.eml", "message/rfc822", "From: =?UTF-8?Q?Bob=0A=0Ahostile=0A?= <bob@example.invalid>\r\nSubject: original\r\n\r\nbody\r\n"}]}
    case LiteralDisplay{}:
      M.Draft{"=?UTF-8?B?SGFja2Vk?= <a@example.invalid>", ["b@example.invalid"], [], [], "Literal display", "body", "Sat, 31 Oct 2026 12:00:00 +0000", "<display@corpus.invalid>", "", "", []}
    case LongDisplay{}:
      M.Draft{String.repeat("é", 39n) ++ " <long.address@example.invalid>", ["b@example.invalid"], [], [], "Long display", "body", "Sat, 31 Oct 2026 12:00:00 +0000", "<longdisplay@corpus.invalid>", "", "", []}
    case AsciiText{}:
      M.Draft{"a@example.invalid", ["b@example.invalid"], [], [], "ASCII attachment", "body", "Sat, 31 Oct 2026 12:00:00 +0000", "<ascii@corpus.invalid>", "", "", [M.Attach{"notes.csv", "text/csv", "one,two\r\n"}]}
    case NonUtf8Text{}:
      M.Draft{"a@example.invalid", ["b@example.invalid"], [], [], "Unlabelled legacy attachment", "body", "Sat, 31 Oct 2026 12:00:00 +0000", "<legacy@corpus.invalid>", "", "", [M.Attach{"notes.txt", "text/plain", "caf\u{E9}"}]}
    case LongUnicodeFilename{}:
      filename_draft(String.repeat("é😀", 45n) ++ ".pdf")
    case LongAsciiFilename{}:
      filename_draft(String.repeat("a", 201n) ++ ".txt")
    case ShortAsciiFilename{}:
      filename_draft("Q1; final \"v2\"\\notes.txt")
    case QuotedSemicolonFilename{}:
      filename_draft("Q1; résumé \"v2\".pdf")
    case BackslashFilename{}:
      filename_draft("répertoire\\notes.txt")
    case LiteralFilename{}:
      filename_draft("=?UTF-8?B?SGk=?=.txt")
    case ControlFilename{}:
      filename_draft("résumé\r\nX-Evil: yes\t\u{0}.txt")

def boundary(c: Case) -> String:
  match c:
    case Attachment{}:
      "b0undary"
    case Injection{}:
      "b"
    case Mixed{}:
      "BB"
    case Empty{}:
      "unused"
    case _:
      "B"

def name(c: Case) -> String:
  match c:
    case Attachment{}:
      "Attachment"
    case Injection{}:
      "Injection"
    case Mixed{}:
      "Mixed"
    case Empty{}:
      "Empty"
    case Unicode{}:
      "Unicode"
    case LiteralShort{}:
      "LiteralShort"
    case LiteralNested{}:
      "LiteralNested"
    case AsciiWords{}:
      "AsciiWords"
    case Ascii69{}:
      "Ascii69"
    case Ascii70{}:
      "Ascii70"
    case Ascii77{}:
      "Ascii77"
    case Ascii79{}:
      "Ascii79"
    case Ascii900{}:
      "Ascii900"
    case ThreadTokens{}:
      "ThreadTokens"
    case ReferenceTokens{}:
      "ReferenceTokens"
    case LongReferences{}:
      "LongReferences"
    case MalformedIds{}:
      "MalformedIds"
    case ReferenceExact{}:
      "ReferenceExact"
    case ReferenceOver{}:
      "ReferenceOver"
    case ReferencesExact{}:
      "ReferencesExact"
    case MandatoryOver{}:
      "MandatoryOver"
    case IdGrammar{}:
      "IdGrammar"
    case KeptBcc{}:
      "KeptBcc"
    case HiddenBcc{}:
      "HiddenBcc"
    case Utf8Text{}:
      "Utf8Text"
    case BoundaryCollision{}:
      "BoundaryCollision"
    case RawMessage{}:
      "RawMessage"
    case HostileOriginal{}:
      "HostileOriginal"
    case LiteralDisplay{}:
      "LiteralDisplay"
    case LongDisplay{}:
      "LongDisplay"
    case AsciiText{}:
      "AsciiText"
    case NonUtf8Text{}:
      "NonUtf8Text"
    case LongUnicodeFilename{}:
      "LongUnicodeFilename"
    case LongAsciiFilename{}:
      "LongAsciiFilename"
    case ShortAsciiFilename{}:
      "ShortAsciiFilename"
    case QuotedSemicolonFilename{}:
      "QuotedSemicolonFilename"
    case BackslashFilename{}:
      "BackslashFilename"
    case LiteralFilename{}:
      "LiteralFilename"
    case ControlFilename{}:
      "ControlFilename"

def subject.of(d: M.Draft) -> String:
  M.Draft{_, _, _, _, s, _, _, _, _, _, _} = d
  s

def subject(c: Case) -> String:
  subject.of(draft(c))

def wire(+c: Case) -> String:
  M.compose(draft(c), boundary(c))

def all() -> List<&2, Case>:
  [Attachment{}, Injection{}, Mixed{}, Empty{}, Unicode{}, LiteralShort{}, LiteralNested{}, AsciiWords{}, Ascii69{}, Ascii70{}, Ascii77{}, Ascii79{}, Ascii900{}, ThreadTokens{}, ReferenceTokens{}, LongReferences{}, MalformedIds{}, ReferenceExact{}, ReferenceOver{}, ReferencesExact{}, MandatoryOver{}, IdGrammar{}, KeptBcc{}, HiddenBcc{}, Utf8Text{}, BoundaryCollision{}, RawMessage{}, HostileOriginal{}, LiteralDisplay{}, LongDisplay{}, AsciiText{}, NonUtf8Text{}, LongUnicodeFilename{}, LongAsciiFilename{}, ShortAsciiFilename{}, QuotedSemicolonFilename{}, BackslashFilename{}, ControlFilename{}, LiteralFilename{}]
