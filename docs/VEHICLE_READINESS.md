# Vehicle Readiness Gate

Before DID discovery, capture one baseline session in this exact order: BLE scan/connect, GATT inventory, ATI, ATDP, ATDPN, 010C, 010D, 0105, 019A, ATH1, 222012, response header observation, disconnect/reconnect, replay.

## Acceptance gate
- Raw BLE notifications are persisted incrementally in SQLite.
- Every ELM command has raw response and latency.
- GATT service/characteristic metadata is stored with the session.
- Session contains git commit and tool version.
- A forced application stop leaves a recoverable session.
- Replay of the baseline capture is deterministic.
- No Honda-specific offset, ECU ID, or DID meaning is promoted from TODO/CANDIDATE without raw evidence.

Only after this gate passes should ECU discovery and read-only 0x22 DID scanning be used. Scanning remains a stationary-vehicle operation.
