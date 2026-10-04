# Development State

Updated baseline: v0.3.4 — Long DID Recovery.

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

## iPad native validation — 2026-10-04

The first physical iPad/KW905/RP8 capture has passed the iPad hardware gate.

- CoreBluetooth selected the expected KW905 path: FFF0 / FFF1 notify / FFF2 write-without-response.
- ELM initialization reported ELM327 v1.5 and ISO 15765-4 CAN 29-bit / 500 kbps.
- Standard known signals 010C / 010D / 0105 / 015B / 019A were read successfully.
- The iPad SQLite capture closed cleanly and passed `PRAGMA integrity_check`.
- Safe ECU census observed the same Mode 01 responder set used by the macOS workflow.
- Source-01 stationary DID discovery covered 2000–207B before manual stop.
- The scanned subset produced exactly 6 complete Positive + 11 positive_partial DIDs matching the prior Session-15 source-01 inventory in that range.
- Real BUFFER FULL handling was exercised for all 11 long positives.
- ATH0 compact retry increased preserved application prefixes from about 70–78 bytes to 108–112 bytes, but still did not recover the complete long payload.
- The raw user capture is not committed; only these validation conclusions are retained.

With the hardware gate passed, the iPad branch is moving to the same adaptive full-range ordering as macOS, while retaining read-only 0x22 and stationary speed monitoring.

## Current unresolved goals
1. Continue stationary discovery to build a larger Positive DID inventory across observed responders.
2. Verify compact retry can turn some Session-15-style partial positives into complete payloads on the real KW905.
3. Once inventory coverage is useful, perform a drive sweep and rank fields for traction motor RPM, generator RPM and torque/current-related signals.
4. Validate promising candidates over multiple independent drive states before promoting any Honda-specific definition.

## Things not yet proven
- Human-readable role names for response CAN IDs.
- Traction motor RPM DID/field.
- Generator RPM DID/field.
- Honda-specific torque/current DID semantics beyond standard PID 9A HV current.
- Whether special diagnostic sessions/security would expose additional DIDs; those operations are intentionally outside the current automated safety scope.

## Next expected user workflow
For v0.3.4, the immediate test is stationary DID discovery, not driving. Confirm that long DIDs such as 2019 no longer stall the scan and are shown as complete or partial. Export a Debug Bundle after the run for analysis.


## Canonical repository status
The one-time ZIP-to-Git transition is complete.

- GitHub `main` contains the full v0.3.4 source, tests, documentation, launch scripts and signal assets.
- Python 3.12 CI installs the package, runs the full test suite, and runs `compileall`.
- Canonicalization was completed by commits `18c4987` / `09a634f`, followed by the CI hardening commit `3c5c673`.
- The full regression run passed **146 tests** and `python -m compileall -q src`.
- Temporary bootstrap helpers were removed after verification.
- GitHub `main` is now the sole development source of truth. Release ZIPs are derived artifacts only.
