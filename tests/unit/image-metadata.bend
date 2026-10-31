# Image bytes sent to Jev retain coding data but not the listed metadata.

import Base
import ../../src/codec.bend as C
import ../../src/json.bend as J
import ../../src/image.bend as Image

def png_chunk(kind: String, +body: String) -> String:
  C.bytes_str([0, 0, 0, C.byte_len(body)]) ++ kind ++ body ++ C.bytes_str([1, 2, 3, 4])

def png_head() -> String:
  C.bytes_str([137, 80, 78, 71, 13, 10, 26, 10]) ++
    png_chunk("IHDR", C.bytes_str([0, 0, 1, 24, 0, 0, 1, 24, 8, 2, 0, 0, 0]))

def png_data() -> String:
  png_chunk("IDAT", C.bytes_str([255, 0, 217]))

def png_end() -> String:
  png_chunk("IEND", "")

def png_clean() -> String:
  png_head() ++ png_chunk("vpAg", "keep") ++ png_data() ++ png_end()

def png_metadata() -> String:
  png_chunk("tEXt", "GPS=1") ++ png_chunk("zTXt", "compressed") ++
    png_chunk("iTXt", "XMP") ++ png_chunk("eXIf", "EXIF") ++ png_chunk("tIME", "time")

def png_private() -> String:
  png_head() ++ png_metadata() ++ png_chunk("vpAg", "keep") ++ png_data() ++
    png_metadata() ++ png_end()

def jpeg_segment(marker: U32, +body: String) -> String:
  C.bytes_str([255, marker, 0, (C.byte_len(body) + 2 : U32)]) ++ body

def jpeg_head() -> String:
  C.bytes_str([255, 216]) ++ jpeg_segment(224, "JFIF") ++ jpeg_segment(238, "Adobe") ++
    jpeg_segment(192, C.bytes_str([8, 1, 24, 1, 24, 1, 1, 17, 0]))

def jpeg_scan() -> String:
  jpeg_segment(218, C.bytes_str([1, 1, 0, 0, 63, 0])) ++
    C.bytes_str([0, 255, 0, 217, 255, 208, 17])

def jpeg_end() -> String:
  C.bytes_str([255, 255, 217])

def jpeg_clean() -> String:
  jpeg_head() ++ jpeg_scan() ++ jpeg_end()

def jpeg_apps(markers: List<&2, U32>) -> String:
  match markers:
    case Nil{}:
      ""
    case marker <> rest:
      jpeg_segment(marker, "private") ++ jpeg_apps(rest)

def jpeg_private() -> String:
  jpeg_head() ++ jpeg_segment(225, "Exif GPS") ++ jpeg_segment(225, "XMP") ++
    jpeg_apps([225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 239, 254]) ++
    jpeg_scan() ++ jpeg_end() ++ "second image GPS"

def jpeg_multiscan() -> String:
  jpeg_head() ++ jpeg_scan() ++ jpeg_segment(196, C.bytes_str([255, 217])) ++
    jpeg_scan() ++ jpeg_end()

def verdict(format: Image.Format, data: String) -> Image.Verdict:
  Image.judge([2], "photo", format, data)

def sent(v: Image.Verdict) -> String:
  match v:
    case Image.Keep{still}:
      C.b64_decode(Maybe.default(&2, String,
        J.as_str(J.get(Image.asset_body(still), "data_base64")), ""))
    case Image.VDrop{section, name, reason}:
      "skipped " ++ Image.reason_name(reason)

def note(v: Image.Verdict) -> J.Json:
  match v:
    case Image.Keep{still}:
      Image.fate_json(Image.Used{Image.Sent{still, Image.slot_ref()}})
    case Image.VDrop{section, name, reason}:
      Image.fate_json(Image.Skipped{section, name, reason})

def field(format: Image.Format, data: String, key: String) -> U32:
  Maybe.default(&2, U32, J.as_u32(J.get(note(verdict(format, data)), key)), 4294967295)

def stripped(format: Image.Format, data: String) -> String:
  sent(verdict(format, data))

def admits.put(admitted: Image.Admitted) -> String:
  match admitted:
    case Image.Take{still, remaining}:
      "used"
    case Image.Leave{section, name, reason, remaining}:
      Image.reason_name(reason)

def admits(v: Image.Verdict, room: U32) -> String:
  admits.put(Image.admit(Image.Room{1, room}, v))

def say(name: String, ok: Bool) -> IO(Unit):
  IO.print(name ++ " " ++ Bool.show(ok))

def main() -> IO(Unit):
  do IO<Unit>:
    say("png metadata removed", String.eq(stripped(Image.Png{}, png_private()), png_clean()))
    say("jpeg metadata and trailer removed", String.eq(stripped(Image.Jpeg{}, jpeg_private()), jpeg_clean()))
    say("jpeg metadata before frame", String.eq(stripped(Image.Jpeg{}, C.bytes_str([255, 216]) ++ jpeg_segment(225, "Exif GPS") ++ String.drop(jpeg_clean(), 2n)), jpeg_clean()))
    say("png idempotent", String.eq(stripped(Image.Png{}, stripped(Image.Png{}, png_private())), png_clean()))
    say("jpeg idempotent", String.eq(stripped(Image.Jpeg{}, stripped(Image.Jpeg{}, jpeg_private())), jpeg_clean()))
    say("sent size", U32.is_eq(field(Image.Png{}, png_private(), "bytes"), C.byte_len(png_clean())))
    say("removed size", U32.is_eq(field(Image.Png{}, png_private(), "metadata_removed_bytes"), (C.byte_len(png_private()) - C.byte_len(png_clean()) : U32)))
    say("clean removed zero", U32.is_zero(field(Image.Jpeg{}, jpeg_clean(), "metadata_removed_bytes")))
    IO.print("budget " ++ admits(verdict(Image.Png{}, png_private()), C.byte_len(png_clean())) ++ " " ++ admits(verdict(Image.Png{}, png_private()), (C.byte_len(png_clean()) - 1 : U32)))
    say("png missing end", String.eq(stripped(Image.Png{}, png_head() ++ png_data()), "skipped unreadable"))
    say("png partial end", String.eq(stripped(Image.Png{}, png_head() ++ png_data() ++ "partial"), "skipped unreadable"))
    say("png nonempty end", String.eq(stripped(Image.Png{}, png_head() ++ png_data() ++ png_chunk("IEND", "x")), "skipped unreadable"))
    say("png trailer", String.eq(stripped(Image.Png{}, png_clean() ++ "private"), "skipped unreadable"))
    say("png truncated metadata", String.eq(stripped(Image.Png{}, png_head() ++ png_data() ++ C.bytes_str([0, 0, 0, 8]) ++ "tEXtshort"), "skipped unreadable"))
    say("png overflow chunk", String.eq(stripped(Image.Png{}, png_head() ++ png_data() ++ C.bytes_str([255, 255, 255, 255]) ++ "tEXt" ++ png_end()), "skipped unreadable"))
    say("png repeated header", String.eq(stripped(Image.Png{}, png_head() ++ png_data() ++ String.drop(png_head(), 8n) ++ png_end()), "skipped unreadable"))
    say("png late animation", String.eq(stripped(Image.Png{}, png_head() ++ png_data() ++ png_chunk("acTL", "") ++ png_end()), "skipped animated"))
    say("jpeg missing end", String.eq(stripped(Image.Jpeg{}, jpeg_head() ++ jpeg_scan()), "skipped unreadable"))
    say("jpeg partial marker", String.eq(stripped(Image.Jpeg{}, jpeg_head() ++ jpeg_scan() ++ C.bytes_str([255])), "skipped unreadable"))
    say("jpeg missing scan", String.eq(stripped(Image.Jpeg{}, jpeg_head() ++ jpeg_end()), "skipped unreadable"))
    say("jpeg late exif", String.eq(stripped(Image.Jpeg{}, jpeg_head() ++ jpeg_scan() ++ jpeg_segment(225, "GPS") ++ jpeg_end()), "skipped unreadable"))
    say("jpeg late comment", String.eq(stripped(Image.Jpeg{}, jpeg_head() ++ jpeg_scan() ++ jpeg_segment(254, "GPS") ++ jpeg_end()), "skipped unreadable"))
    say("jpeg false end in segment", String.eq(stripped(Image.Jpeg{}, jpeg_head() ++ jpeg_scan() ++ jpeg_segment(196, C.bytes_str([255, 217]))), "skipped unreadable"))
    say("jpeg multiple scans preserved", String.eq(stripped(Image.Jpeg{}, jpeg_multiscan()), jpeg_multiscan()))
    say("jpeg truncated segment", String.eq(stripped(Image.Jpeg{}, jpeg_head() ++ C.bytes_str([255, 225, 0, 20]) ++ jpeg_scan() ++ jpeg_end()), "skipped unreadable"))
    say("jpeg repeated frame", String.eq(stripped(Image.Jpeg{}, jpeg_head() ++ jpeg_segment(192, C.bytes_str([8, 1, 24, 1, 24, 1, 1, 17, 0])) ++ jpeg_scan() ++ jpeg_end()), "skipped unreadable"))
    say("jpeg changed height", String.eq(stripped(Image.Jpeg{}, jpeg_head() ++ jpeg_scan() ++ jpeg_segment(220, C.bytes_str([1, 24])) ++ jpeg_end()), "skipped unreadable"))

#|png metadata removed True
#|jpeg metadata and trailer removed True
#|jpeg metadata before frame True
#|png idempotent True
#|jpeg idempotent True
#|sent size True
#|removed size True
#|clean removed zero True
#|budget used over_budget
#|png missing end True
#|png partial end True
#|png nonempty end True
#|png trailer True
#|png truncated metadata True
#|png overflow chunk True
#|png repeated header True
#|png late animation True
#|jpeg missing end True
#|jpeg partial marker True
#|jpeg missing scan True
#|jpeg late exif True
#|jpeg late comment True
#|jpeg false end in segment True
#|jpeg multiple scans preserved True
#|jpeg truncated segment True
#|jpeg repeated frame True
#|jpeg changed height True
