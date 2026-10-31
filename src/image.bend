# Still images for one classify request. A part is one Fate: Used holds the
# still, its pixels, its bytes and a Ref; Skipped holds a section, a name
# and a Reason. The assets map, the body-mode images key and the helper's
# --images flag are projections of that deck; the agent's images array is
# a projection of its Notes, which keep no bytes.

import Base
import ./codec.bend as C
import ./json.bend as J

type Reason is Data:
  Format{}
  Animated{}
  Dimensions{}
  FileSize{}
  OverCount{}
  OverBudget{}
  Unreadable{}
  NoRef{}
  Refused{}

type Format is Data:
  Png{}
  Jpeg{}

type Pixels is Data:
  Pixels{width: U32, height: U32}

type Ref is Data:
  Ref{token: String}

# A still that passed the byte checks and is waiting for a budget.
type Still is Data:
  Still{
    section: List<&2, U32>,
    name: String,
    format: Format,
    pixels: Pixels,
    data: String,
    metadata_removed_bytes: U32
  }

# Before the fetch. Fetch carries the BODY.PEEK window (size + 1).
type Pre is Data:
  Fetch{format: Format, max: U32}
  Omit{reason: Reason}

type Verdict is Data:
  Keep{still: Still}
  VDrop{section: List<&2, U32>, name: String, reason: Reason}

# What a request may carry. A skipped image has no constructor here.
type Sent is Data:
  Sent{still: Still, ref: Ref}

type Fate is Data:
  Used{sent: Sent}
  Skipped{section: List<&2, U32>, name: String, reason: Reason}

type Room is Data:
  Room{left_count: U32, left_bytes: U32}

type Admitted is Data:
  Take{still: Still, room: Room}
  Leave{section: List<&2, U32>, name: String, reason: Reason, room: Room}

def image_count_cap() -> U32:
  4

def image_file_cap() -> U32:
  1572864

def image_request_cap() -> U32:
  1572864

# The most image parts one batch fetches, whatever their fate. Each fetch
# is one read-only IMAP session.
def fetch_cap() -> U32:
  8

def min_side() -> U32:
  280

def max_side() -> U32:
  1568

def min_pixels() -> U32:
  78400

def max_pixels() -> U32:
  2458624

def reason_name(r: Reason) -> String:
  match r:
    case Format{}:
      "format"
    case Animated{}:
      "animated"
    case Dimensions{}:
      "dimensions"
    case FileSize{}:
      "file_size"
    case OverCount{}:
      "over_count"
    case OverBudget{}:
      "over_budget"
    case Unreadable{}:
      "unreadable"
    case NoRef{}:
      "ref"
    case Refused{}:
      "refused"

def format_name(f: Format) -> String:
  match f:
    case Png{}:
      "png"
    case Jpeg{}:
      "jpeg"

# 4 * ceil(n / 3). n that divides by 3 encodes with no padding.
def b64_len(+n: U32) -> U32:
  (4 * ((n + 2) / 3 : U32) : U32)

# Four images can add at most 4 * 3 extra pad bytes, and one image adds none.
def b64_slack() -> U32:
  (4 * (image_count_cap() - 1) : U32)

def mime_format.if(png: Bool, jpeg: Bool) -> Maybe<&2, Format>:
  match png jpeg:
    case True{} _:
      Some{Png{}}
    case False{} True{}:
      Some{Jpeg{}}
    case False{} False{}:
      None{}

def mime_format(+typ: String) -> Maybe<&2, Format>:
  mime_format.if(String.eq(typ, "image/png"),
    String.eq(typ, "image/jpeg") || String.eq(typ, "image/jpg"))

# n base64 characters with a CRLF after every 64 or more of them. MIME
# writes lines of at most 76 characters, and the size BODYSTRUCTURE gives
# counts their CRLFs.
def b64_lines_len(+n: U32) -> U32:
  (n + 2 * ((n + 63) / 64 : U32) : U32)

# The largest part fetched. base64 expands by 4/3 and MIME breaks it into
# lines, so its ceiling is the base64 of the decoded cap with room for a
# CRLF every 64 characters; the decoded cap is checked after the fetch
# (judge.still), and the request cap still counts unbroken base64
# (b64_len). Every other transfer encoding is at most the decoded cap.
def encoded_ceiling(encoding: String) -> U32:
  Bool.pick(U32, String.eq(encoding, "base64"), b64_lines_len(b64_len(image_file_cap())),
    image_file_cap())

def screen.empty(empty: Bool, big: Bool, f: Format, size: U32) -> Pre:
  match empty big:
    case True{} _:
      Omit{Unreadable{}}
    case False{} True{}:
      Omit{FileSize{}}
    case False{} False{}:
      Fetch{f, (size + 1 : U32)}

def screen.sized(f: Format, encoding: String, +size: U32) -> Pre:
  screen.empty(U32.is_zero(size), U32.is_gt(size, encoded_ceiling(encoding)), f, size)

def screen.of(m: Maybe<&2, Format>, encoding: String, size: U32) -> Pre:
  match m:
    case None{}:
      Omit{Format{}}
    case Some{f}:
      screen.sized(f, encoding, size)

def screen(typ: String, encoding: String, +size: U32) -> Pre:
  screen.of(mime_format(typ), encoding, size)

def side_ok(+n: U32) -> Bool:
  U32.is_ge(n, min_side()) && U32.is_le(n, max_side())

# Sides first: a pair outside 280..1568 is rejected before the multiply, so
# a huge u32 product cannot wrap into range.
def pixels_ok.sides(ok: Bool, w: U32, h: U32) -> Bool:
  match ok:
    case False{}:
      False{}
    case True{}:
      +prod = (w * h : U32)
      U32.is_ge(prod, min_pixels()) && U32.is_le(prod, max_pixels())

def pixels_ok(p: Pixels) -> Bool:
  Pixels{+w, +h} = p
  pixels_ok.sides(side_ok(w) && side_ok(h), w, h)

# Header walks. A corrupt deflate stream behind a legal header is not
# detected: the still is kept, and TypeSafe can still refuse it, which
# classify reports as refused after asking again without images.

type Parsed is Data:
  StillImage{pixels: Pixels}
  Moving{}
  WrongMagic{}
  Broken{}

def be_from(a: Char, b: Char, c: Char, d: Char) -> U32:
  ((C.u(a) << 24n) .|. (C.u(b) << 16n) .|. (C.u(c) << 8n) .|. C.u(d) : U32)

def be16_from(a: Char, b: Char) -> U32:
  ((C.u(a) << 8n) .|. C.u(b) : U32)

type Chunk is Data:
  Short{}
  Wide{}
  Ihdr{width: U32, height: U32, next: String}
  Actl{next: String}
  Idat{}
  Other{next: String}

def read_ihdr.bytes(data: String, len: U32) -> Chunk:
  match data:
    case SCon{a, SCon{b, SCon{c, SCon{d, SCon{e, SCon{f, SCon{g, SCon{h, rest}}}}}}}}:
      Ihdr{be_from(a, b, c, d), be_from(e, f, g, h),
        String.drop(rest, U32.to_nat((len - 4 : U32)))}
    case _:
      Short{}

def read_ihdr.if(ok: Bool, len: U32, data: String) -> Chunk:
  match ok:
    case False{}:
      Short{}
    case True{}:
      read_ihdr.bytes(data, len)

# PNG IHDR data is 13 bytes. Any other length is skipped and not walked.
def read_ihdr(+len: U32, data: String) -> Chunk:
  read_ihdr.if(U32.is_eq(len, 13), len, data)

# A length past the decoded cap is not skipped: dropping it would walk a
# lying field. The part is unreadable.
def read_other.if(wide: Bool, len: U32, data: String, actl: Bool) -> Chunk:
  match wide actl:
    case True{} _:
      Wide{}
    case False{} True{}:
      Actl{String.drop(data, U32.to_nat((len + 4 : U32)))}
    case False{} False{}:
      Other{String.drop(data, U32.to_nat((len + 4 : U32)))}

def read_other(+len: U32, data: String, actl: Bool) -> Chunk:
  read_other.if(U32.is_gt(len, image_file_cap()), len, data, actl)

def read_chunk.kind(idat: Bool, ihdr: Bool, actl: Bool, len: U32, data: String) -> Chunk:
  match idat ihdr actl:
    case True{} _ _:
      Idat{}
    case False{} True{} _:
      read_ihdr(len, data)
    case False{} False{} True{}:
      read_other(len, data, True{})
    case False{} False{} False{}:
      read_other(len, data, False{})

def read_chunk.head(len: U32, +typ: String, data: String) -> Chunk:
  read_chunk.kind(String.eq(typ, "IDAT"), String.eq(typ, "IHDR"), String.eq(typ, "acTL"), len,
    data)

def read_chunk(rest: String) -> Chunk:
  match rest:
    case SCon{a, SCon{b, SCon{c, SCon{d, SCon{e, SCon{f, SCon{g, SCon{h, data}}}}}}}}:
      read_chunk.head(be_from(a, b, c, d), SCon{e, SCon{f, SCon{g, SCon{h, SNil{}}}}}, data)
    case _:
      Short{}

def png_magic(s: String) -> Bool:
  match s:
    case SCon{a, SCon{b, SCon{c, SCon{d, SCon{e, SCon{f, SCon{g, SCon{h, _}}}}}}}}:
      U32.is_eq(C.u(a), 137) && U32.is_eq(C.u(b), 80) && U32.is_eq(C.u(c), 78) &&
        U32.is_eq(C.u(d), 71) && U32.is_eq(C.u(e), 13) && U32.is_eq(C.u(f), 10) &&
        U32.is_eq(C.u(g), 26) && U32.is_eq(C.u(h), 10)
    case _:
      False{}

def png_stuck(moving: Bool) -> Parsed:
  match moving:
    case True{}:
      Moving{}
    case False{}:
      Broken{}

def png_idat(moving: Bool, have: Bool, w: U32, h: U32) -> Parsed:
  match moving have:
    case True{} _:
      Moving{}
    case False{} False{}:
      Broken{}
    case False{} True{}:
      StillImage{Pixels{w, h}}

type PngPhase is Data:
  PngScan{rest: String, have: Bool, width: U32, height: U32, moving: Bool}
  PngGot{chunk: Chunk, have: Bool, width: U32, height: U32, moving: Bool}

def png_go(fuel: Nat, phase: PngPhase) -> Parsed:
  match fuel phase:
    case 0n PngScan{rest, have, w, h, moving}:
      png_stuck(moving)
    case 0n PngGot{chunk, have, w, h, moving}:
      png_stuck(moving)
    case 1n+f PngScan{rest, have, w, h, moving}:
      png_go(f, PngGot{read_chunk(rest), have, w, h, moving})
    case 1n+f PngGot{Short{}, have, w, h, moving}:
      png_stuck(moving)
    case 1n+f PngGot{Wide{}, have, w, h, moving}:
      png_stuck(moving)
    case 1n+f PngGot{Idat{}, have, w, h, moving}:
      png_idat(moving, have, w, h)
    case 1n+f PngGot{Ihdr{w2, h2, next}, have, w, h, moving}:
      png_go(f, PngScan{next, True{}, w2, h2, moving})
    case 1n+f PngGot{Actl{next}, have, w, h, moving}:
      png_go(f, PngScan{next, have, w, h, True{}})
    case 1n+f PngGot{Other{next}, have, w, h, moving}:
      png_go(f, PngScan{next, have, w, h, moving})

def judge.png.start(ok: Bool, fuel: Nat, bytes: String) -> Parsed:
  match ok:
    case False{}:
      WrongMagic{}
    case True{}:
      png_go(fuel, PngScan{String.drop(bytes, 8n), False{}, 0, 0, False{}})

def judge.png(fuel: Nat, +bytes: String) -> Parsed:
  judge.png.start(png_magic(bytes), fuel, bytes)

def jpeg_magic(s: String) -> Bool:
  match s:
    case SCon{a, SCon{b, _}}:
      U32.is_eq(C.u(a), 255) && U32.is_eq(C.u(b), 216)
    case _:
      False{}

type Mark is Data:
  Mark{code: U32, rest: String}

# `more` means the byte just read was 0xFF, so the next byte is fill or the
# marker. A failed read is not a marker.
def skip_ff(t: String, more: Bool, b: U32) -> Maybe<&2, Mark>:
  match t more:
    case _ False{}:
      Some{Mark{b, t}}
    case SNil{} True{}:
      None{}
    case SCon{+c, rest} True{}:
      +n = C.u(c)
      skip_ff(rest, U32.is_eq(n, 255), n)

def skip_ff_start(s: String) -> Maybe<&2, Mark>:
  match s:
    case SNil{}:
      None{}
    case SCon{c, t}:
      +n = C.u(c)
      skip_ff(t, U32.is_eq(n, 255), n)

def is_sof(+m: U32) -> Bool:
  U32.is_eq(m, 192) || U32.is_eq(m, 193) || U32.is_eq(m, 194) || U32.is_eq(m, 195) ||
    U32.is_eq(m, 197) || U32.is_eq(m, 198) || U32.is_eq(m, 199) || U32.is_eq(m, 201) ||
    U32.is_eq(m, 202) || U32.is_eq(m, 203) || U32.is_eq(m, 205) || U32.is_eq(m, 206) ||
    U32.is_eq(m, 207)

# RST0-7 and SOI carry no length. TEM (1) neither.
def standalone(+m: U32) -> Bool:
  U32.is_eq(m, 1) || (U32.is_ge(m, 208) && U32.is_le(m, 216))

type JpegStep is Data:
  JpegBad{}
  JpegImage{width: U32, height: U32}
  JpegNext{rest: String}

type Dim is Data:
  Dim{width: U32, height: U32}

def wh_of(after: String) -> Maybe<&2, Dim>:
  match after:
    case SCon{_, SCon{a, SCon{b, SCon{c, SCon{d, _}}}}}:
      Some{Dim{be16_from(c, d), be16_from(a, b)}}
    case _:
      None{}

def jpeg_sof.wh(m: Maybe<&2, Dim>) -> JpegStep:
  match m:
    case None{}:
      JpegBad{}
    case Some{Dim{w, h}}:
      JpegImage{w, h}

def jpeg_sof.body(ok: Bool, after: String) -> JpegStep:
  match ok:
    case False{}:
      JpegBad{}
    case True{}:
      jpeg_sof.wh(wh_of(after))

def jpeg_sof.len(len: U32, after: String) -> JpegStep:
  jpeg_sof.body(U32.is_ge(len, 7), after)

def jpeg_sof(rest: String) -> JpegStep:
  match rest:
    case SCon{hi, SCon{lo, after}}:
      jpeg_sof.len(((C.u(hi) << 8n) .|. C.u(lo) : U32), after)
    case _:
      JpegBad{}

def be16(s: String) -> U32:
  match s:
    case SCon{a, SCon{b, _}}:
      be16_from(a, b)
    case _:
      0

def has2(s: String) -> Bool:
  match s:
    case SCon{_, SCon{_, _}}:
      True{}
    case _:
      False{}

def jpeg_skip.fit(ok: Bool, len: U32, rest: String) -> JpegStep:
  match ok:
    case False{}:
      JpegBad{}
    case True{}:
      JpegNext{String.drop(rest, U32.to_nat(len))}

def jpeg_skip.len(+len: U32, rest: String) -> JpegStep:
  jpeg_skip.fit(U32.is_ge(len, 2) && U32.is_le(len, image_file_cap()), len, rest)

def jpeg_skip.at(ok: Bool, +rest: String) -> JpegStep:
  match ok:
    case False{}:
      JpegBad{}
    case True{}:
      jpeg_skip.len(be16(rest), rest)

def jpeg_skip(+rest: String) -> JpegStep:
  jpeg_skip.at(has2(rest), rest)

# EOI and SOS end the header walk. APP1 carries a length-prefixed payload.
def jpeg_marked.if(stop: Bool, alone: Bool, sof: Bool, rest: String) -> JpegStep:
  match stop alone sof:
    case True{} _ _:
      JpegBad{}
    case False{} True{} _:
      JpegNext{rest}
    case False{} False{} True{}:
      jpeg_sof(rest)
    case False{} False{} False{}:
      jpeg_skip(rest)

def jpeg_marked(+m: U32, rest: String) -> JpegStep:
  jpeg_marked.if(U32.is_eq(m, 217) || U32.is_eq(m, 218), standalone(m), is_sof(m), rest)

def jpeg_step.mark(m: Maybe<&2, Mark>) -> JpegStep:
  match m:
    case None{}:
      JpegBad{}
    case Some{Mark{b, rest}}:
      jpeg_marked(b, rest)

def jpeg_step.ff(is_ff: Bool, t: String) -> JpegStep:
  match is_ff:
    case False{}:
      JpegBad{}
    case True{}:
      jpeg_step.mark(skip_ff_start(t))

def jpeg_step(rest: String) -> JpegStep:
  match rest:
    case SNil{}:
      JpegBad{}
    case SCon{c, t}:
      jpeg_step.ff(U32.is_eq(C.u(c), 255), t)

type JPhase is Data:
  JScan{rest: String}
  JUse{step: JpegStep}

def jpeg_go(fuel: Nat, phase: JPhase) -> Parsed:
  match fuel phase:
    case 0n _:
      Broken{}
    case 1n+f JScan{rest}:
      jpeg_go(f, JUse{jpeg_step(rest)})
    case 1n+f JUse{JpegBad{}}:
      Broken{}
    case 1n+f JUse{JpegImage{w, h}}:
      StillImage{Pixels{w, h}}
    case 1n+f JUse{JpegNext{rest}}:
      jpeg_go(f, JScan{rest})

def judge.jpeg.start(ok: Bool, fuel: Nat, bytes: String) -> Parsed:
  match ok:
    case False{}:
      WrongMagic{}
    case True{}:
      jpeg_go(fuel, JScan{String.drop(bytes, 2n)})

def judge.jpeg(fuel: Nat, +bytes: String) -> Parsed:
  judge.jpeg.start(jpeg_magic(bytes), fuel, bytes)

type Strip is Data:
  Stripped{data: String}
  StripBroken{}
  StripMoving{}

type StripChunk is Data:
  StripChunk{kind: String, length: U32, bytes: String, rest: String, left: U32}

def strip_chunk.fit(ok: Bool, kind: String, length: U32, +size: U32, +data: String,
  left: U32) -> Maybe<&2, StripChunk>:
  match ok:
    case False{}:
      None{}
    case True{}:
      Some{StripChunk{kind, length, String.take(data, U32.to_nat(size)),
        String.drop(data, U32.to_nat(size)), (left - size : U32)}}

def strip_chunk.length(+length: U32, kind: String, data: String, +left: U32) ->
  Maybe<&2, StripChunk>:
  strip_chunk.fit(U32.is_le(length, (left - 12 : U32)), kind, length,
    (length + 12 : U32), data, left)

def strip_chunk.header(ok: Bool, +data: String, left: U32) -> Maybe<&2, StripChunk>:
  match ok data:
    case True{} SCon{a, SCon{b, SCon{c, SCon{d, rest}}}}:
      strip_chunk.length(be_from(a, b, c, d), String.take(rest, 4n), data, left)
    case _ _:
      None{}

def strip_chunk(data: String, +left: U32) -> Maybe<&2, StripChunk>:
  strip_chunk.header(U32.is_ge(left, 12), data, left)

def png_metadata(+kind: String) -> Bool:
  String.eq(kind, "tEXt") || String.eq(kind, "zTXt") || String.eq(kind, "iTXt") ||
    String.eq(kind, "eXIf") || String.eq(kind, "tIME")

def png_animation(+kind: String) -> Bool:
  String.eq(kind, "acTL") || String.eq(kind, "fcTL") || String.eq(kind, "fdAT")

def strip_keep(drop: Bool, bytes: String, acc: List<&2, String>) -> List<&2, String>:
  match drop:
    case True{}:
      acc
    case False{}:
      bytes <> acc

type PngStrip is Data:
  PsWalk{rest: String, left: U32, first: Bool, data_seen: Bool, acc: List<&2, String>}
  PsEnd{result: Strip}

def strip_png.end(ok: Bool, bytes: String, acc: List<&2, String>) -> PngStrip:
  match ok:
    case False{}:
      PsEnd{StripBroken{}}
    case True{}:
      PsEnd{Stripped{String.concat(List.reverse(&2, String, bytes <> acc))}}

def strip_png.kind(bad: Bool, moving: Bool, end: Bool, +kind: String, length: U32,
  bytes: String, rest: String, left: U32, seen: Bool, acc: List<&2, String>) -> PngStrip:
  match bad moving end:
    case True{} _ _:
      PsEnd{StripBroken{}}
    case False{} True{} _:
      PsEnd{StripMoving{}}
    case False{} False{} True{}:
      strip_png.end(seen && U32.is_zero(length) && U32.is_zero(left), bytes, acc)
    case False{} False{} False{}:
      PsWalk{rest, left, False{}, seen || String.eq(kind, "IDAT"),
        strip_keep(png_metadata(kind), bytes, acc)}

def strip_png.step(chunk: Maybe<&2, StripChunk>, +first: Bool, seen: Bool,
  acc: List<&2, String>) -> PngStrip:
  match chunk:
    case None{}:
      PsEnd{StripBroken{}}
    case Some{StripChunk{+kind, length, bytes, rest, left}}:
      strip_png.kind((first && Bool.not(String.eq(kind, "IHDR"))) ||
        (Bool.not(first) && String.eq(kind, "IHDR")),
        png_animation(kind), String.eq(kind, "IEND"), kind, length, bytes, rest, left, seen, acc)

def strip_png.go(fuel: Nat, state: PngStrip) -> Strip:
  match fuel state:
    case _ PsEnd{result}:
      result
    case 0n _:
      StripBroken{}
    case 1n+f PsWalk{rest, left, first, seen, acc}:
      strip_png.go(f, strip_png.step(strip_chunk(rest, left), first, seen, acc))

def strip_png(+data: String, +n: U32) -> Strip:
  strip_png.go(U32.to_nat((n / 12 + 1 : U32)),
    PsWalk{String.drop(data, 8n), (n - 8 : U32), True{}, False{}, [String.take(data, 8n)]})

type StripMark is Data:
  StripMark{code: U32, rest: String, size: U32}

type MarkRead is Data:
  MrSeek{scan: Bool, ff: Bool, used: U32}
  MrFound{code: U32, used: U32}
  MrBad{}

def strip_mark.step(+scan: Bool, ff: Bool, fill: Bool, escaped: Bool, code: U32,
  used: U32) -> MarkRead:
  match scan ff fill escaped:
    case _ True{} True{} _:
      MrSeek{scan, True{}, used}
    case True{} True{} False{} True{}:
      MrSeek{True{}, False{}, used}
    case _ True{} False{} _:
      MrFound{code, used}
    case _ False{} True{} _:
      MrSeek{scan, True{}, used}
    case True{} False{} False{} _:
      MrSeek{True{}, False{}, used}
    case False{} False{} False{} _:
      MrBad{}

def strip_mark.byte(scan: Bool, ff: Bool, +m: U32, used: U32) -> MarkRead:
  strip_mark.step(scan, ff, U32.is_eq(m, 255), U32.is_zero(m) ||
    (U32.is_ge(m, 208) && U32.is_le(m, 215)) || U32.is_eq(m, 1), m, (used + 1 : U32))

def strip_mark.go(data: String, state: MarkRead) -> Maybe<&2, StripMark>:
  match data state:
    case _ MrFound{code, used}:
      Some{StripMark{code, data, used}}
    case _ MrBad{}:
      None{}
    case SNil{} _:
      None{}
    case SCon{c, rest} MrSeek{scan, ff, used}:
      strip_mark.go(rest, strip_mark.byte(scan, ff, C.u(c), used))

def strip_mark(data: String, scan: Bool) -> Maybe<&2, StripMark>:
  strip_mark.go(data, MrSeek{scan, False{}, 0})

def segment_length.fit(ok: Bool, length: U32) -> Maybe<&2, U32>:
  match ok:
    case False{}:
      None{}
    case True{}:
      Some{length}

def segment_length.at(+length: U32, left: U32, min: U32) -> Maybe<&2, U32>:
  segment_length.fit(U32.is_ge(length, min) && U32.is_le(length, left), length)

def segment_length(data: String, left: U32, min: U32) -> Maybe<&2, U32>:
  segment_length.at(be16(data), left, min)

def jpeg_tables(+code: U32) -> Bool:
  U32.is_eq(code, 196) || U32.is_eq(code, 204) || U32.is_eq(code, 219) ||
    U32.is_eq(code, 221)

type JpegTail is Data:
  JtWalk{rest: String, left: U32, used: U32, scan: Bool}
  JtEnd{length: Maybe<&2, U32>}

def jpeg_tail.segment(length: Maybe<&2, U32>, code: U32, rest: String, left: U32,
  used: U32) -> JpegTail:
  match length:
    case None{}:
      JtEnd{None{}}
    case Some{+n}:
      JtWalk{String.drop(rest, U32.to_nat(n)), (left - n : U32), (used + n : U32),
        U32.is_eq(code, 218)}

def jpeg_tail.code(end: Bool, allowed: Bool, +code: U32, +rest: String, +left: U32,
  used: U32) -> JpegTail:
  match end allowed:
    case True{} _:
      JtEnd{Some{used}}
    case False{} False{}:
      JtEnd{None{}}
    case False{} True{}:
      jpeg_tail.segment(segment_length(rest, left,
        Bool.pick(U32, U32.is_eq(code, 218), 6, 2)), code, rest, left, used)

def jpeg_tail.step(marker: Maybe<&2, StripMark>, left: U32, used: U32) -> JpegTail:
  match marker:
    case None{}:
      JtEnd{None{}}
    case Some{StripMark{+code, rest, +size}}:
      jpeg_tail.code(U32.is_eq(code, 217), jpeg_tables(code) || U32.is_eq(code, 218),
        code, rest, (left - size : U32), (used + size : U32))

def jpeg_tail.go(fuel: Nat, state: JpegTail) -> Maybe<&2, U32>:
  match fuel state:
    case _ JtEnd{length}:
      length
    case 0n _:
      None{}
    case 1n+f JtWalk{rest, left, used, scan}:
      jpeg_tail.go(f, jpeg_tail.step(strip_mark(rest, scan), left, used))

def strip_jpeg.tail(length: Maybe<&2, U32>, data: String, acc: List<&2, String>) -> Strip:
  match length:
    case None{}:
      StripBroken{}
    case Some{n}:
      Stripped{String.concat(List.reverse(&2, String, String.take(data, U32.to_nat(n)) <> acc))}

def jpeg_metadata(+code: U32) -> Bool:
  (U32.is_ge(code, 225) && U32.is_le(code, 237)) || U32.is_eq(code, 239) ||
    U32.is_eq(code, 254)

type JpegStrip is Data:
  JsWalk{rest: String, left: U32, frame_seen: Bool, acc: List<&2, String>}
  JsScan{rest: String, left: U32, acc: List<&2, String>}
  JsBroken{}

def strip_jpeg.segment(length: Maybe<&2, U32>, +code: U32, prefix: U32, +original: String,
  left: U32, seen: Bool, acc: List<&2, String>) -> JpegStrip:
  match length:
    case None{}:
      JsBroken{}
    case Some{n}:
      +size = (prefix + n : U32)
      JsWalk{String.drop(original, U32.to_nat(size)), (left - size : U32),
        seen || is_sof(code), strip_keep(jpeg_metadata(code),
          String.take(original, U32.to_nat(size)), acc)}

def strip_jpeg.code(bad: Bool, scan: Bool, alone: Bool, code: U32, rest: String,
  +prefix: U32, original: String, +left: U32, seen: Bool, acc: List<&2, String>) -> JpegStrip:
  match bad scan alone:
    case True{} _ _:
      JsBroken{}
    case False{} True{} _:
      JsScan{original, left, acc}
    case False{} False{} True{}:
      JsWalk{rest, (left - prefix : U32), seen,
        String.take(original, U32.to_nat(prefix)) <> acc}
    case False{} False{} False{}:
      strip_jpeg.segment(segment_length(rest, (left - prefix : U32), 2), code, prefix,
        original, left, seen, acc)

def strip_jpeg.mark(marker: Maybe<&2, StripMark>, original: String, left: U32,
  +seen: Bool, acc: List<&2, String>) -> JpegStrip:
  match marker:
    case None{}:
      JsBroken{}
    case Some{StripMark{+code, rest, prefix}}:
      +scan = U32.is_eq(code, 218)
      +frame = is_sof(code)
      allowed = frame || scan || jpeg_tables(code) || U32.is_eq(code, 1) ||
        (U32.is_ge(code, 224) && U32.is_le(code, 239)) || U32.is_eq(code, 254)
      strip_jpeg.code(Bool.not(allowed) || (frame && seen) || (scan && Bool.not(seen)),
        scan, U32.is_eq(code, 1), code, rest, prefix, original, left, seen, acc)

def strip_jpeg.go(fuel: Nat, state: JpegStrip) -> Strip:
  match fuel state:
    case _ JsBroken{}:
      StripBroken{}
    case _ JsScan{+rest, +left, acc}:
      strip_jpeg.tail(jpeg_tail.go(U32.to_nat((left / 2 + 1 : U32)),
        JtWalk{rest, left, 0, False{}}), rest, acc)
    case 0n _:
      StripBroken{}
    case 1n+f JsWalk{+rest, left, seen, acc}:
      strip_jpeg.go(f, strip_jpeg.mark(strip_mark(rest, False{}), rest, left, seen, acc))

def strip_jpeg(+data: String, +n: U32) -> Strip:
  strip_jpeg.go(U32.to_nat((n / 2 + 1 : U32)),
    JsWalk{String.drop(data, 2n), (n - 2 : U32), False{}, [String.take(data, 2n)]})

def strip(format: Format, data: String, n: U32) -> Strip:
  match format:
    case Png{}:
      strip_png(data, n)
    case Jpeg{}:
      strip_jpeg(data, n)

def judge.stripped(s: Strip, n: U32, section: List<&2, U32>, name: String, format: Format,
  px: Pixels) -> Verdict:
  match s:
    case StripBroken{}:
      VDrop{section, name, Unreadable{}}
    case StripMoving{}:
      VDrop{section, name, Animated{}}
    case Stripped{+data}:
      Keep{Still{section, name, format, px, data, (n - C.byte_len(data) : U32)}}

def judge.size(over: Bool, +n: U32, section: List<&2, U32>, name: String, +format: Format,
  px: Pixels, data: String) -> Verdict:
  match over:
    case True{}:
      VDrop{section, name, FileSize{}}
    case False{}:
      judge.stripped(strip(format, data, n), n, section, name, format, px)

def judge.still(ok: Bool, +n: U32, section: List<&2, U32>, name: String, format: Format,
  px: Pixels, data: String) -> Verdict:
  match ok:
    case False{}:
      VDrop{section, name, Dimensions{}}
    case True{}:
      judge.size(U32.is_gt(n, image_file_cap()), n, section, name, format, px, data)

def judge.parsed(p: Parsed, section: List<&2, U32>, name: String, format: Format,
  +data: String) -> Verdict:
  match p:
    case WrongMagic{}:
      VDrop{section, name, Format{}}
    case Moving{}:
      VDrop{section, name, Animated{}}
    case Broken{}:
      VDrop{section, name, Unreadable{}}
    case StillImage{+px}:
      judge.still(pixels_ok(px), C.byte_len(data), section, name, format, px, data)

def judge(section: List<&2, U32>, name: String, format: Format, +data: String) -> Verdict:
  match format:
    case Png{}:
      judge.parsed(judge.png(64n, data), section, name, Png{}, data)
    case Jpeg{}:
      judge.parsed(judge.jpeg(64n, data), section, name, Jpeg{}, data)

def ref_token(a: U32, b: U32, c: U32, d: U32) -> String:
  "mbimg-" ++ C.hex8(a) ++ "-" ++ C.hex8(b) ++ "-" ++ C.hex8(c) ++ "-" ++ C.hex8(d)

def ref_clear(+token: String, corpus: String) -> Bool:
  Bool.not(String.contains(corpus, token))

def room_new() -> Room:
  Room{image_count_cap(), image_request_cap()}

# Count first: a fifth ready still is over_count even when the bytes are gone.
def admit.budget(over: Bool, still: Still, count: U32, bytes: U32) -> Admitted:
  match over:
    case True{}:
      Still{section, name, format, px, data, removed} = still
      Leave{section, name, OverBudget{}, Room{count, bytes}}
    case False{}:
      Still{section, name, format, px, +data, removed} = still
      Take{Still{section, name, format, px, data, removed},
        Room{(count - 1 : U32), (bytes - C.byte_len(data) : U32)}}

def admit.count(none: Bool, still: Still, count: U32, +bytes: U32) -> Admitted:
  match none:
    case True{}:
      Still{section, name, format, px, data, removed} = still
      Leave{section, name, OverCount{}, Room{count, bytes}}
    case False{}:
      Still{section, name, format, px, +data, removed} = still
      admit.budget(U32.is_gt(C.byte_len(data), bytes),
        Still{section, name, format, px, data, removed}, count, bytes)

def admit.keep(room: Room, still: Still) -> Admitted:
  Room{+count, bytes} = room
  admit.count(U32.is_zero(count), still, count, bytes)

def admit(room: Room, v: Verdict) -> Admitted:
  match v:
    case VDrop{section, name, reason}:
      Leave{section, name, reason, room}
    case Keep{still}:
      admit.keep(room, still)

# What a batch's survey may still use: the room left in its request, and
# how many more parts it may fetch.
type Quota is Data:
  Quota{room: Room, fetches: U32}

def quota_new() -> Quota:
  Quota{room_new(), fetch_cap()}

def ahead.if(over_count: Bool, over_budget: Bool) -> Maybe<&2, Reason>:
  match over_count over_budget:
    case True{} _:
      Some{OverCount{}}
    case False{} True{}:
      Some{OverBudget{}}
    case False{} False{}:
      None{}

def ahead(q: Quota) -> Maybe<&2, Reason>:
  Quota{Room{count, bytes}, fetches} = q
  ahead.if(U32.is_zero(fetches) || U32.is_zero(count), U32.is_zero(bytes))

def quota_fetched(q: Quota) -> Quota:
  Quota{room, fetches} = q
  Quota{room, (fetches - 1 : U32)}

type Judged is Data:
  Judged{verdict: Verdict, quota: Quota}

def quota_admit.put(a: Admitted, fetches: U32) -> Judged:
  match a:
    case Take{still, room}:
      Judged{Keep{still}, Quota{room, fetches}}
    case Leave{section, name, reason, room}:
      Judged{VDrop{section, name, reason}, Quota{room, fetches}}

# A fetched part's verdict against the batch's room, as bind_io will admit
# it: a still that fits stays kept and takes its room; any other part is
# dropped with its reason, and its bytes go with it.
def quota_admit(q: Quota, v: Verdict) -> Judged:
  Quota{room, fetches} = q
  quota_admit.put(admit(room, v), fetches)

def draw_ok(r: Result<&1, &1, U32 & String, U32>) -> Maybe<&2, U32>:
  match r:
    case Done{n}:
      Some{n}
    case Fail{e}:
      None{}

# A failed draw is not a token of zeros.
def quad(a: Maybe<&2, U32>, b: Maybe<&2, U32>, c: Maybe<&2, U32>, d: Maybe<&2, U32>) ->
  Maybe<&2, String>:
  match a b c d:
    case Some{w} Some{x} Some{y} Some{z}:
      Some{ref_token(w, x, y, z)}
    case _ _ _ _:
      None{}

def draw_token() -> IO(Maybe<&2, String>):
  do IO<Maybe<&2, String>>:
    a : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    b : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    c : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    d : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    return quad(draw_ok(a), draw_ok(b), draw_ok(c), draw_ok(d))

type Bind is Data:
  BWalk{vs: List<&2, Verdict>, corpus: String, room: Room, acc: List<&2, Fate>}
  BMint{left: Nat, corpus: String, still: Still, room: Room, rest: List<&2, Verdict>,
    acc: List<&2, Fate>}
  BUse{token: Maybe<&2, String>, left: Nat, corpus: String, still: Still, room: Room,
    rest: List<&2, Verdict>, acc: List<&2, Fate>}

def skipped_ref(s: Still) -> Fate:
  Still{section, name, format, px, data, removed} = s
  Skipped{section, name, NoRef{}}

def bind_admit(rest: List<&2, Verdict>, corpus: String, acc: List<&2, Fate>, a: Admitted) ->
  Bind:
  match a:
    case Leave{section, name, reason, room}:
      BWalk{rest, corpus, room, Skipped{section, name, reason} <> acc}
    case Take{still, room}:
      BMint{4n, corpus, still, room, rest, acc}

def bind_use.clear(ok: Bool, +token: String, left: Nat, corpus: String, still: Still, room: Room,
  rest: List<&2, Verdict>, acc: List<&2, Fate>) -> Bind:
  match ok:
    case True{}:
      BWalk{rest, corpus ++ "\n" ++ token, room, Used{Sent{still, Ref{token}}} <> acc}
    case False{}:
      BMint{left, corpus, still, room, rest, acc}

def bind_use(token: Maybe<&2, String>, left: Nat, +corpus: String, still: Still, room: Room,
  rest: List<&2, Verdict>, acc: List<&2, Fate>) -> Bind:
  match token:
    case None{}:
      BMint{left, corpus, still, room, rest, acc}
    case Some{+t}:
      bind_use.clear(ref_clear(t, corpus), t, left, corpus, still, room, rest, acc)

def bind_fuel(n: Nat) -> Nat:
  Nat.add(Nat.mul(n, 12n), 2n)

def bind_run(fuel: Nat, b: Bind) -> IO(List<&2, Fate>):
  match fuel b:
    case 0n _:
      IO.pure(List<&2, Fate>, [])
    case 1n+f BWalk{Nil{}, corpus, room, acc}:
      IO.pure(List<&2, Fate>, List.reverse(&2, Fate, acc))
    case 1n+f BWalk{v <> rest, corpus, room, acc}:
      bind_run(f, bind_admit(rest, corpus, acc, admit(room, v)))
    case 1n+f BMint{0n, corpus, still, room, rest, acc}:
      bind_run(f, BWalk{rest, corpus, room, skipped_ref(still) <> acc})
    case 1n+f BMint{1n+k, corpus, still, room, rest, acc}:
      do IO<List<&2, Fate>>:
        tok : Maybe<&2, String> <- draw_token()
        bind_run(f, BUse{tok, k, corpus, still, room, rest, acc})
    case 1n+f BUse{token, left, corpus, still, room, rest, acc}:
      bind_run(f, bind_use(token, left, corpus, still, room, rest, acc))

def bind_io(+vs: List<&2, Verdict>, corpus: String) -> IO(List<&2, Fate>):
  bind_run(bind_fuel(List.length(&2, Verdict, vs)), BWalk{vs, corpus, room_new(), []})

def sent_of(fs: List<&2, Fate>) -> List<&2, Sent>:
  match fs:
    case Nil{}:
      []
    case Used{s} <> t:
      s <> sent_of(t)
    case Skipped{section, name, reason} <> t:
      sent_of(t)

def refs_of(ss: List<&2, Sent>) -> List<&2, Ref>:
  match ss:
    case Nil{}:
      []
    case Sent{st, r} <> t:
      r <> refs_of(t)

def ref_strs(rs: List<&2, Ref>) -> List<&2, String>:
  match rs:
    case Nil{}:
      []
    case Ref{t} <> rest:
      t <> ref_strs(rest)

def images_kv(refs: List<&2, Ref>) -> J.Json:
  J.kv("images", J.strs(ref_strs(refs)))

def slot_ref() -> Ref:
  Ref{ref_token(0, 0, 0, 0)}

def four_refs() -> List<&2, Ref>:
  [slot_ref(), slot_ref(), slot_ref(), slot_ref()]

# The bytes added to a non-empty object by one images key of four refs,
# including the comma in front of the key.
def ref_slot() -> U32:
  +with = C.utf8_len(J.show(J.obj([J.kv("k", J.num(1)), images_kv(four_refs())])))
  +bare = C.utf8_len(J.show(J.obj([J.kv("k", J.num(1))])))
  (with - bare : U32)

def asset_body(st: Still) -> J.Json:
  Still{section, name, format, px, data, removed} = st
  J.obj([J.kv("type", J.str("image")), J.kv("format", J.str(format_name(format))),
    J.kv("data_base64", J.str(C.b64_encode(data, False{})))])

def asset_kvs(ss: List<&2, Sent>) -> List<&2, J.Json>:
  match ss:
    case Nil{}:
      []
    case Sent{st, Ref{token}} <> t:
      J.kv(token, asset_body(st)) <> asset_kvs(t)

def assets(used: List<&2, Sent>) -> Maybe<&2, J.Json>:
  match used:
    case Nil{}:
      None{}
    case s <> t:
      Some{J.obj(asset_kvs(s <> t))}

def frame_sent() -> Sent:
  Sent{Still{[], "", Jpeg{}, Pixels{280, 280}, "", 0}, slot_ref()}

def frame_used() -> List<&2, Sent>:
  [frame_sent(), frame_sent(), frame_sent(), frame_sent()]

# ,"assets": plus four jpeg entries with empty data_base64.
def asset_framing() -> U32:
  +with = C.utf8_len(J.show(J.obj([J.kv("k", J.num(1)), J.kv("assets", J.obj(asset_kvs(frame_used())))])))
  +bare = C.utf8_len(J.show(J.obj([J.kv("k", J.num(1))])))
  (with - bare : U32)

def notice_text() -> String:
  "Image classification is experimental. Jev's answers on a message with a used image may depend on that image."

def section_text(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case n <> Nil{}:
      U32.show(n)
    case n <> t:
      U32.show(n) ++ "." ++ section_text(t)

# What the agent is told of one part: a used still's section, name,
# format, decoded size and pixels, never its bytes; or a skipped part's
# reason.
type Note is Data:
  NoteUsed{section: List<&2, U32>, name: String, format: Format, bytes: U32, pixels: Pixels,
    metadata_removed_bytes: U32}
  NoteSkipped{section: List<&2, U32>, name: String, reason: Reason}

def note_of(f: Fate) -> Note:
  match f:
    case Used{Sent{Still{section, name, format, px, data, removed}, r}}:
      NoteUsed{section, name, format, C.byte_len(data), px, removed}
    case Skipped{section, name, reason}:
      NoteSkipped{section, name, reason}

def notes_of(fs: List<&2, Fate>) -> List<&2, Note>:
  match fs:
    case Nil{}:
      []
    case f <> t:
      note_of(f) <> notes_of(t)

# A used still whose request TypeSafe refused. TypeSafe does not say which
# image it rejected, so every still of that request is reported refused.
def refused(n: Note) -> Note:
  match n:
    case NoteUsed{section, name, format, bytes, px, removed}:
      NoteSkipped{section, name, Refused{}}
    case NoteSkipped{section, name, reason}:
      NoteSkipped{section, name, reason}

def refused_all(ns: List<&2, Note>) -> List<&2, Note>:
  match ns:
    case Nil{}:
      []
    case n <> t:
      refused(n) <> refused_all(t)

def note_json(n: Note) -> J.Json:
  match n:
    case NoteUsed{section, name, format, bytes, Pixels{w, h}, removed}:
      J.obj([J.kv("section", J.str(section_text(section))), J.kv("name", J.str(name)),
        J.kv("fate", J.str("used")), J.kv("format", J.str(format_name(format))),
        J.kv("bytes", J.num(bytes)), J.kv("width", J.num(w)), J.kv("height", J.num(h)),
        J.kv("metadata_removed_bytes", J.num(removed))])
    case NoteSkipped{section, name, reason}:
      J.obj([J.kv("section", J.str(section_text(section))), J.kv("name", J.str(name)),
        J.kv("fate", J.str("skipped")), J.kv("reason", J.str(reason_name(reason)))])

def fate_json(f: Fate) -> J.Json:
  note_json(note_of(f))

def notice_kv(any_used: Bool) -> List<&2, J.Json>:
  match any_used:
    case True{}:
      [J.kv("image_notice", J.str(notice_text()))]
    case False{}:
      []
