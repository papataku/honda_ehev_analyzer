# Phase 17 — Live diagnostics and one-click test finalization

The Live Dashboard now refreshes a communication-quality snapshot every two seconds from the current session's persisted command/raw records. It shows grade, score, p95 latency, timeout rate and error rate. The computation is read-only and does not rewrite capture data.

`Save Test & Export Debug Bundle` closes the current session first, builds a single-session debug bundle, refreshes the Session Browser, and opens a fresh session so subsequent testing cannot accidentally append to the completed run.

RSSI remains `unavailable` unless the BLE backend supplies a trustworthy live RSSI value; the UI does not invent one.
