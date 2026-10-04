# Session 16 Analysis — Expanded DID Inventory and Runtime Hardening

Capture: `session-16-20261004-131144`  
Analyzer: 0.3.4 / build `0.3.4-19d17335a17c`

This document records only reproducible evidence from the exported Debug Bundle. The raw vehicle bundle itself is intentionally not committed.

## Capture quality

- 3,131 ELM command rows
- 7,641 raw BLE notifications
- 3,115 command rows marked successful
- Debug Bundle communication grade: GOOD / score 100
- quality-window median latency: about 108 ms
- quality-window p95 latency: about 172 ms
- observed RSSI: about -62 dBm

The transport remains fast enough for the existing serialized request scheduler. No command pipelining should be introduced.

## Safety-stop validation

Two early DID discovery attempts were automatically stopped when the periodic standard vehicle-speed check detected motion:

- first stop: 13 km/h
- second stop: 5 km/h

This confirms that the fail-safe rule in `AsyncDidDiscovery` worked on the real vehicle: unknown `0x22` discovery did not continue while moving.

The old UI-action summary only logged the manual stop flag, so those safety stops could look like ordinary completion in `ui_actions.jsonl`. Phase 35 changes the summary to an explicit `stop_reason` such as `speed_safety`, `user`, `consecutive_error`, or `complete`.

## Positive DID expansion

The Session 16 exported scan contains:

- 1,879 DID result rows
- 62 complete `positive`
- 13 `positive_partial`
- 1,804 NRC results

The application reported 81 Positive/partial-Positive DIDs in the cumulative cross-session inventory at the end of the scan. Session 16 therefore materially expands the inventory available to the next driving sweep.

### ECU source 01 — long Positive responses

The following DIDs were observed as `positive_partial` because the KW905 text buffer truncated the tail:

`2019, 2025, 2028, 202A, 202B, 202C, 2059, 2068, 206A, 206B, 206C`

The compact `ATH0` retry recovered a longer prefix for several of them, but none became a complete payload in this capture. Preserve the received prefix and do not synthesize missing bytes.

### ECU source 0E — newly useful region

Session 16 found a large cluster of complete Positive DIDs:

`2200, 2201, 2202, 2203, 2211, 2212, 2213, 2220, 2221, 2230, 2231, 2240, 2241, 2242, 22E0, 22E4,`

`2600, 2601, 2610, 2611, 2612, 2613, 2614, 2615, 2620, 2621, 2622, 2623, 2624, 2625, 2630,`

`2660, 2661, 2662, 2663, 2664, 2665, 2667, 2668, 266A, 266C, 266D, 266E, 266F, 2673, 2676, 2678, 2679, 267A, 267B, 267E, 267F,`

`2680, 2681, 2685, 2686, 2691, 2692, 2693, 269F`

Additionally, `26A0` and `26A1` started valid Positive responses but remained `positive_partial`.

The repeated 36/54-byte payload families are good targets for byte-change analysis during a real drive, but their semantics are still unknown.

### ECU source EF

Two additional complete Positive DIDs were found:

- `C000` — 56-byte payload
- `C020` — 4-byte payload

No human-readable ECU role is assigned from the response ID alone.

## DID 2012 SOC evidence reproduced

Session 16 independently reproduces the earlier Session 13 result.

For the time-aligned points available in this short capture, DID `2012` data byte 5 tracked standard PID `5B` SOC with:

- Pearson correlation about 0.9985
- mean absolute error about 0.39 percentage points
- maximum observed absolute error below 0.9 percentage points

Bytes 24–27 also remain strongly SOC-correlated. This strengthens the evidence that byte 5 is an SOC mirror candidate, but it is still not an official Honda semantic definition.

## Why motor/generator ranking is not yet conclusive

Only 30 DID drive-sample rows were present in this bundle, and they cover the older ECU 01 inventory only:

- 2001: 4 samples
- 2010: 3
- 2012: 17
- 2013: 2
- 2018: 2
- 2020: 2

The new ECU 0E / EF Positive DIDs were discovered later in the same session, after the drive plan had already been snapshotted. They therefore have no useful driving time series in Session 16.

The field-ranking code intentionally requires at least five samples per DID before correlation. No traction-motor RPM, generator RPM, torque, or current-specific Honda DID should be promoted from Session 16 alone.

## Runtime issue found from the UI timeline

The bundle also exposed a reproducible asynchronous UI race:

1. Vehicle Readiness was running.
2. Connect was pressed before Readiness had completed.
3. both coroutines mutated `self.transport`.
4. the Readiness finalizer cleared the transport created by Connect.
5. Connect then failed while reading `self.transport.mtu_size`.

Rapid repeated BLE-scan presses also launched overlapping scans and appended duplicate device entries.

Phase 35 serializes BLE scan / readiness / connect operations with an ownership gate and keeps each coroutine's transport in a local variable. A stale coroutine can no longer clear another operation's transport.

## Next vehicle workflow

The next useful test is a **driving sweep**, not another immediate broad DID search.

1. Launch the hardened build.
2. Run Readiness once, then Connect after it completes.
3. Start a fresh live session **after** the expanded Positive inventory is present.
4. Drive long enough to sample the enlarged inventory repeatedly; target roughly 20–30 minutes with varied safe driving states.
5. Include useful natural states: EV low/medium speed, engine-on, acceleration, steady cruise, deceleration/regeneration.
6. Do not run unknown DID discovery while moving.
7. Export the Debug Bundle.
8. Run DID coverage/ranking and focus first on ECU 0E fields that vary with EV-only speed and HV power/current.

The goal of the next capture is not to discover more names. It is to obtain enough repeated samples to let the existing BE/LE signed/unsigned field expansion and correlation workflow rank credible traction-motor/generator candidates.
