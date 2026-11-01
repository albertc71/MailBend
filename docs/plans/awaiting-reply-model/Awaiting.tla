----------------------------- MODULE Awaiting -----------------------------
EXTENDS Naturals
CONSTANT AllowIncomplete
VARIABLES phase, complete, valid, positive, result
vars == <<phase, complete, valid, positive, result>>
Init == /\ phase = "Read"
        /\ complete = TRUE /\ valid = TRUE /\ positive = FALSE /\ result = "none"
Observe == /\ phase = "Read"
           /\ phase' = "Classify"
           /\ complete' \in BOOLEAN /\ valid' \in BOOLEAN /\ positive' \in BOOLEAN
           /\ UNCHANGED result
Classify == /\ phase = "Classify"
            /\ phase' = "Done"
            /\ result' = IF valid /\ positive THEN "replied"
                          ELSE IF valid /\ (complete \/ AllowIncomplete) THEN "awaiting"
                          ELSE "unknown"
            /\ UNCHANGED <<complete, valid, positive>>
Done == /\ phase = "Done" /\ UNCHANGED vars
Next == Observe \/ Classify \/ Done
NoFalseAbsence == result = "awaiting" => complete /\ valid /\ ~positive
PositiveNeedsIdentity == result = "replied" => valid /\ positive
=============================================================================
