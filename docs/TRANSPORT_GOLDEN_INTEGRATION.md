# Phase 14 — Transport Golden Integration

This phase tests the same `ElmSession` parser path used by live operation while injecting transport-level failures before the first vehicle test.

Covered: extreme BLE-like fragmentation, merged notification payloads, duplicate fragments, command timeout, simulated disconnect/reconnect, and a deterministic JSON integration capture suitable for regression fixtures.

Synthetic captures are explicitly marked `synthetic: true`. They are transport/parser evidence only and MUST NOT be used as Honda RP8 signal evidence.

## Vehicle acceptance gate

Before DID discovery, capture the real KW905 sequence in `VEHICLE_READINESS.md`, retain raw BLE notifications and ELM responses, then promote a small anonymized capture into `tests/golden/`. A real capture replaces assumptions about GATT characteristics, ATH1 formatting, ISO-TP presentation, and response CAN IDs.
