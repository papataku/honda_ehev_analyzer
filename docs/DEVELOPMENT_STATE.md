# Development State

Updated baseline: v0.3.4 — Long DID Recovery, plus Session 16 vehicle evidence and Phase 35 runtime hardening.

## Working features
- macOS BLE connection to KW905 and GATT discovery.
- ELM command reconstruction through `>` across fragmented BLE notifications.
- Vehicle Readiness workflow and Debug Bundle export.
- Live/replay standard OBD signals and standard Hybrid/EV PID 5B/9A decoding.
- Automatic drive-state labeling from known signals.
- Passive ECU responder census and safe physical probe.
- Stationary read-only UDS `0x22` DID discovery with persistent resume.
- Adaptive DID ordering: 0x2000 priority, sector/page sampling, promising-page deep scan, final fill.
- Target ~10 req/s scan rate where KW905 response timing allows.
- Positive inventory, positive-partial handling for `BUFFER FULL`, compact retry.
- Driving sweep of discovered DID inventory with plan snapshot and coverage.
- Candidate field expansion/correlation against known references.

## Latest vehicle findings
- Mode 01 responder IDs: 18DAF101 / 102 / 106 / 10E / 1EF observed.
- Standard PID 5B provides usable HV remaining charge / SOC.
- Standard PID 9A provides usable HV voltage and signed current; HV power is derived V×I.
- DID 2012 byte 5 is a strong SOC-mirror candidate.
- Session 15 found 17 Positive/partial-positive DIDs in ECU source 01 around 0x2000; see PROJECT_CONTEXT.
- Several long positives reached `BUFFER FULL`; v0.3.4 preserves and retries them.
- Session 16 expanded the cumulative Positive/partial-Positive inventory to 81 entries, with a large newly observed ECU-source 0E cluster in the 0x2200/0x2600 regions and ECU-source EF positives at C000/C020.
- Session 16 confirmed the stationary safety guard by automatically stopping DID discovery at measured vehicle speeds of 13 km/h and 5 km/h.
- Session 16 compact ATH0 retry preserved longer prefixes but did not fully recover the long Positive payloads; these remain evidence-preserving `positive_partial` records.
- Session 16 again confirmed DID 2012 byte 5 as a strong PID-5B SOC mirror candidate (Pearson about 0.9985 in the available aligned points).

## Current unresolved goals
1. Perform a longer drive sweep with the expanded cross-session Positive inventory, especially the newly discovered ECU-source 0E/EF DIDs.
2. Obtain at least five changing samples per DID where possible so the existing field-ranking pipeline can evaluate EV-speed, engine-RPM, HV-power/current and SOC correlations.
3. Rank and validate traction motor RPM, generator RPM and torque/current-related candidates across multiple independent driving states.
4. Keep long DIDs as partial evidence unless a future read-only transport path can retrieve the complete bytes; the current KW905 compact retry is not sufficient for all of them.
5. Validate promising candidates over multiple independent drive states before promoting any Honda-specific definition.

## Things not yet proven
- Human-readable role names for response CAN IDs.
- Traction motor RPM DID/field.
- Generator RPM DID/field.
- Honda-specific torque/current DID semantics beyond standard PID 9A HV current.
- Whether special diagnostic sessions/security would expose additional DIDs; those operations are intentionally outside the current automated safety scope.

## Next expected user workflow
Session 16 has completed the immediate stationary-discovery validation: long responses no longer stall the scan, partial data is preserved, and the vehicle-speed guard stopped discovery correctly while moving. The next useful vehicle test is now a **20–30 minute drive sweep** started after the expanded Positive inventory is loaded. Capture varied natural EV, engine-on, acceleration, cruise and regeneration states, then export a Debug Bundle and run DID coverage/ranking. Do not run unknown DID discovery while moving.


## Canonical repository status
The one-time ZIP-to-Git transition is complete.

- GitHub `main` contains the full v0.3.4 source, tests, documentation, launch scripts and signal assets.
- Python 3.12 CI installs the package, runs the full test suite, and runs `compileall`.
- Canonicalization was completed by commits `18c4987` / `09a634f`, followed by the CI hardening commit `3c5c673`.
- The full regression run passed **146 tests** and `python -m compileall -q src`.
- Temporary bootstrap helpers were removed after verification.
- GitHub `main` is now the sole development source of truth. Release ZIPs are derived artifacts only.
