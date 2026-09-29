# Phase 11 — Mac-only dry run before vehicle testing

Use `Elm327SimulatorTransport` to exercise the exact `ElmSession`/ELM prompt parser without a car or BLE adapter. It intentionally fragments responses so a BLE notification is never assumed to equal one ELM response.

Synthetic `019A` and `222012` payloads are test fixtures only. They do **not** define Honda RP8 offsets, scaling, ECU ownership, SOC, motor RPM, or any other vehicle semantics.

Recommended pre-vehicle gate:

1. Run the full pytest suite.
2. Run initialization against the simulator and verify all 13 initialization/metadata commands complete.
3. Exercise STOP (`speed=0`), EV (`rpm=0, speed>0`), and ENGINE (`rpm>0`) simulator states.
4. Verify `ATH1` + `222012` preserves the synthetic response CAN ID and complete raw payload.
5. Repeat with tiny fragment sizes `(1,2,3)` to stress prompt reconstruction.
6. Only after this passes, proceed to the real KW905 BLE/GATT readiness sequence in `VEHICLE_READINESS.md`.

The first real KW905 capture remains the authority for GATT characteristics, actual ELM formatting, response CAN IDs, ISO-TP presentation, and Honda-specific payload semantics.
