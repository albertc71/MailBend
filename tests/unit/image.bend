# Image deck for mail_classify: caps, pixel sides, skip reasons, and the
# projections an agent and TypeSafe can see. Tokens from IO are checked by
# shape, because the draws are not a fixed fixture.

import Base
import ../../src/codec.bend as C
import ../../src/json.bend as J
import ../../src/image.bend as Image
import ../../src/jev.bend as Jev

def many(n: Nat, acc: String) -> String:
  match n:
    case 0n:
      acc
    case 1n+p:
      many(p, SCon{'x', acc})

def png_of(w2: U32, w3: U32, h2: U32, h3: U32) -> String:
  C.bytes_str([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, w2, w3,
    0, 0, h2, h3, 8, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 73, 68, 65, 84, 0, 0, 0, 0])

def png_anim() -> String:
  C.bytes_str([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 1, 24, 0, 0,
    1, 24, 8, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 97, 99, 84, 76, 0, 0, 0, 0, 0, 0, 0, 0, 73, 68,
    65, 84, 0, 0, 0, 0])

def jpeg_ok() -> String:
  C.bytes_str([255, 216, 255, 225, 0, 8, 0, 1, 0, 2, 0, 3, 255, 192, 0, 11, 8, 1, 24, 6, 32, 1,
    1, 17, 0])

def caps_line() -> String:
  +text = (Jev.request_limit() + Jev.overhead() : U32)
  +b64 = Image.b64_len(Image.image_file_cap())
  +max = (text + Image.asset_framing() + b64 + Image.b64_slack() : U32)
  "caps " ++ U32.show(Image.image_count_cap()) ++ " " ++ U32.show(Image.image_file_cap()) ++ " " ++
    U32.show(Image.image_request_cap()) ++ " slot " ++ U32.show(Image.ref_slot()) ++ " framing " ++
    U32.show(Image.asset_framing()) ++ " b64 " ++ U32.show(b64) ++ " slack " ++
    U32.show(Image.b64_slack()) ++ " text " ++ U32.show(text) ++ " max " ++ U32.show(max)

def side(w: U32, h: U32) -> String:
  Bool.show(Image.pixels_ok(Image.Pixels{w, h}))

def reasons() -> String:
  Image.reason_name(Image.Format{}) ++ " " ++ Image.reason_name(Image.Animated{}) ++ " " ++
    Image.reason_name(Image.Dimensions{}) ++ " " ++ Image.reason_name(Image.FileSize{}) ++ " " ++
    Image.reason_name(Image.OverCount{}) ++ " " ++ Image.reason_name(Image.OverBudget{}) ++ " " ++
    Image.reason_name(Image.Unreadable{}) ++ " " ++ Image.reason_name(Image.Ref{})

def show_pre(p: Image.Pre) -> String:
  match p:
    case Image.Fetch{f, max}:
      "fetch " ++ Image.format_name(f) ++ " " ++ U32.show(max)
    case Image.Omit{r}:
      "omit " ++ Image.reason_name(r)

def show_verdict(v: Image.Verdict) -> String:
  match v:
    case Image.Keep{Image.Still{section, name, f, Image.Pixels{w, h}, data}}:
      "keep " ++ Image.format_name(f) ++ " " ++ U32.show(w) ++ " " ++ U32.show(h)
    case Image.VDrop{section, name, r}:
      "drop " ++ Image.reason_name(r)

def judge(f: Image.Format, data: String) -> String:
  show_verdict(Image.judge([], "n", f, data))

def keep_n(n: Nat) -> Image.Verdict:
  Image.Keep{Image.Still{[], "a.png", Image.Png{}, Image.Pixels{280, 280}, many(n, "")}}

def drop_fmt() -> Image.Verdict:
  Image.VDrop{[], "g.gif", Image.Format{}}

def counts(room: Image.Room, vs: List<&2, Image.Verdict>) -> String:
  match vs:
    case Nil{}:
      ""
    case v <> t:
      counts.put(Image.admit(room, v), t)

def counts.put(a: Image.Admitted, t: List<&2, Image.Verdict>) -> String:
  match a:
    case Image.Take{s, Image.Room{c, b}}:
      "t" ++ U32.show(c) ++ counts(Image.Room{c, b}, t)
    case Image.Leave{section, name, r, Image.Room{c, b}}:
      Image.reason_name(r) ++ counts(Image.Room{c, b}, t)

def five_keeps() -> List<&2, Image.Verdict>:
  [keep_n(8n), keep_n(8n), keep_n(8n), keep_n(8n), keep_n(8n)]

def behind() -> List<&2, Image.Verdict>:
  [drop_fmt(), drop_fmt(), drop_fmt(), drop_fmt(), keep_n(8n)]

def budget() -> List<&2, Image.Verdict>:
  [keep_n(1572864n), keep_n(1n)]

def hyphens(s: String, n: U32) -> U32:
  match s:
    case SNil{}:
      n
    case SCon{'-', t}:
      hyphens(t, (n + 1 : U32))
    case SCon{c, t}:
      hyphens(t, n)

def show_bound(fs: List<&2, Image.Fate>) -> String:
  match fs:
    case Image.Used{Image.Sent{st, Image.Ref{+token}}} <> Nil{}:
      "used " ++ Nat.show(String.length(token)) ++ " " ++
        Bool.show(String.starts_with(token, "mbimg-")) ++ " " ++ U32.show(hyphens(token, 0)) ++
        " " ++ Bool.show(String.contains(J.show(Image.fate_json(Image.Used{Image.Sent{st,
          Image.Ref{token}}})), "mbimg-"))
    case Image.Skipped{section, name, r} <> Nil{}:
      "skipped " ++ Image.reason_name(r)
    case _:
      "none"

def sample_ref() -> String:
  Image.ref_token(19088743, 2309737967, 0, 4294967295)

def sample_sent() -> Image.Sent:
  Image.Sent{Image.Still{[1, 2], "scan.png", Image.Png{}, Image.Pixels{1200, 800}, "abcd"},
    Image.Ref{sample_ref()}}

def show_assets(m: Maybe<&2, J.Json>) -> String:
  match m:
    case None{}:
      "none"
    case Some{j}:
      J.show(j)

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(caps_line())
    IO.print("sides " ++ side(279, 280) ++ " " ++ side(1569, 1568) ++ " " ++ side(280, 280) ++
      " " ++ side(1568, 1568))
    IO.print("reasons " ++ reasons())
    IO.print("screen " ++ show_pre(Image.screen("image/gif", "base64", 10)) ++ " " ++
      show_pre(Image.screen("image/png", "base64", 0)) ++ " " ++
      show_pre(Image.screen("image/png", "base64", 2097153)) ++ " " ++
      show_pre(Image.screen("image/png", "base64", 100)) ++ " " ++
      show_pre(Image.screen("image/jpg", "8bit", 10)) ++ " " ++
      show_pre(Image.screen("image/jpeg", "base64", 2097152)) ++ " " ++
      show_pre(Image.screen("image/png", "quoted-printable", 1572864)) ++ " " ++
      show_pre(Image.screen("image/png", "quoted-printable", 1572865)))
    IO.print("judge " ++ judge(Image.Png{}, png_of(1, 24, 1, 24)) ++ " " ++
      judge(Image.Png{}, png_of(1, 23, 1, 24)) ++ " " ++
      judge(Image.Png{}, png_of(6, 32, 6, 32)) ++ " " ++
      judge(Image.Png{}, png_of(6, 33, 1, 24)) ++ " " ++
      judge(Image.Png{}, png_anim()) ++ " " ++
      judge(Image.Png{}, C.bytes_str([255, 216])) ++ " " ++
      judge(Image.Png{}, C.bytes_str([137, 80, 78, 71, 13, 10, 26, 10])) ++ " " ++
      judge(Image.Jpeg{}, jpeg_ok()) ++ " " ++
      judge(Image.Jpeg{}, C.bytes_str([0, 0])) ++ " " ++
      judge(Image.Png{}, png_of(1, 24, 1, 24) ++ many(1572820n, "")))
    IO.print("counts " ++ counts(Image.room_new(), five_keeps()))
    IO.print("behind " ++ counts(Image.room_new(), behind()))
    IO.print("budget " ++ counts(Image.room_new(), budget()))
    IO.print("ref " ++ sample_ref())
    IO.print("clear " ++ Bool.show(Image.ref_clear(sample_ref(), "hello")) ++ " " ++
      Bool.show(Image.ref_clear(sample_ref(), "xx" ++ sample_ref() ++ "yy")))
    IO.print("fate " ++ J.show(Image.fate_json(Image.Used{sample_sent()})))
    IO.print("fate " ++ J.show(Image.fate_json(Image.Skipped{[2], "anim.png", Image.Animated{}})))
    IO.print("notice " ++ Image.notice_text())
    IO.print("assets " ++ show_assets(Image.assets([])))
    IO.print("assets " ++ show_assets(Image.assets([sample_sent()])))
    bound : List<&2, Image.Fate> <- Image.bind_io([Image.Keep{Image.Still{[1], "scan.png",
      Image.Png{}, Image.Pixels{280, 280}, "abcd"}}], "hello")
    IO.print("bound " ++ show_bound(bound))

#|caps 4 1572864 1572864 slot 187 framing 387 b64 2097152 slack 12 text 60128 max 2157679
#|sides 279 false 1569 false 280 true 1568 true
#|reasons format animated dimensions file_size over_count over_budget unreadable ref
#|screen omit format omit unreadable omit file_size fetch png 101 fetch jpeg 11 fetch jpeg 2097153 fetch png 1572865 omit file_size
#|judge keep png 280 280 drop dimensions keep png 1568 1568 drop dimensions drop animated drop format drop unreadable keep jpeg 1568 280 drop format drop file_size
#|counts t3t2t1t0over_count
#|behind formatformatformatformatt3
#|budget t3over_budget
#|ref mbimg-01234567-89abcdef-00000000-ffffffff
#|clear true false
#|fate {"section":"1.2","name":"scan.png","fate":"used","format":"png","bytes":4,"width":1200,"height":800}
#|fate {"section":"2","name":"anim.png","fate":"skipped","reason":"animated"}
#|notice Image classification is experimental. Jev's answers on a message with a used image may depend on that image.
#|assets none
#|assets {"mbimg-01234567-89abcdef-00000000-ffffffff":{"type":"image","format":"png","data_base64":"YWJjZA=="}}
#|bound used 41 true 3 false
