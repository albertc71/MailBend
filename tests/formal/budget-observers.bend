# Natural-number observations of the production prefix and image admission.

import Base
import ../../src/codec.bend as C
import ../../src/json.bend as J
import ../../src/response.bend as Response
import ../../src/image.bend as Image

def escaped_bytes(s: String) -> Nat:
  match s:
    case SNil{}:
      0n
    case SCon{c, t}:
      Nat.add(U32.to_nat(C.utf8_len(J.esc_char(c))), escaped_bytes(t))

def prefix_text(p: Response.Prefix) -> String:
  Response.Prefix{text, left} = p
  text

def prefix_left(p: Response.Prefix) -> U32:
  Response.Prefix{text, left} = p
  left

# A nonnegative remainder witnesses an upper bound without expanding a
# concrete U32 cap into a unary Nat during the theorem's type comparison.
type Within<-used: Nat, -cap: U32> is Type:
  Within{remaining: Nat, proof: {U32.to_nat(cap) == Nat.add(used, remaining) : Nat}}

type Admission is Data:
  Admission{stills: List<&2, Image.Still>, room: Image.Room}

def room(a: Image.Admitted) -> Image.Room:
  match a:
    case Image.Take{still, room}:
      room
    case Image.Leave{section, name, reason, room}:
      room

def admit_all.put(a: Image.Admitted, later: Admission) -> Admission:
  match a later:
    case Image.Take{still, unused} Admission{stills, room}:
      Admission{still <> stills, room}
    case Image.Leave{section, name, reason, unused} Admission{stills, room}:
      Admission{stills, room}

def admit_all(vs: List<&2, Image.Verdict>, remaining: Image.Room) -> Admission:
  match vs:
    case Nil{}:
      Admission{[], remaining}
    case v <> rest:
      +a = Image.admit(remaining, v)
      admit_all.put(a, admit_all(rest, room(a)))

def stills(a: Admission) -> List<&2, Image.Still>:
  Admission{stills, room} = a
  stills

def remaining(a: Admission) -> Image.Room:
  Admission{stills, room} = a
  room

def count(r: Image.Room) -> U32:
  Image.Room{count, bytes} = r
  count

def bytes(r: Image.Room) -> U32:
  Image.Room{count, bytes} = r
  bytes

def measured_bytes(ss: List<&2, Image.Still>) -> Nat:
  match ss:
    case Nil{}:
      0n
    case Image.Still{section, name, format, px, data, removed} <> t:
      Nat.add(U32.to_nat(C.byte_len(data)), measured_bytes(t))

def exact_bytes(ss: List<&2, Image.Still>) -> Nat:
  match ss:
    case Nil{}:
      0n
    case Image.Still{section, name, format, px, data, removed} <> t:
      Nat.add(String.length(data), exact_bytes(t))

# The fetch boundary supplies bounded strings. Arbitrary mathematical
# strings can exceed U32, so that premise is part of the exact-byte law.
def lengths_exact(ss: List<&2, Image.Still>) -> Type:
  match ss:
    case Nil{}:
      Unit
    case Image.Still{section, name, format, px, data, removed} <> t:
      {U32.to_nat(C.byte_len(data)) == String.length(data) : Nat} & lengths_exact(t)
