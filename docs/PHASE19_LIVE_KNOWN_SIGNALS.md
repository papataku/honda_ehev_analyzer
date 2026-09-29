# Phase 19 — Live Known-Signal Polling

Adds a conservative live polling loop for only the already-known requests: `010C`, `010D`, `0105`, `019A`, and `222012`.

* Polling is serialized through the existing `ElmSession` lock; no command burst is generated when the adapter is slow.
* RPM, speed, and coolant are decoded only from standard OBD responses.
* `019A` and `222012` remain RAW. No RP8-specific offset or meaning is inferred.
* `NO DATA`, malformed responses, and negative responses never fabricate a value.
* This is **not** DID scanning and cannot enumerate a DID range.
* Default intervals are deliberately modest and are configuration candidates until KW905 vehicle measurements exist.

Use the GUI `Start Known Live Polling` / `Stop Live Polling` controls only after the Vehicle Readiness gate succeeds. Raw BLE and ELM command/response evidence continues to be persisted in the active session.
