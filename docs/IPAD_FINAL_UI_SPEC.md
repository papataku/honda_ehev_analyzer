# Honda Analyzer iPad — Final UI Structure

This document turns the UI concept into an implementable product structure. It describes the intended primary navigation and operator flow for the native iPad app.

## Product principles

1. Evidence first: start SQLite recording before vehicle initialization.
2. One primary next action: the app should always make the recommended next step obvious.
3. Separate driving from discovery:
   - driving = known-signal live monitoring
   - stationary = read-only DID discovery
4. Keep expert information available without putting it in the default path.
5. Never infer ECU roles from CAN IDs alone.
6. Unknown automated vehicle access remains read-only UDS 0x22.

## Startup / Bluetooth connection

The app opens on a dedicated Bluetooth connection screen until a transport reaches `ready`.

Left pane:
- BLE state
- scan/stop control
- hide unnamed toggle, default ON
- name filter
- detected/displayed counts

Right pane:
- large device rows
- advertised name
- peripheral UUID
- RSSI + qualitative signal strength
- clear connecting/GATT-discovery progress

On `ready`, the app enters the analyzer workspace automatically.

## Analyzer workspace navigation

The workspace sidebar contains only page navigation plus the current BLE connection summary:

- Dashboard
- DID Discovery
- Sessions
- Technical
- Settings

Functional controls must not accumulate in the sidebar.

## Dashboard

Purpose: daily operating screen.

Top:
- title and vehicle-analysis context
- REC / LIVE / DID / DID PAUSE status pills

Guided readiness:
1. BLE connected
2. SQLite recording active
3. ELM/vehicle initialization successful
4. all known signals decoded

The "next action" card presents the next recommended step and action button.

Known-signal validation requires valid decoded values for:
- RPM
- vehicle speed
- coolant
- HV SOC
- PID 9A HV voltage/current/power

Main metric cards:
- Engine RPM
- Speed
- Coolant
- HV SOC
- HV voltage
- HV current
- HV power

Live trend cards:
- RPM
- HV power

Live trends appear only after enough samples exist.

Operation choice:
- Driving: live known-signal monitoring
- Stationary: read-only DID discovery

If recording is active, event-marker buttons are shown.

Session completion/export is shown as a dedicated card rather than being hidden in technical controls.

## DID Discovery

Purpose: safe unknown-signal discovery while stationary.

The page presents the sequence directly:

1. Confirm full stop / P
2. Run safe known-request ECU census
3. Choose an actually observed responder source
4. Run:
   - short 2000–20FF scan, or
   - confirmed adaptive 0000–FFFF scan

Hard prerequisites in code:
- BLE ready
- SQLite recording active
- ELM initialized inside current capture
- known signals decoded inside current capture
- stationary confirmation
- safe ECU census completed
- selected source present in observed responders

Full-range scan requires an explicit confirmation dialog.

While scanning:
- progress and current DID are visible
- Positive / partial counts are visible
- manual safe stop is prominent
- Positive DID inventory appears

Motion behavior:
- DID traffic pauses immediately
- only 010D is polled during pause
- three consecutive zero-speed samples are required for automatic resume
- manual stop overrides resume
- pause/resume is written to SQLite events

Advanced controls are collapsed:
- request rate
- motion auto-resume option
- manual ECU source entry

Manual source entry does not bypass the observed-responder gate.

## Sessions

Purpose: manage evidence files without using the Files app as the primary UI.

Shows local `HondaAnalyzerSessions/*.sqlite3` files:
- filename
- last modified date/time
- file size
- Share action

The current recording is shown separately as active and cannot be exported as a finalized capture until it is closed.

Future extension:
- session summary
- replay
- candidate comparison
- debug bundle generation

## Technical

Purpose: troubleshooting and expert inspection.

Contains:
- selected GATT service/characteristics/properties
- ELM transcript
- current readiness/recording/DID state
- detailed status text

Technical output is not shown permanently on the Dashboard.

## Settings

Primary settings:
- Bluetooth connection route
- DID request rate
- motion pause / stable-zero auto-resume

Safety policy is shown as a short fixed checklist.

The UI does not offer write/reset UDS services.

## Layout rules

- Main content max width: about 1180 pt.
- Metric grid: adaptive, minimum about 180 pt.
- Compact buttons/candidates: adaptive wrapping grid.
- Sidebar: page navigation only, roughly 220–310 pt.
- Large touch targets for BLE devices and primary workflow actions.
- Use system Dynamic Type and VoiceOver labels for key signal/device rows.
- Prefer SF Symbols and semantic SwiftUI materials over bespoke bitmap chrome.

## Visual language

- Native iPad/SwiftUI structure.
- Neutral material cards.
- Accent color for actionable/active elements.
- Green for successfully proven readiness.
- Orange for pause/caution.
- Red only for destructive stop actions.
- Monospaced text only for CAN IDs, DIDs and raw technical data.

## App icon

Brand-neutral icon:
- vehicle gauge
- analysis waveform
- wireless diagnostic motif

Do not reuse Honda trademarks/logos.

The 1024x1024 AppIcon is generated by the Xcode build and verified in CI.


## High-performance adapter polling

The app supports fast custom ELM327-compatible adapters without changing the one-command-at-a-time safety model.

Selectable targets for both live known-signal polling and DID discovery:
- 5 req/s
- 10 req/s
- 20 req/s
- 50 req/s
- 100 req/s
- app-side unthrottled mode

The application always waits for the ELM prompt before sending the next command. Unthrottled mode removes only deliberate pacing sleeps; it does not pipeline multiple outstanding vehicle requests.

The UI displays measured effective request/DID rates because adapter, BLE transport, ECU response latency and capture overhead may prevent the requested target from being reached.

DID discovery has a separate opt-in high-performance timing switch. Compatibility timing remains the default. When explicitly enabled, ATST is shortened in stages for 20/50/100+ req/s operation. The UI warns that excessively short timeouts can create false negative/timeouts on slower ECUs.

Recommended validation sequence for a custom adapter:
1. 20 req/s, compatibility timing.
2. Compare Positive/NRC inventory with a known slower baseline.
3. 50 req/s.
4. Enable high-performance timing only when NO DATA timeout behavior is the remaining bottleneck.
5. 100 req/s or unthrottled only after inventory equivalence is maintained.

SQLite capture writes remain asynchronous to the receive/command path so database writes do not synchronously gate the next ELM request.
