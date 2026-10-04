# iPad UX Review

Review scope: first launch, BLE connection, session capture, known-signal validation, stationary ECU/DID discovery, scan pause/resume, and evidence export.

This review deliberately combines several user and engineering perspectives. It is not a claim that external human reviewers were consulted; it is a structured multidisciplinary design review applied to the current implementation.

## 1. New user / first-time operator

### Findings

- The previous analyzer sidebar exposed many controls without making the required order obvious.
- Terms such as ELM, ECU source, DID and adaptive scan appear before the operator knows whether the basic vehicle connection is healthy.
- It was possible to initialize ELM before starting SQLite capture, losing useful initialization evidence.
- A long list of BLE discoveries made the first screen harder to operate.

### Changes

- Dedicated Bluetooth connection screen.
- Large device rows in the detail pane.
- "名前なしを除外" enabled by default plus text filtering.
- Main analyzer now shows a four-stage guided setup:
  1. BLE connected
  2. SQLite recording
  3. vehicle communication initialized
  4. known signals validated
- The app presents one recommended next action at a time.
- Manual/technical controls remain available under a detail disclosure.

## 2. UI / interaction design

### Findings

- Information hierarchy was weak: connection, capture, transport setup, live monitoring and discovery had similar visual weight.
- Safety state and scan state were mostly text.
- Dense sidebars are poor touch targets on iPad.
- Technical logs and GATT data are useful but should not dominate normal operation.

### Changes

- Wide BLE selection pane with large tap targets.
- Main content header exposes REC / LIVE / DID / DID PAUSE state.
- Setup progress uses numbered stages and completion marks.
- Operation is split conceptually into:
  - driving: live monitoring
  - stationary: DID discovery
- Motion pause gets a dedicated safety banner.
- Secondary controls are collapsed where practical.

## 3. Vehicle safety / diagnostic protocol review

### Findings

- Unknown DID discovery must remain impossible while moving.
- Stopping the scan permanently on any speed transition was safe but poor operationally for long stationary discovery interrupted by brief movement.
- Automatic resume should not trigger from one noisy zero-speed sample.

### Changes

- Unknown automated discovery remains UDS service 0x22 only.
- While active, vehicle speed is rechecked.
- Motion / unknown speed pauses all DID traffic.
- During pause, only OBD 010D is requested.
- Resume requires three consecutive zero-speed samples.
- Manual stop always overrides automatic resume.
- Pause and resume are written to SQLite events.
- Full-range scan still requires explicit long-duration acknowledgement.

## 4. BLE / transport review

### Findings

- Discovery lists include many irrelevant unnamed peripherals.
- Device UUID alone is difficult to recognize.
- GATT selection and connection progress need to remain visible for troubleshooting.

### Changes

- Default hide-unnamed filter.
- Optional advertised-name filtering.
- Device rows show name, UUID and RSSI.
- Named devices are prioritized; same-name entries prefer stronger RSSI.
- Connecting and GATT discovery are explicit states.
- Analyzer keeps a route back to the connection screen.

## 5. Evidence / data-analysis review

### Findings

- Evidence should begin before transport initialization where possible.
- Second-only timestamps were insufficient for later alignment and lag analysis.
- Long scans must survive day/session boundaries.

### Changes

- Guided setup recommends starting SQLite capture before ELM initialization.
- Capture timestamps use fractional ISO-8601.
- RAW BLE metadata follows the same layer/source convention as macOS.
- Terminal DID history is unioned across prior iPad SQLite files.
- Positive / positive_partial / NRC 0x31 are resumed as complete; retryable failures are not.

## 6. iPad engineering / QA review

### Findings

Important states must be independently testable:

- BLE disconnected / scanning / connecting / ready
- recording stopped / active
- ELM initialized / not initialized
- known signals validated / not validated
- DID idle / scanning / speed-paused
- user stop / speed pause / stable-zero resume

### Changes

- View model now tracks ELM initialization and known-signal validation explicitly.
- Connection changes reset dependent readiness state.
- Stable-zero resume has a pure core tracker with regression coverage.
- CI builds the generated iPad application after Swift core tests.

## Remaining UX work

1. Validate the new guided workflow on a physical iPad in portrait and landscape.
2. Consider a session summary/export screen after recording stops.
3. Add explicit error recovery actions for BLE/GATT/ELM failures instead of relying only on status text.
4. Consider retaining the last successfully used KW905 and offering a clear one-tap reconnect path.
5. Validate Dynamic Type and VoiceOver labels.
6. Continue reducing technical detail in the primary path without hiding the evidence/debug path.
