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

## Build and install on a physical iPad

The short path is:

```bash
git switch ipad-native
git pull --ff-only
brew install xcodegen
cd ipad
xcodegen generate
open HondaAnalyzer.xcodeproj
```

Then in Xcode:

1. Sign in under **Xcode > Settings > Apple Accounts**.
2. Select the **HondaAnalyzer** target.
3. Under **Signing & Capabilities**, keep **Automatically manage signing** enabled and select your Team.
4. Connect and pair the iPad with the Mac.
5. On the iPad enable **Settings > Privacy & Security > Developer Mode** and complete the required restart/confirmation.
6. Select the physical iPad as the Xcode run destination.
7. Press **Command-R** or **Run ▶**.

Xcode builds, signs, installs, and launches **Honda Analyzer** on the iPad.

On first launch, allow Bluetooth access. Then use **5秒スキャン** to find the KW905.

A paid Apple Developer Program membership is not required for personal-device testing. A free **Personal Team** can be used, but its provisioning profile expires after 7 days, so the app then needs to be rebuilt/reinstalled from Xcode.

If Xcode says the default bundle identifier is unavailable, change `PRODUCT_BUNDLE_IDENTIFIER` in `ipad/project.yml` to a unique identifier, run `xcodegen generate` again, and reopen the project.

For the complete first-install guide, troubleshooting, app startup procedure, and the initial RP8/KW905 validation sequence, see:

**`docs/IPAD_PORT.md` → “Build, install, and launch on a physical iPad”**

Use a physical iPad for BLE validation; the simulator is only a compile/UI gate.

## Safety
Automated unknown discovery remains UDS 0x22 only and stationary-only. No write/session/security/routine-control/actuator services are added.


## Live known-signal path
The app now has a serialized ELM command session and a first live path:
`AT init -> ATCP18 -> ATSHDB33F1 -> 010C/010D/0105/015B/019A`.
The UI shows RPM, speed, coolant, SOC, HV voltage/current/power and keeps a command transcript.


## Evidence capture
The iPad port now writes the Mac-compatible SQLite schema with WAL + FULL synchronous durability.
Incoming BLE notification chunks are stored in `raw_capture`, completed ELM commands in `commands`, and drive markers in `events`.
Writes use a dedicated serial queue so UI rendering is not used as the storage execution path.


## Continuous live capture and export
Known signals can now be polled continuously with one serialized pass per cycle and a one-second inter-cycle delay.
The live cycle reads 010C/010D/0105/015B/019A only.
Completed SQLite sessions can be exported through the iPad share sheet, and the app Documents directory is exposed to Files.
