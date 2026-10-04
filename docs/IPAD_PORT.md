# iPad Native Port

Development branch: `ipad-native`  
Tracking issue: #2

## Objective

Connect a physical iPad directly to the KONNWEI KW905 over BLE and preserve the same evidence-first capture model as the macOS analyzer.

The Python/macOS implementation remains the reference implementation. The iPad app is a second runtime for in-vehicle capture, not a fork of the signal semantics.

## Implemented

- Native Swift / SwiftUI iPad application shell.
- CoreBluetooth scan, connect, GATT inventory, write and notify path.
- ELM `>` prompt reconstruction across fragmented BLE notifications.
- 29-bit 18DA/18DB parsing and ISO-TP reassembly.
- Standard OBD:
  - 010C Engine RPM
  - 010D Vehicle Speed
  - 0105 Coolant
  - 015B Hybrid/EV SOC
  - 019A HV voltage/current and derived power
- Serialized ELM command execution with timeout and read-only command guard.
- Continuous known-signal polling.
- Mac-compatible SQLite evidence capture with WAL/FULL durability.
- BLE raw chunks, ELM command/response latency, event markers and DID scan results.
- iPad Files/share-sheet export of completed SQLite captures.
- UDS 0x22 response classification:
  - `positive`
  - `positive_partial`
  - NRC
  - NO DATA
  - timeout/error
- Session-15-style `BUFFER FULL` recovery:
  - normal read with `ATH1`
  - if a valid `62 DID` partial is proven, retry once with `ATH0`
  - preserve the longer partial if still truncated
  - restore `ATH1`
- Initial stationary discovery workflow for ECU source + DID `2000–20FF`.
- Resume semantics matching macOS: positive / positive_partial / NRC 0x31 are terminal; NO DATA / timeout remain retryable.
- Speed is re-read during discovery. Unknown speed or speed above 0.1 km/h stops discovery.
- Five consecutive communication errors stop discovery rather than continuing a bad header/link state.

## Safety invariants

- Automated unknown discovery is UDS service `0x22` only.
- No DiagnosticSessionControl, SecurityAccess, write, RoutineControl or actuator service is exposed by the discovery workflow.
- Discovery requires:
  1. an active SQLite recording session,
  2. explicit user confirmation of complete stop / P range,
  3. a successful live `010D` reading of zero speed.
- Vehicle speed is rechecked at least every two seconds during the current discovery workflow.
- Live driving polling and DID discovery are mutually exclusive.
- Raw evidence is saved before later semantic promotion.
- ECU source IDs are not assigned human-readable ECU roles without evidence.

## First physical-iPad validation

Use a physical iPad; the simulator is only a compile/UI gate.

1. Open the generated Xcode project and install on the iPad.
2. Start the app and scan for the KW905.
3. Connect and confirm the GATT inventory. Existing RP8 evidence expects service FFF0 with notify/write characteristics in that service.
4. Run ELM initialization.
5. Start SQLite recording.
6. Read known signals once:
   - 010C
   - 010D
   - 0105
   - 015B
   - 019A
7. Start continuous known-signal polling and verify values update.
8. Stop polling.
9. With the vehicle safely stationary in P, enable the stationary confirmation.
10. Use ECU source `01` and run `2000–20FF` at 5 req/s for the first validation.
11. Confirm known positives such as 2012 appear and Session-15 long DIDs do not stall the scan.
12. Stop recording and export the SQLite file through Files/share sheet.
13. Analyze the exported session on macOS before expanding the iPad scan range.

Do not begin a full 0000–FFFF iPad sweep until this first hardware gate passes.

## Regression gates

CI runs on Apple SDK:

- `swift test` for `HondaAnalyzerCore`
- XcodeGen project generation
- iOS Simulator `xcodebuild`

Cross-platform regression fixtures cover ELM framing, CAN/ISO-TP, known OBD decoding, UDS 0x22 response classification, partial responses, read-only safety, and DID resume storage.

## Next work

1. Validate the direct BLE path on a physical iPad/KW905.
2. Add active/passive ECU census UI.
3. Port the macOS adaptive full-range discovery order after the 2000–20FF hardware gate.
4. Add offline replay and Debug Bundle export.
5. Add drive sweep and candidate analysis.
6. Keep heavy correlation workloads on macOS until an iPad-native implementation provides a clear benefit.
