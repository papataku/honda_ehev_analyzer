# Phase 13 — SQLite → Replay → Analysis → HTML Golden Session

This phase closes the Mac-only regression loop before vehicle capture.

1. Generate the deterministic synthetic drive cycle.
2. Persist every synthetic observation incrementally into the same SQLite `raw_capture` table used by sessions.
3. Persist automatic state-transition markers.
4. Close the session cleanly.
5. Read the immutable RAW rows back as replay input.
6. Verify SHA-256 identity and deterministic analysis results.
7. Generate an HTML analysis report from the same run.
8. Regression-test crash recovery for an abandoned OPEN session.

## Evidence boundary
The generated payload, motor RPM, generator RPM and state transitions are **SYNTHETIC ONLY**. They are pipeline test truth, not Honda STEP WGN RP8 evidence, and must never be promoted into `KNOWN`/`VERIFIED` signal definitions.

## Acceptance gate
`pytest -q` must pass before vehicle work. After the first KW905 capture, a small anonymized real capture should be added under `tests/golden/` and replayed through the same protocol/analysis path. The expected results must be based only on observed RAW evidence.
