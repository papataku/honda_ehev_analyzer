# M5CAN capability negotiation — fail-closed policy

Applies to Draft PR #20, stacked on #19. Date: 2026-10-18.

This is a **host policy**, not a proof that an ECU can safely be queried.
The M5CAN-Dial adapter is identified independently using ATZ/ATI. It then
answers an optional, versioned `ATM5CAP` query. An advertised ECU list is
**never** permission to transmit CAN.

| ATI/ATZ identity | ATM5CAP reply | Session vehicle reads | Rationale |
| --- | --- | --- | --- |
| ordinary ELM327 / KW905 | not sent | legacy read-only ELM behavior | M5CAN-only feature not engaged |
| M5CAN | recognized protocol 1.0/1.1 | legacy read-only mode; ECU01 physical policy | recognized capability |
| M5CAN | recognized 1.2 with `UDS_ECUS=...` and `TX=OFF` | **blocked** | passive routing experiment, no physical TX |
| M5CAN | exactly `?`, `ERROR`, or `NO DATA` | legacy read-only ELM fallback | explicitly unsupported command; compatibility |
| M5CAN | `M5CAN-CAPS` with bad fields / missing TX / future major | **blocked** | cannot infer permission from unknown protocol |
| M5CAN | `TX=ON` / `TX=READ_ONLY` | **blocked** | mode has not been safety-approved |
| M5CAN | unexpected successful `OK` or other text | **blocked** | not a recognized negotiation |
| M5CAN | no response / BLE timeout | **blocked** | no evidence of supported legacy/future mode |
| M5CAN identified by ATZ | ATI fails or replies as a generic ELM | **blocked unless valid CAPS later succeeds** | adapter identity may not be silently downgraded by a metadata response |

When blocked, single PID/DID commands, dedicated batch commands, experimental
ECU-targeted requests and lease commands are rejected **before transport.write**.
AT metadata commands remain readable for fault diagnosis. The UI must not report
ELM initialization complete or enable capture, and recording should include a
`M5CAN_PROTOCOL_REJECTED` or `M5CAN_PROTOCOL` event with TX state.

Reconnecting a device calls `resetProtocolNegotiation`, clearing both the
capability and the rejection state. The new BLE peer MUST identify and
negotiate again; a previous allowance or rejection must not be reused.

## Tests and release gates

- `M5CANPassiveHandshakeIntegrationTests`: fake BLE, malformed/future CAPS,
  timeout, explicit legacy rejection, zero diagnostic BLE writes, reconnection.
- Existing suite: KW905/legacy batch/framing and iPad capture behavior.
- GitHub Actions Swift tests and iPad simulator build must pass.
- No vehicle TX profile enabled, no real CAN simulator/vehicle or two-device
  hardware validation performed.
- A qualified independent CAN, vehicle safety, BLE/RTOS, iPad and QA review
  remains mandatory before opt-in physical multi-ECU transmission.
