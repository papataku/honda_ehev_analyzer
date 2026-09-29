# macOS Honda e:HEV CAN / UDS Analyzer

Pre-vehicle reference implementation for Honda STEP WGN RP8 e:HEV analysis on Apple Silicon macOS, implemented through the first-capture readiness workflow and analysis phases.

## Status
Implemented through the first pre-vehicle capture workflow: layered transport/protocol/analysis, BLE/ELM capture, incremental SQLite sessions/replay, safe UDS 0x22 scanner core, live known-signal polling/plotting, payload differential/heatmap/field expansion/correlation, versioned signal definitions, Car Scanner and SmartRing interchange, debug bundles, readiness automation, deterministic fault injection and regression coverage.

RP8/KW905 vehicle captures have confirmed stable BLE/ELM communication, multiple OBD responders, and the drive-capture pipeline. Session 12 established that Mode 01 PID `9A` is the standardized Hybrid/EV Vehicle System Data and is directly usable for HV battery voltage/current; power is derived as V×I. Standard PID `5B` is Hybrid/EV battery remaining charge (SOC). DID `2012`, ECU role names, and traction motor/generator RPM/torque fields remain `TODO-VEHICLE-TEST`; they are not inferred from response IDs alone.

## Architecture
`Transport -> Protocol -> Analysis -> Storage/Export -> GUI`

Raw observations are append-only. Derived data can be regenerated.

## Quick start
```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -e '.[dev]'
pytest -q
```

## Safety
Automated DID scanning must be restricted to UDS service `0x22` and should stop when vehicle speed is above zero. No write/session/security/control services are included in the scanner core.

See `docs/IMPLEMENTATION_PLAN.md` and `docs/VEHICLE_TEST_PLAN.md`.

## Vehicle-ready desktop capture (0.2.0)
The macOS GUI now opens an incremental SQLite session automatically, records raw BLE notifications and ELM command/response latency, stores discovered GATT metadata, provides explicit raw-capture control, STOP/EV/ENGINE ON/ACCEL/CRUISE/REGEN/CUSTOM event markers with 1-6 shortcuts, and includes a session browser/recovery path. See `docs/VEHICLE_READINESS.md` before the first RP8 test.


## Phase 11: Mac-only KW905/ELM dry-run simulator
Added `Elm327SimulatorTransport` for pre-vehicle testing through the same `ElmSession` parser used by live transports. It supports initialization metadata, fragmented prompt responses, known OBD requests, synthetic 019A/222012 raw responses, headers, and STOP/EV/ENGINE scenario state changes. Synthetic Honda payloads intentionally carry no vehicle semantics. See `docs/MAC_ONLY_DRY_RUN.md`.

## Phase 12 — Synthetic end-to-end drive cycle
A deterministic Mac-only drive cycle now exercises STOP → EV low/medium/high → ENGINE ON → ACCEL → CRUISE → REGEN. It feeds the state classifier, statistics, lag correlation, and separate Motor/Generator candidate detectors. The generated motor/generator values are synthetic truth for regression only and MUST NOT be used as Honda RP8 signal definitions or evidence.

## Phase 13 — Golden Session full loop
Added a deterministic synthetic Golden Session that writes incremental RAW observations to SQLite, reads them back as replay input, verifies a SHA-256 identity, reruns deterministic analysis, generates an HTML report, and regression-tests abandoned-session recovery. Synthetic values remain explicitly barred from Honda RP8 evidence.

## Phase 14 — transport golden integration
Adds Mac-only integration coverage for fragmentation, merged/duplicate chunks, timeout, disconnect/reconnect, and synthetic golden capture generation through the production `ElmSession` parser path. See `docs/TRANSPORT_GOLDEN_INTEGRATION.md`.


## Phase 15 — Vehicle Readiness automation
GUI one-button acceptance gate added. See `docs/VEHICLE_READINESS_AUTOMATION.md`. The gate performs only the known first-vehicle sequence, persists evidence, tests reconnect, and verifies captured ELM response byte replay. It never starts a DID range scan.

## Phase 16 — Vehicle diagnostics & one-click debug bundle

Adds a conservative communication-quality assessment using measured ELM latency, timeout/error rate and BLE RSSI when available. The result is GOOD/FAIR/POOR with evidence rather than an assumed KW905 polling capability. A session-scoped debug bundle exporter includes only the selected session's metadata, commands, BLE/GATT metadata, raw capture and events, preventing unrelated sessions from being swept into a support archive.

## Phase 17
Live Dashboard communication-quality monitoring and one-click `Save Test & Export Debug Bundle` are implemented. See `docs/PHASE17_LIVE_DIAGNOSTICS.md`.

## Phase 18 — Drive Test Mode

Passenger-oriented large-button drive test UI was added for STOP / EV / ENGINE ON / ACCEL / CRUISE / REGEN / CUSTOM markers. It shows persisted communication quality, raises communication-only warnings, and provides one-action session close + Debug Bundle export. It never starts DID scanning. See `docs/PHASE18_DRIVE_TEST_MODE.md`.

## Phase 19 — Live known-signal polling
Adds serialized, no-backlog live polling for only `010C`, `010D`, `0105`, `019A`, and `222012`. RPM/speed/coolant are decoded; `019A` and `222012` remain RAW until vehicle evidence establishes their fields. This feature is separate from and cannot start DID scanning. See `docs/PHASE19_LIVE_KNOWN_SIGNALS.md`.

## Phase 20
Live pyqtgraph time-series buffers are now connected to known numeric polling signals. Event markers share the session-relative plot timeline, and the plot includes a selectable time region for follow-on differential/correlation analysis. 019A and DID 2012 remain raw evidence rather than guessed numeric signals.

## Phase 21
Selected-range unknown-payload comparison foundation is included (`payload_diff.py`): raw ELM hex extraction for visualization, byte-by-byte differential view data, per-byte activity ratios, and session command-row retrieval. No Honda-specific offsets are inferred.

## Phase 22
Payload Analysis GUI connects timeline A/B selection to `019A` / `222012` differential hex, byte activity heatmap, and offset-specific automatic field expansion. These are evidence/candidate views only and do not promote unknown fields to VERIFIED.

## Phase 23
Selected unknown fields can now be correlated against known numeric signals with asynchronous timestamp alignment, Pearson/Spearman, ±5 s lag search, scatter data, and a non-confirming Drive Motor candidate score. Candidate output is evidence only and never promotes a signal to VERIFIED. See `docs/PHASE23_CORRELATION_WORKFLOW.md`.

## Phase 24 — final pre-vehicle gate
The live scheduler now explicitly selects `18DB33F1` for Mode 01/019A and `18DBEFF1` for UDS DID 2012 instead of relying on the adapter's previous header. Vehicle Readiness performs the same explicit header selection. `Preflight.command`, `Run Honda Analyzer.command`, and `docs/PRE_VEHICLE_FINAL_CHECKLIST.md` provide the final Mac-only gate and the exact stationary-first vehicle procedure. At this point, remaining unknowns require a real KW905/RP8 capture rather than further guessing.

## 0.2.1 pre-vehicle recheck
A second implementation audit found and corrected several issues before real-vehicle use: ELM `NO DATA`/CAN failures are no longer reported as successful commands; readiness now establishes protocol/format state itself; compact `ATS0` text and ISO-TP SF/FF/CF responses are parsed; payload analysis excludes response service/PID/DID bytes; GATT auto-selection prefers a write/notify pair in the same service; communication quality distinguishes no-data/timeout/link errors; scan RSSI/MTU are retained when available; live polling defaults are more conservative; the terminal defaults to a read-only vehicle-safe guard; and ending a drive test cancels live polling before session close. The regression suite now includes real-format compact/multiframe cases.

Scope clarification: this build is intended for the first stationary readiness capture and passenger-operated known-signal/RAW drive capture. The read-only 0x22 scanner core exists, but ECU Discovery / physical-address ELM client / scanner GUI wiring is not yet vehicle-ready and should be completed only after the first RP8 response IDs are captured.

## Phase 25 — async persistence + Offline Replay (0.2.2)
Capture-path SQLite writes for RAW BLE notifications, ELM responses, events, and device metadata now run through a dedicated batched writer thread rather than committing synchronously in the Qt event loop. Session close/export/analysis/replay use explicit durability barriers. A new **Offline Replay** tab can load any persisted session and deterministically Play/Pause/Step/Seek the known-signal dashboard, numeric plots, event markers, and ELM transcript without connecting to BLE or transmitting to the vehicle. `019A` and `222012` remain raw hexadecimal evidence. See `docs/PHASE25_ASYNC_STORAGE_OFFLINE_REPLAY.md`.

## 0.2.3 real-KW905 correction
The first RP8/KW905 capture showed that this ELM327 v1.5-compatible adapter rejects an 8-digit `ATSH`. 29-bit headers are now selected as `ATCP18` + `ATSHDB33F1` (OBD) or `ATSHDBEFF1` (Honda UDS functional request). Live Dashboard no longer aborts before each PID due to the rejected header command. Payload Analysis now exposes A/B range assignment and zero-sample errors instead of silently doing nothing.

## 0.2.4 — 初心者向け日本語UI + ECU確認
実車取得後の操作フィードバックを反映し、主要ページを日本語化して推奨順序へ並べ替えた。全ページに「ここですること / ここで分かること / 先に必要なこと」を表示し、条件不足時は理由と次の操作を案内する。

新しい **3. ECU確認** では、保存済みセッションから車両への送信なしで `18DAF1xx` responderを集計する Passive Census、停車/P確認後に既知read-only request (`0100/010C/010D/0105/019A/222012`) だけを各1回送る Safe Census、観測済みECU 1台へ `22 2012` を1回だけ送る Physical Probeを提供する。表示数は診断応答ECU候補数であり、搭載ECU総数とは扱わない。DID範囲scanはこの初心者向けGUIから開始しない。

最初のRP8/KW905実車captureで、`010C`に対して少なくとも `18DAF1EF / 18DAF10E / 18DAF101 / 18DAF102 / 18DAF106` が観測され、`019A` と `222012` は `18DAF101` のmulti-frame応答が観測された。これらのresponse形式を回帰テストへ反映した。詳細は `docs/PHASE27_GUIDED_JAPANESE_UI_ECU_CENSUS.md` と `docs/BEGINNER_UI_REVIEW.md`。

## 0.2.5 初心者視点の再レビュー

複数の新人像（車/CAN未経験、ソフト経験者、整備経験者、PC操作初心者、CAN経験者）で、画面文言→ボタン→実行条件→処理→失敗表示を再点検しました。詳細は `docs/BEGINNER_UI_REVIEW_0.2.5.md` を参照してください。

主な修正: Readiness PASS後の案内、RAW保存の説明とガード、マーカー条件、CUSTOMキャンセル、Payload A/B前提、相関field前提、保存ZIP表示、ライブ中セッション切替、ECU用語補足。

## 0.2.6: 小さい画面への対応
0.2.5でMac画面より大きく開き、下部へ到達できない問題を修正しました。
起動サイズはmacOSの利用可能画面サイズに合わせ、全ページをスクロール可能にしています。
横長だった操作ボタンも複数段へ分割し、ウィンドウを640x480まで縮小できる構成に変更しました。

## 0.2.7 — 実車Session 4反映 / 走行解析準備

0.2.7では、実車Session 4のレビューを基にPayload A/B比較をByte統計方式へ変更し、空SessionのZIP化防止、UI操作ログ、配布ZIP用Build ID、全診断応答インベントリを追加しました。

走行フェーズでは、RPM/車速/水温/019A/222012の既知read-only要求を継続取得し、その要求に返った全response CAN IDをRAWとして保存します。これは車内CAN全フレームの受動キャプチャではありません。詳細は `docs/DRIVE_ANALYSIS_PHASE_0_2_7.md` を参照してください。

## 0.2.8 — 自動走行状態判定 + 対応Mode 01全PID巡回

次回乗車で手動マーカー無しでも解析できるよう、標準OBDのsupport bitmapを起動時に確認し、対応PIDのみを低速巡回保存します。RPM/車速/アクセル等から走行状態を自動ラベル化し、Honda 019A / 222012 / 全response ID RAWと同じSession時刻で保存します。詳細は `docs/PHASE28_NEXT_RIDE_FULL_CAPTURE.md` を参照してください。


## 0.2.9 — Session 12: 標準Hybrid/EV信号の正式デコード

実走行Session 12を解析し、従来RAW扱いだったMode 01 PID `9A`をSAE J1979の標準Hybrid/EV Vehicle System Dataとしてデコードします。HVバッテリー電圧・符号付き電流・電力（V×I）をライブ表示、保存、オフライン再生、相関解析へ追加しました。PID `5B`はHybrid/EV Battery Pack Remaining Charge（一般にSOC）として表示します。減速中かつHV電力が負の場合、自動状態判定は「回生」を実測確認として扱います。アクセルPID 49はRP8で解放時も約20%の基準値を持つため、固定0%近傍しきい値でアクセルOFF判定しません。詳細は `docs/PHASE29_SESSION12_STANDARD_HEV.md`。


## 0.3.0 — Session 13 regression
- PID 9Aの受信後UI例外を通信エラーとして二重記録していた問題を修正。
- RAW受信成功後のデコード/表示例外は `live_decode_error` として分離。
- DID 2012 data byte 5を、Session 13の強い相関証拠に基づく「SOCミラー候補（未確定）」としてライブ/リプレイ表示。

## 0.3.1 — DID Discovery → driving sweep

The ECU page now supports a complete read-only discovery workflow: stationary UDS 0x22 DID scanning of observed ECU responders, persistent Positive DID inventory, multi-day resume, and automatic sampling of all discovered Positive DIDs during later driving. The drive session snapshots the intended DID list, records each positive payload, reports coverage, and ranks changing fields against vehicle speed, engine RPM, HV SOC, HV battery power and HV battery current.

Unknown DID discovery never runs while driving. Driving only reads DIDs that were previously Positive. Diagnostic session changes, Security Access and write services are intentionally outside this tool's discovery path.

See `docs/PHASE31_DID_DISCOVERY_DRIVE_SWEEP.md` and `docs/REVIEW_0_3_1_MULTI_ROLE.md`.

## 0.3.2 - DID探索 10 req/s目標

Session 14の実車計測を反映し、DID Discoveryを高速化した。既定は10 req/s目標。
8 req/s以上では探索中だけELM Adaptive Timing/timeoutを高速設定へ切り替え、終了時に復元する。
また0x2012が存在する0x2000帯を先行探索し、その後に全範囲を埋める。
詳細は `docs/RELEASE_NOTES_0_3_2.md` を参照。


## 0.3.3 - 適応優先DID探索

全範囲DID探索を、既知2000帯 → 16領域粗探索 → 0x100ページ代表探索 → 反応ページ即深掘り → 未探索全埋め、の適応優先順へ変更。代表点が無反応でも最終Coverageからは除外しない。0.3.2の10 req/s目標高速タイミングも継承。

詳細は `docs/RELEASE_NOTES_0_3_3.md` と `docs/REVIEW_0_3_3_ADAPTIVE_SCAN.md` を参照。


## 0.3.4 - Session 15 長大DID応答リカバリ

実車Session 15で、長大なUDS Positive responseがKW905の`BUFFER FULL`により途中欠落し、0.3.3ではerrorとして失われていた問題を修正。`62 DID`まで確認できた応答は`positive_partial`として受信済みprefixを保存し、`ATH0` compact retryで完全取得を試みる。部分PositiveはDID存在確認済みとして探索を先へ進め、走行Coverageでも完全/部分を区別する。

詳細は `docs/RELEASE_NOTES_0_3_4.md` と `docs/REVIEW_0_3_4_SESSION15_LONG_DID.md` を参照。
