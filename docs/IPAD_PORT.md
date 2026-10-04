# iPad Native Port

Development branch: `ipad-native`  
Tracking issue: #2

## Objective
Connect a physical iPad directly to the KONNWEI KW905 over BLE and preserve the same evidence-first capture model as the macOS analyzer.

## Compatibility policy
The Python/macOS implementation remains the reference. Cross-platform regression must cover ELM framing, CAN/ISO-TP, 010C/010D/0105/015B, PID 9A, UDS 0x22, incomplete long-response prefixes, and the read-only safety guard.

## Planned sequence
1. Protocol core and CoreBluetooth transport.
2. Live known-signal capture and SQLite persistence.
3. Stationary ECU/DID discovery with resume and long-response recovery.
4. Offline replay and Debug Bundle export.
5. Drive sweep and candidate analysis.
6. SmartRing export.

Heavy correlation workloads may initially remain on macOS. Raw session evidence should stay portable so Mac and iPad can analyze the same capture.
