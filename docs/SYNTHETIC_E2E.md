# Synthetic End-to-End Drive Cycle

Purpose: exercise the analysis path before taking the Mac into the vehicle.

States: STOP, EV_LOW, EV_MEDIUM, EV_HIGH, ENGINE_ON, ACCEL, CRUISE, REGEN.

The cycle intentionally includes `Engine RPM ~= 0 && Vehicle Speed > 60 km/h`, which is the key discriminator requested for Drive Motor RPM discovery. State classification is recomputable with threshold changes. Candidate detectors return score/evidence/contradictions and never VERIFIED.

The synthetic motor/generator formulas are test fixtures only. They do not represent RP8 gearing, ECU layout, DID offsets, scale, or units and must never be exported as vehicle signal definitions.
