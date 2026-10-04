# Honda Analyzer for iPad

Native iPadOS port of the macOS Honda e:HEV analyzer.

The Python implementation remains the behavioral reference. Raw ELM responses must decode identically on both platforms; unknown Honda DID semantics are not invented.

## Phase 1 now present
- Swift package `HondaAnalyzerCore`
- ELM `>` framing
- 29-bit 18DA/18DB parsing and ISO-TP reassembly
- incomplete prefix preservation for future `BUFFER FULL` recovery
- 010C/010D/0105/015B decoding
- PID 9A voltage/current/power decoding
- UDS 0x22 positive payload extraction
- Python-equivalent read-only command guard
- CoreBluetooth KW905 scan/connect/GATT/write/notify transport
- initial SwiftUI iPad connection screen

## Build
```bash
brew install xcodegen
cd ipad
xcodegen generate
open HondaAnalyzer.xcodeproj
```

Use a physical iPad for BLE validation.

## Safety
Automated unknown discovery remains UDS 0x22 only and stationary-only. No write/session/security/routine-control/actuator services are added.
