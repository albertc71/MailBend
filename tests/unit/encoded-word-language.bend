# RFC 2231 language metadata does not change an encoded word's charset.

import Base
import ../../src/mime.bend as M
import ../../src/codec.bend as C

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(M.decode_header("=?iso-8859-1*en?Q?Alice=85?="))
    IO.print(M.decode_header("=?WINDOWS-1252*EN-US?B?Y2Fm6Q==?="))
    IO.print(M.decode_header("=?utf-8*vi?Q?caf=C3=A9?="))
    IO.print(M.decode_header("=?latin1*fr?Q?caf=E9?= =?latin1*fr?Q?_cr=E8me?="))
    IO.print(M.decode_header("=?iso-8859-1?Q?Alice=85?="))
    IO.print(M.decode_header("=?unknown*en?Q?caf=E9?="))
    IO.print(M.decode_header("=?iso-8859-1**en?Q?Alice=85?="))
    IO.print(M.decode_header("=?iso-8859-1*?Q?Alice=85?="))
    IO.print(M.decode_header("=?iso-8859-1*en!?Q?Alice=85?="))
    IO.print(M.decode_header("=?iso-8859-1*en?Q?Alice=85"))
    IO.print(M.decode_header("=?latin1*es-419?Q?caf=E9?="))
    IO.print(M.decode_header("=?latin1*-en?Q?caf=E9?="))
    IO.print(M.decode_header("=?latin1*en-?Q?caf=E9?="))
    IO.print(M.decode_header("=?latin1*en--US?Q?caf=E9?="))
    IO.print(M.decode_header("=?latin1*9en?Q?caf=E9?="))
    IO.print(C.charset_decode("iso-8859-1*en", "\u{85}"))

#|Alice…
#|café
#|café
#|café crème
#|Alice…
#|caf�
#|Alice�
#|Alice�
#|Alice�
#|=?iso-8859-1*en?Q?Alice=85
#|café
#|caf�
#|caf�
#|caf�
#|caf�
#|�
