# Phase 18 — Drive Test Mode

Adds a passenger-oriented full-size test screen for real-vehicle logging.

- Large STOP / EV / ENGINE ON / ACCEL / CRUISE / REGEN / CUSTOM marker buttons.
- Existing keyboard shortcuts 1–6 remain available.
- Last marker is shown prominently to reduce accidental double marking.
- Communication health is refreshed from persisted command measurements.
- Warnings concern analyzer communication quality only; they do not make vehicle-safety judgments.
- Poor communication recommends preserving the session and not starting scans. Drive Test Mode itself never starts DID scanning.
- END TEST closes the current session and exports the session-scoped Debug Bundle.
- Raw capture remains incremental in SQLite; no large end-of-test memory buffer is introduced.

The intended operator is a passenger. The driver must not interact with the Mac while driving.
