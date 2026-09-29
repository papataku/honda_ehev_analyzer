# 0.2.3 — first real RP8/KW905 capture correction

This build is based on the first real RP8/KW905 logs.

- Fixes classic ELM327 v1.5 29-bit header selection: `ATCP18` + 3-byte `ATSH` instead of rejected 8-digit `ATSH`.
- Live Known Polling stops and reports header-selection errors instead of silently looping.
- Vehicle Readiness uses the same clone-compatible header sequence.
- Simulator now rejects the old 8-digit command so Preflight covers the real failure mode.
- Payload Analysis no longer silently ignores Analyze when A/B ranges are missing.
- Adds explicit current-range / Set A / Set B controls, source-session display, and zero-sample diagnostics.

The previously captured readiness responses remain valid raw evidence. The drive interval after the old Live Polling Start cannot contain normal PID polling because the old build aborted at each rejected header command.
