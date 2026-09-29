# Pre-vehicle 0.2.2 release notes

This build closes the two software-side gaps identified in the 0.2.1 audit before the first RP8 drive capture.

## Completed

- Dedicated asynchronous SQLite writer for RAW BLE, command/response, event, and device records.
- WAL + FULL synchronous durability; short batches; no silent capture-record dropping.
- Flush barriers before session close, Debug Bundle export, readiness completion, payload analysis, offline replay load, and application shutdown.
- Offline Replay tab for persisted sessions with Play/Pause/Step/Seek and 0.5–20x speed.
- Historical Engine RPM / Vehicle Speed / Coolant reconstruction via the same decoder used by live polling.
- Historical `019A` and `222012` shown as raw hexadecimal only.
- Event-marker replay on the same session-relative plot timeline.
- Historical ELM command/response transcript.
- Offline selected ranges feed Payload Analysis.
- Historical known-signal series feed Correlation, avoiding dependence on the live five-minute ring after restart.

## Verification in this archive

- `pytest`: 82 passed.
- `python -m compileall -q src`: passed.
- Dedicated writer tests: flush visibility, enqueue ordering, deterministic replay/seek.
- Additional stress check: 5,000 RAW rows queued and persisted; all 5,000 visible after the durability barrier.

## Still requires the real Mac/vehicle

The review environment does not have PySide6 installed and is not the user's Apple Silicon Mac. Therefore the following remain hardware/runtime checks rather than claimed verification:

- PySide6/pyqtgraph GUI launch on the Mac.
- CoreBluetooth/Bleak behavior with the physical KW905.
- Actual KW905 GATT layout/MTU/reconnect behavior.
- RP8 response CAN IDs and proprietary payload meanings.

ECU discovery / physical-address DID scanning remains intentionally outside the first vehicle run.
