------------------------------ MODULE Brief ------------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Uids, Groups, AllowMissing, AllowBudgetLoss
VARIABLES phase, selected, fetched, observed, assigned, fits, checkpoint
vars == <<phase, selected, fetched, observed, assigned, fits, checkpoint>>
Init == /\ phase = "Search" /\ selected = {} /\ fetched = {} /\ observed = {}
        /\ assigned = [u \in {} |-> "unknown_people"] /\ fits = FALSE /\ checkpoint = FALSE
Search == /\ phase = "Search" /\ phase' = "Headers"
          /\ selected' \in SUBSET Uids
          /\ UNCHANGED <<fetched, observed, assigned, fits, checkpoint>>
Headers == /\ phase = "Headers" /\ phase' = "Group"
           /\ fetched' \in SUBSET selected /\ observed' \in SUBSET selected
           /\ UNCHANGED <<selected, assigned, fits, checkpoint>>
Group == /\ phase = "Group"
         /\ phase' = IF fetched = selected \/ AllowMissing THEN "Budget" ELSE "Failed"
         /\ assigned' \in [fetched -> Groups]
         /\ \A u \in fetched : assigned'[u] = "people" => u \in observed
         /\ fits' \in BOOLEAN
         /\ UNCHANGED <<selected, fetched, observed, checkpoint>>
Budget == /\ phase = "Budget" /\ phase' = IF fits \/ AllowBudgetLoss THEN "Returned" ELSE "Failed"
          /\ checkpoint' = (fits \/ AllowBudgetLoss)
          /\ UNCHANGED <<selected, fetched, observed, assigned, fits>>
Stop == /\ phase \in {"Returned", "Failed"} /\ UNCHANGED vars
Next == Search \/ Headers \/ Group \/ Budget \/ Stop
CompletePartition == phase = "Returned" => DOMAIN assigned = selected
BudgetCheckpoint == checkpoint => fits
FailedHasNoCheckpoint == phase = "Failed" => ~checkpoint
PeopleNeedObservation == \A u \in DOMAIN assigned : assigned[u] = "people" => u \in observed
=============================================================================
