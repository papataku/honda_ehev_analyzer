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
- Adaptive full-range `0000–FFFF` ordering matching macOS: known 2000 page, sector heads, page sentinels, hot-page deep scan, exhaustive fill.
- Cross-capture-file resume using prior iPad SQLite evidence still present on the device.
- Resume semantics matching macOS: positive / positive_partial / NRC 0x31 are terminal; NO DATA / timeout remain retryable.
- Fractional ISO-8601 timestamps for subsecond replay/correlation ordering.
- RAW BLE layer/source metadata aligned with macOS conventions.
- Speed is re-read during discovery. Unknown speed or speed above 0.1 km/h pauses DID traffic immediately.
- While speed-paused, only OBD `010D` is polled; no UDS DID request is transmitted.
- With auto-resume enabled, discovery resumes at the same logical position after 0 km/h is confirmed three consecutive times.
- Pause/resume transitions are saved in SQLite events as `DID_SCAN_PAUSE_SPEED` / `DID_SCAN_RESUME_STATIONARY`.
- Five consecutive communication errors stop discovery rather than continuing a bad header/link state.

## Safety invariants

- Automated unknown discovery is UDS service `0x22` only.
- No DiagnosticSessionControl, SecurityAccess, write, RoutineControl or actuator service is exposed by the discovery workflow.
- Discovery requires:
  1. an active SQLite recording session,
  2. explicit user confirmation of complete stop / P range,
  3. a successful live `010D` reading of zero speed.
- Vehicle speed is rechecked at least every two seconds during active discovery.
- If motion is detected, UDS discovery traffic pauses. During the pause, only `010D` is read approximately once per second until stable zero-speed is proven.
- Live driving polling and DID discovery are mutually exclusive.
- Raw evidence is saved before later semantic promotion.
- ECU source IDs are not assigned human-readable ECU roles without evidence.


## Build, install, and launch on a physical iPad

The KW905 path uses CoreBluetooth, so final validation must be done on a physical iPad. The iOS Simulator is useful only as a compile/UI gate.

### 1. Prepare the Mac

Install a current Xcode version that supports the iPadOS version installed on the target iPad. Launch Xcode once so it can finish installing components and accepting its license.

Get the iPad branch:

```bash
git clone https://github.com/papataku/honda_ehev_analyzer.git
cd honda_ehev_analyzer
git switch ipad-native
git pull --ff-only
```

If the repository is already cloned:

```bash
cd honda_ehev_analyzer
git fetch origin
git switch ipad-native
git pull --ff-only
```

Install XcodeGen if necessary, generate the Xcode project, and open it:

```bash
brew install xcodegen
cd ipad
xcodegen generate
open HondaAnalyzer.xcodeproj
```

The generated project is derived from `ipad/project.yml`. If project settings such as the bundle identifier need to be changed permanently, edit `project.yml` and run `xcodegen generate` again rather than relying only on a one-off Xcode UI edit.

### 2. Add an Apple Account and configure signing

In Xcode:

1. Open **Xcode > Settings > Apple Accounts** and sign in with the Apple Account that will be used for development.
2. In the Project navigator, select **HondaAnalyzer**.
3. Select the **HondaAnalyzer** target.
4. Open **Signing & Capabilities**.
5. Leave **Automatically manage signing** enabled.
6. Select the appropriate **Team**.

A paid Apple Developer Program membership is not required just to install and test the app on your own iPad. Xcode can use a free **Personal Team**. Apple currently limits Personal Team provisioning: the provisioning profile expires after 7 days, so the app must then be rebuilt and reinstalled from Xcode.

The default bundle identifier is:

```
com.papataku.HondaAnalyzer
```

If Xcode reports that the bundle identifier is unavailable for the selected team, edit `ipad/project.yml`, for example:

```yaml
PRODUCT_BUNDLE_IDENTIFIER: com.papataku.HondaAnalyzer.dev
```

Then regenerate the project:

```bash
cd ipad
xcodegen generate
open HondaAnalyzer.xcodeproj
```

Use a bundle identifier unique to the selected Apple Account/team.

### 3. Pair the iPad with the Mac

For the first installation, using a USB-C/USB cable is the simplest path.

1. Unlock the iPad.
2. Connect it to the Mac.
3. If the iPad asks **Trust This Computer?**, tap **Trust** and enter the iPad passcode.
4. Open Xcode's device view/Device Hub and select the iPad.
5. Complete pairing if Xcode asks for it.

After pairing, the iPad should appear as a physical run destination in Xcode.

### 4. Enable Developer Mode on the iPad

Xcode-installed development apps require Developer Mode.

On the iPad:

1. Open **Settings > Privacy & Security**.
2. Find **Developer Mode** under Security.
3. Turn it on.
4. Confirm the restart.
5. After the iPad restarts, unlock it.
6. Confirm **Enable Developer Mode** and enter the device passcode.

If **Developer Mode** is not shown, first connect/pair the iPad with Xcode; Apple only exposes this setting after the device has entered the development pairing flow.

### 5. Build, install, and launch from Xcode

In Xcode:

1. Confirm the scheme at the top is **HondaAnalyzer**.
2. Choose the connected physical iPad as the run destination.
3. Press the **Run ▶** button or press **Command-R**.

Xcode will:

1. build the Swift app,
2. sign it,
3. create/register the development provisioning data when needed,
4. install the app on the iPad,
5. launch **Honda Analyzer**.

On the first launch, allow Bluetooth access when iPadOS asks. Without Bluetooth permission the app cannot discover the KW905.

After Xcode has installed the app successfully, the **Honda Analyzer** icon remains on the iPad and the app can normally be launched directly from the iPad without the Mac connected, while its development provisioning remains valid.

### 6. First app startup check

Before connecting the car-side workflow, verify the app itself:

1. Launch **Honda Analyzer**.
2. Confirm the app opens without immediately terminating.
3. Tap **5秒スキャン**.
4. Confirm the KW905 appears.
5. Tap the KW905.
6. Confirm the BLE state reaches **ready**.
7. Inspect the displayed GATT inventory.

Existing RP8/KW905 evidence expects the BLE service around `FFF0`, with notify/write characteristics in that service. The app now stores the detected device UUID, selected write/notify UUIDs, and full GATT inventory in the SQLite capture metadata.

If the KW905 does not appear, make sure Bluetooth is enabled and disconnect another phone/tablet/app such as Car Scanner if it is currently using the adapter.

### 7. First real-vehicle validation sequence

Do not begin with a full DID scan.

Use this sequence:

1. Connect the iPad to KW905 and confirm **ready**.
2. Tap **ELM初期化**.
3. Confirm the ELM transcript does not show initialization failures.
4. Tap **SQLite記録開始**.
5. Tap **既知信号を1回取得**.
6. Confirm:
   - Engine RPM
   - Vehicle Speed
   - Coolant
   - HV SOC
   - HV Voltage
   - HV Current
   - HV Power
7. Start **既知信号ライブ取得** and confirm the values update.
8. Stop live acquisition.
9. Park safely and keep the vehicle in P.
10. Enable **完全停止・Pレンジを確認**.
11. Run **既知の安全な要求でECU候補を確認**.
12. Select an observed ECU source. The first RP8 validation target is expected to include source `01`, but the UI must use the actually observed responder list rather than assigning ECU roles by assumption.
13. Run **2000–20FF 探索 / 再開** at **5 req/s**.
14. Confirm DID `2012` and other known-positive candidates are observed where the vehicle actually responds.
15. Confirm a long response / `BUFFER FULL` does not stall the scan.
16. Stop SQLite recording.
17. Use the iPad share sheet or Files app to export the SQLite file.
18. Inspect that capture on the Mac before expanding the scan range.

Do not run the full `0000–FFFF` search until this hardware gate passes.

### 8. Updating the app after code changes

For later builds:

```bash
cd honda_ehev_analyzer
git switch ipad-native
git pull --ff-only
cd ipad
xcodegen generate
open HondaAnalyzer.xcodeproj
```

Select the iPad and press **Command-R** again. Xcode rebuilds and installs the new development build over the previous one.

If a Personal Team provisioning profile has expired, simply rebuilding/running from Xcode creates fresh development provisioning and reinstalls the app.

### 9. Common problems

**The iPad is not shown as a run destination**

- Unlock the iPad.
- Reconnect the cable.
- Accept **Trust This Computer**.
- Check Xcode's Device Hub/device list.
- Make sure the installed Xcode supports the iPadOS version.
- Install missing iOS/iPadOS platform support from Xcode if requested.

**Developer Mode is missing**

Pair the iPad with Xcode first, then check **Settings > Privacy & Security > Developer Mode** again.

**Signing requires a development team**

Add the Apple Account in Xcode settings and choose its Team under **Signing & Capabilities**.

**Bundle Identifier is unavailable**

Change `PRODUCT_BUNDLE_IDENTIFIER` in `ipad/project.yml` to a unique value, rerun `xcodegen generate`, and reopen the project.

**The app built previously but no longer starts**

If using a free Personal Team, the development provisioning profile expires after 7 days. Reconnect the iPad to the Mac and run the app from Xcode again.

**The simulator builds but KW905 cannot be tested**

Expected. BLE hardware validation for this project is a physical-iPad test.

**KW905 is not found**

Make sure Bluetooth permission is allowed for Honda Analyzer and ensure the adapter is not still connected to another phone/tablet/app.

### Apple references

- Running apps on physical devices: https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices
- Developer Mode: https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device
- Developer account / Personal Team limits: https://developer.apple.com/help/account/basics/about-your-developer-account


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

## Physical validation result — 2026-10-04

The first real iPad/KW905/RP8 hardware gate passed using an exported iPad SQLite capture.

Verified from the capture:

- SQLite integrity: `ok`; session closed cleanly.
- 865 raw BLE chunks / 12,594 raw bytes were preserved.
- 274 ELM commands were recorded with no command-row failures after positive-partial promotion.
- KW905 GATT selection was correct:
  - service `FFF0`
  - notify `FFF1`
  - write-without-response `FFF2`
- ELM identification/protocol:
  - `ELM327 v1.5`
  - `ISO 15765-4 (CAN 29/500)`
- Mode 01 responders observed: `18DAF101`, `18DAF102`, `18DAF106`, `18DAF10E`, `18DAF1EF`.
- Known signals decoded successfully:
  - engine RPM
  - vehicle speed
  - coolant
  - HV SOC
  - HV voltage/current/power
- Stationary speed checks returned 0 km/h during discovery.
- ECU source `01` scan reached DID `207B`, covering 124 unique DIDs.
- Scan outcomes:
  - 6 complete Positive
  - 11 `positive_partial`
  - 107 NRC `0x31`
- Those 17 Positive/partial DIDs match the prior Session-15 source-01 inventory within the scanned subset.
- All 11 long Positive responses exercised real `BUFFER FULL` recovery.
- `ATH0` compact retry increased the preserved application-data prefix from about 70–78 bytes to 108–112 bytes.
- The long replies still did not fit completely, so they correctly remain `positive_partial`.

The uploaded raw vehicle database is not committed to the public repository. Only this validation summary is retained.

This closes the initial physical-iPad gate. Adaptive full-range ordering and cross-capture-file resume have now been added while preserving the same stationary/read-only safety rules. The next hardware gate is a short physical run of the new adaptive workflow before committing to a multi-hour full-range scan.

## Regression gates

CI runs on Apple SDK:

- `swift test` for `HondaAnalyzerCore`
- XcodeGen project generation
- iOS Simulator `xcodebuild`

Cross-platform regression fixtures cover ELM framing, CAN/ISO-TP, known OBD decoding, UDS 0x22 response classification, partial responses, read-only safety, and DID resume storage.

## Next work

1. Rebuild/install the latest `ipad-native` app and perform a short physical validation of adaptive full-range ordering/resume.
2. Confirm a second capture skips the terminal DIDs already proven by the first iPad SQLite file.
3. Add offline replay and Debug Bundle export.
4. Add drive sweep and candidate analysis.
5. Keep heavy correlation workloads on macOS until an iPad-native implementation provides a clear benefit.
