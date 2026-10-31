# Reply and forward prefix normalization preserves subject text, list tags,
# malformed lookalikes, and canonical fixed points.

import Base
import ../../src/tools.bend as T
import ../../src/mime.bend as M

def check(+source: String, reply: String, forward: String) -> String:
  +r = T.prefixed("Re:", source)
  +f = T.prefixed("Fwd:", source)
  Bool.show(String.eq(r, reply)) ++ " " ++ Bool.show(String.eq(f, forward)) ++ " " ++
    Bool.show(String.eq(T.prefixed("Re:", r), r)) ++ " " ++
    Bool.show(String.eq(T.prefixed("Fwd:", f), f))

def boundary(+source: String, reply: String, forward: String) -> String:
  Bool.show(Nat.is_eq(String.length(source), 998n)) ++ " " ++ check(source, reply, forward)

def truncated_counter() -> String:
  +source = T.hdr_line([M.Hdr{"subject", "AW[" ++ String.repeat("9", 1000n) ++ "]: x"}], "subject")
  boundary(source, "Re: " ++ source, "Fwd: " ++ source)

def decoded_once() -> String:
  source = T.hdr_line([M.Hdr{"subject", "=?UTF-8?Q?AW=3A_=3D=3FUTF-8=3FB=3FSGk=3D=3F=3D?="}], "subject")
  check(source, "Re: =?UTF-8?B?SGk=?=", "Fwd: =?UTF-8?B?SGk=?=")

def check_boundaries() -> IO(Unit):
  +tag = "[" ++ String.repeat("x", 991n) ++ "]"
  +unclosed = "[" ++ String.repeat("x", 993n) ++ "AW:x"
  do IO<Unit>:
    IO.print("long run " ++ boundary(String.repeat("AW: Fwd: ", 110n) ++ "日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("long counter " ++ boundary("Re[" ++ String.repeat("9", 991n) ++ "]: x", "Re: x", "Fwd: x"))
    IO.print("long tag " ++ boundary(tag ++ " AW:x", "Re: " ++ tag ++ " x", "Fwd: " ++ tag ++ " x"))
    IO.print("unclosed tag " ++ boundary(unclosed, "Re: " ++ unclosed, "Fwd: " ++ unclosed))
    IO.print("truncated counter " ++ truncated_counter())
    IO.print("decoded once " ++ decoded_once())

def main() -> IO(Unit):
  do IO<Unit>:
    check_boundaries()
    IO.print("1 " ++ check("re: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("2 " ++ check("RE[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("3 " ++ check("Re(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("4 " ++ check("fwd: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("5 " ++ check("FWD[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("6 " ++ check("Fwd(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("7 " ++ check("fw: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("8 " ++ check("FW[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("9 " ++ check("Fw(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("10 " ++ check("aw: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("11 " ++ check("AW[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("12 " ++ check("Aw(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("13 " ++ check("wg: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("14 " ++ check("WG[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("15 " ++ check("Wg(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("16 " ++ check("sv: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("17 " ++ check("SV[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("18 " ++ check("Sv(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("19 " ++ check("vb: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("20 " ++ check("VB[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("21 " ++ check("Vb(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("22 " ++ check("vs: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("23 " ++ check("VS[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("24 " ++ check("Vs(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("25 " ++ check("vl: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("26 " ++ check("VL[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("27 " ++ check("Vl(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("28 " ++ check("ref: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("29 " ++ check("REF[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("30 " ++ check("Ref(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("31 " ++ check("tr: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("32 " ++ check("TR[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("33 " ++ check("Tr(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("34 " ++ check("r: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("35 " ++ check("R[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("36 " ++ check("R(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("37 " ++ check("rif: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("38 " ++ check("RIF[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("39 " ++ check("Rif(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("40 " ++ check("i: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("41 " ++ check("I[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("42 " ++ check("I(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("43 " ++ check("rv: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("44 " ++ check("RV[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("45 " ++ check("Rv(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("46 " ++ check("res: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("47 " ++ check("RES[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("48 " ++ check("Res(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("49 " ++ check("enc: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("50 " ++ check("ENC[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("51 " ++ check("Enc(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("52 " ++ check("odp: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("53 " ++ check("ODP[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("54 " ++ check("Odp(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("55 " ++ check("pd: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("56 " ++ check("PD[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("57 " ++ check("Pd(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("58 " ++ check("ynt: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("59 " ++ check("YNT[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("60 " ++ check("Ynt(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("61 " ++ check("ilt: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("62 " ++ check("ILT[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("63 " ++ check("Ilt(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("64 " ++ check("回复: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("65 " ++ check("回复[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("66 " ++ check("回复(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("67 " ++ check("转发: 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("68 " ++ check("转发[2]： 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("69 " ++ check("转发(003): 日本語 Café", "Re: 日本語 Café", "Fwd: 日本語 Café"))
    IO.print("70 " ++ check("İLT: Türkçe", "Re: Türkçe", "Fwd: Türkçe"))
    IO.print("71 " ++ check("İlt[0]： Türkçe", "Re: Türkçe", "Fwd: Türkçe"))
    IO.print("72 " ++ check("Re: AW[2]: WG(3)： x", "Re: x", "Fwd: x"))
    IO.print("73 " ++ check("[team] AW: x", "Re: [team] x", "Fwd: [team] x"))
    IO.print("74 " ++ check("[a] AW: [b] WG: x", "Re: [a] [b] x", "Fwd: [a] [b] x"))
    IO.print("75 " ++ check("[a][b]AW:x", "Re: [a] [b] x", "Fwd: [a] [b] x"))
    IO.print("76 " ++ check("[Re:] AW: x", "Re: [Re:] x", "Fwd: [Re:] x"))
    IO.print("77 " ++ check("Re:  [a]  x ", "Re:  [a]  x ", "Fwd: [a] x "))
    IO.print("78 " ++ check("AW:  x ", "Re: x ", "Fwd: x "))
    IO.print("79 " ++ check("AW:\t x", "Re: x", "Fwd: x"))
    IO.print("80 " ++ check("Re:", "Re: ", "Fwd: "))
    IO.print("81 " ++ check("[a] AW:", "Re: [a]", "Fwd: [a]"))
    IO.print("82 " ++ check(" RE: hello", "Re: hello", "Fwd: hello"))
    IO.print("83 " ++ check("fwd: x", "Re: x", "Fwd: x"))
    IO.print("84 " ++ check("WG: x", "Re: x", "Fwd: x"))
    IO.print("85 " ++ check("Re: Subject: AW: x", "Re: Subject: AW: x", "Fwd: Subject: AW: x"))
    IO.print("86 " ++ check("AW: Café  日本語  ", "Re: Café  日本語  ", "Fwd: Café  日本語  "))
    IO.print("87 " ++ check("AW: =?UTF-8?B?SGk=?=", "Re: =?UTF-8?B?SGk=?=", "Fwd: =?UTF-8?B?SGk=?="))
    IO.print("88 " ++ check("hello", "Re: hello", "Fwd: hello"))
    IO.print("89 " ++ check("Reply needed", "Re: Reply needed", "Fwd: Reply needed"))
    IO.print("90 " ++ check("Information", "Re: Information", "Fwd: Information"))
    IO.print("91 " ++ check("Recreation: x", "Re: Recreation: x", "Fwd: Recreation: x"))
    IO.print("92 " ++ check("Forward: x", "Re: Forward: x", "Fwd: Forward: x"))
    IO.print("93 " ++ check("RE : x", "Re: RE : x", "Fwd: RE : x"))
    IO.print("94 " ++ check("Re\t: x", "Re: Re\t: x", "Fwd: Re\t: x"))
    IO.print("95 " ++ check("Re[]: x", "Re: Re[]: x", "Fwd: Re[]: x"))
    IO.print("96 " ++ check("Re(): x", "Re: Re(): x", "Fwd: Re(): x"))
    IO.print("97 " ++ check("Re[2x]: x", "Re: Re[2x]: x", "Fwd: Re[2x]: x"))
    IO.print("98 " ++ check("Re[2): x", "Re: Re[2): x", "Fwd: Re[2): x"))
    IO.print("99 " ++ check("Re(2]: x", "Re: Re(2]: x", "Fwd: Re(2]: x"))
    IO.print("100 " ++ check("Re[-2]: x", "Re: Re[-2]: x", "Fwd: Re[-2]: x"))
    IO.print("101 " ++ check("Re[+2]: x", "Re: Re[+2]: x", "Fwd: Re[+2]: x"))
    IO.print("102 " ++ check("Re[٢]: x", "Re: Re[٢]: x", "Fwd: Re[٢]: x"))
    IO.print("103 " ++ check("Re[2] : x", "Re: Re[2] : x", "Fwd: Re[2] : x"))
    IO.print("104 " ++ check("Re[2][3]: x", "Re: Re[2][3]: x", "Fwd: Re[2][3]: x"))
    IO.print("105 " ++ check("Re{2}: x", "Re: Re{2}: x", "Fwd: Re{2}: x"))
    IO.print("106 " ++ check("Re；x", "Re: Re；x", "Fwd: Re；x"))
    IO.print("107 " ++ check("[team AW: x", "Re: [team AW: x", "Fwd: [team AW: x"))
    IO.print("108 " ++ check("[[team]] AW: x", "Re: [[team]] AW: x", "Fwd: [[team]] AW: x"))
    IO.print("109 " ++ check("[team] plain AW: x", "Re: [team] plain AW: x", "Fwd: [team] plain AW: x"))
    IO.print("110 " ++ check("x AW: y", "Re: x AW: y", "Fwd: x AW: y"))
    IO.print("111 " ++ check("", "Re: ", "Fwd: "))
    IO.print("112 " ++ check(" ", "Re:  ", "Fwd:  "))
    IO.print("113 " ++ check("  x ", "Re:   x ", "Fwd:   x "))
    IO.print("114 " ++ check("\tx\t", "Re: \tx\t", "Fwd: \tx\t"))
    IO.print("115 " ++ check("  [team]  x ", "Re:   [team]  x ", "Fwd:   [team]  x "))
    IO.print("116 " ++ check("[list]  x ", "Re: [list]  x ", "Fwd: [list]  x "))
    IO.print("117 " ++ check("AW@host: x", "Re: AW@host: x", "Fwd: AW@host: x"))
    IO.print("118 " ++ check("Rifle: x", "Re: Rifle: x", "Fwd: Rifle: x"))
    IO.print("119 " ++ check("Ré: x", "Re: Ré: x", "Fwd: Ré: x"))
    IO.print("120 " ++ check("ＩＬＴ: x", "Re: ＩＬＴ: x", "Fwd: ＩＬＴ: x"))
    IO.print("121 " ++ check("ＡＷ: x", "Re: ＡＷ: x", "Fwd: ＡＷ: x"))
    IO.print("122 " ++ check("A\u{E0061}W: x", "Re: A\u{E0061}W: x", "Fwd: A\u{E0061}W: x"))
    IO.print("123 " ++ check("name@example.invalid", "Re: name@example.invalid", "Fwd: name@example.invalid"))
    IO.print("124 " ++ check("Re[2]", "Re: Re[2]", "Fwd: Re[2]"))
    IO.print("125 " ++ check("Re:   x ", "Re:   x ", "Fwd: x "))
    IO.print("126 " ++ check("Fwd:   x ", "Re: x ", "Fwd:   x "))
    IO.print("127 " ++ check("Re: [team]  x ", "Re: [team]  x ", "Fwd: [team] x "))

#|long run True True True True True
#|long counter True True True True True
#|long tag True True True True True
#|unclosed tag True True True True True
#|truncated counter True True True True True
#|decoded once True True True True
#|1 True True True True
#|2 True True True True
#|3 True True True True
#|4 True True True True
#|5 True True True True
#|6 True True True True
#|7 True True True True
#|8 True True True True
#|9 True True True True
#|10 True True True True
#|11 True True True True
#|12 True True True True
#|13 True True True True
#|14 True True True True
#|15 True True True True
#|16 True True True True
#|17 True True True True
#|18 True True True True
#|19 True True True True
#|20 True True True True
#|21 True True True True
#|22 True True True True
#|23 True True True True
#|24 True True True True
#|25 True True True True
#|26 True True True True
#|27 True True True True
#|28 True True True True
#|29 True True True True
#|30 True True True True
#|31 True True True True
#|32 True True True True
#|33 True True True True
#|34 True True True True
#|35 True True True True
#|36 True True True True
#|37 True True True True
#|38 True True True True
#|39 True True True True
#|40 True True True True
#|41 True True True True
#|42 True True True True
#|43 True True True True
#|44 True True True True
#|45 True True True True
#|46 True True True True
#|47 True True True True
#|48 True True True True
#|49 True True True True
#|50 True True True True
#|51 True True True True
#|52 True True True True
#|53 True True True True
#|54 True True True True
#|55 True True True True
#|56 True True True True
#|57 True True True True
#|58 True True True True
#|59 True True True True
#|60 True True True True
#|61 True True True True
#|62 True True True True
#|63 True True True True
#|64 True True True True
#|65 True True True True
#|66 True True True True
#|67 True True True True
#|68 True True True True
#|69 True True True True
#|70 True True True True
#|71 True True True True
#|72 True True True True
#|73 True True True True
#|74 True True True True
#|75 True True True True
#|76 True True True True
#|77 True True True True
#|78 True True True True
#|79 True True True True
#|80 True True True True
#|81 True True True True
#|82 True True True True
#|83 True True True True
#|84 True True True True
#|85 True True True True
#|86 True True True True
#|87 True True True True
#|88 True True True True
#|89 True True True True
#|90 True True True True
#|91 True True True True
#|92 True True True True
#|93 True True True True
#|94 True True True True
#|95 True True True True
#|96 True True True True
#|97 True True True True
#|98 True True True True
#|99 True True True True
#|100 True True True True
#|101 True True True True
#|102 True True True True
#|103 True True True True
#|104 True True True True
#|105 True True True True
#|106 True True True True
#|107 True True True True
#|108 True True True True
#|109 True True True True
#|110 True True True True
#|111 True True True True
#|112 True True True True
#|113 True True True True
#|114 True True True True
#|115 True True True True
#|116 True True True True
#|117 True True True True
#|118 True True True True
#|119 True True True True
#|120 True True True True
#|121 True True True True
#|122 True True True True
#|123 True True True True
#|124 True True True True
#|125 True True True True
#|126 True True True True
#|127 True True True True
