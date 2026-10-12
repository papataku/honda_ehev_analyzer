# Explicit debug BLE soak mode

Depends on PR8 (fix/ipad-capture-ble-idle-20261012). This is a diagnostic
experiment, not an automatic driving collector or DID scanner. Normal app
launch remains unchanged and Release builds exclude the UI/controller.

Back up the existing Documents folder with devicectl before install; never
uninstall/reset app data. Sign with the existing configured Team and bundle ID.
Do not print private identifiers in public reports. A locked device can install
but cannot launch; ask the operator to unlock after preparation is complete.

Mac launch: `xcrun devicectl device process launch --device DEVICE
--terminate-existing com.papataku.HondaAnalyzer --ble-soak
--soak-scenario batch --soak-seconds 1800 --soak-run-id UNIQUE_ID`.
The app scans for M5CAN-Dial, verifies GATT and capabilities, and requires
DEMO=1 MODE=DEMO before reading only010C/010D/0105/015B/019A.
Idle still performs configuration/meta identity/DEMO verification but no PID
reads. Single reads each PID serially; batch sends the versioned Mode01 list.
One command is in flight, each run is bounded to3600s, cancellation stops it.
Unknown DID discovery and reconnect/resume of driving collection are absent.

Documents/BLESoak contains a unique SQLite and JSONL per run. Raw BLE chunks,
completed commands, BLE_STATE/NSError reason, GATT UUID, scene phase, samples,
failures and end are preserved. Console output is not required. Retrieve with
devicectl device copy from after completion and check SQLite integrity. WAL/SHM
files must be copied together if SQLite is still open.

Keep-awake is scoped to the test and restores the prior idleTimer setting on
completion. Manual lock/background are separate tests; OS background continuity
is not guaranteed. The tested60s simultaneous smoke completed203 five-PID
batches and220/220 commands, integrity ok. Thirty-minute repetitions and full
load matching remain physical gates, not implied by Swift/simulator success.

The currently installed first trial reports286501f-diag-dirty: raw bin/source
artifacts are saved locally. The additional admission-policy unit tests in this
branch came after that first build. Do not label the installed dirty test as an
exact clean committed head. Publish clean builds/CI for reproduction separately.
