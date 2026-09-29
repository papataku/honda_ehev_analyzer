# Changelog

This changelog records release-level changes. Earlier detailed phase notes remain in `README.md` and `docs/`.

## 0.3.4 — Long DID Recovery
- Treat `62 DID ... BUFFER FULL` as a partial Positive instead of a missing DID or ordinary transport error.
- Preserve received prefixes and retry long responses in compact ELM output mode.
- Mark incomplete results as `positive_partial` and continue scanning instead of repeatedly blocking on the same DID.
- Distinguish complete vs partial responses in discovery and drive coverage.
- Added regressions based on Session 15 long-response behavior.

## 0.3.3 — Adaptive Fast DID Scan
- Adaptive discovery order: known 0x2000 band, coarse 16-sector sampling, 0x100-page sampling, immediate deep-scan of promising pages, then full remaining coverage.
- Retained eventual no-gap coverage despite priority ordering.
- Kept approximately 10 req/s target using ELM adaptive timing where sustainable.

## 0.3.2 — Faster DID Discovery
- Raised DID discovery target to approximately 10 requests/s when adapter timing permits.
- Prioritized the known 0x2000 region before generic full-range fill.

## 0.3.1 — DID Discovery and Drive Sweep
- Added stationary UDS 0x22 discovery across observed ECU responders.
- Persisted Positive DID inventory with resume support.
- Added drive-plan snapshot, round-robin sampling of discovered DIDs, coverage reporting, and candidate ranking against known vehicle signals.

## 0.3.0 — Session 13 regression
- Separated successful RAW reception from later decode/UI exceptions.
- Added DID 2012 Byte 5 SOC-mirror candidate evidence without promoting it to a verified Honda definition.

## 0.2.9 — Standard Hybrid/EV decoding
- Decoded standard PID 9A HV battery voltage/current and derived power.
- Promoted standard PID 5B to the known Hybrid/EV remaining-charge/SOC display path.

## 0.2.8 and earlier
See `README.md` and phase-specific documents in `docs/` for the detailed historical development record.
