# Implementation Plan

The supplied 72-section specification is the source of truth. Implementation is intentionally phased; vehicle-specific values are never guessed.

## Phase 1 — included in this archive
- Layered package layout: Transport / Protocol / Analysis / Storage / Export.
- Abstract transport and deterministic MockTransport.
- ELM prompt framing independent of BLE notification boundaries.
- Known OBD formula helpers and UDS 0x22 positive/NRC parser.
- Read-only `safe_scan_request()` that can only construct 0x22 requests.
- Safe arithmetic formula sandbox without Python eval.
- Initial automatic field expansion.
- SQLite WAL database with append-only raw capture primitive.
- RP8 signal definition seed with unknown Honda semantics explicitly marked.
- pytest regression tests.

## Phase 2
Bleak scan/selection, GATT inspector, raw notifications, discovered write/notify characteristics, MTU/RSSI metadata, ELM terminal, reconnect and continuous raw logging. No KONNWEI-name or UUID guessing.

## Phase 3
Known signals 010C/010D/0105/019A/222012, ISO-TP reassembly, response CAN-ID preservation, Live Dashboard. 019A offsets must come from existing capture/vehicle evidence.

## Phase 4–9
Implement the requested session browser/replay/markers; ECU discovery and safe resumable DID scanning; payload diff/heatmap/field expansion/correlation/lag/scatter; candidate detectors and versioned formulas; Car Scanner + SmartRing interchange/reporting; fault injection/scheduler/debug bundle/golden CI.

## Non-negotiable invariants
1. Raw data is immutable and written incrementally.
2. Live and replay traverse the same parser/signal pipeline.
3. ECU identity is part of every DID observation.
4. Candidate is not Verified without evidence across sessions.
5. Automated scanning sends only UDS 0x22 and stops when speed > 0 if speed is available.
6. Target: keep BLE/DB/heavy analysis off the GUI thread. Current 0.2.1 still performs short SQLite writes and some offline analysis on the Qt/event-loop thread; this is a documented limitation for the conservative first capture and should be refactored before high-rate/long-duration use.
7. Session metadata records tool and Git versions.


## Phase 2 implementation update
Implemented runtime BLE scanning, GATT discovery/inspection, characteristic auto-selection without vendor UUID assumptions, raw notification hook, prompt-framed ELM command session, initialization metadata commands, and a PySide6 BLE Inspector / ELM Terminal scaffold. Requires macOS hardware test before marking vehicle-verified.

## Phase 3 implementation update
Added header-tolerant OBD text extraction and known-signal decode registry for 010C/010D/0105, plus raw placeholders for 019A and 222012. Honda-specific 019A offsets and DID 2012 semantics intentionally remain un-decoded pending raw vehicle evidence. Live Dashboard UI scaffold is present; polling/plotting is next.


## Phase 4 implementation update
Expanded SQLite WAL schema for sessions/devices/commands/raw/DID/events, added per-observation commits, crash recovery (`OPEN` -> `RECOVERED`), indexes, session listing, and deterministic ReplayTransport using the same Transport interface. Replay supports timed speed factors, MAX (`inf`) and explicit step access. Plot/marker UI integration remains to be completed.

## Phase 5 implementation status
Implemented the safety-critical core for ECU/DID exploration: 29-bit response ECU extraction without assuming all Honda IDs match it, read-only UDS 0x22 scanner API, speed>0 automatic stop hook, rate limiting, pause/stop, SQLite resume state, and positive-DID selection queries. GUI wiring to the Phase 5 core remains a known limitation until real KW905 header formatting is captured; this avoids guessing ELM/ISO-TP behavior.

## Phase 6 status
Implemented analysis-core primitives for payload differential/activity workflows: full field expansion (u8/s8/u16/s16 BE+LE/u24/u32/s32 BE+LE + bits), descriptive statistics, Pearson/Spearman correlation, sample-lag search, byte activity/change detection, bit toggles, counter detection, scale candidates, and a conservative Drive Motor RPM candidate scorer that returns evidence/contradictions and never marks VERIFIED. GUI heatmap/scatter/multi-plot wiring remains a follow-on task and needs real capture data for useful validation.

## Phase 7 progress
Implemented analysis-side Phase 7 foundations:
- Separate Generator RPM candidate heuristic (not reusing Drive Motor assumptions).
- Mechanical torque × RPM power candidate calculation; explicitly not equated with HV electrical power.
- Safe Formula Sandbox arithmetic evaluator and batch application (no Python eval/calls/attributes).
- Versioned SignalDefinition schema with KNOWN/CANDIDATE/VERIFIED/REJECTED/TODO-VEHICLE-TEST/UNKNOWN states.
- SmartRing export gate: only KNOWN or VERIFIED definitions are exportable.

Remaining UI work: Formula Editor widgets and candidate review workflow. Vehicle-specific unknowns remain TODO-VEHICLE-TEST until RAW evidence exists.

## Phase 7 status
Implemented separate conservative Generator candidate scoring, mechanical-power helper, safe formula sandbox extensions, versioned signal-definition model/status validation, and SmartRing signal export restricted to KNOWN/VERIFIED definitions. Vehicle evidence is still required for Honda-specific fields.

## Phase 8 status
Implemented dependency-light Car Scanner CSV import with delimiter/decimal detection and raw-byte preservation, SmartRing CSV/JSON/JSONL import, manual timeline offsets and cross-correlation alignment candidates, generic CSV/JSON export, HTML report generation with escaping, and shared SmartRing signal-config export. Automatic alignment is advisory only; it never mutates original timestamps. GUI import/report wiring and real sample validation remain manual-test items.


## Phase 9 completion
Implemented deterministic replay fault injection, packet timing statistics, ELM poll scheduler simulation/recommended-rate helper, application logging setup, privacy-scoped debug bundle export, and golden capture regression scaffolding. Vehicle-derived recommended rates remain TODO-VEHICLE-TEST until KW905 latency is measured.
