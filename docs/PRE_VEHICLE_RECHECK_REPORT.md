# Pre-vehicle implementation recheck report — 0.2.1

Date: 2026-09-24

## What was actually rechecked

- Entire source/archive structure and pre-vehicle scripts.
- Full pytest regression suite after corrections: **77 passed**.
- `python -m compileall -q src`: passed.
- ELM response framing, error classification, compact `ATS0` text, 29-bit headers and ISO-TP SF/FF/CF reconstruction.
- Vehicle Readiness command order and independence from prior adapter state.
- Explicit `18DB33F1` / `18DBEFF1` header switching.
- Payload-analysis offset normalization for `019A` and DID `2012`.
- GATT characteristic selection policy and reconnect queue cleanup.
- Communication-quality handling of no-data, timeout and errors.
- Session end / live-poll cancellation behavior.
- Read-only scanner core restriction to UDS 0x22 and speed-stop hook.
- Debug-bundle single-session scoping.

## Problems found in the previous pre-vehicle archive and corrected

1. ELM `NO DATA` was not classified as a failed data request, allowing false readiness/diagnostic success.
2. GUI `record_response()` wrote `success=True` even for failed ELM command results.
3. Vehicle Readiness depended on inherited adapter state instead of resetting/configuring protocol 7 and CAN formatting itself.
4. The payload-analysis extractor expected space-separated byte tokens even though initialization uses `ATS0`; real compact ELM text could therefore produce empty/incorrect payloads.
5. No explicit ISO-TP SF/FF/CF reconstruction existed on the payload-analysis path despite earlier wording suggesting it did.
6. Response service/PID/DID bytes were being included in candidate payload offsets; 0.2.1 analyzes only bytes after `41 9A` or `62 20 12` for those sources.
7. Communication quality could show GOOD before any communication and did not separate timeouts from other outcomes.
8. The end-test action could close a session while the polling task was still alive, risking subsequent writes into a newly opened session.
9. GATT auto-selection could choose write/notify characteristics from unrelated services; same-service UART-like pairs are now preferred.
10. The packaged procedure implied ECU Discovery/DID Scanner was GUI-ready. It is not: the scanner core is implemented/tested, but real physical-address ELM wiring and GUI integration remain pending first RP8 evidence.

## Remaining limitations before claims beyond the first capture

- This review environment is Linux/Python 3.13 x86_64, not the user's Apple Silicon Mac. PySide6/Bleak/pyqtgraph were not installed in the review container, so GUI/BLE runtime behavior could only be syntax/static-checked here. `Preflight.command` on the actual Mac is therefore still mandatory.
- The exact KW905 GATT layout, MTU behavior and BLE reliability remain hardware-verification items.
- Honda-specific meanings/offsets for `019A`, DID `2012`, motor/generator RPM/torque and inverter values remain unknown by design.
- SQLite writes and some offline analysis still run synchronously on the Qt/event-loop thread. The live poll defaults were reduced for the first capture and UI logs are capped, but a background writer is recommended before high-rate/long-duration use.
- Correlation currently relies on the five-minute in-memory known-signal ring. Raw command responses are persisted, but historical known-signal reconstruction after restart is not yet wired into the GUI.
- ECU/DID scanner core is not yet connected to a real ELM physical-address client or GUI. Do not attempt a range scan from this build.

## Current go/no-go statement

**GO for:** stationary KW905/RP8 Vehicle Readiness and a conservative passenger-operated first drive capture of known OBD + raw `019A`/`222012`, provided the Mac-side Preflight passes and the real readiness report has no base-OBD/reconnect/replay FAIL.

**NOT YET GO for:** claiming decoded Honda proprietary signals, automated ECU discovery on the real adapter, or vehicle-ready DID range scanning.


## 0.2.2 follow-up hardening

The two main follow-up items from this review are now implemented:

- Capture-path RAW/command/event/device persistence uses a dedicated SQLite writer thread with short FULL-synchronous WAL batches and explicit flush barriers before close/export/analysis/replay.
- Historical sessions can be reconstructed in the new Offline Replay tab. Known RPM/speed/coolant series and event markers are recreated from SQLite; `019A`/`222012` remain raw. Offline timeline selection can feed Payload Analysis, and historical known-signal series can feed Correlation.

Regression suite after this follow-up: **82 passed** plus `compileall`. A 5,000-row writer stress check completed with all rows visible after the flush barrier. The review container still does not include PySide6, so the actual macOS GUI launch remains part of `Preflight.command` on the Mac.
