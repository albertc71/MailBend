--------------------------- MODULE Continuation ---------------------------
\* Design-time exploration only; runtime tests cover production wiring.
EXTENDS Naturals, FiniteSets
CONSTANTS Uids, H, ArrivalPredicate, UnboundedRange, SkipPrefix
VARIABLES after, matching, selected, nextAfter, more, delivered, phase
vars == <<after, matching, selected, nextAfter, more, delivered, phase>>
Init == /\ after = 0 /\ matching \in SUBSET Uids /\ selected = {}
        /\ nextAfter = 0 /\ more = FALSE /\ delivered = {} /\ phase = "Select"
Candidates == IF ArrivalPredicate THEN Uids ELSE matching
Eligible == {u \in Candidates : u > after /\ (UnboundedRange \/ u <= H)}
Max(s) == CHOOSE n \in s : \A u \in s : u <= n
Select == /\ phase = "Select" /\ phase' = "Publish"
          /\ selected' \in SUBSET Eligible /\ Cardinality(selected') <= 1
          /\ (Eligible # {} => selected' # {})
          /\ \A u \in selected' : \A v \in Eligible : v <= u => v \in selected'
          /\ more' = (selected' # Eligible)
          /\ nextAfter' = IF SkipPrefix \/ ~more' THEN H ELSE Max(selected')
          /\ UNCHANGED <<after, matching, delivered>>
Publish == /\ phase = "Publish" /\ phase' = IF more THEN "Flags" ELSE "Done"
           /\ after' = nextAfter /\ delivered' = delivered \cup selected
           /\ UNCHANGED <<matching, selected, nextAfter, more>>
Flags == /\ phase = "Flags" /\ phase' = "Select"
         /\ matching' \in SUBSET Uids /\ selected' = {}
         /\ UNCHANGED <<after, nextAfter, more, delivered>>
Stop == /\ phase = "Done" /\ UNCHANGED vars
Next == Select \/ Publish \/ Flags \/ Stop
WithinSnapshot == selected \subseteq {u \in Uids : u <= H}
UnseenOnly == phase = "Publish" => selected \subseteq matching
NoOmittedMatchSkipped == phase = "Publish" => \A u \in Eligible \ selected : u > nextAfter
NoRepeat == phase = "Publish" => selected \cap delivered = {}
StrictPartialProgress == (phase = "Publish" /\ more) => nextAfter > after
CompletedAtOriginalH == phase = "Done" => after = H
=============================================================================
