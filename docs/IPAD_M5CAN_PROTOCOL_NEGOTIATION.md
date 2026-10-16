# iPad M5CAN dedicated BLE capability negotiation (2026-10-10)

## Decision

**The name M5Dial or M5CAN in a BLE advertisement never authorizes proprietary vehicle commands.** Only a new, verified adapter handshake does.

Sequence:

1. iPad initializes the selected BLE adapter with ordinary ELM commands (ATZ, ATI, etc.).
2. If the *current* ATZ/ATI identifies M5CAN, iPad sends `ATM5CAP\r` once.
3. The current M5CAN v0.4 firmware responds: `M5CAN-CAPS PROTO=1.1 FW=0.4.1-phase3d-implicit BATCH=16 OPS=OBD01,UDS22 STREAM=0 LEASE=IMPLICIT`.
4. Parse every field. **Firmware version** identifies the build; **protocol major/minor** identifies how bytes/commands are interpreted. Minor versions can add capabilities; unknown operations are ignored. Unknown major versions, missing/malformed/unsupported capability replies or KW905 adapters remain in standard ELM327 mode.
5. For verified `OBD01` on protocol 1.x, iPad polls RPM, speed, coolant, SOC and HV electrical PID using one `ATM5B00:010C,010D,0105,015B,019A` command, receiving tagged subresponses and `M5DONE\r>`.
6. The firmware performs **five serial read-only vehicle CAN requests**, not five CAN requests in parallel. For UDS, the firmware V1 supports **up to 16 known ECU01 DIDs as a single BLE command**, `ATM5B01:2012,E480,...`. This is not the same as asking an ECU for 16 DIDs in one UDS 0x22 message. iPad V1 enables **the five Mode01 live requests** first; DID batch use awaits independent hardware acceptance.
7. Session reconnect, adapter change and capture reinitialization clear the negotiated protocol, pending ELM continuation and response fragments. The next session starts in ordinary ELM mode until the handshake succeeds again.

The Settings page shows the selected firmware and protocol label. SQLite receives a `M5CAN_PROTOCOL` event with negotiated version and features; the original tagged batch reply remains available as RAW and batch command. Synthesized per-PID rows preserve reference signals for offline correlation, with per-PID measured latency = 0 (unknown per item, not the overall batch RTT).

| Hardware version | Dedicated protocol | Default |
|---|---|---|
| KW905, any | Off | One request / one prompt |
| M5CAN old v0.3, no ATM5CAP | Off | One request / one prompt |
| M5CAN firmware 0.4.1 / PROTO 1.0, OBD01 | On for supported Mode01 PIDs | Five PIDs in one BLE command |
| Future M5CAN PROTO 1.1 + extra known/unknown optional features | Known supported features only | Ignore unknown operations |
| Future M5CAN PROTO 2.x | Off until iPad explicitly implements it | Fail closed to ELM compatibility |

## Developer/QA acceptance

- Protocol v1.0 and firmware version parsed independently.
- Missing/invalid capability and device identity cause deterministic ELM fallback.
- No proprietary commands are sent to KW905 or unverified current BLE peripherals.
- Tagged replies must preserve exact ordering and include M5DONE; untagged or reordered frames are rejected rather than silently assigned to the wrong PID.
- A single NO DATA does not discard other successfully decoded PID items.
- All CAN requests still pass existing read-only, TX lease, ISO-TP and per-ID pacing safety gates.
- No unknown DID enumeration while moving.
- Build/test PASS does **not** establish on-vehicle latency improvement or firmware compatibility; capture a new parked reference and compare effective req/s + missing data.


## Protocol 1.1: lease traffic removed

M5CAN v0.4.1 advertises `LEASE=IMPLICIT` on the capability response. Only after explicitly receiving and parsing this flag does iPad omit `ATM5TX1` for normal read-only ELM commands and dedicated batch reads. This saves an extra BLE request/response every ~2 seconds in the previous capture, and the redundant per-batch renewal. M5CAN generates bounded internal authorization per whitelisted diagnostic query, including each 1–16 subrequest; all CAN TX is serialized, fault-locked and revoked on disconnect.

Legacy protocol 1.0 without `LEASE` is interpreted as `LEASE=EXPLICIT` for backward compatibility; an older M5CAN v0.3 continues to use the existing host-side lease renewal if required. KW905 never receives M5CAN-only commands. Any unsupported/malformed LEASE field fails negotiation safely. Firmware version and protocol version remain separate.

Physical acceptance: verify that `ATM5TX1` count falls to **zero** for M5CAN protocol 1.1 (not for legacy devices), that RPM/speed/SOC/019A and known DID data remain correct, and that BLE disconnect prevents continued authorization. Do not treat build PASS as physical validation.
