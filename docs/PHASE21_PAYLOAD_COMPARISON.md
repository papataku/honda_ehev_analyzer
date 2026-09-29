# Phase 21 — Selected-range payload comparison foundation

Adds a raw-preserving analysis layer for comparing unknown ELM/UDS payloads across selected time ranges.

* Extracts byte tokens from stored ELM responses for visualization; stored raw bytes are never modified.
* Produces offset-by-offset A/B differences without assigning Honda-specific meaning.
* Computes per-byte activity ratios to rank changing offsets.
* Adds DB command-row retrieval so 019A and 222012 observations can be selected from a session.
* This is an analysis aid only. It never promotes a field to VERIFIED.

Next GUI step: bind two selected timeline ranges (A/B) to a differential hex table and byte-activity heatmap.
