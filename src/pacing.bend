# One serial session owns this affine ledger. No mail plan or IO lives here.
import Base

type Entry is Type:
  PacingEntry{cost: U32, completed: Nat}

type Ledger is Type:
  PacingOff{}
  PacingInvalid{}
  PacingReady{budget: U32, last: Maybe<&2, Nat>, entries: List<&1, Entry>}
  PacingFaulted{budget: U32, entries: List<&1, Entry>, held: U32}

type Flight is Type:
  PacingFlight{budget: U32, admitted: Nat, entries: List<&1, Entry>, cost: U32}

type Reason is Data:
  PacingBadConfig{}
  PacingBadCost{}
  PacingTooLarge{}
  PacingWait{seconds: Nat}
  PacingBroken{}

type Admission is Type:
  PacingRefused{reason: Reason, ledger: Ledger}
  PacingAdmitted{flight: Flight}

def budget_ok(+budget: U32) -> Bool:
  U32.is_ge(budget, 1) && U32.is_le(budget, 4096)

def room(budget: U32, cost: U32) -> Nat:
  Nat.sub(U32.to_nat(budget), U32.to_nat(cost))

def fits.capacity(enough: Bool, +budget: U32, +cost: U32) -> Bool:
  match enough:
    case False{}:
      False{}
    case True{}:
      budget_ok(budget) && U32.is_ge(cost, 1) && U32.is_le(cost, budget)

def fits(+budget: U32, +cost: U32, used: Nat) -> Bool:
  fits.capacity(Nat.is_le(used, room(budget, cost)), budget, cost)

def clock_cap() -> Nat:
  Nat.add(Nat.mul(2097152n, 4294967295n), 2097151n)

# The floor guard covers quantization only, not a failing or jumping clock.
def clock_ok(last: Maybe<&2, Nat>, +now: Nat) -> Bool:
  match last:
    case None{}:
      Nat.is_le(now, clock_cap())
    case Some{before}:
      Nat.is_le(before, now) && Nat.is_le(now, clock_cap())

def retained(completed: Nat, now: Nat) -> Bool:
  Nat.is_lt(Nat.sub(now, completed), 600001n)

def seconds_left(completed: Nat, now: Nat) -> Nat:
  Nat.div(Nat.add(Nat.sub(600001n, Nat.sub(now, completed)), 999n), 1000n)

# Entries are newest first. The first prefix exceeding room sets the wait.
# Reconstruct the entire input so an ordinary refusal commits no pruning.
def inspect.put(cost: U32, completed: Nat, r: List<&1, Entry> & (Nat & Nat)) ->
  List<&1, Entry> & (Nat & Nat):
  (entries, metrics) = r
  (PacingEntry{cost, completed} <> entries, metrics)

def inspect(
  entries: List<&1, Entry>, +now: Nat, +capacity: Nat, used: Nat, +wait: Nat
) -> List<&1, Entry> & (Nat & Nat):
  match entries:
    case Nil{}:
      ([], (used, wait))
    case PacingEntry{+cost, +completed} <> tail:
      +next : Nat = Nat.add(used,
        Bool.pick(Nat, retained(completed, now), U32.to_nat(cost), 0n))
      next_wait : Nat = Bool.pick(Nat,
        Nat.is_eq(wait, 0n) && Nat.is_gt(next, capacity),
        seconds_left(completed, now), wait)
      inspect.put(cost, completed, inspect(tail, now, capacity, next, next_wait))

def prune.put(keep: Bool, cost: U32, completed: Nat, tail: List<&1, Entry>) -> List<&1, Entry>:
  match keep:
    case True{}:
      PacingEntry{cost, completed} <> tail
    case False{}:
      tail

def prune(entries: List<&1, Entry>, +now: Nat) -> List<&1, Entry>:
  match entries:
    case Nil{}:
      []
    case PacingEntry{cost, +completed} <> tail:
      prune.put(retained(completed, now), cost, completed, prune(tail, now))

def admit.capacity(
  enough: Bool, budget: U32, last: Maybe<&2, Nat>, +now: Nat, cost: U32,
  entries: List<&1, Entry>, wait: Nat
) -> Admission:
  match enough:
    case True{}:
      PacingAdmitted{PacingFlight{budget, now, prune(entries, now), cost}}
    case False{}:
      PacingRefused{PacingWait{wait}, PacingReady{budget, last, entries}}

def admit.inspected(
  +budget: U32, last: Maybe<&2, Nat>, now: Nat, +cost: U32,
  r: List<&1, Entry> & (Nat & Nat)
) -> Admission:
  (entries, metrics) = r
  (used, wait) = metrics
  admit.capacity(fits(budget, cost, used), budget, last, now, cost, entries, wait)

def admit.clock(
  valid: Bool, +budget: U32, last: Maybe<&2, Nat>, +now: Nat, +cost: U32,
  entries: List<&1, Entry>
) -> Admission:
  match valid:
    case False{}:
      PacingRefused{PacingBroken{}, PacingFaulted{budget, entries, 0}}
    case True{}:
      admit.inspected(budget, last, now, cost,
        inspect(entries, now, room(budget, cost), 0n, 0n))

def admit.cost(
  valid: Bool, +budget: U32, +last: Maybe<&2, Nat>, +now: Nat, +cost: U32,
  entries: List<&1, Entry>
) -> Admission:
  match valid:
    case False{}:
      PacingRefused{Bool.pick(Reason, U32.is_zero(cost), PacingBadCost{}, PacingTooLarge{}),
        PacingReady{budget, last, entries}}
    case True{}:
      admit.clock(clock_ok(last, now), budget, last, now, cost, entries)

def admit(ledger: Ledger, +cost: U32, now: Nat) -> Admission:
  match ledger:
    case PacingOff{}:
      PacingRefused{PacingBadConfig{}, PacingOff{}}
    case PacingInvalid{}:
      PacingRefused{PacingBadConfig{}, PacingInvalid{}}
    case PacingFaulted{budget, entries, held}:
      PacingRefused{PacingBroken{}, PacingFaulted{budget, entries, held}}
    case PacingReady{+budget, last, entries}:
      admit.cost(budget_ok(budget) && U32.is_ge(cost, 1) && U32.is_le(cost, budget),
        budget, last, now, cost, entries)

def fault(flight: Flight) -> Ledger:
  PacingFlight{budget, admitted, entries, cost} = flight
  PacingFaulted{budget, entries, cost}

def finish.if(valid: Bool, flight: Flight, +now: Nat) -> Ledger:
  match valid:
    case False{}:
      fault(flight)
    case True{}:
      PacingFlight{budget, admitted, entries, cost} = flight
      PacingReady{budget, Some{now}, PacingEntry{cost, now} <> entries}

def finish(flight: Flight, +now: Nat) -> Ledger:
  PacingFlight{budget, +admitted, entries, cost} = flight
  finish.if(clock_ok(Some{admitted}, now), PacingFlight{budget, admitted, entries, cost}, now)
