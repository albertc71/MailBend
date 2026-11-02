------------------------- MODULE CandidateFilters -------------------------
EXTENDS Naturals
CONSTANT PromoteCoverage
VARIABLES phase, sampleComplete, reportedComplete, replyComplete, valid,
          positive, lists, automated, listSignal, autoSignal, excluded, result
vars == <<phase, sampleComplete, reportedComplete, replyComplete, valid,
          positive, lists, automated, listSignal, autoSignal, excluded, result>>
Init == /\ phase = "Sample"
        /\ sampleComplete \in BOOLEAN /\ reportedComplete = sampleComplete
        /\ replyComplete \in BOOLEAN /\ valid \in BOOLEAN /\ positive \in BOOLEAN
        /\ lists \in BOOLEAN /\ automated \in BOOLEAN
        /\ listSignal \in BOOLEAN /\ autoSignal \in BOOLEAN
        /\ excluded = FALSE /\ result = "none"
Filter == /\ phase = "Sample"
          /\ excluded' = ((lists /\ listSignal) \/ (automated /\ autoSignal))
          /\ reportedComplete' = (sampleComplete \/ (PromoteCoverage /\ excluded'))
          /\ phase' = "Classify"
          /\ UNCHANGED <<sampleComplete, replyComplete, valid, positive,
                         lists, automated, listSignal, autoSignal, result>>
Classify == /\ phase = "Classify"
            /\ phase' = "Done"
            /\ result' = IF excluded THEN "excluded"
                          ELSE IF valid /\ positive THEN "replied"
                          ELSE IF valid /\ replyComplete THEN "awaiting"
                          ELSE "unknown"
            /\ UNCHANGED <<sampleComplete, reportedComplete, replyComplete,
                           valid, positive, lists, automated, listSignal,
                           autoSignal, excluded>>
Done == /\ phase = "Done" /\ UNCHANGED vars
Next == Filter \/ Classify \/ Done
NoFalseAbsence == result = "awaiting" => valid /\ replyComplete /\ ~positive
PositiveRetained == phase = "Done" /\ ~excluded /\ valid /\ positive => result = "replied"
DisabledRetains == ~lists /\ ~automated => ~excluded
NoInventedCoverage == reportedComplete => sampleComplete
=============================================================================
