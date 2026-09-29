# Project Context — Honda e:HEV Analyzer

## Purpose
Build a macOS analyzer that discovers and validates vehicle signals on a Honda STEP WGN e:HEV RP8, preserves raw diagnostic evidence, and exports verified signal definitions for an ESP32-S3 round SmartRing meter.

The analyzer is deliberately evidence-first: unknown Honda data is discovered, recorded, replayed, compared against known references, and promoted only when the evidence justifies it.

## Canonical repository
`git@github.com:papataku/honda_ehev_analyzer.git`

The repository is the source of truth. Release ZIPs are convenience artifacts, not the development master.

## Hardware / environment
- Vehicle: Honda STEP WGN e:HEV RP8 (2023)
- Adapter: KONNWEI KW905, ELM327-compatible BLE adapter
- Desktop: Apple Silicon macOS, Python 3.12+
- BLE observed on KW905: service FFF0; notify FFF1; write FFF2
- CAN protocol observed: ISO 15765-4 CAN 29/500

## Architecture
`Transport -> ELM/CAN/ISO-TP -> OBD/UDS -> Signal/Analysis -> SQLite/Replay/Export -> GUI`

Key principles:
- transport is replaceable (BLE now; USB-CAN/SocketCAN/J2534 later),
- raw capture is append-only,
- live and replay use the same parsing/decoding logic where practical,
- derived data must be reproducible from saved raw evidence.

## Real vehicle evidence summary

### BLE / ELM
Real KW905 captures have shown stable FFF0/FFF1/FFF2 communication and ELM responses fragmented across multiple BLE notifications. One BLE notification is not one ELM response; the ELM prompt `>` terminates a command response.

On this adapter, 29-bit functional headers are selected with:
- `ATCP18`
- `ATSHDB33F1` for standard OBD / Mode 01
- `ATSHDBEFF1` for the Honda/UDS functional request used in existing tests

An 8-digit `ATSH18DB33F1` returns `?` on the real adapter.

### Observed Mode 01 response CAN IDs
At least these responders have been observed for Engine RPM requests:
- `18DAF101`
- `18DAF102`
- `18DAF106`
- `18DAF10E`
- `18DAF1EF`

Coolant responses have been observed from `18DAF101`, `18DAF102`, and `18DAF106`.

These are responder IDs, not confirmed human-readable ECU role names. Do not label them PCM/HPCM/etc without evidence.

### Known standard signals
- `010C`: Engine RPM
- `010D`: Vehicle speed
- `0105`: Coolant temperature
- `015B`: Hybrid/EV battery remaining charge (used as SOC)
- `019A`: Hybrid/EV Vehicle System Data, decoded for HV battery voltage/current; HV power = V × I

RP8 captures show positive HV battery current/power as discharge and negative values as charge/regeneration. Preserve raw values alongside derived units.

### UDS DID 2012
- Request: `22 2012`
- Positive service prefix: `62 20 12`
- Response has been observed from `18DAF101`.
- Session 13 showed DID 2012 data Byte 5 tracking standard PID 5B SOC extremely closely. Treat it as a strong SOC-mirror candidate, not an official Honda definition.
- DID 2012 has not shown convincing traction motor RPM behavior in the current drive logs.

### Session 15 long-DID finding
Scanning ECU source 01 in the 0x2000 region found at least the following DIDs initiating Positive responses:
`2001, 2010, 2012, 2013, 2018, 2019, 2020, 2025, 2028, 202A, 202B, 202C, 2059, 2068, 206A, 206B, 206C`.

In the v0.3.3-era capture, six were complete and eleven produced long responses that reached `BUFFER FULL`. v0.3.4 treats these as `positive_partial`, retries a compact response mode, preserves all received bytes, and continues scanning.

This list is evidence from a particular scan state; it is not a declaration that these are the only valid DIDs.

## DID discovery requirements
- Automated unknown discovery is UDS `0x22` only.
- Scan only while stationary; speed is rechecked during the scan.
- Stop if speed is non-zero or cannot be confirmed.
- Do not use DiagnosticSessionControl, SecurityAccess, write, routine-control, or actuator services in the automated scanner.
- Scan can be split across sessions/days.
- Discovery order is adaptive for time-to-first-useful-result, but eventual full requested-range coverage must be retained.
- Definitive results can be resumed/skipped; transient transport failures are retryable.

## Adaptive scan order
1. Known useful `0x2000–0x20FF` range.
2. Coarse sampling across the 16 high-nibble sectors (`0xxx` … `Fxxx`).
3. Sample `0x100` pages within sectors.
4. Immediately deep-scan pages with Positive or other potentially meaningful responses.
5. Fill every remaining untested DID so priority optimization never becomes permanent exclusion.

The target rate is approximately 10 requests/s when the adapter response time permits it. Never overlap ELM commands; wait for the prompt and use adaptive timing/timeout settings instead.

## Long response policy
Long UDS responses can exceed the ELM/KW905 text-output buffer.
- `62 DID` + `BUFFER FULL` means the DID exists and a Positive response started.
- Retry with reduced ELM text overhead where supported.
- Preserve a still-truncated response as `positive_partial`.
- Do not count it as an ordinary link failure.
- Do not retry the same partial DID forever before progressing to the rest of the range.

## Driving sweep requirements
Unknown discovery does not run while driving. The drive capture uses the previously discovered Positive/partial Positive inventory.

During driving:
- known reference signals remain higher priority,
- discovered DIDs are sampled round-robin within available KW905 bandwidth,
- all response CAN IDs and raw payloads are preserved,
- a drive-plan snapshot records what the session intended to sample,
- coverage reports distinguish planned / sampled / complete / partial.

## Analysis goals
Primary unknown targets:
- traction motor RPM,
- generator RPM,
- motor/generator torque or related current/power signals.

Known reference axes include:
- vehicle speed,
- Engine RPM,
- accelerator,
- HV SOC,
- HV voltage/current/power,
- EV/engine/acceleration/deceleration/regeneration state.

Automatically expand changing payload regions as signed/unsigned multi-byte candidates in BE/LE forms and correlate with references. Correlation and state behavior create candidates; they do not confirm semantics.

## SmartRing target
Verified definitions will ultimately feed an ESP32-S3 round display meter. Required known display data already includes Engine RPM, coolant, HV SOC and HV battery input/output kW. Motor RPM remains an active discovery target.

## Data / privacy / repository hygiene
Vehicle Debug Bundles and raw session databases can contain detailed trip/diagnostic traces. Do not commit vehicle session ZIPs or user-specific raw logs to the public repository unless explicitly requested. Commit code, tests, synthetic fixtures, anonymized regression excerpts, and documentation instead.

## Current release baseline
As of the initial repository import, the working baseline is v0.3.4 (Long DID Recovery). Consult `CHANGELOG.md` and release notes for subsequent changes.
