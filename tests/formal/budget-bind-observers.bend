# Law-contract observations of the production Bind state, not a second runner.
import Base
import ../../src/image.bend as Image
import ../../src/codec.bend as C
import ./budget-observers.bend as Budget

def still_weight(bytes: Bool, still: Image.Still) -> Nat:
  match bytes still:
    case False{} _:
      1n
    case True{} Image.Still{section, name, format, px, data, removed}:
      U32.to_nat(C.byte_len(data))

def room_cap(bytes: Bool, room: Image.Room) -> U32:
  match bytes:
    case False{}:
      Budget.count(room)
    case True{}:
      Budget.bytes(room)

def room_weight(bytes: Bool, room: Image.Room) -> Nat:
  U32.to_nat(room_cap(bytes, room))

def used(+bytes: Bool, fates: List<&2, Image.Fate>) -> Nat:
  match fates:
    case Nil{}:
      0n
    case Image.Skipped{section, name, reason} <> rest:
      used(bytes, rest)
    case Image.Used{Image.Sent{still, ref}} <> rest:
      Nat.add(still_weight(bytes, still), used(bytes, rest))

def resources(+bytes: Bool, b: Image.Bind) -> Nat:
  match b:
    case Image.BWalk{vs, corpus, room, acc}:
      Nat.add(used(bytes, acc), room_weight(bytes, room))
    case Image.BMint{left, corpus, still, room, rest, acc}:
      Nat.add(Nat.add(still_weight(bytes, still), used(bytes, acc)), room_weight(bytes, room))
    case Image.BUse{token, left, corpus, still, room, rest, acc}:
      Nat.add(Nat.add(still_weight(bytes, still), used(bytes, acc)), room_weight(bytes, room))

def discarded(bytes: Bool, b: Image.Bind) -> Nat:
  match b:
    case Image.BMint{0n, corpus, still, room, rest, acc}:
      still_weight(bytes, still)
    case _:
      0n

# A finite trace chooses arbitrary outcomes of the IO draw. Every step calls
# precisely the production transition; it does not restate admission/binding.
def trace(draws: List<&2, Maybe<&2, String>>, b: Image.Bind) -> Image.Bind:
  match draws:
    case Nil{}:
      b
    case draw <> rest:
      trace(rest, Image.bind_next(b, draw))

def accumulator(b: Image.Bind) -> List<&2, Image.Fate>:
  match b:
    case Image.BWalk{vs, corpus, room, acc}:
      acc
    case Image.BMint{left, corpus, still, room, rest, acc}:
      acc
    case Image.BUse{token, left, corpus, still, room, rest, acc}:
      acc

def reserve(+bytes: Bool, b: Image.Bind) -> Nat:
  match b:
    case Image.BWalk{vs, corpus, room, acc}:
      room_weight(bytes, room)
    case Image.BMint{left, corpus, still, room, rest, acc}:
      Nat.add(still_weight(bytes, still), room_weight(bytes, room))
    case Image.BUse{token, left, corpus, still, room, rest, acc}:
      Nat.add(still_weight(bytes, still), room_weight(bytes, room))

def cap(bytes: Bool) -> U32:
  match bytes:
    case False{}:
      Image.image_count_cap()
    case True{}:
      Image.image_request_cap()

def exact_used(fs: List<&2, Image.Fate>) -> Nat:
  match fs:
    case Nil{}:
      0n
    case Image.Skipped{section, name, reason} <> rest:
      exact_used(rest)
    case Image.Used{Image.Sent{Image.Still{section, name, format, px, data, removed}, ref}} <> rest:
      Nat.add(String.length(data), exact_used(rest))

def lengths_exact(fs: List<&2, Image.Fate>) -> Type:
  match fs:
    case Nil{}:
      Unit
    case Image.Skipped{section, name, reason} <> rest:
      lengths_exact(rest)
    case Image.Used{Image.Sent{Image.Still{section, name, format, px, data, removed}, ref}} <> rest:
      {U32.to_nat(C.byte_len(data)) == String.length(data) : Nat} & lengths_exact(rest)
