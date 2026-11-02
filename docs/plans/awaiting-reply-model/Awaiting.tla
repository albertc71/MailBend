----------------------------- MODULE Awaiting -----------------------------
EXTENDS Naturals
CONSTANT AllowIncomplete
VARIABLES phase, replyComplete, sampleComplete, valid, positive, result
vars == <<phase, replyComplete, sampleComplete, valid, positive, result>>
Init == /\ phase = "Read"
        /\ replyComplete = TRUE /\ sampleComplete = TRUE /\ valid = TRUE /\ positive = FALSE /\ result = "none"
Observe == /\ phase = "Read"
           /\ phase' = "Classify"
           /\ replyComplete' \in BOOLEAN /\ sampleComplete' \in BOOLEAN /\ valid' \in BOOLEAN /\ positive' \in BOOLEAN
           /\ UNCHANGED result
Classify == /\ phase = "Classify"
            /\ phase' = "Done"
            /\ result' = IF valid /\ positive THEN "replied"
                          ELSE IF valid /\ (replyComplete \/ AllowIncomplete) THEN "awaiting"
                          ELSE "unknown"
            /\ UNCHANGED <<replyComplete, sampleComplete, valid, positive>>
Done == /\ phase = "Done" /\ UNCHANGED vars
Next == Observe \/ Classify \/ Done
NoFalseAbsence == result = "awaiting" => replyComplete /\ valid /\ ~positive
PositiveNeedsIdentity == result = "replied" => valid /\ positive
=============================================================================
