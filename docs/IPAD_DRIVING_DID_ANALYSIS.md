# iPad 走行解析 / 停車DID探索 — 安全な2モード運用

## Goal

Discover candidate **drive-motor speed, generator speed, shaft speed, torque, electrical power and operating-state fields** from unknown Honda e:HEV UDS 0x22 payloads.

**Finding Positive DIDs is not enough.** The app must accumulate *repeated time-aligned payload samples* alongside known references, then rank raw byte fields without assuming an ECU ID equals a semantic role.

## Two modes (single serial ELM command lane)

| Vehicle state | Requests | Data handling |
|---|---|---|
| Moving / speed > 0 | Only already *fully Positive* read-only DID 0x22 allowlist + OBD `010C`, `010D`, `0105`, `015B`, `019A` references | Write complete DID payloads with timestamps to `did_drive_samples`; standard observations to `commands` |
| 0 km/h but not confirmed P | No unknown DID scan | Hold scan suspended; show "P確認待ち" |
| P confirmed, 0 km/h confirmed (3 consecutive samples after a pause) | Unknown read-only DID scan (manual start or resume of an explicitly started scan) | Store statuses in `did_scan`; existing history preserves progress |
| Unknown speed / BLE errors | No unknown scan | Remain fail-closed, log status |

The app cannot read actual P-range status from currently confirmed vehicle signals. **P confirmation is a manual operator assertion, not a hardware-verified gear state.** The app clears the assertion as soon as speed >0 is observed.

Do **not** equate traffic-light stops to safe discovery conditions.

## Workflow A: explore and collect

1. Stop safely in P. Connect BLE, start SQLite, initialize ELM and verify the 5 standard signals.
2. Open **DID探索** and confirm stationary/P. Run safe ECU census, then scan for new read-only Positive DIDs.
3. When the vehicle moves during an ongoing discovery session, new/unvalidated DID requests stop. The paused scan begins sampling *already discovered complete Positive DIDs* and also updates vehicle speed, engine RPM, HV power.
4. Only after 0 km/h is observed 3 times and P is **reconfirmed**, the suspended unknown scan may resume.
5. Stop discovery to close the current session; do not manually operate the iPad while driving.

## Workflow B: driving without unknown discovery

1. After at least one stationary Positive-DID discovery, use **走行解析 → 収集開始** before moving.
2. The app rotates up to 16 known positive DIDs, four per known-signal cycle. Each cycle captures RPM, speed, coolant, SOC and HV electrical measurements, then complete DID payloads when moving.
3. Stop capture after safely parking. The app stores the complete payload *after removing UDS 62 XX XX* with source ECU, response CAN ID, timestamp and latency.
4. Open **走行解析 → この記録を解析**, or **セッション → 信号解析** to analyze a saved SQLite.
5. For unknown discovery, first stop driving capture, then perform stationary/P confirmation on the DID探索 page.

**There is no automatic unknown DID scan at a 0-km/h traffic light.**

## Positive-DID allowlist

Read-only SQLite `did_scan` history across local iPad captures. Inclusion:
- successful fully reassembled `positive` status;
- payload length 1..64 bytes;
- valid ECU source, expected responder `18DAF1xx`;
- exclude `F100..F1FF` ECU identity/coding-style data;
- exclude `positive_partial` and negative/no-data outcomes;
- no fixed 16/24 candidate truncation; all eligible historical responders are managed with adaptive sampling

Potential candidates based on uploaded logs include `2012`, `E480`, `E481`, `E600`, `E602`, but **none is automatically declared to be motor RPM**.

## Offline analysis

The iPad ranks each payload field as 8/16/32-bit signed/unsigned big-/little-endian raw series. It tests:
- all-moving speed correlation;
- EV-moving speed correlation (engine RPM below 150);
- engine RPM correlation;
- HV battery power correlation;
- variation and number of unique values.

Labels are **hypotheses**: drive-motor-speed candidate, generator/engine-linked candidate, torque/power candidate, or unclassified change. Each row shows DID, ECU, field format/offset, sample count, raw range and correlation coefficients. The app does not automatically create a validated signal definition or infer a physical unit/scale from correlation alone.

To validate true motor RPM additionally:
- include stopped, EV-moving, engine-running, accelerating and regenerating intervals;
- fit a candidate motor shaft rpm-to-speed ratio across multiple speeds and compare observed residuals;
- test sign/direction, byte order and scale under independent sessions;
- keep generator candidates separate from drive motor;
- only export signals to TacoTacoMeter after repeated independent validation.

## Implementation paths

- `ipad/Sources/HondaAnalyzerCore/DriveDIDAnalysis.swift` — allowlist + offline ranking/SQLite readback
- `ipad/Sources/HondaAnalyzerCore/CaptureStore.swift` — time-series insert
- `ipad/App/AnalyzerViewModel.swift` — supervised serial ELM acquisition, pause/rearm handling
- `ipad/App/DrivingAnalysisPage.swift` — dedicated UI
- `ipad/App/AnalyzerWorkspaceV2.swift` — sidebar route and Sessions->analysis
- `ipad/Tests/HondaAnalyzerCoreTests/HondaAnalyzerCoreTests.swift` — regression tests

## Physical verification

Use a passenger or parked operation. Never handle the iPad while driving.

- Full Positive is captured with correct ECU/length and persisted in `did_drive_samples`.
- Five known standard OBD references remain available; true 0 RPM is not "missing".
- No unknown DID is transmitted while speed >0, speed unknown, or P confirmation missing.
- After a speed-triggered pause, 0 km/h alone is not sufficient; renewed P confirmation is required.
- ELM commands stay strictly serialized; no concurrent live/drive/scan tasks.
- SQLite can be cleanly finalized and replayed after the task stops.
- The same candidate can be ranked independently across two sessions with consistent scale/offset.


## Adaptive acquisition after many Positive DIDs

There is no fixed 24-DID ceiling. Every eligible historical complete Positive UDS 0x22 responder is retained in the scheduler, keyed by ECU and DID. F100–F1FF identity-oriented and partial-response identifiers remain excluded from driving scans; baseline known Mode 01 PIDs are always polled for reference and safety.

| Priority | Evidence | Next check target |
|---|---|---|
| Learning | New Positive DID | about 1 second |
| Active | Reassembled payload changes | about 0.8 seconds |
| Watch | 7 unchanged comparisons | about 12 seconds |
| Dormant | 12 unchanged comparisons across at least 2 moving contexts | about 90 seconds |
| Individual failed responses | Transport / UDS failure, not evidence of stability | 5/10/20/40/60 second exponential retry |

Intervals are **scheduling targets rather than guarantees**. A limited BLE/ELM/ECU link cannot poll hundreds of changing DIDs at 1 Hz; the planner prioritizes changing values and dedicates one in four available opportunities to learning/sparse rechecks. Operating-mode changes wake suppressed candidates earlier. Any newly changed payload returns to Active. Nothing is permanently discarded merely because it was constant during one trip.

The Driving Analysis page shows total, learning, active, watch and dormant counts. Snapshots are checkpointed during collection and at clean stop; recording termination flushes the SQLite writer. The screen only lists the first 48 identifiers to keep it readable, **but all eligible identifiers remain managed**. SQLite stores the entire DID plan, actual complete samples, and priority-transition events for reproducibility.

For large captures, offline candidate analysis reads time-spanning sampled rows per DID (typically a few hundred) while leaving the SQLite source untouched; the computation is off the main SwiftUI actor so the interface can still respond.

Priority snapshots are now persisted in the SQLite did_drive_adaptive_state table and restored from the latest recorded state for each ECU/DID. Every new session still forces an initial recheck; no historical decision permanently blocks data collection. Suppression tests compare complete payload bytes; counters or checksums that change even when physical fields do not may keep a DID in Active. Field-level noise detection and cross-session priority caching are future improvements. Being 'Active' does not prove a motor or generator signal.

Single-byte complete-positive responses are included as valid state/flag candidates. Zero-length and incomplete responses remain excluded.
