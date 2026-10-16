# iPad Analyzer — multidisciplinary UI and usability review (2026-10-10)

Scope: `ipad-native` implementation of Dashboard, Guided Start, Driving Analysis, Stationary DID Discovery, Sessions, Technical and Settings, reviewed against SwiftUI sources and previously captured KW905/SQLite behavior.

**Review method:** independent checklists for six professional perspectives, performed by the assistant. No external people were recruited, and no physical iPad screenshots or accessibility-device run were available for this review. This is a **source/UI-flow review**, not a completed human usability test.

## Task-oriented novice walkthrough

**Scenario 1: "I want to see what my car is doing"**

1. Open Bluetooth screen and choose a named device.
2. Dashboard displays the four completion gates BLE → SQLite → ELM init → known signals, with a single next-action button.
3. After validation, the "What do you want to do?" section offers **1. 車両データを見る**.
4. The user can start/stop *live display*, without interacting with unknown UDS commands.
5. End the capture, then share SQLite.

**Scenario 2: "Find the drive-motor RPM"**

1. Prepare recording through the guided four steps.
2. Choose **2. モーター信号を調べる**.
3. On the 走行解析 page, a checklist shows whether known Positive DIDs exist, whether the connection/recording/reference signals are ready, and why the start button is unavailable.
4. If there are no Positive DIDs, a direct link takes the user to stationary DID discovery, not a dead-end disabled button.
5. After a safely parked Positive-DID discovery, start driving capture **before** moving. The application polls known reference PIDs and a bounded list of previously positive UDS DIDs.
6. Stop collecting after safely parking and analyze the capture. Analyzed candidates are explicitly shown as **仮説・未検証**, with correlation explanations, sample counts, offset/format and raw ranges.
7. From the Sessions page, the user can open a saved capture's candidate analysis.

**Scenario 3: "Explore unknown DIDs"**

1. Choose **3. 未知の信号を探す**.
2. Intro explains that a DID is an ECU data identifier, and "Positive" means a response exists, **not** that its physical meaning is validated.
3. Safe order: record + initialize → manually confirm parking/P → census → select responding ECU → small scan, or full scan with confirmation.
4. The page now shows the missing prerequisite instead of leaving both scan buttons disabled without explanation.
5. If the scan detects motion, unknown enumeration pauses; known-positive sampling can continue. It will **not** automatically scan again at a traffic-light stop; three consecutive 0 km/h checks and renewed manual P confirmation are required.

## Independent review perspectives and outcomes

| Perspective | Finding before review | Severity | Resolution |
|---|---|---|---|
| Novice | Live monitoring and motor candidate acquisition sounded like the same operation, and the Dashboard did not link to 走行解析 | High | Replaced two operation cards with **three purpose-first choices**; dedicated navigation |
| Novice | The 走行解析 start button was disabled with no reason or next step | High | Four-point readiness checklist, explicit blocked reason, link to stationary exploration |
| Analyst | Candidate scores looked like confidence percentages/validated motor identity | High | **Hypothesis/unverified** labels; explanation that score is prioritization, not truth probability, with reference correlation glossary |
| Analyst | Raw DID format and association with speed/RPM not interpretable for nonexperts | Medium | Glossary explains DID, Positive, EV interval and Pearson r; row retains signedness/offset/raw range and counts |
| UI/UX | Status badges existed only on Dashboard; switching pages hid active acquisition state | Medium | Sidebar connection footer shows REC, DRIVE, paused discovery, discovery, live status |
| UI/UX | Exploration buttons competed for horizontal room | Medium | Adaptive grid and large touch controls; partial alignment of settings rate selectors |
| Vehicle safety | 0 km/h looked equivalent to confirmed P/park | Critical | Updated screen wording: manual P is required, 0 km/h alone never resumes an unknown scan |
| QA | SQLite end button could remain clickable visually while drive task was active | High | Added `isDriveCollecting` to disabled state (the ViewModel guard already existed) |
| Accessibility | Primary page required studying raw expert terms in dense text | Medium | Meaning-first labels and expandable glossary; on-screen instructions and larger primary controls |

## What remains open

These items **cannot be honestly declared complete without real devices and reference captures**.

1. Visual iPad QA: portrait/landscape/Split View, Dynamic Type, 44pt target checks, VoiceOver focus/order. No real iPad screenshots examined in this review.
2. Validate the *automatic switch* from discovery pause to known-signal drive capture in the vehicle, especially lag between 010D speed checks and stopping unknown requests.
3. A recurring signal-candidate comparison view spanning two or more captures, with residual error and ratio/scale fitting for motor speed, remains unimplemented.
4. End-to-end performance with the **self-built ELM327-compatible adapter** is not established. The known KW905 round-trip is significantly slower.
5. Field rankings remain hypotheses until EV/engine-running/acceleration/regeneration and repeated independent sessions validate the same bit field and physical scaling.
6. Hardware-derived P-range readout is not implemented. The confirmation is a manual user assertion; do not misrepresent it as an ECU-verified parking signal.
7. Historical capture analysis is synchronous in the current ViewModel; for large multi-hour databases it should be moved off the UI thread with explicit progress/cancel support.

## Acceptance criteria for next physical UX pass

- An operator unfamiliar with DID can distinguish the three dashboard purposes within ~10 seconds, without looking up terminology.
- The disabled Drive Start button always has a visible, actionable explanation and a route to missing Positive DID discovery.
- Session remains visibly REC across Dashboard, Driving and DID pages and cannot close while driving capture is still active.
- DID scan shows **which** step is missing, from BLE/SQLite/ELM/P/census/responding ECU, and full-scan confirmation clearly explains scope.
- User cannot read a candidate score as a verified confidence percentage or assume any ranked field already is motor RPM.
- The vehicle cannot enter unknown scanning purely because a red-light stop results in 0 km/h.
- VoiceOver reads key status, readiness, action and candidate information in a sensible order on real iPad hardware.

Relevant files:
- `ipad/App/WorkflowViews.swift`: purpose-first operation choices, start guidance, navigation
- `ipad/App/DrivingAnalysisPage.swift`: drive readiness checklist, blocked reasons, glossary and candidate semantics
- `ipad/App/AnalyzerWorkspaceV2.swift`: navigation, discovery walkthrough and persistent statuses
- `ipad/App/AnalyzerViewModel.swift`: authoritative acquisition safety gates
- `docs/IPAD_DRIVING_DID_ANALYSIS.md`: acquisition and heuristic semantics
