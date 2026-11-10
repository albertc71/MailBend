import Base
import ../../src/pacing.bend as P

# The prior timestamp is generalized; the public literal discharges monotonicity.
law full_budget_refuses_after:
  for before: Nat
  for monotone: {Nat.is_le(before, 1000n) == True{} : Bool}
  {P.admit(P.PacingReady{6, Some{before}, [P.PacingEntry{6, 1000n}]}, 1, 1000n) ==
    P.PacingRefused{P.PacingWait{601n},
      P.PacingReady{6, Some{before}, [P.PacingEntry{6, 1000n}]}} : P.Admission}

def full_budget_refuses_after(before, monotone):
  %Equal.sym(Bool, Nat.is_le(before, 1000n), True{}, monotone) :
    {P.admit.clock(_ && Nat.is_le(1000n, P.clock_cap()),
      6, Some{before}, 1000n, 1, [P.PacingEntry{6, 1000n}]) ==
      P.PacingRefused{P.PacingWait{601n},
        P.PacingReady{6, Some{before}, [P.PacingEntry{6, 1000n}]}} : P.Admission}
  {==}

# Literal independent boundary examples. No provider or IO claim.
law full_budget_refuses:
  {P.admit(P.PacingReady{6, Some{1000n}, [P.PacingEntry{6, 1000n}]}, 1, 1000n) ==
    P.PacingRefused{P.PacingWait{601n},
      P.PacingReady{6, Some{1000n}, [P.PacingEntry{6, 1000n}]}} : P.Admission}

def full_budget_refuses():
  full_budget_refuses_after(1000n, {==})

law exact_ten_minutes_retained:
  {P.admit(P.PacingReady{6, Some{1000n}, [P.PacingEntry{6, 1000n}]}, 1, 601000n) ==
    P.PacingRefused{P.PacingWait{1n},
      P.PacingReady{6, Some{1000n}, [P.PacingEntry{6, 1000n}]}} : P.Admission}

def exact_ten_minutes_retained():
  {==}

law floor_guard_releases:
  {P.admit(P.PacingReady{6, Some{1000n}, [P.PacingEntry{6, 1000n}]}, 1, 601001n) ==
    P.PacingAdmitted{P.PacingFlight{6, 601001n, [], 1}} : P.Admission}

def floor_guard_releases():
  {==}

law staggered_waits_for_enough:
  {P.admit(P.PacingReady{6, Some{2000n},
    [P.PacingEntry{2, 2000n}, P.PacingEntry{4, 1000n}]}, 4, 10000n) ==
    P.PacingRefused{P.PacingWait{592n}, P.PacingReady{6, Some{2000n},
      [P.PacingEntry{2, 2000n}, P.PacingEntry{4, 1000n}]}} : P.Admission}

def staggered_waits_for_enough():
  {==}

law staggered_release_keeps_newer:
  {P.admit(P.PacingReady{6, Some{2000n},
    [P.PacingEntry{2, 2000n}, P.PacingEntry{4, 1000n}]}, 4, 601001n) ==
    P.PacingAdmitted{P.PacingFlight{6, 601001n, [P.PacingEntry{2, 2000n}], 4}} : P.Admission}

def staggered_release_keeps_newer():
  {==}

law too_large_is_not_waitable:
  {P.admit(P.PacingReady{5, None{}, []}, 6, 0n) ==
    P.PacingRefused{P.PacingTooLarge{}, P.PacingReady{5, None{}, []}} : P.Admission}

def too_large_is_not_waitable():
  {==}

law zero_cost_is_invalid:
  {P.admit(P.PacingReady{5, None{}, []}, 0, 0n) ==
    P.PacingRefused{P.PacingBadCost{}, P.PacingReady{5, None{}, []}} : P.Admission}

def zero_cost_is_invalid():
  {==}

law backward_clock_fault_keeps_charge:
  {P.admit(P.PacingReady{8, Some{1000n}, [P.PacingEntry{8, 1000n}]}, 1, 999n) ==
    P.PacingRefused{P.PacingBroken{},
      P.PacingFaulted{8, [P.PacingEntry{8, 1000n}], 0}} : P.Admission}

def backward_clock_fault_keeps_charge():
  {==}

law completion_keeps_full_charge:
  {P.finish(P.PacingFlight{8, 1000n, [], 8}, 2000n) ==
    P.PacingReady{8, Some{2000n}, [P.PacingEntry{8, 2000n}]} : P.Ledger}

def completion_keeps_full_charge():
  {==}

law completion_regression_faults:
  {P.finish(P.PacingFlight{8, 1000n, [], 8}, 999n) ==
    P.PacingFaulted{8, [], 8} : P.Ledger}

def completion_regression_faults():
  {==}

law raw_failure_charge_never_expires:
  {P.admit(P.fault(P.PacingFlight{8, 1000n, [], 8}), 1, 9000000n) ==
    P.PacingRefused{P.PacingBroken{}, P.PacingFaulted{8, [], 8}} : P.Admission}

def raw_failure_charge_never_expires():
  {==}

# Conditional at the capacity decision seam, not proof that IO uses it.
law capacity_refusal_has_no_flight:
  for budget: U32
  for last: Maybe<&2, Nat>
  for now: Nat
  for cost: U32
  for entries: List<&1, P.Entry>
  for wait: Nat
  {P.admit.capacity(False{}, budget, last, now, cost, entries, wait) ==
    P.PacingRefused{P.PacingWait{wait}, P.PacingReady{budget, last, entries}} : P.Admission}

def capacity_refusal_has_no_flight(budget, last, now, cost, entries, wait):
  {==}

law excess_does_not_fit:
  for budget: U32
  for cost: U32
  for used: Nat
  for excess: {Nat.is_le(used, P.room(budget, cost)) == False{} : Bool}
  {P.fits(budget, cost, used) == False{} : Bool}

def excess_does_not_fit(budget, cost, used, excess):
  %Equal.sym(Bool, Nat.is_le(used, P.room(budget, cost)), False{}, excess) :
    {P.fits.capacity(_, budget, cost) == False{} : Bool}
  {==}

law inspected_excess_refuses_unchanged:
  for budget: U32
  for last: Maybe<&2, Nat>
  for now: Nat
  for cost: U32
  for entries: List<&1, P.Entry>
  for used: Nat
  for wait: Nat
  for excess: {Nat.is_le(used, P.room(budget, cost)) == False{} : Bool}
  {P.admit.inspected(budget, last, now, cost, (entries, (used, wait))) ==
    P.PacingRefused{P.PacingWait{wait}, P.PacingReady{budget, last, entries}} : P.Admission}

def inspected_excess_refuses_unchanged(budget, last, now, cost, entries, used, wait, excess):
  %Equal.sym(Bool, P.fits(budget, cost, used), False{},
    excess_does_not_fit(budget, cost, used, excess)) :
    {P.admit.capacity(_, budget, last, now, cost, entries, wait) ==
      P.PacingRefused{P.PacingWait{wait}, P.PacingReady{budget, last, entries}} : P.Admission}
  {==}

law mixed_expiry_refusal_keeps_both:
  {P.admit(P.PacingReady{6, Some{2000n},
    [P.PacingEntry{2, 2000n}, P.PacingEntry{4, 1000n}]}, 5, 601001n) ==
    P.PacingRefused{P.PacingWait{1n}, P.PacingReady{6, Some{2000n},
      [P.PacingEntry{2, 2000n}, P.PacingEntry{4, 1000n}]}} : P.Admission}

def mixed_expiry_refusal_keeps_both():
  {==}
