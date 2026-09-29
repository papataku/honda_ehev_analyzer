# Final pre-vehicle checklist — RP8 + KW905 (rechecked 0.2.2)

This archive is ready for the **first stationary readiness capture and conservative passenger-operated drive capture**. It is **not** claiming that ECU/DID discovery is vehicle-ready yet; the read-only scanner core exists, but physical-address ELM wiring and GUI controls remain deliberately unwired until the first real response IDs are captured.

## 1. On the Mac before leaving

1. Use Python 3.12 or newer. `Preflight.command` accepts `python3.12` or a compatible `python3`.
2. Double-click `Preflight.command`.
3. All regression tests and `PRE-VEHICLE SOFTWARE GATE` must pass.
4. Start `Run Honda Analyzer.command`; confirm the GUI opens.
5. Keep the Mac charged and prevent sleep during the test if appropriate.
6. Do not delete `~/.honda-ehev-analyzer/`; it contains incremental evidence.

## 2. Stationary vehicle readiness

1. Park safely. Plug in KW905 and put the vehicle in the communication state (READY/ignition as appropriate).
2. BLE Inspector -> Scan BLE -> select the actual adapter. The scan-time RSSI is retained when available.
3. Run **Vehicle Readiness Test**. It performs no DID range scan.
4. The readiness routine resets/configures the adapter itself: echo/linefeeds/spaces, headers, long messages, CAN formatting/flow control, then protocol 7 (ISO 15765-4 29-bit 500 kbit/s).
5. Base OBD (`010C`,`010D`,`0105`), reconnect and replay-parser identity are hard gates. `019A`/`222012` are vehicle-specific and may produce WARN rather than a false PASS.
6. Save the HTML/JSON report. It contains discovered GATT metadata, MTU when exposed by Bleak, selected write/notify characteristics, and response CAN ID when observed.
7. Do not treat DID `2012` as SOC or any other signal. It remains raw/candidate evidence.

## 3. Acceptance before driving

Proceed to a passenger-operated drive capture only when BLE connect/reconnect, ELM initialization, base OBD values, RAW persistence and replay-parser identity are reliable. Investigate every FAIL. A WARN caused only by unsupported/absent `019A` or `222012` may still allow a base-OBD capture, but that missing source obviously cannot be analyzed later.

The ELM terminal starts in **Vehicle Safe Mode**: AT commands plus read-only OBD 01/09 and UDS 0x22 requests only. Do not disable it in the vehicle unless there is a deliberate bench/debug reason.

## 4. First driving capture

The driver must not operate the Mac. Use a passenger for marker input. Use **Known Live Polling** only. The first-capture schedule is intentionally conservative: Engine RPM and speed 2 Hz each, `019A` 2 Hz, coolant 0.2 Hz and DID 2012 0.5 Hz, with serialized requests and no catch-up burst. The scheduler explicitly changes between `18DB33F1` and `18DBEFF1`.

Capture STOP, EV low/medium/high, ENGINE ON, ACCEL, CRUISE and REGEN. Prioritize a clean EV segment where Engine RPM is approximately zero while Vehicle Speed is non-zero. Use **END TEST — Save Session + Debug Bundle** at the end; this now stops the polling task before closing the session.

## 5. After the first capture

Load the captured session in **Offline Replay** first. Replay/seek the known signals and event markers, then select time ranges and analyze the captured `019A` / `222012` payloads. Compact `ATS0` responses and ISO-TP SF/FF/CF sequences are handled without requiring space-separated hex, and service/PID/DID prefixes are excluded from payload offsets.

Do **not** expect an ECU Discovery/DID Scanner GUI in this build. The Phase 5 read-only 0x22 scanner core is tested, but it still needs a real ELM physical-address client bound to the response IDs observed in the first capture. That binding should be implemented and tested stationary before any DID range scan is attempted.

## Known limitations retained intentionally

- Exact KW905 GATT/MTU behavior is still unverified on the user's physical adapter.
- Honda-specific `019A` offsets, DID `2012` meaning, Drive/Generator Motor RPM/Torque and inverter fields remain unknown until real evidence exists.
- Capture-path SQLite inserts now use a dedicated writer thread, but macOS GUI responsiveness under the user's actual KW905/BLE notification pattern still requires the first hardware run.
- Offline Replay reconstructs persisted ELM command responses and event markers. Lower-level BLE notification fragments remain preserved in `raw_capture`/debug bundles but are not used to emulate a virtual BLE adapter in the GUI.
