# Phase 16 — Vehicle diagnostics and debug bundle

The analyzer now evaluates communication quality from observed data: p95 latency, timeout/error rate, and BLE RSSI when the platform exposes it. Thresholds are diagnostic guardrails, not Honda/KW905 specifications. The analyzer must continue to preserve the underlying measurements.

`create_session_debug_bundle()` exports exactly one selected session. It does not crawl the analyzer directory and therefore does not accidentally include unrelated sessions. The bundle contains a manifest, command history/raw responses, BLE device metadata, immutable raw BLE capture, event markers, optional application.log, and explicitly selected configuration files.

Before the first RP8 drive test, use Vehicle Readiness, inspect the communication-quality evidence, then export a debug bundle at the end of the test. Do not start a DID sweep while moving.
