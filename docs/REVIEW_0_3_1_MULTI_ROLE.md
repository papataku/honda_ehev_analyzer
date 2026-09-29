# 0.3.1 Multi-role review record

The implementation was reviewed in separate passes using different operator/engineering perspectives. These are independent review roles, not claims of multiple human reviewers.

## 1. Beginner operator review

Questions asked:

- What is a DID?
- Does pressing Start change anything in the car?
- Why can a full scan take many hours?
- Can I stop today and continue another day?
- Why is a DID missing even after scanning 0000–FFFF?
- What should I do during driving?

Changes made:

- Added purpose/result/prerequisite text directly in the ECU page.
- Added scan range, rate, time estimate, progress, Positive count, stop/resume status.
- Large scans require an explicit long-duration acknowledgement.
- Clarified that only current-session read-only UDS 0x22 is scanned; 0x10/0x27/write services are not used.
- Clarified that driving uses already-discovered Positive DIDs and does not brute-force unknown DIDs.

## 2. Vehicle/UDS safety review

Questions asked:

- Can the scan start while moving?
- What happens if the car starts moving during a scan?
- What happens if speed cannot be read?
- Can a bad header/transport state cause thousands of repeated commands?
- Are session/security/write services used?

Changes made:

- Stationary/P-range acknowledgement remains mandatory.
- Actual OBD vehicle speed is re-read approximately every 2 seconds during discovery.
- Non-zero or unavailable speed stops discovery fail-safe.
- Five consecutive infrastructure errors stop discovery.
- Discovery service is fixed to 0x22 only.
- No 0x10, 0x27, write/routine-control path was added.

## 3. Embedded/transport engineering review

Questions asked:

- Does a 5-ECU full scan unfairly spend hours on ECU 01 first?
- Can a huge Positive DID plan delay time-critical RAW database writes?
- Does the driving scheduler starve known signals?
- Are duplicate DIDs sampled fairly?

Changes made:

- Multi-ECU discovery rotates by 256-DID chunks.
- Driving plan is persisted atomically before capture rather than queueing thousands of individual plan writes.
- Known/high-priority polling remains ahead of low-rate sweeps.
- Positive DIDs use a deterministic, de-duplicated round-robin iterator.
- DID 2012 is not double-requested because it is already a core poll.

## 4. Data-analysis review

Questions asked:

- Will hundreds of DIDs freeze the UI?
- Does the analyzer expand huge numbers of fields that never change?
- Can SOC drift be mistaken for motor RPM because both correlate with route/time?
- Is HV current used as a reference for current/torque candidates?

Changes made:

- Only fields overlapping changed bytes are expanded.
- Reference timestamp arrays are prebuilt and aligned by binary search.
- Equivalent field value series are de-duplicated.
- Strong SOC correlation is penalized in motor-RPM prioritization.
- Both HV power and HV current are reference signals.
- Analysis runs via `asyncio.to_thread` to reduce GUI blocking.

## 5. Forensics/reproducibility review

Questions asked:

- After receiving only a debug ZIP, can we know which DIDs were intended to be sampled?
- Can we distinguish “not planned” from “planned but not reached during the drive”?
- Can stationary discovery evidence be retained?

Changes made:

- Added immutable session-specific `did_drive_plan` snapshot.
- Added `did_drive_samples` table and coverage report.
- Added scan/plan/sample files to Debug Bundle.
- Existing Build ID / source hash remain in the manifest.

## 6. Regression/QA review

Added tests cover:

- positive/NRC/NO DATA classification
- speed fail-safe
- cross-session resume rules
- full-range time estimate
- multi-ECU chunk order
- positive inventory
- plan and coverage persistence
- debug bundle content
- fair Positive DID round-robin
- synthetic motor-like EV-speed correlation vs SOC mirror
- complete legacy regression suite

Session 13 was also reprocessed through the new field-ranker. Its 1,002 DID 2012 samples produced no strong motor-RPM candidate (maximum priority remained low), consistent with the previous evidence that DID 2012 is predominantly battery-state related.
