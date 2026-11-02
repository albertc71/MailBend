# Concrete serialization checks complement the universal accounting proofs.

import Base
import ../../src/codec.bend as C
import ../../src/json.bend as J
import ../../src/response.bend as Response
import ../../src/image.bend as Image
import ../formal/budget-observers.bend as Budget

def prefix_case(+s: String, +left: U32) -> Bool:
  +p = Response.prefix(s, left)
  +part = Budget.prefix_text(p)
  remain = Budget.prefix_left(p)
  +whole = C.utf8_len(J.esc(s))
  String.starts_with(s, part) && U32.is_le(C.utf8_len(J.esc(part)), left) &&
    Nat.is_eq(Budget.escaped_bytes(part), U32.to_nat(C.utf8_len(J.esc(part)))) &&
    (Bool.not(U32.is_le(whole, left)) ||
      (String.eq(s, part) && U32.is_eq(remain, (left - whole : U32))))

def prefix_budgets(n: Nat, +s: String, +left: U32) -> Bool:
  match n:
    case 0n:
      True{}
    case 1n+p:
      prefix_case(s, left) && prefix_budgets(p, s, (left + 1 : U32))

def ascii_cases(n: Nat, +code: U32) -> Bool:
  match n:
    case 0n:
      True{}
    case 1n+p:
      prefix_budgets(16n, SCon{C.chr(code), "é\n😀"}, 0) &&
        ascii_cases(p, (code + 1 : U32))

def unicode_cases(codes: List<&2, U32>) -> Bool:
  match codes:
    case Nil{}:
      True{}
    case code <> rest:
      +s = {SCon{C.chr(code), "\"\\\n"} : String}
      prefix_budgets(16n, s, 0) && prefix_case(s, 4294967295) && unicode_cases(rest)

def still(data: String) -> Image.Still:
  Image.Still{[], "synthetic", Image.Png{}, Image.Pixels{280, 280}, data, 0}

def keep(data: String) -> Image.Verdict:
  Image.Keep{still(data)}

def count_example() -> Bool:
  +got = Budget.admit_all([keep("a"), keep("b"), keep("c"), keep("d"), keep("e")],
    Image.room_new())
  Nat.is_eq(List.length(&2, Image.Still, Budget.stills(got)), 4n) &&
    Nat.is_eq(Budget.exact_bytes(Budget.stills(got)), 4n)

def byte_example() -> Bool:
  +got = Budget.admit_all([keep("ab"), keep("cd"), keep("e"), keep("f")], Image.Room{4, 3})
  Nat.is_eq(List.length(&2, Image.Still, Budget.stills(got)), 2n) &&
    Nat.is_eq(Budget.exact_bytes(Budget.stills(got)), 3n) &&
    U32.is_zero(Budget.bytes(Budget.remaining(got)))

def drive(n: Nat, b: Image.Bind, +draw: Maybe<&2, String>) -> Image.Bind:
  match n:
    case 0n:
      b
    case 1n+k:
      drive(k, Image.bind_next(b, draw), draw)

def no_ref_result(b: Image.Bind) -> Bool:
  match b:
    case Image.BWalk{Nil{}, corpus, Image.Room{count, bytes},
      Image.Skipped{second, second_name, Image.OverCount{}} <>
      Image.Skipped{first, first_name, Image.NoRef{}} <> Nil{}}:
      U32.is_zero(count) && U32.is_eq(bytes, 2)
    case _:
      False{}

def failed_draw_does_not_refund() -> Bool:
  no_ref_result(drive(11n, Image.BWalk{[keep("a"), keep("b")], "", Image.Room{1, 3}, []}, None{}))

def successful_result(b: Image.Bind) -> Bool:
  match b:
    case Image.BWalk{Nil{}, corpus, Image.Room{count, bytes},
      Image.Skipped{section, name, Image.OverCount{}} <>
      Image.Used{Image.Sent{Image.Still{s4, n4, f4, p4, d4, m4}, Image.Ref{t4}}} <>
      Image.Used{Image.Sent{Image.Still{s3, n3, f3, p3, d3, m3}, Image.Ref{t3}}} <>
      Image.Used{Image.Sent{Image.Still{s2, n2, f2, p2, d2, m2}, Image.Ref{t2}}} <>
      Image.Used{Image.Sent{Image.Still{s1, n1, f1, p1, d1, m1}, Image.Ref{t1}}} <> Nil{}}:
      U32.is_zero(count) && U32.is_eq(bytes, 1572860) &&
        String.eq(d1, "a") && String.eq(d2, "b") && String.eq(d3, "c") && String.eq(d4, "d") &&
        String.eq(t1, "one") && String.eq(t2, "two") && String.eq(t3, "three") && String.eq(t4, "four")
    case _:
      False{}

def successful_draws() -> Bool:
  b0 = {Image.BWalk{[keep("a"), keep("b"), keep("c"), keep("d"), keep("e")], "", Image.room_new(), []} : Image.Bind}
  b1 = drive(3n, b0, Some{"one"})
  b2 = drive(3n, b1, Some{"two"})
  b3 = drive(3n, b2, Some{"three"})
  b4 = drive(3n, b3, Some{"four"})
  successful_result(Image.bind_next(b4, None{}))

def say(name: String, ok: Bool) -> IO(Unit):
  IO.print(name ++ ": " ++ Bool.pick(String, ok, "true", "false"))

def main() -> IO(Unit):
  do IO<Unit>:
    say("ASCII and control scalar budgets", ascii_cases(128n, 0))
    say("Unicode width and maximum allowance", unicode_cases([127, 128, 2047, 2048,
      55295, 57344, 65535, 65536, 1114111]))
    say("empty string budgets", prefix_budgets(16n, "", 0))
    say("actual admission count boundary", count_example())
    say("actual admission byte boundary", byte_example())
    say("production failed draws do not refund room", failed_draw_does_not_refund())
    say("production draw sequence preserves four images", successful_draws())

#|ASCII and control scalar budgets: true
#|Unicode width and maximum allowance: true
#|empty string budgets: true
#|actual admission count boundary: true
#|actual admission byte boundary: true
#|production failed draws do not refund room: true
#|production draw sequence preserves four images: true
