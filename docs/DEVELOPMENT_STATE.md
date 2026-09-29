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


## Canonical bootstrap status
The one-time full-source import is tracked by GitHub Issue #1.
Until that issue is closed, the repository contains the durable project context
and a partial initial import, but it must not be treated as a complete buildable
v0.3.4 checkout. The verified bootstrap input is the v0.3.4 release ZIP with
SHA-256 `bae24021b3ca8b1587817821f2db7799ccac3f9dc707aecad962382a30c20d3d`.
Use `tools/bootstrap_v034_from_zip.sh` and
`docs/BOOTSTRAP_CANONICAL_SOURCE.md` to materialize the complete tested tree.
After Issue #1 is closed, GitHub `main` is the sole development source of truth.
