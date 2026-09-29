# Phase 23 — Field Correlation Workflow

Adds timestamp-aware correlation for a selected unknown payload interpretation against known signals. Candidate samples and known OBD samples are aligned by nearest timestamp; source timestamps are never rewritten. Pearson, Spearman, ±5 s lag search, scatter data, statistics, and the existing Drive Motor heuristic are available.

The Motor score is evidence only. It cannot set `VERIFIED`, and no Honda-specific offset/scale is inferred. Vehicle Speed / Engine RPM samples used by the GUI come from the live known-signal buffers; future persisted-signal reconstruction can use the same analysis API.
