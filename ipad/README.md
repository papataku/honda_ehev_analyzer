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


## Adaptive full-range DID discovery

After the first physical-iPad gate passed, the iPad app gained the same priority model used by the macOS analyzer:

1. `2000–20FF` first
2. the first few DIDs of each 0x1000 sector
3. first/midpoint sentinels of every 0x100 page
4. fully scan pages that produced Positive/partial or another interesting NRC
5. exhaustively fill every remaining DID

This changes order only; it does not skip silent regions.

The full-range button requires the long-scan acknowledgement and the same stationary/P-range + live `010D == 0` safety gate. Speed continues to be rechecked while scanning.

Resume now reads terminal DID results from all `.sqlite3` capture files still present in the iPad `HondaAnalyzerSessions` folder. This allows a long scan to be stopped, a new recording created later, and already proven Positive/positive_partial/NRC-0x31 DIDs to be skipped.

The first physical log also showed that second-only timestamps were insufficient for replay/correlation. New captures use fractional ISO-8601 timestamps, and RAW BLE rows use the same `BLE` / `ble:<notify UUID>` metadata convention as macOS.


## Motion pause and automatic stationary resume

DID discovery no longer has to terminate permanently when vehicle speed becomes non-zero.

With **走行検出時は一時停止し、0 km/h安定後に自動再開** enabled:

- active DID traffic stops immediately when `010D` is unknown or above 0.1 km/h,
- while moving/unknown, the scanner sends only `010D` approximately once per second,
- no `0x22` DID request is sent while speed-paused,
- three consecutive zero-speed samples are required before the same scan resumes,
- the pending DID is not marked complete simply because motion occurred,
- pause/resume is recorded in SQLite events.

Turning the option off preserves the conservative behavior: motion ends the current scan and a later scan must be started manually.


## Bluetooth connection screen

The iPad app now starts with a dedicated BLE connection screen instead of placing every discovered peripheral in the analyzer sidebar.

- Left pane: scan controls, connection state, filters.
- Right pane: large selectable device rows with name, UUID and RSSI.
- **名前なしを除外** is enabled by default because the expected KW905 advertises a name.
- An optional name search field further narrows the list.
- When the selected device reaches BLE `ready`, the app automatically opens the analyzer workspace.
- The analyzer sidebar keeps only the current connection summary and a button to return to the Bluetooth connection screen; discovered-device rows no longer expand that sidebar.


## Guided analyzer workflow

The analyzer workspace now leads first-time operators through the intended evidence-first order:

1. connect KW905 over BLE,
2. start SQLite recording,
3. initialize vehicle/ELM communication,
4. validate known standard signals,
5. while stationary, run the safe ECU census,
6. select an observed ECU,
7. start either the short 2000–20FF scan or the confirmed full adaptive scan.

The next recommended action is shown prominently. Technical/manual controls remain available under disclosure sections for experienced users.

DID discovery is now hard-gated by the same prerequisites in code, not just by UI wording. Full-range 0000–FFFF discovery uses an explicit confirmation dialog rather than a persistent acknowledgement toggle.

The dashboard metric grid is adaptive for iPad split-view/portrait widths, and key device/metric rows include accessibility labels.

## App icon

The Xcode project generates a dedicated Honda Analyzer app icon before the asset-catalog build. The design is intentionally brand-neutral: a vehicle gauge, an analysis waveform, and a wireless/diagnostic signal motif. It does not reuse the Honda logo.

The generated asset is declared as the build-script output so the same icon is produced in CI and local Xcode builds.


## High-rate custom ELM327-compatible adapters

The iPad app can now use substantially faster custom ELM327-compatible hardware.

Available app-side targets:
- 5 req/s
- 10 req/s
- 20 req/s
- 50 req/s
- 100 req/s
- unthrottled

Both known-signal live polling and DID discovery expose their own target rate. The app still serializes ELM commands and waits for each prompt before sending the next request; "unthrottled" removes only the artificial app-side delay.

The UI also shows the measured effective rate so the real adapter/ECU limit can be observed.

For DID discovery, **高性能ELM互換機向け短時間タイムアウト** is a separate opt-in. It progressively shortens ELM `ATST` at 20/50/100+ req/s. This can improve NO DATA scanning on fast custom hardware, but it can also create false timeouts if an ECU responds more slowly. Start at 20 req/s, compare Positive/NRC results against a slower control run, and raise the rate only when the response inventory remains stable.

Compatibility mode keeps the previously validated KW905 timing.

Live polling no longer sleeps a fixed one second after each five-signal cycle. It computes the remaining delay from the selected aggregate request-rate target. At 50 req/s, for example, a five-request cycle targets about 10 cycles per second only when the adapter and ECU can actually respond that quickly.
