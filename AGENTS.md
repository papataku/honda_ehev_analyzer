# AGENTS.md — Honda e:HEV Analyzer project context

This repository is the source of truth for the Honda e:HEV Analyzer. Future coding agents and reviewers should read this file and `docs/PROJECT_CONTEXT.md` before changing behavior.

## Source of truth and versioning
- Canonical repository: `git@github.com:papataku/honda_ehev_analyzer.git`
- Keep `pyproject.toml` and `src/honda_analyzer/__init__.py` versions in sync.
- Record meaningful changes in `CHANGELOG.md` and release notes under `docs/`.
- Debug bundles and vehicle sessions must record tool version and build/source identity.
- Never treat generated ZIPs as the canonical source once a revision is committed here.

## Vehicle / adapter currently used for validation
- Vehicle: Honda STEP WGN e:HEV RP8, 2023 model.
- BLE adapter: KONNWEI KW905 / ELM327-compatible adapter.
- macOS analyzer host: Apple Silicon Mac.
- KW905 GATT observed on real hardware: service `FFF0`, notify `FFF1`, write `FFF2`.
- Observed CAN protocol: ISO 15765-4, 29-bit / 500 kbit/s.
- On this KW905, 29-bit transmit headers must use `ATCP18` + 3-byte `ATSH...`; an 8-digit `ATSH18DB33F1` returns `?`.

## Safety invariants
- Automated unknown DID discovery is read-only UDS service `0x22` only.
- Do not add `0x10` session changes, `0x27` SecurityAccess, write/routine/control services, or actuator commands to automated discovery without an explicit new design review.
- DID discovery is stationary-only. Vehicle speed must be rechecked while scanning; speed > 0 or inability to verify speed stops the scan.
- Driving mode never performs unknown DID discovery. It only reads DIDs previously observed as Positive/partial Positive.
- The driver must not operate the Mac while driving.

## Evidence policy
- Preserve RAW evidence. BLE notifications, ELM command/response text, timestamps, response CAN IDs, and partial long responses are evidence.
- Do not guess Honda-specific semantics from an ID, byte offset, correlation, or ECU source address.
- Mark unknowns as UNKNOWN / CANDIDATE / TODO-VEHICLE-TEST until evidence is sufficient.
- A high correlation is candidate evidence, not a signal definition.
- `BUFFER FULL` after a valid `62 DID` prefix is a partial Positive, not a nonexistent DID or link failure.

## Real-vehicle facts already established
- Mode 01 `010C` has responses from at least `18DAF101`, `18DAF102`, `18DAF106`, `18DAF10E`, `18DAF1EF`.
- `0105` coolant has been observed from `18DAF101`, `18DAF102`, `18DAF106`.
- Mode 01 PID `9A` is standard Hybrid/EV Vehicle System Data and is used for HV battery voltage/current; power is derived as V×I. On the RP8 logs, positive battery current/power corresponds to discharge and negative to charging/regeneration.
- Mode 01 PID `5B` is used as Hybrid/EV battery remaining charge (SOC).
- UDS DID `2012` responds from `18DAF101`. Byte 5 is a strong SOC mirror candidate from Session 13 but remains an unverified Honda-specific interpretation.
- DID `2012` has not shown convincing traction-motor RPM behavior.
- Session 15 established multiple Positive DIDs in the 0x2000 range and exposed long responses that can trigger KW905 `BUFFER FULL`.

## Current discovery strategy
- Prefer useful DIDs early without sacrificing eventual full coverage.
- Priority order: known `0x2000–0x20FF` band, coarse 16-sector sampling, `0x100` page sampling, immediate deep scan of promising pages, then fill all remaining DIDs.
- Full coverage remains the end goal; priority sampling must never permanently skip a range.
- Scanner supports multi-day resume. Positive and definitive unsupported results may be skipped on resume; transient timeout/NO DATA conditions should remain retryable.
- Target discovery rate is 10 req/s when the adapter can sustain it, using adaptive timing rather than command overlap.

## Long response handling
- First try normal headers.
- If a Positive response is truncated with `BUFFER FULL`, retry in compact form (for example header suppression where safe) to reduce ELM output volume.
- If still truncated, preserve the received prefix as `positive_partial`, mark it incomplete, and continue scanning instead of looping forever.
- Driving coverage must distinguish complete vs partial samples.

## Driving analysis strategy
- High-priority known references: vehicle speed, engine RPM, accelerator, HV SOC, HV voltage/current/power, and automatic state labels.
- During driving, round-robin all discovered Positive/partial Positive DIDs subject to adapter bandwidth.
- Persist a drive plan snapshot so post-analysis can compare intended vs actually sampled DIDs.
- Rank changing fields against EV-only vehicle speed, overall speed, engine RPM, HV current, HV power, and SOC. Candidate rankings are not confirmations.

## UI expectations
- Primary GUI is Japanese and designed for non-experts.
- Every major page should explain: what to do here, what can be learned, prerequisites, and why a disabled action is unavailable.
- Avoid silent no-ops. When an action cannot run, state the reason and next step.
- Keep the whole window resizable; pages must remain scrollable on small Mac displays.

## Testing / review expectations
- Run the full pytest suite and `python -m compileall -q src` before release.
- Add regression tests for every real-vehicle failure found in a session.
- Review from at least these perspectives: beginner UX, vehicle/UDS safety, BLE/ELM transport, persistence/replay, data analysis, and forensic reproducibility.
- When PySide6 is unavailable in the build environment, state that actual Qt rendering was not smoke-tested there; rely on Mac preflight for that part.

## Next work after v0.3.4
1. Continue stationary DID discovery with v0.3.4+ and verify compact retry turns some Session-15 partial DIDs into complete responses.
2. Accumulate Positive/partial Positive DID inventory across observed ECUs.
3. Once inventory coverage is useful, run a drive sweep that samples all discovered DIDs while recording known OBD/HV references.
4. Analyze for traction motor RPM, generator RPM, torque/current candidates; do not infer from names or ID proximity alone.


## Canonical bootstrap status
The one-time full-source import is tracked by GitHub Issue #1.
Until that issue is closed, the repository contains the durable project context
and a partial initial import, but it must not be treated as a complete buildable
v0.3.4 checkout. The verified bootstrap input is the v0.3.4 release ZIP with
SHA-256 `bae24021b3ca8b1587817821f2db7799ccac3f9dc707aecad962382a30c20d3d`.
Use `tools/bootstrap_v034_from_zip.sh` and
`docs/BOOTSTRAP_CANONICAL_SOURCE.md` to materialize the complete tested tree.
After Issue #1 is closed, GitHub `main` is the sole development source of truth.
