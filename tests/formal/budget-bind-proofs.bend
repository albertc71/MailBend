# Conservation through the actual production Bind state machine.
import Base
import ../../src/image.bend as Image
import ../../src/codec.bend as C
import ./budget-bind-observers.bend as B
import ./budget-observers.bend as Budget
import ./budget-proofs.bend as P
import ./budget-arithmetic.bend as A

def add_zero(a: Nat) -> {Nat.add(a, 0n) == a : Nat}:
  match a:
    case 0n:
      {==}
    case 1n+p:
      Equal.cong(Nat, Nat, n => 1n+n, Nat.add(p, 0n), p, add_zero(p))

def add_comm(a: Nat, +b: Nat) -> {Nat.add(a, b) == Nat.add(b, a) : Nat}:
  match a:
    case 0n:
      Equal.sym(Nat, Nat.add(b, 0n), b, add_zero(b))
    case 1n+p:
      Equal.trans(Nat, 1n+Nat.add(p, b), 1n+Nat.add(b, p), Nat.add(b, 1n+p),
        Equal.cong(Nat, Nat, n => 1n+n, Nat.add(p, b), Nat.add(b, p), add_comm(p, b)),
        Equal.sym(Nat, Nat.add(b, 1n+p), 1n+Nat.add(b, p), A.add_right_succ(b, p)))

def add_swap(+a: Nat, +b: Nat, -c: Nat)
  -> {Nat.add(a, Nat.add(b, c)) == Nat.add(b, Nat.add(a, c)) : Nat}:
  Equal.trans(Nat, Nat.add(a, Nat.add(b, c)), Nat.add(Nat.add(a, b), c),
    Nat.add(b, Nat.add(a, c)), P.add_assoc(a, b, c),
    Equal.trans(Nat, Nat.add(Nat.add(a, b), c), Nat.add(Nat.add(b, a), c),
      Nat.add(b, Nat.add(a, c)),
      Equal.cong(Nat, Nat, n => Nat.add(n, c), Nat.add(a, b), Nat.add(b, a), add_comm(a, b)),
      Equal.sym(Nat, Nat.add(b, Nat.add(a, c)), Nat.add(Nat.add(b, a), c), P.add_assoc(b, a, c))))

def step_weight(bytes: Bool, a: Image.Admitted) -> Nat:
  match bytes:
    case False{}:
      P.step_count(a)
    case True{}:
      P.step_bytes(a)

def select_admit_count(-before: Image.Room, -a: Image.Admitted, proof: P.step_conserved(before, a))
  -> {B.room_weight(False{}, before) == Nat.add(step_weight(False{}, a),
    B.room_weight(False{}, Budget.room(a))) : Nat}:
  (count, size) = proof
  count

def select_admit_bytes(-before: Image.Room, -a: Image.Admitted, proof: P.step_conserved(before, a))
  -> {B.room_weight(True{}, before) == Nat.add(step_weight(True{}, a),
    B.room_weight(True{}, Budget.room(a))) : Nat}:
  (count, size) = proof
  size

def admit_conserved(bytes: Bool, before: Image.Room, v: Image.Verdict)
  -> {B.room_weight(bytes, before) == Nat.add(step_weight(bytes, Image.admit(before, v)),
    B.room_weight(bytes, Budget.room(Image.admit(before, v)))) : Nat}:
  match bytes:
    case False{}:
      select_admit_count(before, Image.admit(before, v), P.admit_conserves(before, v))
    case True{}:
      select_admit_bytes(before, Image.admit(before, v), P.admit_conserves(before, v))

# Admission transfers room into the one pending image. It never resets room.
def bind_admit_conserved(bytes: Bool, rest: List<&2, Image.Verdict>, corpus: String,
  acc: List<&2, Image.Fate>, a: Image.Admitted)
  -> {B.resources(bytes, Image.bind_admit(rest, corpus, acc, a)) ==
    Nat.add(step_weight(bytes, a), Nat.add(B.used(bytes, acc),
      B.room_weight(bytes, Budget.room(a)))) : Nat}:
  match bytes a:
    case False{} Image.Leave{section, name, reason, room}:
      {==}
    case True{} Image.Leave{section, name, reason, room}:
      {==}
    case False{} Image.Take{still, room}:
      Equal.sym(Nat,
        Nat.add(1n, Nat.add(B.used(False{}, acc), B.room_weight(False{}, room))),
        Nat.add(Nat.add(1n, B.used(False{}, acc)), B.room_weight(False{}, room)),
        P.add_assoc(1n, B.used(False{}, acc), B.room_weight(False{}, room)))
    case True{} Image.Take{Image.Still{section, name, format, px, data, removed}, room}:
      Equal.sym(Nat,
        Nat.add(U32.to_nat(C.byte_len(data)), Nat.add(B.used(True{}, acc), B.room_weight(True{}, room))),
        Nat.add(Nat.add(U32.to_nat(C.byte_len(data)), B.used(True{}, acc)), B.room_weight(True{}, room)),
        P.add_assoc(U32.to_nat(C.byte_len(data)), B.used(True{}, acc), B.room_weight(True{}, room)))

# Success moves the pending image to Used; retry preserves it and its room.
def bind_use_clear_conserved(ok: Bool, bytes: Bool, token: String, left: Nat,
  corpus: String, still: Image.Still, room: Image.Room, rest: List<&2, Image.Verdict>,
  acc: List<&2, Image.Fate>)
  -> {B.resources(bytes, Image.bind_use.clear(ok, token, left, corpus, still, room, rest, acc)) ==
    Nat.add(Nat.add(B.still_weight(bytes, still), B.used(bytes, acc)), B.room_weight(bytes, room)) : Nat}:
  match ok:
    case False{}:
      {==}
    case True{}:
      {==}

def bind_use_conserved(token: Maybe<&2, String>, bytes: Bool, left: Nat, +corpus: String,
  still: Image.Still, room: Image.Room, rest: List<&2, Image.Verdict>, acc: List<&2, Image.Fate>)
  -> {B.resources(bytes, Image.bind_use(token, left, corpus, still, room, rest, acc)) ==
    Nat.add(Nat.add(B.still_weight(bytes, still), B.used(bytes, acc)), B.room_weight(bytes, room)) : Nat}:
  match token:
    case None{}:
      {==}
    case Some{+t}:
      bind_use_clear_conserved(Image.ref_clear(t, corpus), bytes, t, left, corpus, still, room, rest, acc)

def bind_walk_conserved(+bytes: Bool, +v: Image.Verdict, rest: List<&2, Image.Verdict>,
  corpus: String, +room: Image.Room, +acc: List<&2, Image.Fate>)
  -> {Nat.add(B.used(bytes, acc), B.room_weight(bytes, room)) ==
    B.resources(bytes, Image.bind_admit(rest, corpus, acc, Image.admit(room, v))) : Nat}:
  +a = Image.admit(room, v)
  +u = B.used(bytes, acc)
  +w = step_weight(bytes, a)
  +r = B.room_weight(bytes, Budget.room(a))
  Equal.trans(Nat, Nat.add(u, B.room_weight(bytes, room)), Nat.add(u, Nat.add(w, r)),
    B.resources(bytes, Image.bind_admit(rest, corpus, acc, a)),
    Equal.cong(Nat, Nat, n => Nat.add(u, n), B.room_weight(bytes, room), Nat.add(w, r),
      admit_conserved(bytes, room, v)),
    Equal.trans(Nat, Nat.add(u, Nat.add(w, r)), Nat.add(w, Nat.add(u, r)),
      B.resources(bytes, Image.bind_admit(rest, corpus, acc, a)), add_swap(u, w, r),
      Equal.sym(Nat, B.resources(bytes, Image.bind_admit(rest, corpus, acc, a)),
        Nat.add(w, Nat.add(u, r)), bind_admit_conserved(bytes, rest, corpus, acc, a))))

def bind_next_conserved(bytes: Bool, b: Image.Bind, draw: Maybe<&2, String>)
  -> {B.resources(bytes, b) == Nat.add(B.discarded(bytes, b),
    B.resources(bytes, Image.bind_next(b, draw))) : Nat}:
  match b:
    case Image.BWalk{Nil{}, corpus, room, acc}:
      {==}
    case Image.BWalk{v <> rest, corpus, room, acc}:
      bind_walk_conserved(bytes, v, rest, corpus, room, acc)
    case Image.BMint{0n, corpus, Image.Still{section, name, format, px, data, removed}, room, rest, acc}:
      +still = {Image.Still{section, name, format, px, data, removed} : Image.Still}
      Equal.sym(Nat,
        Nat.add(B.still_weight(bytes, still), Nat.add(B.used(bytes, acc), B.room_weight(bytes, room))),
        Nat.add(Nat.add(B.still_weight(bytes, still), B.used(bytes, acc)), B.room_weight(bytes, room)),
        P.add_assoc(B.still_weight(bytes, still), B.used(bytes, acc), B.room_weight(bytes, room)))
    case Image.BMint{1n+k, corpus, still, room, rest, acc}:
      {==}
    case Image.BUse{token, left, corpus, still, room, rest, acc}:
      Equal.sym(Nat,
        B.resources(bytes, Image.bind_use(token, left, corpus, still, room, rest, acc)),
        Nat.add(Nat.add(B.still_weight(bytes, still), B.used(bytes, acc)), B.room_weight(bytes, room)),
        bind_use_conserved(token, bytes, left, corpus, still, room, rest, acc))

def retain_bound(before: Nat, +after: Nat, +discarded: Nat, cap: U32,
  balance: {before == Nat.add(discarded, after) : Nat}, bound: Budget.Within<before, cap>)
  -> Budget.Within<after, cap>:
  Budget.Within{remaining, proof} = bound
  Budget.Within{Nat.add(discarded, remaining),
    Equal.trans(Nat, U32.to_nat(cap), Nat.add(before, remaining), Nat.add(after, Nat.add(discarded, remaining)),
      proof,
      Equal.trans(Nat, Nat.add(before, remaining), Nat.add(Nat.add(discarded, after), remaining),
        Nat.add(after, Nat.add(discarded, remaining)),
        Equal.cong(Nat, Nat, n => Nat.add(n, remaining), before, Nat.add(discarded, after), balance),
        Equal.trans(Nat, Nat.add(Nat.add(discarded, after), remaining),
          Nat.add(discarded, Nat.add(after, remaining)), Nat.add(after, Nat.add(discarded, remaining)),
          Equal.sym(Nat, Nat.add(discarded, Nat.add(after, remaining)),
            Nat.add(Nat.add(discarded, after), remaining), P.add_assoc(discarded, after, remaining)),
          add_swap(discarded, after, remaining))))}

def trace_bound(draws: List<&2, Maybe<&2, String>>, +bytes: Bool, +b: Image.Bind, +cap: U32,
  bound: Budget.Within<B.resources(bytes, b), cap>)
  -> Budget.Within<B.resources(bytes, B.trace(draws, b)), cap>:
  match draws:
    case Nil{}:
      bound
    case +draw <> rest:
      trace_bound(rest, bytes, Image.bind_next(b, draw), cap,
        retain_bound(B.resources(bytes, b), B.resources(bytes, Image.bind_next(b, draw)),
          B.discarded(bytes, b), cap, bind_next_conserved(bytes, b, draw), bound))

def regroup(+pending: Nat, +used: Nat, +room: Nat)
  -> {Nat.add(Nat.add(pending, used), room) == Nat.add(Nat.add(pending, room), used) : Nat}:
  Equal.trans(Nat, Nat.add(Nat.add(pending, used), room), Nat.add(pending, Nat.add(used, room)),
    Nat.add(Nat.add(pending, room), used),
    Equal.sym(Nat, Nat.add(pending, Nat.add(used, room)), Nat.add(Nat.add(pending, used), room),
      P.add_assoc(pending, used, room)),
    Equal.trans(Nat, Nat.add(pending, Nat.add(used, room)), Nat.add(pending, Nat.add(room, used)),
      Nat.add(Nat.add(pending, room), used),
      Equal.cong(Nat, Nat, n => Nat.add(pending, n), Nat.add(used, room), Nat.add(room, used), add_comm(used, room)),
      P.add_assoc(pending, room, used)))

def resources_split(+bytes: Bool, b: Image.Bind)
  -> {B.resources(bytes, b) == Nat.add(B.reserve(bytes, b), B.used(bytes, B.accumulator(b))) : Nat}:
  match b:
    case Image.BWalk{vs, corpus, room, acc}:
      add_comm(B.used(bytes, acc), B.room_weight(bytes, room))
    case Image.BMint{left, corpus, still, room, rest, acc}:
      regroup(B.still_weight(bytes, still), B.used(bytes, acc), B.room_weight(bytes, room))
    case Image.BUse{token, left, corpus, still, room, rest, acc}:
      regroup(B.still_weight(bytes, still), B.used(bytes, acc), B.room_weight(bytes, room))

def self_bound(+cap: U32) -> Budget.Within<U32.to_nat(cap), cap>:
  Budget.Within{0n, Equal.sym(Nat, Nat.add(U32.to_nat(cap), 0n), U32.to_nat(cap),
    add_zero(U32.to_nat(cap)))}

def initial_bound(bytes: Bool, vs: List<&2, Image.Verdict>, corpus: String, room: Image.Room)
  -> Budget.Within<B.resources(bytes, Image.BWalk{vs, corpus, room, []}), B.room_cap(bytes, room)>:
  self_bound(B.room_cap(bytes, room))

def used_cap_from_room(+draws: List<&2, Maybe<&2, String>>, +bytes: Bool,
  +vs: List<&2, Image.Verdict>, +corpus: String, +room: Image.Room)
  -> Budget.Within<B.used(bytes, B.accumulator(B.trace(draws,
    Image.BWalk{vs, corpus, room, []}))), B.room_cap(bytes, room)>:
  +initial = {Image.BWalk{vs, corpus, room, []} : Image.Bind}
  +final = B.trace(draws, initial)
  retain_bound(B.resources(bytes, final), B.used(bytes, B.accumulator(final)), B.reserve(bytes, final),
    B.room_cap(bytes, room), resources_split(bytes, final),
    trace_bound(draws, bytes, initial, B.room_cap(bytes, room), initial_bound(bytes, vs, corpus, room)))

def production_used_cap(draws: List<&2, Maybe<&2, String>>, bytes: Bool,
  vs: List<&2, Image.Verdict>, corpus: String)
  -> Budget.Within<B.used(bytes, B.accumulator(B.trace(draws,
    Image.BWalk{vs, corpus, Image.room_new(), []}))), B.cap(bytes)>:
  match bytes:
    case False{}:
      used_cap_from_room(draws, False{}, vs, corpus, Image.room_new())
    case True{}:
      used_cap_from_room(draws, True{}, vs, corpus, Image.room_new())

# Pin the IO adapter to the proved transition. These are wiring obligations,
# not substitutes for the conservation induction above.
def bind_run_walk(fuel: Nat, v: Image.Verdict, rest: List<&2, Image.Verdict>, corpus: String,
  room: Image.Room, acc: List<&2, Image.Fate>)
  -> {Image.bind_run(1n+fuel, Image.BWalk{v <> rest, corpus, room, acc}) ==
    Image.bind_run(fuel, Image.bind_next(Image.BWalk{v <> rest, corpus, room, acc}, None{})) : IO(List<&2, Image.Fate>)}:
  {==}

def bind_run_exhausted(fuel: Nat, corpus: String, still: Image.Still, room: Image.Room,
  rest: List<&2, Image.Verdict>, acc: List<&2, Image.Fate>)
  -> {Image.bind_run(1n+fuel, Image.BMint{0n, corpus, still, room, rest, acc}) ==
    Image.bind_run(fuel, Image.bind_next(Image.BMint{0n, corpus, still, room, rest, acc}, None{})) : IO(List<&2, Image.Fate>)}:
  {==}

def bind_run_use(fuel: Nat, token: Maybe<&2, String>, left: Nat, corpus: String, still: Image.Still,
  room: Image.Room, rest: List<&2, Image.Verdict>, acc: List<&2, Image.Fate>)
  -> {Image.bind_run(1n+fuel, Image.BUse{token, left, corpus, still, room, rest, acc}) ==
    Image.bind_run(fuel, Image.bind_next(Image.BUse{token, left, corpus, still, room, rest, acc}, None{})) : IO(List<&2, Image.Fate>)}:
  {==}

def bind_io_initial(vs: List<&2, Image.Verdict>, corpus: String)
  -> {Image.bind_io(vs, corpus) == Image.bind_run(Image.bind_fuel(List.length(&2, Image.Verdict, vs)),
    Image.BWalk{vs, corpus, Image.room_new(), []}) : IO(List<&2, Image.Fate>)}:
  {==}

def bind_run_draw(fuel: Nat, left: Nat, corpus: String, still: Image.Still, room: Image.Room,
  rest: List<&2, Image.Verdict>, acc: List<&2, Image.Fate>)
  -> {Image.bind_run(1n+fuel, Image.BMint{1n+left, corpus, still, room, rest, acc}) ==
    IO.bind(Maybe<&2, String>, List<&2, Image.Fate>, Image.draw_token(),
      tok => Image.bind_run(fuel, Image.bind_next(Image.BMint{1n+left, corpus, still, room, rest, acc}, tok))) : IO(List<&2, Image.Fate>)}:
  {==}

def bind_run_done(fuel: Nat, corpus: String, room: Image.Room, acc: List<&2, Image.Fate>)
  -> {Image.bind_run(1n+fuel, Image.BWalk{[], corpus, room, acc}) ==
    IO.pure(List<&2, Image.Fate>, List.reverse(&2, Image.Fate, acc)) : IO(List<&2, Image.Fate>)}:
  {==}

def used_reverse_go(+bytes: Bool, fs: List<&2, Image.Fate>, +acc: List<&2, Image.Fate>)
  -> {B.used(bytes, List.reverse.go(&2, Image.Fate, fs, acc)) ==
    Nat.add(B.used(bytes, fs), B.used(bytes, acc)) : Nat}:
  match fs:
    case Nil{}:
      {==}
    case Image.Skipped{section, name, reason} <> rest:
      used_reverse_go(bytes, rest, Image.Skipped{section, name, reason} <> acc)
    case Image.Used{Image.Sent{+still, ref}} <> +rest:
      Equal.trans(Nat,
        B.used(bytes, List.reverse.go(&2, Image.Fate, rest, Image.Used{Image.Sent{still, ref}} <> acc)),
        Nat.add(B.used(bytes, rest), Nat.add(B.still_weight(bytes, still), B.used(bytes, acc))),
        Nat.add(Nat.add(B.still_weight(bytes, still), B.used(bytes, rest)), B.used(bytes, acc)),
        used_reverse_go(bytes, rest, Image.Used{Image.Sent{still, ref}} <> acc),
        Equal.trans(Nat,
          Nat.add(B.used(bytes, rest), Nat.add(B.still_weight(bytes, still), B.used(bytes, acc))),
          Nat.add(B.still_weight(bytes, still), Nat.add(B.used(bytes, rest), B.used(bytes, acc))),
          Nat.add(Nat.add(B.still_weight(bytes, still), B.used(bytes, rest)), B.used(bytes, acc)),
          add_swap(B.used(bytes, rest), B.still_weight(bytes, still), B.used(bytes, acc)),
          P.add_assoc(B.still_weight(bytes, still), B.used(bytes, rest), B.used(bytes, acc))))

def used_reverse(+bytes: Bool, +fs: List<&2, Image.Fate>)
  -> {B.used(bytes, List.reverse(&2, Image.Fate, fs)) == B.used(bytes, fs) : Nat}:
  Equal.trans(Nat, B.used(bytes, List.reverse(&2, Image.Fate, fs)), Nat.add(B.used(bytes, fs), 0n),
    B.used(bytes, fs), used_reverse_go(bytes, fs, []), add_zero(B.used(bytes, fs)))

def used_count(fs: List<&2, Image.Fate>)
  -> {B.used(False{}, fs) == List.length(&2, Image.Sent, Image.sent_of(fs)) : Nat}:
  match fs:
    case Nil{}:
      {==}
    case Image.Skipped{section, name, reason} <> rest:
      used_count(rest)
    case Image.Used{Image.Sent{still, ref}} <> rest:
      Equal.cong(Nat, Nat, n => 1n+n, B.used(False{}, rest),
        List.length(&2, Image.Sent, Image.sent_of(rest)), used_count(rest))

def used_exact(fs: List<&2, Image.Fate>, exact: B.lengths_exact(fs))
  -> {B.used(True{}, fs) == B.exact_used(fs) : Nat}:
  match fs:
    case Nil{}:
      {==}
    case Image.Skipped{section, name, reason} <> rest:
      used_exact(rest, exact)
    case Image.Used{Image.Sent{Image.Still{section, name, format, px, data, removed}, ref}} <> rest:
      (head, tail) = exact
      %head : {Nat.add(U32.to_nat(C.byte_len(data)), B.used(True{}, rest)) == Nat.add(_, B.exact_used(rest)) : Nat}
      %used_exact(rest, tail) : {Nat.add(U32.to_nat(C.byte_len(data)), B.used(True{}, rest)) == Nat.add(U32.to_nat(C.byte_len(data)), _) : Nat}
      {==}

def within_equal(before: Nat, after: Nat, cap: U32, eq: {before == after : Nat},
  bound: Budget.Within<before, cap>) -> Budget.Within<after, cap>:
  Budget.Within{remaining, proof} = bound
  Budget.Within{remaining, Equal.trans(Nat, U32.to_nat(cap), Nat.add(before, remaining),
    Nat.add(after, remaining), proof,
    Equal.cong(Nat, Nat, n => Nat.add(n, remaining), before, after, eq))}

def returned_cap(+draws: List<&2, Maybe<&2, String>>, +bytes: Bool,
  +vs: List<&2, Image.Verdict>, +corpus: String)
  -> Budget.Within<B.used(bytes, List.reverse(&2, Image.Fate, B.accumulator(B.trace(draws,
    Image.BWalk{vs, corpus, Image.room_new(), []})))), B.cap(bytes)>:
  +acc = B.accumulator(B.trace(draws, Image.BWalk{vs, corpus, Image.room_new(), []}))
  within_equal(B.used(bytes, acc), B.used(bytes, List.reverse(&2, Image.Fate, acc)), B.cap(bytes),
    Equal.sym(Nat, B.used(bytes, List.reverse(&2, Image.Fate, acc)), B.used(bytes, acc), used_reverse(bytes, acc)),
    production_used_cap(draws, bytes, vs, corpus))

def bind_run_zero(b: Image.Bind)
  -> {Image.bind_run(0n, b) == IO.pure(List<&2, Image.Fate>, []) : IO(List<&2, Image.Fate>)}:
  {==}
