# iPad virtual BLE / ELM327 prototype (experimental branch)

This is an **iPadOS Simulator protocol-level prototype**, **not** a complete ESP32-S3 CPU/BLE radio emulator. The real `KW905BLETransport`, `ElmCommandSession`, SwiftUI screens, decoders and SQLite recording paths are reused. The virtual peripheral responds to BLE-style characteristic writes with fragmented notifications.

## Scope / safety

- Simulator ONLY: enabled when launched with the `--ble-sim` argument. A physical iPad always uses CoreBluetooth even if this argument is passed.
- No physical BLE scanning when enabled. Discover one `ESP32-ELM327-SIM` device (virtual RSSI -42), GATT FFF0 / Notify FFF1 / Write FFF2.
- `ATZ`, `ATI`, ELM init, `010C`, `010D`, `0105`, `015B`, `019A` and `222012` have synthetic deterministic replies. Other read-only DIDs return NO DATA; unsafe commands return ?.
- Stationary speed is **0 km/h** by default, specifically to keep existing DID-scan safety gates active. Tests can set `vehicleState = .moving` (42 km/h) to exercise moving safeguards.
- The app shows an orange virtual-mode warning. SQLite evidence stores `simulated: true` in device metadata, and filenames start `SIMULATED-session-`; NEVER treat this as real vehicle evidence.
- Real BLE radio quality, RF timing, ESP32 CPU scheduling, and ESP32-specific firmware behavior are **not measured** here.

## Manual macOS / Xcode reproduction

```bash
git fetch origin
git switch experiment/ipad-ble-virtual-peripheral
cd ipad
swift test
brew install xcodegen   # if not installed
xcodegen generate
open HondaAnalyzer.xcodeproj
```

In Xcode, select an **iPad Simulator** destination. Edit Scheme > Run > Arguments Passed On Launch and add **`--ble-sim`**. Run the app and:

1. Tap **5秒スキャン**. A device `ESP32-ELM327-SIM` appears.
2. Select it; the app transitions to the existing analysis workspace after simulated GATT `ready`.
3. Start SQLite recording, press ELM initialization and then known-signal acquisition.
4. Expect RPM ~1200 (increases by 240 each poll), speed 0, coolant 90 °C, SOC 60 %, voltage 288 V, current -10 A, power -2.88 kW.
5. Try Live Polling, disconnect/reconnect, and check raw notifications and command transcripts. `222012` returns synthetic AABBCC.
6. Verify `SIMULATED-session-*.sqlite3` and metadata `simulated: true`.

For CLI execution once an iPad Simulator is running and the app is installed:

```bash
xcrun simctl launch booted com.papataku.HondaAnalyzer --ble-sim
```

Without the flag, the normal CoreBluetooth implementation remains unchanged.

## CI

`.github/workflows/ipad-virtual-ble.yml` runs `swift test` and builds the iPad Simulator app on a macOS GitHub-hosted runner. The workflow also attempts to boot an available iPad Simulator, launches the app with the flag, and saves a screenshot artifact. Screenshot success validates launch/rendering, **not** the physical BLE stack. `VirtualBLETests.swift` verifies the ELM session and parser path including split notifications.

## Next phase (not implemented in this branch)

Replace the deterministic responder with an ESP32 firmware-facing TCP/GATT event bridge. Investigate `esp-emulator` compatibility with the current M5Dial firmware separately, and compare protocol traces against real hardware. Do not claim ESP32 end-to-end emulation until firmware boots and sends valid responses.
