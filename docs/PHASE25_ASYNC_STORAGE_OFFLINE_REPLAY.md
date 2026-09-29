# Phase 25 — Async capture storage + Offline Replay Dashboard

This phase hardens the first-vehicle capture path without inventing Honda-specific signal semantics.

## Async SQLite writer

High-frequency `raw_capture`, `commands`, `events`, and `devices` inserts are queued to a dedicated SQLite writer thread. The writer owns a separate SQLite connection, uses WAL + `synchronous=FULL`, and commits short batches (default: up to 64 records / 100 ms). The GUI no longer performs one SQLite commit for every BLE notification or ELM response.

A durability barrier (`flush`) is performed before:

- closing a capture session,
- exporting a Debug Bundle,
- payload analysis that must see the newest rows,
- loading an Offline Replay session,
- application shutdown.

The queue is intentionally unbounded: capture evidence is not silently dropped to keep the UI responsive. A writer failure is treated as a capture-stopping storage error rather than silently losing records.

## Offline Replay Dashboard

The new **Offline Replay** tab reads an existing SQLite session and replays persisted command responses and event markers without opening BLE or transmitting anything to the vehicle.

Controls:

- load a previous session,
- Play / Pause / Step,
- 0.5x / 1x / 2x / 5x / 10x / 20x playback,
- timeline seek,
- replayed Engine RPM / Vehicle Speed / Coolant plots,
- replayed STOP / EV / ENGINE ON / ACCEL / CRUISE / REGEN / CUSTOM markers,
- reconstructed dashboard values,
- timestamped ELM command/response transcript.

`019A` and `222012` remain raw hexadecimal payloads. Offline replay calls the same known-signal decoder used by live polling, so live and replay do not have separate Honda-specific decoding logic.

## Scope

This is a replay of persisted **ELM command evidence and event markers** for analysis/UI reproduction. The lower-level BLE `raw_capture` table remains preserved for forensic inspection and debug bundles; the GUI replay does not attempt to re-drive a virtual BLE stack from notification fragments.

No ECU discovery or DID range scan is started by Offline Replay.
