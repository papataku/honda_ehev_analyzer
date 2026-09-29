# 0.2.9 Release Notes — Session 12 Hybrid/EV decode

This release is based on the RP8 drive capture `session-12-20260926-103939`.

## Vehicle evidence

- ~20 minute session, 6,579 ELM commands and 26,997 BLE RAW notifications.
- No recorded ELM command failures in the capture.
- 46 Mode 01 PIDs discovered through the support bitmap walk.
- PID 49 accelerator pedal D had an RP8 released baseline around 20%, so absolute pedal position is not treated as a universal 0%-at-release switch.
- PID 5B decoded as Hybrid/EV Battery Pack Remaining Charge (SOC): ~40.4–50.6% in this capture.
- PID 9A decoded as Hybrid/EV Vehicle System Data:
  - voltage ~238.3–264.0 V
  - current ~-104.6–+116.4 A
  - derived power ~-27.5–+27.8 kW
- On this RP8 capture, positive PID 9A current/power aligns with traction discharge and negative values align with charging/regeneration. This direction label is vehicle-evidence-backed, not guessed from the CAN response ID.

## UI / analysis changes

- Live Dashboard: HV SOC / voltage / current / power.
- Offline Replay: the same Hybrid/EV values are reconstructed from immutable command evidence.
- Correlation page: HV SOC and HV power are selectable references.
- Auto-state: deceleration + negative measured HV power can be labelled `回生`; without HV power it remains a candidate.
- AUTO_STATE persistence is debounced for 1.2 s to reduce one-km/h quantization chatter.
- Payload Analysis labels PID 9A as a standard/known structure and DID 2012 as unknown.
- Simulator emits standards-shaped synthetic PID 5B and PID 9A data.

## Still unknown

- DID 2012 byte semantics.
- Traction motor/generator RPM and torque.
- Human-readable ECU role names for the five observed diagnostic response IDs.

No unknown signal is promoted to VERIFIED from correlation alone.
