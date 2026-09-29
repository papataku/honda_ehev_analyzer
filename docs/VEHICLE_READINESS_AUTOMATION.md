# Phase 15 — Vehicle Readiness Automation

The GUI now provides **Run Vehicle Readiness Test** after BLE device selection. It is deliberately an acceptance gate, not a scanner.

Sequence: transport/BLE connect → GATT capture (when exposed by the transport) → `ATI` → `ATDP` → `ATDPN` → `010C` → `010D` → `0105` → `019A` → `ATH1` → `222012` → response-header observation → disconnect/reconnect + `ATI` → captured ELM response byte-identity replay check.

Rules:
- No DID range scan is executed.
- `019A` and `2012` remain raw evidence; no RP8-specific offset semantics are inferred.
- Absence of a parsed response CAN ID is WARN, not invented data.
- Any command/transport failure makes the overall gate FAIL, while later checks continue where possible so one vehicle visit yields maximum diagnostics.
- Reports are written as JSON + HTML under `~/.honda-ehev-analyzer/readiness/`.
- When a Session is open, command results and BLE raw notifications continue to be persisted to SQLite.
- The replay check verifies exact captured ELM response bytes through the common ReplayTransport path. It does not claim to reproduce CAN traffic hidden by ELM327/KW905.

Before driving, obtain a PASS or retain the generated report/debug evidence and fix the failed layer on the Mac. Do not proceed to DID scanning from this readiness test.
