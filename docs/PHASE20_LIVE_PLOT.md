# Phase 20 — Live Plot and marker synchronization

The Live Dashboard now has a pyqtgraph time-series view for decoded numeric known signals (RPM, vehicle speed, coolant). It uses bounded in-memory display buffers only; protocol RAW remains authoritative in SQLite.

Event markers are inserted on the same session-relative time axis, so STOP / EV / ENGINE ON / ACCEL / CRUISE / REGEN can be visually related to signal changes. A LinearRegionItem is provided for selecting a time interval for later differential/correlation workflows.

019A and DID 2012 remain RAW-only until vehicle evidence establishes field definitions. Hex payloads are deliberately not coerced into arbitrary numeric plots.
