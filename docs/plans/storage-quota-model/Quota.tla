------------------------------ MODULE Quota ------------------------------
EXTENDS Naturals
CONSTANT BypassCapability
VARIABLES phase, advertised, valid, sessions, result
vars == <<phase, advertised, valid, sessions, result>>
Init == /\ phase = "Probe"
        /\ advertised \in BOOLEAN
        /\ valid \in BOOLEAN
        /\ sessions = 0
        /\ result = "unknown"
Gate == /\ phase = "Probe"
        /\ phase' = IF advertised \/ BypassCapability THEN "Quota" ELSE "Done"
        /\ sessions' = IF advertised \/ BypassCapability THEN 1 ELSE 0
        /\ UNCHANGED <<advertised, valid, result>>
Observe == /\ phase = "Quota"
           /\ phase' = "Done"
           /\ result' = IF valid THEN "known" ELSE "unknown"
           /\ UNCHANGED <<advertised, valid, sessions>>
Done == /\ phase = "Done" /\ UNCHANGED vars
Next == Gate \/ Observe \/ Done
CapabilityBudget == sessions = 1 => advertised
AtMostOneSession == sessions <= 1
KnownNeedsEvidence == result = "known" => advertised /\ valid
=============================================================================
