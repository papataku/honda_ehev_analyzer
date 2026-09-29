# 0.3.1 — DID Discovery / Drive Sweep release

## Added

- Guided stationary UDS 0x22 DID discovery for observed ECU responders.
- `0000–FFFF` range support with rate control, progress, time estimate, stop and cross-session resume.
- 2-second vehicle-speed fail-safe during discovery.
- 256-DID multi-ECU chunk rotation.
- Cross-session Positive DID inventory.
- Session-specific Positive DID drive plan snapshot.
- Low-rate Positive DID round-robin during live driving.
- DID drive Coverage table.
- Automated field ranking against EV vehicle speed, all speed, engine RPM, HV power, HV current and SOC.
- Debug Bundle export of discovery/plan/drive samples.
- Preflight DID pipeline self-test.

## Safety boundary

Discovery uses only UDS 0x22 in the current diagnostic session. It does not use DiagnosticSessionControl, SecurityAccess, writes, routines or unknown-service fuzzing. Unknown DID discovery is stationary-only; driving reads only DIDs that were previously Positive.

## Verification

- Full regression suite: 125 tests expected after Phase 31 tests are included.
- Python compileall required to pass.
- Session 13 DID 2012 regression: no strong motor-RPM candidate, consistent with earlier analysis.
- Qt offscreen smoke test could not be executed in the build container because PySide6 is not installed there; `Preflight.command` installs/checks PySide6 on the target Mac.
