---------------------------- MODULE Checkpoint ----------------------------
\* Design-time exploration only: CI does not run or compare this model to code.
EXTENDS Naturals, FiniteSets
CONSTANT Uids
VARIABLES done, high, unseen, selected, more, cursor
vars == <<done, high, unseen, selected, more, cursor>>
Init == /\ done = FALSE /\ high \in Uids
        /\ unseen \in SUBSET Uids
        /\ selected = {} /\ more = FALSE /\ cursor = 0
Eligible == {u \in unseen : u > 0 /\ u <= high}
Max(s) == CHOOSE n \in s : \A u \in s : u <= n
Select == /\ done' = TRUE /\ selected' \in SUBSET Eligible
          /\ (Eligible # {} => selected' # {})
          /\ \A u \in selected' : \A v \in Eligible : v <= u => v \in selected'
          /\ more' = (selected' # Eligible)
          /\ cursor' = IF more' THEN IF selected' = {} THEN 0 ELSE Max(selected') ELSE high
          /\ UNCHANGED <<high, unseen>>
Next == Select
NoOmittedUnseenSkipped == done => \A u \in Eligible \ selected : u > cursor
CompleteUsesHighWater == (done /\ ~more /\ selected = Eligible) => cursor = high
SnapshotExcludesRaces == selected \subseteq {u \in Uids : u <= high}
=============================================================================
