# Phase 31 — DID Discovery → Positive DID Drive Sweep

## Goal

Find read-only UDS `0x22` DIDs that actually return data from already-observed ECU responders, persist the results across days, then sample every Positive DID during driving and compare its fields with known references such as vehicle speed, engine RPM, HV battery power/current and SOC.

This is **not** passive capture of every CAN frame. It is diagnostic request/response acquisition through the KW905/ELM327.

## Stationary DID Discovery

- Service is fixed to UDS `ReadDataByIdentifier (0x22)`.
- Range is user-selectable from `0000` through `FFFF`.
- Multiple observed ECUs can be selected together.
- Requests are rate-limited (0.5/1/2/3 req/s in the GUI).
- Vehicle speed is re-read about every 2 seconds. If speed is non-zero **or cannot be confirmed**, discovery stops fail-safe.
- No DiagnosticSessionControl (`0x10`), SecurityAccess (`0x27`) or write services are used.
- Positive responses and NRC `0x31` are treated as checked for cross-session resume.
- Timeout, `NO DATA`, and non-0x31 NRC results remain retryable on a later scan.
- Five consecutive infrastructure/error outcomes stop the scan to avoid sending thousands of identical failed requests.
- With multiple ECUs, scan order advances in 256-DID chunks per ECU. This balances multi-day progress without changing the physical CAN header on every request.

A full `0000–FFFF` scan at 2 req/s is intrinsically long. Five ECUs require about 45.5 hours before protocol/header/speed-check overhead. The GUI shows this estimate and requires an explicit acknowledgement for large scans.

## Positive DID Inventory

Every Positive DID stores:

- ECU source identifier
- DID
- response CAN ID
- payload
- latency
- discovery session/time

The inventory is built across sessions so discovery can continue on later days.

## Driving: Positive DID Sweep

When Live Capture starts, the current Positive DID inventory is snapshotted into `did_drive_plan` for that session. This makes later coverage reproducible even if more DIDs are discovered afterward.

The live scheduler prioritizes known references first:

- engine RPM
- vehicle speed
- coolant
- HV SOC
- PID 9A HV voltage/current/power
- automatic drive-state inputs

Low-rate bandwidth is shared by:

1. supported standard Mode 01 PID sweep;
2. Positive DID round-robin sweep.

DID `2012` remains a core poll and is copied into the same drive-sample table rather than requested twice.

## Post-drive coverage and ranking

For every planned ECU/DID pair, the UI shows:

- samples acquired
- unique payload count
- min/max payload length

Changing fields are expanded only around bytes that actually changed. Candidate interpretations include signed/unsigned 8/16/24/32-bit BE/LE values. Equivalent value series are de-duplicated.

Each candidate is compared against:

- EV-only vehicle speed (Engine RPM < 150 rpm)
- all vehicle speed
- HV battery power
- HV battery current
- HV SOC
- engine RPM

The ranking is evidence prioritization only. The software does not rename a field to “motor RPM”, “motor current”, or another semantic without additional evidence.

## Debug Bundle

The session ZIP now also contains:

- `did_scan.json`
- `did_drive_plan.json`
- `did_drive_samples.jsonl`

This makes stationary discovery, intended driving coverage, and actual driving samples independently auditable.
