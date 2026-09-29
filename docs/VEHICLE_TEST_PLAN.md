# First Vehicle Test Plan

Do not start a DID sweep. With MacBook Air + KW905 + STEP WGN RP8, execute in this order:

1. BLE connection and full GATT inventory.
2. ATI.
3. ATDP / ATDPN.
4. 010C.
5. 010D.
6. 0105.
7. 019A.
8. ATH1.
9. 222012.
10. Record response CAN ID(s).
11. Persist raw BLE/ELM/ISO-TP evidence.
12. Disconnect/reconnect.
13. Close session cleanly.
14. Replay the capture offline through the identical parser pipeline.

Only after deterministic replay succeeds: stationary ECU discovery -> physical addressing verification -> safe 0x22 DID scan -> positive DID set. During driving, poll only known signals plus selected positive DIDs.

Required driving markers: STOP, EV low/medium/high, ENGINE ON, ACCEL, CRUISE, REGEN. Motor-RPM analysis should emphasize Engine RPM ~= 0 while Vehicle Speed > 0.
