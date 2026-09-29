# Phase 26 — real KW905 header / live dashboard / payload UX fix

The first RP8 capture exposed an ELM327 v1.5 compatibility issue that the simulator did not model: `ATSH18DB33F1` and `ATSH18DBEFF1` returned `?`. Classic ELM327 29-bit CAN addressing splits the identifier into `ATCP18` plus the lower three header bytes (`ATSHDB33F1` / `ATSHDBEFF1`). Live polling and Vehicle Readiness now use that form, and the simulator intentionally rejects 8-digit `ATSH` so this regression is testable.

Payload Analysis also no longer fails silently when A/B ranges are absent. The tab shows the current selection, explicit **Set A** / **Set B** controls, and a clear message when either selected range has zero successful command samples.

The first real session after pressing Start Known Live Polling contains repeated header-setting failures, so that drive interval cannot be reconstructed into known-signal polling samples. The earlier readiness responses remain valid immutable evidence.

Live polling errors are now visible in the status/terminal and a header-selection failure stops polling immediately rather than sending the same rejected command repeatedly. Payload Analysis shows its source session and clears stale A/B ranges when an Offline Replay session is loaded.
