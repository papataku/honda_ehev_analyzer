import SwiftUI
import Combine
import HondaAnalyzerCore

@MainActor
final class AnalyzerViewModel: ObservableObject {
    let ble: KW905BLETransport
    private let session: ElmCommandSession
    private var captureStore: CaptureStore?
    private var captureSessionID: Int64?
    private var liveTask: Task<Void, Never>?
    private var didScanTask: Task<Void, Never>?
    private var driveCaptureTask: Task<Void, Never>?
    private var driveScheduler: AdaptiveDriveDIDScheduler?
    private var didScanStopRequested = false
    private var activeHeaderCommand: String?
    private var priority18Configured = false
    private var bleObservation: AnyCancellable?
    private var bleStateObservation: AnyCancellable?

    @Published var isBusy = false
    @Published var standardPIDInventory = StandardPIDInventory()
    @Published var isStandardPIDSurveying = false
    @Published var standardPIDProgress = "未調査"
    @Published var selectedExtraPIDs: Set<UInt8> = []
    @Published var latestPIDCSVURL: URL?
    @Published var latestPIDJSONURL: URL?
    private var standardPIDTask: Task<Void, Never>?
    private var unifiedTask: Task<Void, Never>?
    private var signalChangeTracker = SignalChangeTracker()
    @Published var changingSignals: [ObservedSignalTrend] = []
    @Published var isUnifiedCollecting = false
    @Published var unifiedStage = "未開始"
    @Published var unifiedUnknownProbes = 0
    @Published var unifiedStandardProbes = 0
    @Published var unifiedZeroSeconds = 0.0

    @Published var vehicleProtocolLabel = "未確認（ELM327互換）"
    @Published var elmInitialized = false
    @Published var knownSignalsValidated = false
    @Published var isLivePolling = false
    @Published var isDidScanning = false
    @Published var isDriveCollecting = false
    @Published var driveCollectedCount = 0
    @Published var driveCurrent = "未開始"
    @Published var driveCandidates: [DriveDID] = []
    @Published var driveSamplingSummary = AdaptiveDriveDIDScheduler(candidates: []).summary
    @Published var driveFieldCandidates: [DriveFieldCandidate] = []
    @Published var analyzedRecordingName = ""
    @Published var isDriveAnalyzing = false
    @Published var isDidScanPausedForSpeed = false
    @Published var autoResumeDidScanAfterStop = true
    @Published var isRecording = false
    @Published var stationaryConfirmed = false
    @Published var longDidScanAcknowledged = false
    @Published var didScanEcu = "01"
    @Published var didScanRateHz = 5.0
    @Published var didScanUnthrottled = false
    @Published var aggressiveElmTimingEnabled = false
    @Published var didScanEffectiveRateHz = 0.0
    @Published var livePollingRequestRateHz = 5.0
    @Published var livePollingUnthrottled = false
    @Published var liveEffectiveRequestRateHz = 0.0 // actual ELM commands per second
    @Published var liveEffectivePIDRateHz = 0.0 // logical Mode01 PID requests per second
    @Published var liveLastBatchSize = 1
    @Published var didScanProgress = 0.0
    @Published var didScanCurrent = "未開始"
    @Published var didPositiveCount = 0
    @Published var didPartialCount = 0
    @Published var positiveDids: [DidProbeOutcome] = []
    @Published var observedEcus: [EcuResponder] = []
    @Published var recordingFile = ""
    @Published var recordingURL: URL?
    @Published var statusMessage = "KW905またはM5CAN-Dialへ接続してください"
    @Published var rpm: Double?
    @Published var speedKmh: Int?
    @Published var coolantC: Int?
    @Published var socPercent: Double?
    @Published var hvVoltage: Double?
    @Published var hvCurrent: Double?
    @Published var hvPowerKW: Double?
    @Published var transcript: [String] = []
    @Published var liveSamples: [LiveSignalSample] = []

    init() {
        let transport = KW905BLETransport()
        self.ble = transport
        self.session = ElmCommandSession(transport: transport)
        session.onRawReceive = { [weak self] data in self?.recordRaw(data) }
        session.onResult = { [weak self] result in self?.recordCommand(result) }
        bleObservation = transport.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        bleStateObservation = transport.$state.sink { [weak self] state in
            guard let self else { return }
            if self.isUnifiedCollecting &&
               (state == "disconnected" || state == "connect-failed" ||
                state == "gatt-error" || state == "bluetooth-unavailable") {
                self.unifiedTask?.cancel()
                self.unifiedStage = "BLE中断：統合収集を停止しました"
                self.recordLifecycleEvent(kind: "UNIFIED_LINK_LOST", note: "state=\(state)")
            }
            if state == "connecting" || state == "disconnected" ||
                state == "connect-failed" || state == "gatt-error" ||
                state == "bluetooth-unavailable" {
                self.session.resetProtocolNegotiation()
                self.elmInitialized = false
                self.knownSignalsValidated = false
                self.vehicleProtocolLabel = "未確認（ELM327互換）"
                self.stationaryConfirmed = false
                self.observedEcus = []
                self.activeHeaderCommand = nil
                self.priority18Configured = false
            }
        }
    }

    func startRecording() {
        guard captureStore == nil, !isDidScanning, !isLivePolling, !isDriveCollecting,
              !isUnifiedCollecting, !isBusy else { return }
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let folder = documents.appendingPathComponent("HondaAnalyzerSessions", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = folder.appendingPathComponent("session-\(stamp).sqlite3")
            let store = try CaptureStore(url: url)
            store.onError = { [weak self] error in
                self?.statusMessage = "記録エラー: \(error.localizedDescription)"
            }
            let sid = try store.createSession(toolVersion: "ipad-native")
            captureStore = store
            captureSessionID = sid
            saveBleSnapshot(store: store, sessionID: sid)
            recordingURL = url
            recordingFile = url.lastPathComponent
            isRecording = true

            // Evidence-first workflow: communication readiness must be proven
            // again inside every new capture session so initialization and
            // known-signal evidence are present in that SQLite file.
            session.resetProtocolNegotiation()
            vehicleProtocolLabel = "未確認（ELM327互換）"
            elmInitialized = false
            knownSignalsValidated = false
            stationaryConfirmed = false
            observedEcus = []
            liveSamples.removeAll()
            signalChangeTracker = SignalChangeTracker()
            changingSignals = []
            unifiedStage = "未開始"
            unifiedUnknownProbes = 0
            unifiedStandardProbes = 0
            standardPIDInventory = StandardPIDInventory()
            latestPIDCSVURL = nil
            latestPIDJSONURL = nil
            standardPIDProgress = "未調査"
            statusMessage = "記録開始。次に車両通信を初期化してください"
            refreshPositiveDids()
            refreshDriveCandidates()
            driveCollectedCount = 0
            driveScheduler = nil
            driveSamplingSummary = AdaptiveDriveDIDScheduler(candidates: []).summary
            driveFieldCandidates = []
        } catch {
            statusMessage = "記録開始失敗: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard !isDidScanning, !isLivePolling, !isDriveCollecting,
              !isUnifiedCollecting, !isBusy, let store = captureStore, let sid = captureSessionID else { return }
        do {
            try store.closeSession(sid)
            store.flush()
            statusMessage = "記録保存完了: \(recordingFile)"
        } catch {
            statusMessage = "記録終了失敗: \(error.localizedDescription)"
        }
        captureStore = nil
        captureSessionID = nil
        isRecording = false
        // Finalized sidecars are derived from the same in-memory survey rows and
        // raw commands already flushed to the matching session SQLite.
        try? writeStandardPIDExports()
    }

    /// Low-volume forensic markers for screen-lock state, app lifecycle and BLE changes.
    func recordLifecycleEvent(kind: String, note: String) {
        guard let store = captureStore, let sid = captureSessionID else { return }
        store.addEvent(sessionID: sid, at: Date(), kind: kind, note: note)
    }

    func toggleExtraPID(_ pid: UInt8) {
        guard !isLivePolling, !isBusy, !isStandardPIDSurveying else { return }
        if selectedExtraPIDs.contains(pid) {
            selectedExtraPIDs.remove(pid)
        } else if selectedExtraPIDs.count < 4, !isStandardBitmapPID(pid),
                  ![0x0C, 0x0D, 0x05, 0x5B, 0x9A].contains(pid) {
            selectedExtraPIDs.insert(pid)
        }
    }

    /// Read-only Mode 01 survey. This is mutually exclusive with live/drive/DID jobs.
    /// Raw notifications and commands remain in SQLite; per-responder results are also
    /// written as structured evidence events for offline reconstruction.
    func startStandardPIDSurvey() {
        guard isRecording, ble.state == "ready", elmInitialized, knownSignalsValidated,
              !isBusy, !isLivePolling, !isDidScanning, !isDriveCollecting,
              !isUnifiedCollecting else {
            statusMessage = "標準PID調査にはBLE接続・記録・初期化・既知信号確認が必要です"
            return
        }
        isBusy = true
        isStandardPIDSurveying = true
        standardPIDProgress = "対応PIDビットマップを確認中"
        statusMessage = "標準PID調査中（安全な読取専用Mode 01）"

        standardPIDTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await prepareMode01()
                var inventory = StandardPIDInventory()
                var nextBases: [UInt8] = [0x00]
                var visited: Set<UInt8> = []
                var allPIDs: Set<UInt8> = []
                while !nextBases.isEmpty {
                    try Task.checkCancellation()
                    let base = nextBases.removeFirst()
                    guard visited.insert(base).inserted else { continue }
                    let cmd = String(format: "01%02X", base)
                    var bitmaps: [StandardPIDBitmap] = []
                    for attempt in 0..<3 {
                        try Task.checkCancellation()
                        do {
                            let reply = try await session.command(cmd, timeout: 4)
                            append(reply)
                            bitmaps = parseStandardPIDBitmaps(reply.text, base: base)
                        } catch {
                            recordLifecycleEvent(kind: "PID_BITMAP_RETRY",
                                                 note: "pid=\(cmd) attempt=\(attempt+1) error=\(error)")
                        }
                        if !bitmaps.isEmpty { break }
                        if attempt < 2 { try await Task.sleep(nanoseconds: 250_000_000) }
                    }
                    for bitmap in bitmaps {
                        inventory.addBitmap(bitmap)
                        allPIDs.formUnion(bitmap.supported.filter { !isStandardBitmapPID($0) })
                        recordLifecycleEvent(
                            kind: "PID_BITMAP",
                            note: String(format: "base=%02X can=%@ mask=%08X",
                                         base, bitmap.canID ?? "unknown", bitmap.mask)
                        )
                        if Int(base) < 0xE0 && bitmap.supported.contains(base &+ 0x20) {
                            nextBases.append(base &+ 0x20)
                        }
                    }
                    standardPIDInventory = inventory
                    standardPIDProgress = "対応範囲 \(visited.count)件 / 候補 \(allPIDs.count)件"
                }
                let orderedPIDs = allPIDs.sorted()
                recordLifecycleEvent(kind: "PID_SURVEY_PLAN",
                                     note: "mode=01 read_only pids=\(orderedPIDs.map { String(format:"%02X",$0) }.joined(separator:","))")
                for (index, pid) in orderedPIDs.enumerated() {
                    try Task.checkCancellation()
                    let cmd = String(format: "01%02X", pid)
                    var readings: [StandardPIDReading] = []
                    for attempt in 0..<2 {
                        try Task.checkCancellation()
                        var failureStatus: StandardPIDSampleStatus = .noData
                        do {
                            let response = try await session.command(cmd, timeout: 4)
                            append(response)
                            readings = readStandardPID(pid, from: response.text, at: Date(),
                                                       latencyMs: response.latencyMs)
                        } catch {
                            failureStatus = .timeout
                            recordLifecycleEvent(kind: "PID_RETRY",
                                                 note: "pid=\(cmd) attempt=\(attempt+1) error=\(error)")
                        }
                        if !readings.isEmpty { break }
                        inventory.addFailure(pid: pid, status: failureStatus)
                        recordLifecycleEvent(kind: "PID_ATTEMPT_FAILURE",
                                             note: "pid=\(cmd) status=\(failureStatus.rawValue) attempt=\(attempt+1)")
                        if attempt == 0 { try await Task.sleep(nanoseconds: 300_000_000) }
                    }
                    for reading in readings {
                        inventory.addReading(reading)
                        saveStandardPIDReading(reading)
                    }
                    if readings.isEmpty {
                        recordLifecycleEvent(kind: "PID_NO_RESPONSE", note: "pid=\(cmd) retryable=true")
                    }
                    standardPIDInventory = inventory
                    standardPIDProgress = "実応答 \(index+1)/\(orderedPIDs.count) PID"
                    if (index+1) % 8 == 0 {
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                try writeStandardPIDExports()
                standardPIDProgress = "調査完了：\(inventory.sortedRows.count)件（ECU別）"
                statusMessage = "標準PID調査完了。候補を確認しCSV/JSONを共有できます"
            } catch is CancellationError {
                standardPIDProgress = "中断（再調査可能）"
                statusMessage = "標準PID調査を中断しました"
            } catch {
                standardPIDProgress = "調査失敗：\(error.localizedDescription)"
                statusMessage = standardPIDProgress
            }
            isStandardPIDSurveying = false
            isBusy = false
            standardPIDTask = nil
        }
    }

    func stopStandardPIDSurvey() { standardPIDTask?.cancel() }

    private func saveStandardPIDReading(_ reading: StandardPIDReading) {
        recordLifecycleEvent(kind: "PID_SAMPLE",
             note: "id=\(reading.identifier) status=\(reading.status.rawValue) payload=\(reading.payloadHex) " +
                   "value=\(reading.value.map { String($0) } ?? "null") " +
                   "latency_ms=\(reading.latencyMs.map { String($0) } ?? "unknown")")
    }

    private func writeStandardPIDExports() throws {
        guard let sessionURL = recordingURL else { return }
        let stem = sessionURL.deletingPathExtension().lastPathComponent
        let directory = sessionURL.deletingLastPathComponent()
        let csvURL = directory.appendingPathComponent(stem + "-pid-candidates.csv")
        let jsonURL = directory.appendingPathComponent(stem + "-pid-candidates.json")
        try standardPIDCSV(standardPIDInventory.sortedRows).write(to: csvURL, atomically: true, encoding: .utf8)
        try standardPIDJSON(standardPIDInventory.sortedRows).write(to: jsonURL, options: .atomic)
        latestPIDCSVURL = csvURL
        latestPIDJSONURL = jsonURL
    }

    func addMarker(_ kind: String) {
        guard let store = captureStore, let sid = captureSessionID else {
            statusMessage = "マーカーを記録するには記録を開始してください"
            return
        }
        store.addEvent(sessionID: sid, at: Date(), kind: kind)
        transcript.append("MARK  \(kind)")
    }

    func initializeELM() {
        guard !isBusy, !isLivePolling, !isDidScanning, !isDriveCollecting else { return }
        isBusy = true
        statusMessage = "ELM初期化中"
        Task {
            let results = await session.initialize()
            activeHeaderCommand = nil
            priority18Configured = false
            for result in results { append(result) }
            let failed = results.filter { !$0.success }
            if let caps = session.negotiatedM5CAN {
                vehicleProtocolLabel = caps.description
                if let store = captureStore, let sid = captureSessionID {
                    store.addEvent(
                        sessionID: sid, at: Date(), kind: "M5CAN_PROTOCOL",
                        note: "proto=\(caps.major).\(caps.minor) firmware=\(caps.firmwareVersion) batch=\(caps.maxBatchIDs) obd01=\(caps.supportsOBD01) uds22=\(caps.supportsUDS22) stream=\(caps.supportsStreaming)"
                    )
                }
            } else {
                vehicleProtocolLabel = "標準ELM327通信（専用プロトコル未確認・無効）"
            }
            elmInitialized = failed.isEmpty
            if !elmInitialized { knownSignalsValidated = false }
            statusMessage = failed.isEmpty ? "ELM初期化完了" : "ELM初期化完了（失敗 \(failed.count)件）"
            isBusy = false
        }
    }

    func readKnownSignals() {
        guard !isBusy, !isLivePolling, !isDidScanning, !isDriveCollecting else { return }
        isBusy = true
        statusMessage = "既知信号を取得中"
        Task {
            do {
                try await prepareMode01()
                try await pollKnownCycle(requireComplete: true)
                knownSignalsValidated = true
                statusMessage = "既知信号取得完了"
            } catch {
                statusMessage = "取得失敗: \(error.localizedDescription)"
                transcript.append("ERROR  \(error)")
            }
            isBusy = false
        }
    }

    private func trackStandardReading(_ reading: StandardPIDReading) {
        guard reading.status == .decoded || reading.status == .uninterpreted else { return }
        let ascii = Array(reading.payloadHex.utf8)
        let data = Data((0..<(ascii.count / 2)).compactMap { pair -> UInt8? in
            UInt8(String(decoding: ascii[(pair * 2)..<(pair * 2 + 2)], as: UTF8.self), radix: 16)
        })
        signalChangeTracker.observePID(
            pid: reading.pid, canID: reading.responseCANID,
            value: reading.value, payload: data,
            unit: reading.unit ?? "",
            name: standardPIDCatalog[reading.pid]?.name ?? String(format: "PID %02X", reading.pid),
            at: reading.timestamp
        )
    }


    /// One operator action starts all read-only data collection on one
    /// serialized ELM lane. The fixed baseline always has first priority.
    /// Zero speed means "stationary by speed", never a verified P gear.
    func startUnifiedCollection() {
        guard isRecording, elmInitialized, knownSignalsValidated,
              ble.state == "ready", !isBusy, !isUnifiedCollecting,
              !isLivePolling, !isDriveCollecting, !isDidScanning,
              !isStandardPIDSurveying,
              let store = captureStore, let sid = captureSessionID else {
            statusMessage = "接続・記録・通信初期化・既知信号確認を完了してください"
            return
        }
        isUnifiedCollecting = true
        unifiedUnknownProbes = 0
        unifiedStandardProbes = 0
        unifiedStage = "ライブ監視を開始しました"
        store.addEvent(sessionID: sid, at: Date(), kind: "UNIFIED_START",
                       note: "Mode01 and verified-DID while driving; unknown-22 only stable-zero >=5s")
        refreshDriveCandidates()
        unifiedTask = Task { [weak self] in
            guard let self else { return }
            var gate = AutomaticZeroSpeedGate()
            var planner = UnifiedAcquisitionPlanner()
            var bitmapQueue: [UInt8] = [0]
            var seenBitmaps: Set<UInt8> = []
            var pidQueue: [UInt8] = []
            var seenPIDs: Set<UInt8> = []
            var didQueue: [String: [UInt16]] = [:]
            var turn = 0
            var nextResponder = 0
            var consecutiveBaselineErrors = 0
            var lastCensusAt: Date = .distantPast
            do {
                while !Task.isCancelled {
                    try Task.checkCancellation()
                    guard ble.state == "ready", elmInitialized,
                          isRecording else { break }
                    let started = Date()
                    // One active command at a time, never competing Tasks.
                    do {
                        try await prepareMode01()
                        try await pollKnownCycle()
                        consecutiveBaselineErrors = 0
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        gate.reset(reason: "基本信号の取得エラー")
                        consecutiveBaselineErrors += 1
                        store.addEvent(sessionID: sid, at: Date(),
                                       kind: "UNIFIED_LIVE_ERROR",
                                       note: error.localizedDescription)
                        if consecutiveBaselineErrors >= 3 { throw error }
                        continue
                    }
                    gate.observe(speedKmh: speedKmh.map(Double.init), at: Date())
                    unifiedZeroSeconds = gate.firstZeroAt.map {
                        Date().timeIntervalSince($0)
                    } ?? 0
                    let moving = (speedKmh ?? 0) > 0
                    let stableZero = gate.canProbe(at: Date())
                    unifiedStage = moving
                        ? "走行中：ライブ・既知DID・標準PID取得"
                        : stableZero
                            ? "車速0を5秒以上確認：停止時の未知DID探索"
                            : "ライブ取得中：車速0の安定を確認中"
                    turn += 1

                    // ECU discovery only uses previously validated read-only
                    // requests. Each read is guarded by a new speed sample.
                    if stableZero && observedEcus.isEmpty &&
                        Date().timeIntervalSince(lastCensusAt) >= 30 {
                        lastCensusAt = Date()
                        do {
                        var found: [String: EcuResponder] = [:]
                        for req in safeEcuCensusRequests {
                            try Task.checkCancellation()
                            guard let speed = try? await readScanSpeed(),
                                  speed <= 0.1 else {
                                gate.reset(reason: "ECU確認時の車速不明")
                                break
                            }
                            gate.observe(speedKmh: speed, at: Date())
                            guard gate.canProbe(at: Date()) else { break }
                            try await selectHeader(req.headerCommand)
                            let result = try await session.command(req.command, timeout: 3.0)
                            append(result)
                            for ecu in ecuResponders(in: result.text) {
                                found[ecu.responseCanID] = ecu
                            }
                        }
                        if !found.isEmpty {
                            observedEcus = found.values.sorted { $0.source < $1.source }
                            didScanEcu = observedEcus[0].source
                            store.addEvent(sessionID: sid, at: Date(),
                                           kind: "UNIFIED_ECU_FOUND",
                                           note: observedEcus.map(\.source).joined(separator: ","))
                        }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            gate.reset(reason: "ECU確認エラー")
                            store.addEvent(sessionID: sid, at: Date(),
                                           kind: "UNIFIED_ECU_ERROR",
                                           note: error.localizedDescription)
                        }
                    }
                    if didQueue.isEmpty && !observedEcus.isEmpty {
                        let priority = Array(UInt16(0x2000)...UInt16(0x20FF)) +
                                       Array(UInt16(0x2200)...UInt16(0x22FF)) +
                                       Array(UInt16(0x2600)...UInt16(0x26FF))
                        for ecu in observedEcus {
                            let old = loadDidScanHistory(
                                from: captureDatabaseURLs(), ecu: ecu.source,
                                start: 0x2000, end: 0x26FF
                            ).completed
                            didQueue[ecu.source] = priority.filter { !old.contains($0) }
                        }
                    }
                    // Continue low-rate sampling after the first survey so
                    // changing supported PIDs are actually discovered over time.
                    if pidQueue.isEmpty && !seenPIDs.isEmpty {
                        pidQueue = seenPIDs.sorted()
                    }
                    let unknownAvailable = didQueue.values.contains { !$0.isEmpty }
                    let action = planner.next(
                        isMoving: moving, zeroSpeedAuthorized: stableZero,
                        hasBitmap: !bitmapQueue.isEmpty,
                        hasStandardPID: !pidQueue.isEmpty,
                        hasKnownDID: !driveCandidates.isEmpty,
                        hasUnknownDID: unknownAvailable
                    )

                    // Background errors must never silence the baseline.
                    do {
                        switch action {
                        case .supportedPIDBitmap:
                            let base = bitmapQueue.removeFirst()
                            if seenBitmaps.insert(base).inserted {
                                try await prepareMode01()
                                let result = try await session.command(
                                    String(format: "01%02X", base), timeout: 3)
                                append(result)
                                for bitmap in parseStandardPIDBitmaps(result.text, base: base) {
                                    standardPIDInventory.addBitmap(bitmap)
                                    for pid in bitmap.supported
                                        where !isStandardBitmapPID(pid) &&
                                              ![0x05, 0x0C, 0x0D, 0x5B, 0x9A].contains(pid) {
                                        if seenPIDs.insert(pid).inserted {
                                            pidQueue.append(pid)
                                        }
                                    }
                                    if base < 0xE0,
                                       bitmap.supported.contains(base &+ 0x20),
                                       !seenBitmaps.contains(base &+ 0x20),
                                       !bitmapQueue.contains(base &+ 0x20) {
                                        bitmapQueue.append(base &+ 0x20)
                                    }
                                }
                                pidQueue.sort()
                                standardPIDProgress = "bitmap: \(seenBitmaps.count)ページ / 候補 \(pidQueue.count)件"
                            }
                        case .standardPID:
                            let pid = pidQueue.removeFirst()
                            try await prepareMode01()
                            let result = try await session.command(
                                String(format: "01%02X", pid), timeout: 3)
                            append(result)
                            let readings = readStandardPID(
                                pid, from: result.text, at: Date(),
                                latencyMs: result.latencyMs
                            )
                            if readings.isEmpty {
                                standardPIDInventory.addFailure(pid: pid, status: .noData)
                            }
                            for reading in readings {
                                standardPIDInventory.addReading(reading)
                                saveStandardPIDReading(reading)
                                trackStandardReading(reading)
                            }
                            unifiedStandardProbes += 1
                        case .knownDrivingDID:
                            if let candidate = schedulerFor(driveCandidates).next(
                                now: Date(), context: drivingContext
                            ) {
                                let outcome = await sampleKnownDrivingDID(candidate)
                                _ = recordAdaptiveDriveSample(
                                    candidate, outcome: outcome,
                                    scheduler: schedulerFor(driveCandidates),
                                    store: store, sessionID: sid
                                )
                                if outcome.status == .positive {
                                    signalChangeTracker.observeDID(
                                        ecu: candidate.ecu, did: candidate.did,
                                        payload: outcome.payload, at: Date()
                                    )
                                }
                            }
                        case .stationaryUnknownDID:
                            let sources = observedEcus.map(\.source)
                            if !sources.isEmpty {
                                nextResponder %= sources.count
                                var selection: (source: String, did: UInt16)?
                                for offset in 0..<sources.count {
                                    let name = sources[(nextResponder + offset) % sources.count]
                                    if var remaining = didQueue[name], !remaining.isEmpty {
                                        selection = (name, remaining.removeFirst())
                                        didQueue[name] = remaining
                                        nextResponder = (nextResponder + offset + 1) % sources.count
                                        break
                                    }
                                }
                                if let item = selection {
                                    let checkedSpeed = try? await readScanSpeed()
                                    if let checkedSpeed, checkedSpeed <= 0.1 {
                                        gate.observe(speedKmh: checkedSpeed, at: Date())
                                    } else {
                                        gate.reset(reason: "未知DID直前の車速不明・走行検出")
                                    }
                                    if gate.canProbe(at: Date()), !Task.isCancelled,
                                       let header = physicalRequestHeaderCommand(for: item.source) {
                                        try await selectHeader(header)
                                        let cmd = String(format: "22%04X", item.did)
                                        let result = try await session.command(cmd, timeout: 2.5)
                                        append(result)
                                        let outcome = classifyUDS22Text(
                                            result.text, ecu: item.source, did: item.did,
                                            latencyMs: result.latencyMs
                                        )
                                        store.saveDidScan(sessionID: sid, at: Date(), outcome: outcome)
                                        didScanCurrent = "ECU \(item.source) / \(cmd) / \(outcome.status.rawValue)"
                                        unifiedUnknownProbes += 1
                                        if outcome.status == .positive ||
                                            outcome.status == .positivePartial {
                                            refreshPositiveDids(flush: true)
                                            refreshDriveCandidates()
                                        }
                                    } else {
                                        didQueue[item.source, default: []].insert(item.did, at: 0)
                                    }
                                }
                            }
                        case .baseline, .idle:
                            break
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        store.addEvent(sessionID: sid, at: Date(),
                                       kind: "UNIFIED_BACKGROUND_ERROR",
                                       note: "action=\(action.rawValue) \(error.localizedDescription)")
                        // Fail closed for unknown DID. Do not retry the same
                        // unknown request without another stable-zero check.
                    }

                    changingSignals = signalChangeTracker.changingSignals()
                    if turn.isMultiple(of: 10) {
                        store.addEvent(sessionID: sid, at: Date(),
                                       kind: "UNIFIED_HEARTBEAT",
                                       note: "cycle=\(turn) pid=\(unifiedStandardProbes) did=\(unifiedUnknownProbes)")
                    }
                    let delay = pollingDelaySeconds(
                        requestCount: 5,
                        targetRequestRateHz: max(1, livePollingRequestRateHz),
                        elapsedSeconds: Date().timeIntervalSince(started),
                        unthrottled: false
                    )
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
            } catch is CancellationError {
            } catch {
                unifiedStage = "通信エラー：統合収集を停止"
                statusMessage = "統合収集を停止：\(error.localizedDescription)"
                store.addEvent(sessionID: sid, at: Date(), kind: "UNIFIED_FATAL_ERROR",
                               note: error.localizedDescription)
            }
            store.addEvent(sessionID: sid, at: Date(), kind: "UNIFIED_STOP",
                           note: "standard=\(unifiedStandardProbes) unknown=\(unifiedUnknownProbes)")
            store.saveDriveSamplingState(
                sessionID: sid, at: Date(),
                seeds: driveScheduler?.snapshots() ?? []
            )
            store.flush()
            try? writeStandardPIDExports()
            isUnifiedCollecting = false
            unifiedTask = nil
            if !unifiedStage.contains("エラー") && !unifiedStage.contains("BLE中断") {
                unifiedStage = "統合収集を停止しました。SQLite記録を終了して共有できます"
            }
        }
    }

    func stopUnifiedCollection() {
        unifiedTask?.cancel()
        unifiedStage = "停止処理中：通信の応答後に保存します"
    }

    func startLivePolling() {
        guard ble.state == "ready", elmInitialized, knownSignalsValidated,
              !isBusy, !isLivePolling, !isDidScanning, !isDriveCollecting,
              !isUnifiedCollecting else {
            statusMessage = "BLE接続・ELM初期化・既知信号確認を完了してください"
            return
        }
        isLivePolling = true
        liveEffectiveRequestRateHz = 0
        liveEffectivePIDRateHz = 0
        liveLastBatchSize = 1

        let targetRate = max(1.0, livePollingRequestRateHz)
        let unthrottled = livePollingUnthrottled
        if let store = captureStore, let sid = captureSessionID {
            store.addEvent(
                sessionID: sid,
                at: Date(),
                kind: "LIVE_POLL_CONFIG",
                note: "target_req_s=\(targetRate) unthrottled=\(unthrottled)"
            )
        }
        statusMessage = unthrottled
            ? "既知信号ライブ取得中：アプリ側レート制限なし"
            : "既知信号ライブ取得中：目標 \(targetRate.formatted()) req/s"

        liveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await prepareMode01()
                while !Task.isCancelled {
                    let cycleStarted = Date()
                    try await pollKnownCycle()
                    if rpm != nil && speedKmh != nil && coolantC != nil &&
                        socPercent != nil && hvVoltage != nil && hvCurrent != nil {
                        knownSignalsValidated = true
                    }

                    let elapsed = Date().timeIntervalSince(cycleStarted)
                    let delay = pollingDelaySeconds(
                        requestCount: 5 + selectedExtraPIDs.count,
                        targetRequestRateHz: targetRate,
                        elapsedSeconds: elapsed,
                        unthrottled: unthrottled
                    )
                    if delay > 0 {
                        try await Task.sleep(
                            nanoseconds: UInt64(delay * 1_000_000_000)
                        )
                    }

                    let cycleSeconds = max(
                        0.001,
                        Date().timeIntervalSince(cycleStarted)
                    )
                    let batchEnabled = session.negotiatedM5CAN?.supportsOBD01 == true
                    liveLastBatchSize = batchEnabled ? 5 : 1
                    liveEffectiveRequestRateHz = Double((batchEnabled ? 1 : 5) + selectedExtraPIDs.count) / cycleSeconds
                    liveEffectivePIDRateHz = Double(5 + selectedExtraPIDs.count) / cycleSeconds
                }
            } catch is CancellationError {
            } catch {
                statusMessage = "ライブ取得停止: \(error.localizedDescription)"
                transcript.append("ERROR  \(error)")
            }
            isLivePolling = false
            liveTask = nil
        }
    }

    func stopLivePolling() {
        try? writeStandardPIDExports()
        liveTask?.cancel()
        liveTask = nil
        isLivePolling = false
        liveEffectiveRequestRateHz = 0
        liveEffectivePIDRateHz = 0
        liveLastBatchSize = 1
        statusMessage = "ライブ取得停止"
    }

    func runSafeEcuCensus() {
        guard !isBusy, !isLivePolling, !isDidScanning, !isDriveCollecting else { return }
        guard stationaryConfirmed else {
            statusMessage = "ECU確認前に完全停止・Pレンジ確認をチェックしてください"
            return
        }
        guard isRecording else {
            statusMessage = "ECU確認はRAW証拠を残すためSQLite記録中だけ実行できます"
            return
        }
        guard elmInitialized else {
            statusMessage = "先に車両通信を初期化してください"
            return
        }
        guard knownSignalsValidated else {
            statusMessage = "先に既知信号を確認してください"
            return
        }

        isBusy = true
        statusMessage = "停車中の安全なECU確認を実行中"

        Task {
            do {
                guard let speed = try await readScanSpeed(), speed <= 0.1 else {
                    statusMessage = "車速が0 km/hと確認できないためECU確認を中止しました"
                    isBusy = false
                    return
                }

                var found: [String: EcuResponder] = [:]
                for request in safeEcuCensusRequests {
                    try await selectHeader(request.headerCommand)
                    let result = try await session.command(request.command, timeout: 6.0)
                    append(result)
                    for responder in ecuResponders(in: result.text) {
                        found[responder.responseCanID] = responder
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }

                observedEcus = found.values.sorted {
                    (Int($0.source, radix: 16) ?? 0) < (Int($1.source, radix: 16) ?? 0)
                }
                if !observedEcus.contains(where: { $0.source == normalizedEcuSource(didScanEcu) }),
                   let first = observedEcus.first {
                    didScanEcu = first.source
                }

                statusMessage = observedEcus.isEmpty
                    ? "安全な既知要求に応答する18DAF1xx ECU候補は確認できませんでした"
                    : "応答ECU候補を \(observedEcus.count) 個確認しました。役割名は未確定です"
            } catch {
                statusMessage = "ECU確認中止: \(error.localizedDescription)"
                transcript.append("ECU CENSUS ERROR  \(error)")
            }
            isBusy = false
        }
    }

    func selectDidEcu(_ source: String) {
        if let normalized = normalizedEcuSource(source) {
            didScanEcu = normalized
            refreshPositiveDids(flush: true)
        }
    }

    func startDidScan2000Range() {
        startDidScan(start: 0x2000, end: 0x20FF, adaptive: false)
    }

    func startAdaptiveFullDidScan() {
        guard longDidScanAcknowledged else {
            statusMessage = "全範囲探索は長時間になるため確認チェックが必要です"
            return
        }
        startDidScan(start: 0x0000, end: 0xFFFF, adaptive: true)
    }

    private func startDidScan(start: UInt16, end: UInt16, adaptive: Bool) {
        guard !isBusy, !isLivePolling, !isDriveCollecting,
              !isDidScanning, !isUnifiedCollecting else { return }
        guard stationaryConfirmed else {
            statusMessage = "DID探索前に完全停止・Pレンジ確認をチェックしてください"
            return
        }
        guard let store = captureStore, let sid = captureSessionID else {
            statusMessage = "DID探索はRAW証拠を残すためSQLite記録中だけ実行できます"
            return
        }
        guard elmInitialized else {
            statusMessage = "DID探索前に車両通信を初期化してください"
            return
        }
        guard knownSignalsValidated else {
            statusMessage = "DID探索前に既知信号を確認してください"
            return
        }
        guard let ecu = normalizedEcuSource(didScanEcu) else {
            statusMessage = "ECU sourceは01のような2桁16進数で指定してください"
            return
        }
        guard observedEcus.contains(where: { $0.source == ecu }) else {
            statusMessage = "先に安全なECU候補確認を実行し、観測されたECUを選択してください"
            return
        }

        didScanStopRequested = false
        isDidScanning = true
        didScanProgress = 0
        didScanCurrent = "準備中"
        statusMessage = adaptive
            ? "停車確認後、adaptive full-range DID探索を開始します"
            : "停車確認後、DID 2000–20FFを探索します"

        didScanTask = Task { [weak self] in
            guard let self else { return }
            let rate = max(1.0, didScanRateHz)
            let unthrottled = didScanUnthrottled
            let timing = elmDidPollingTimingProfile(
                targetRateHz: rate,
                unthrottled: unthrottled,
                aggressive: aggressiveElmTimingEnabled
            )
            let targetLabel = unthrottled ? "制限なし" : "\(rate.formatted()) req/s"
            didScanEffectiveRateHz = 0
            var timingTouched = false

            do {
                store.addEvent(
                    sessionID: sid,
                    at: Date(),
                    kind: "DID_SCAN_CONFIG",
                    note: "ecu=\(ecu) start=\(String(format: "%04X", start)) " +
                        "end=\(String(format: "%04X", end)) adaptive=\(adaptive) " +
                        "target_req_s=\(rate) unthrottled=\(unthrottled) " +
                        "aggressive_timing=\(aggressiveElmTimingEnabled)"
                )
                store.flush()
                let historyURLs = captureDatabaseURLs()
                let history = loadDidScanHistory(
                    from: historyURLs,
                    ecu: ecu,
                    start: start,
                    end: end
                )
                var completed = history.completed
                completed.formUnion(try store.completedDids(ecu: ecu, start: start, end: end))
                let positiveHints = history.positiveHints
                let rangeCount = Int(end) - Int(start) + 1
                let pendingCount = max(0, rangeCount - completed.count)

                if pendingCount == 0 {
                    didScanProgress = 1.0
                    didScanCurrent = "指定範囲は確認済み"
                    statusMessage = "保存済みSQLite履歴により、このDID範囲はすでに確認済みです"
                    isDidScanning = false
                    didScanTask = nil
                    return
                }

                guard let speed = try await readScanSpeed(), speed <= 0.1 else {
                    didScanCurrent = "安全停止"
                    statusMessage = "車速が0 km/hと確認できないためDID探索を開始しません"
                    isDidScanning = false
                    didScanTask = nil
                    return
                }

                if !timing.setup.isEmpty {
                    timingTouched = true
                    do {
                        for command in timing.setup { try await sendAT(command) }
                        statusMessage = "DID探索中：ELM \(timing.name)設定 / 目標 \(targetLabel)"
                    } catch {
                        for command in timing.restore { _ = try? await commandIgnoringFailure(command) }
                        statusMessage = "高速タイミング設定を使えないため通常設定で探索します"
                    }
                }

                let total = pendingCount
                let scanRateStarted = Date()
                var attempted = Set<UInt16>()
                var consecutiveErrors = 0
                var nextSpeedCheck = Date()
                var aborted = false
                var sectorScores: [Int: Int] = [:]
                var pageScores: [Int: Int] = [:]
                var deepScannedPages = Set<Int>()

                for did in positiveHints where start <= did && did <= end {
                    sectorScores[didSectorIndex(did), default: 0] += 100
                    pageScores[didPageIndex(did), default: 0] += 100
                }

                @MainActor
                func isPending(_ did: UInt16) -> Bool {
                    did >= start && did <= end &&
                    !completed.contains(did) &&
                    !attempted.contains(did)
                }

                @MainActor
                func probeOne(_ did: UInt16, phase: String) async throws {
                    if aborted || didScanStopRequested || Task.isCancelled || !isPending(did) {
                        return
                    }

                    if Date() >= nextSpeedCheck {
                        let speed = try await readScanSpeed()
                        if speed == nil || (speed ?? 0) > 0.1 {
                            let resumed = try await waitForStationaryResume(
                                store: store,
                                sessionID: sid,
                                ecu: ecu,
                                did: did,
                                initialSpeedKmh: speed
                            )
                            if !resumed {
                                aborted = true
                                return
                            }
                        }
                        nextSpeedCheck = Date().addingTimeInterval(1.0)
                    }

                    let started = Date()
                    let outcome = await requestDidWithCompactRetry(ecu: ecu, did: did)
                    store.saveDidScan(sessionID: sid, at: Date(), outcome: outcome)
                    attempted.insert(did)
                    didScanEffectiveRateHz = Double(attempted.count) / max(
                        0.001,
                        Date().timeIntervalSince(scanRateStarted)
                    )

                    let score = didOutcomeInterestScore(status: outcome.status, nrc: outcome.nrc)
                    if score > 0 {
                        sectorScores[didSectorIndex(did), default: 0] += score
                        pageScores[didPageIndex(did), default: 0] += score
                    }

                    if outcome.status == .positive || outcome.status == .positivePartial {
                        consecutiveErrors = 0
                        refreshPositiveDids(flush: true)
                    } else if outcome.status == .nrc || outcome.status == .noData {
                        consecutiveErrors = 0
                    } else {
                        consecutiveErrors += 1
                    }

                    didScanProgress = min(1.0, Double(attempted.count) / Double(total))
                    didScanCurrent =
                        "\(phase) / ECU \(ecu) / DID \(String(format: "%04X", did)) / " +
                        "\(attempted.count)/\(total) / \(outcome.status.rawValue)"

                    if consecutiveErrors >= 5 {
                        statusMessage = "通信エラーが5回連続したため安全停止しました"
                        aborted = true
                        return
                    }

                    let delay = pollingDelaySeconds(
                        requestCount: 1,
                        targetRequestRateHz: rate,
                        elapsedSeconds: Date().timeIntervalSince(started),
                        unthrottled: unthrottled
                    )
                    if delay > 0 {
                        try await Task.sleep(
                            nanoseconds: UInt64(delay * 1_000_000_000)
                        )
                    }
                }

                @MainActor
                func probeCandidates(_ candidates: [UInt16], phase: String) async throws {
                    for did in candidates {
                        if aborted || didScanStopRequested || Task.isCancelled { return }
                        try await probeOne(did, phase: phase)
                    }
                }

                if !adaptive || rangeCount <= 0x100 {
                    let candidates = (Int(start)...Int(end)).map(UInt16.init)
                    try await probeCandidates(candidates, phase: "通常順序")
                } else {
                    try await probeCandidates(
                        didKnownPriority(start: start, end: end),
                        phase: "1/5 既知2000帯"
                    )

                    if !aborted && !didScanStopRequested && !Task.isCancelled {
                        try await probeCandidates(
                            didSectorHeads(start: start, end: end, width: 4),
                            phase: "2/5 16領域先頭"
                        )
                    }

                    if !aborted && !didScanStopRequested && !Task.isCancelled {
                        for sector in didPrioritizedSectors(
                            start: start,
                            end: end,
                            scores: sectorScores
                        ) {
                            try await probeCandidates(
                                didPageSentinels(
                                    sector: sector,
                                    start: start,
                                    end: end,
                                    offsets: [0x00, 0x80]
                                ),
                                phase: "3/5 0x100ページ代表"
                            )
                            if aborted || didScanStopRequested || Task.isCancelled { break }

                            let hotPages = didPagesInSector(sector, start: start, end: end)
                                .filter { pageScores[$0, default: 0] > 0 && !deepScannedPages.contains($0) }
                                .sorted {
                                    let left = pageScores[$0, default: 0]
                                    let right = pageScores[$1, default: 0]
                                    if left != right { return left > right }
                                    return $0 < $1
                                }

                            for page in hotPages {
                                guard let bounds = didPageBounds(page) else { continue }
                                let lo = max(Int(start), Int(bounds.lowerBound))
                                let hi = min(Int(end), Int(bounds.upperBound))
                                if lo <= hi {
                                    try await probeCandidates(
                                        (lo...hi).map(UInt16.init),
                                        phase: "4/5 反応ページ深掘り"
                                    )
                                    deepScannedPages.insert(page)
                                }
                                if aborted || didScanStopRequested || Task.isCancelled { break }
                            }

                            if aborted || didScanStopRequested || Task.isCancelled { break }
                        }
                    }

                    if !aborted && !didScanStopRequested && !Task.isCancelled {
                        for sector in didPrioritizedSectors(
                            start: start,
                            end: end,
                            scores: sectorScores
                        ) {
                            for page in didPrioritizedPages(
                                sector: sector,
                                start: start,
                                end: end,
                                scores: pageScores
                            ) {
                                guard let bounds = didPageBounds(page) else { continue }
                                let lo = max(Int(start), Int(bounds.lowerBound))
                                let hi = min(Int(end), Int(bounds.upperBound))
                                if lo <= hi {
                                    try await probeCandidates(
                                        (lo...hi).map(UInt16.init),
                                        phase: "5/5 未探索全埋め"
                                    )
                                }
                                if aborted || didScanStopRequested || Task.isCancelled { break }
                            }
                            if aborted || didScanStopRequested || Task.isCancelled { break }
                        }
                    }
                }

                store.flush()
                refreshPositiveDids()

                if didScanStopRequested || Task.isCancelled {
                    statusMessage = "DID探索を停止しました。過去のSQLiteを含む保存済み結果から再開できます"
                } else if aborted {
                    // Specific safety/error reason has already been set.
                } else if attempted.count >= total {
                    statusMessage = adaptive
                        ? "adaptive full-range DID探索が完了しました"
                        : "DID 2000–20FFの探索が完了しました"
                    didScanProgress = 1.0
                } else {
                    statusMessage = "DID探索を終了しました。未探索分は次回resumeされます"
                }
            } catch is CancellationError {
                statusMessage = "DID探索を停止しました。保存済み結果は残っています"
            } catch {
                statusMessage = "DID探索中止: \(error.localizedDescription)"
                transcript.append("DID ERROR  \(error)")
            }

            if timingTouched {
                for command in timing.restore { _ = try? await commandIgnoringFailure(command) }
            }
            activeHeaderCommand = nil
            store.addEvent(
                sessionID: sid,
                at: Date(),
                kind: "DID_SCAN_END",
                note: "ecu=\(ecu) current=\(didScanCurrent) " +
                    String(format: "effective_did_s=%.2f", didScanEffectiveRateHz)
            )
            store.flush()
            refreshPositiveDids()
            refreshDriveCandidates()
            isDidScanPausedForSpeed = false
            isDidScanning = false
            didScanTask = nil
        }
    }

    private func captureDatabaseURLs() -> [URL] {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return recordingURL.map { [$0] } ?? [] }

        let folder = documents.appendingPathComponent("HondaAnalyzerSessions", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var result = urls.filter {
            $0.pathExtension.lowercased() == "sqlite3" &&
            !$0.lastPathComponent.hasSuffix("-wal") &&
            !$0.lastPathComponent.hasSuffix("-shm")
        }
        if let recordingURL, !result.contains(recordingURL) {
            result.append(recordingURL)
        }
        return result
    }

    func stopDidScan() {
        didScanStopRequested = true
        didScanTask?.cancel()
        didScanCurrent = "停止要求済み"
        statusMessage = "現在の要求が終わったところでDID探索を停止します"
    }

    func refreshDriveCandidates() {
        captureStore?.flush()
        driveCandidates = loadDriveDIDCandidates(from: captureDatabaseURLs())
        driveScheduler?.addCandidates(driveCandidates)
        if let driveScheduler { driveSamplingSummary = driveScheduler.summary }
    }

    private func schedulerFor(_ candidates: [DriveDID]) -> AdaptiveDriveDIDScheduler {
        if let driveScheduler {
            driveScheduler.addCandidates(candidates)
            return driveScheduler
        }
        let created = AdaptiveDriveDIDScheduler(candidates: candidates)
        // Reuse historical priorities but ALWAYS recheck after reconnect.
        created.restore(loadDriveSamplingSeeds(from: captureDatabaseURLs()))
        driveScheduler = created
        driveSamplingSummary = created.summary
        return created
    }

    private var drivingContext: DriveOperatingContext {
        DriveOperatingContext.classify(
            speedKmh: speedKmh.map(Double.init),
            engineRPM: rpm,
            powerKW: hvPowerKW
        )
    }

    private func recordAdaptiveDriveSample(
        _ candidate: DriveDID,
        outcome: DidProbeOutcome,
        scheduler: AdaptiveDriveDIDScheduler,
        store: CaptureStore,
        sessionID: Int64
    ) -> Bool {
        let now = Date()
        let isPositive = outcome.status == .positive && !outcome.payload.isEmpty
        if isPositive {
            store.saveDriveSample(sessionID: sessionID, at: now, outcome: outcome)
            driveCollectedCount += 1
        }
        if let transition = scheduler.observe(
            candidate,
            payload: isPositive ? outcome.payload : nil,
            at: now,
            context: drivingContext
        ) {
            store.addEvent(
                sessionID: sessionID, at: now, kind: "DRIVE_DID_PRIORITY",
                note: "\(candidate.label) \(transition.previous.rawValue) -> \(transition.current.rawValue) \(transition.reason)"
            )
        }
        if isPositive && driveCollectedCount % 250 == 0 {
            store.saveDriveSamplingState(
                sessionID: sessionID, at: now, seeds: scheduler.snapshots()
            )
        }
        driveSamplingSummary = scheduler.summary
        return isPositive
    }

    func analyzeDriveRecording(_ url: URL? = nil) {
        guard !isDriveAnalyzing, !isDriveCollecting, !isDidScanning, !isLivePolling,
              let captureURL = url ?? recordingURL else {
            statusMessage = "収集停止後、保存済みSQLiteから解析を開始してください"
            return
        }
        captureStore?.flush()
        isDriveAnalyzing = true
        analyzedRecordingName = captureURL.lastPathComponent
        driveFieldCandidates = []
        statusMessage = "過去のDID時系列を解析しています"
        Task { [weak self] in
            // Large capture analysis must never monopolize SwiftUI's main actor.
            let ranked = await Task.detached(priority: .userInitiated) {
                analyzeDriveCapture(captureURL)
            }.value
            guard let self else { return }
            driveFieldCandidates = ranked
            isDriveAnalyzing = false
            statusMessage = ranked.isEmpty
                ? "候補なし：同一DIDを走行中に8回以上取得し、車速/RPMの変化があるログが必要"
                : "走行時系列を解析しました（候補 \(ranked.count)件。意味は未確定）"
        }
    }

    /// Driving collection enumerates ALL previously complete-positive read-only DIDs.
    /// Adaptive scheduling moves stable payloads to sparse rechecks (never bans them).
    func startDriveCollection() {
        guard !isBusy, !isDidScanning, !isLivePolling, !isDriveCollecting,
              !isUnifiedCollecting, ble.state == "ready", isRecording, elmInitialized, knownSignalsValidated,
              let store = captureStore, let sid = captureSessionID else {
            statusMessage = "BLE・記録・ELM・既知信号を準備してから走行解析を開始してください"
            return
        }
        refreshDriveCandidates()
        guard !driveCandidates.isEmpty else {
            statusMessage = "収集対象DIDがありません。Pレンジ停車でPositive DID探索を先に行ってください"
            return
        }
        let candidates = driveCandidates
        let scheduler = schedulerFor(candidates)
        store.saveDrivePlan(sessionID: sid, at: Date(), candidates: candidates)
        isDriveCollecting = true
        driveCollectedCount = 0
        driveFieldCandidates = []
        driveCurrent = "車速・RPM・HV Power確認中"
        store.addEvent(
            sessionID: sid, at: Date(), kind: "DRIVE_CAPTURE_START",
            note: "read_only_known_positive=\(candidates.count) adaptive=true budget=4-per-cycle"
        )
        driveCaptureTask = Task { [weak self] in
            guard let self else { return }
            var consecutiveTransportErrors = 0
            do {
                while !Task.isCancelled {
                    try await prepareMode01()
                    try await pollKnownCycle()
                    if let speed = speedKmh, speed > 0 {
                        stationaryConfirmed = false
                        for _ in 0..<4 {
                            try Task.checkCancellation()
                            guard let candidate = scheduler.next(
                                now: Date(), context: drivingContext
                            ) else { break }
                            let outcome = await sampleKnownDrivingDID(candidate)
                            let success = recordAdaptiveDriveSample(
                                candidate, outcome: outcome, scheduler: scheduler,
                                store: store, sessionID: sid
                            )
                            consecutiveTransportErrors = success ? 0 : consecutiveTransportErrors + 1
                            driveCurrent = "\(candidate.label) / \(driveCollectedCount)件保存 / " +
                                "\(driveSamplingSummary.dormant)件は低頻度再確認"
                            if consecutiveTransportErrors >= 12 {
                                // Historical responders may disappear or reject a
                                // request in a new session. Back off each DID,
                                // without aborting sampling of other ECU sources.
                                if ble.state != "ready" {
                                    throw NSError(
                                        domain: "HondaAnalyzer.DriveCapture", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey:
                                            "BLE切断により解析を停止しました"]
                                    )
                                }
                                store.addEvent(
                                    sessionID: sid, at: Date(),
                                    kind: "DRIVE_DID_RETRY_BACKOFF",
                                    note: "12 consecutive failures; individual DID retries remain scheduled"
                                )
                                consecutiveTransportErrors = 0
                            }
                        }
                    } else {
                        driveCurrent = "停車／車速不明：未知DIDは送信せず待機"
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
            } catch is CancellationError {
            } catch {
                transcript.append("DRIVE CAPTURE ERROR \(error.localizedDescription)")
                statusMessage = "走行解析収集停止: \(error.localizedDescription)"
            }
            store.saveDriveSamplingState(
                sessionID: sid, at: Date(), seeds: scheduler.snapshots()
            )
            store.addEvent(
                sessionID: sid, at: Date(), kind: "DRIVE_CAPTURE_END",
                note: "complete_samples=\(driveCollectedCount) active=\(driveSamplingSummary.active) watch=\(driveSamplingSummary.watch) dormant=\(driveSamplingSummary.dormant)"
            )
            store.flush()
            isDriveCollecting = false
            driveCaptureTask = nil
            if !Task.isCancelled {
                driveCurrent = "終了：\(driveCollectedCount)件"
            }
        }
    }

    func stopDriveCollection() {
        driveCaptureTask?.cancel()
        statusMessage = "走行解析収集を終了中。現在の要求完了を待っています"
    }

    private func sampleKnownDrivingDID(_ candidate: DriveDID) async -> DidProbeOutcome {
        // No ATH0 retry, no unknown DID enumeration, no write/reset service.
        guard let header = physicalRequestHeaderCommand(for: candidate.ecu) else {
            return DidProbeOutcome(ecu: candidate.ecu, did: candidate.did, status: .error)
        }
        do {
            try await selectHeader(header)
            let command = String(format: "22%04X", candidate.did)
            let result = try await session.command(command, timeout: 5.0)
            append(result)
            let outcome = classifyUDS22Text(
                result.text, ecu: candidate.ecu, did: candidate.did,
                latencyMs: result.latencyMs
            )
            promoteCommandIfPositive(command, outcome: outcome)
            return outcome
        } catch {
            return DidProbeOutcome(
                ecu: candidate.ecu, did: candidate.did,
                status: .error, rawText: error.localizedDescription
            )
        }
    }

    private func waitForStationaryResume(
        store: CaptureStore,
        sessionID: Int64,
        ecu: String,
        did: UInt16,
        initialSpeedKmh: Double?
    ) async throws -> Bool {
        let reason = initialSpeedKmh.map { String(format: "vehicle speed %.1f km/h", $0) }
            ?? "vehicle speed unavailable"

        store.addEvent(
            sessionID: sessionID,
            at: Date(),
            kind: "DID_SCAN_PAUSE_SPEED",
            note: "ECU \(ecu) DID \(String(format: "%04X", did)): \(reason)"
        )

        isDidScanPausedForSpeed = true
        didScanCurrent = "一時停止 DID \(String(format: "%04X", did))"

        if !autoResumeDidScanAfterStop {
            statusMessage = "車速を検出したためDID探索を停止しました"
            isDidScanPausedForSpeed = false
            return false
        }

        var tracker = StationaryResumeTracker(requiredZeroSamples: 3)
        let knownCandidates = loadDriveDIDCandidates(from: captureDatabaseURLs())
        let scheduler = schedulerFor(knownCandidates)
        var monitoringIndex = 0
        store.saveDrivePlan(sessionID: sessionID, at: Date(), candidates: knownCandidates)
        store.addEvent(
            sessionID: sessionID, at: Date(), kind: "DRIVE_COLLECT_WHILE_DID_PAUSED",
            note: "known_positive_count=\(knownCandidates.count)"
        )

        while !didScanStopRequested && !Task.isCancelled {
            let speed: Double?
            do {
                speed = try await readScanSpeed()
            } catch {
                tracker.reset()
                statusMessage = "DID探索一時停止中：車速確認失敗。0 km/h安定待ち"
                transcript.append("DID PAUSE SPEED CHECK ERROR  \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            let stoppedStable = tracker.observe(speedKmh: speed)
            if mayResumeUnknownDID(stableZero: stoppedStable, parkingConfirmed: stationaryConfirmed) {
                store.addEvent(
                    sessionID: sessionID,
                    at: Date(),
                    kind: "DID_SCAN_RESUME_STATIONARY",
                    note: "ECU \(ecu) DID \(String(format: "%04X", did)): 0 km/h x3 + renewed P confirmation"
                )
                store.saveDriveSamplingState(
                    sessionID: sessionID, at: Date(), seeds: scheduler.snapshots()
                )
                isDidScanPausedForSpeed = false
                didScanCurrent = "再開 DID \(String(format: "%04X", did))"
                statusMessage = "車速0 km/h安定とP確認により未知DID探索を再開"
                activeHeaderCommand = nil
                return true
            }

            if let speed, speed > 0 {
                stationaryConfirmed = false
                if let candidate = scheduler.next(
                    now: Date(), context: drivingContext
                ) {
                    let outcome = await sampleKnownDrivingDID(candidate)
                    _ = recordAdaptiveDriveSample(
                        candidate, outcome: outcome, scheduler: scheduler,
                        store: store, sessionID: sessionID
                    )
                    didScanCurrent = "走行解析 \(candidate.label) / \(driveCollectedCount)件" +
                        "（低頻度確認 \(driveSamplingSummary.dormant)件）"
                }

                // Refresh correlated references while moving, not unknown DIDs.
                monitoringIndex += 1
                if monitoringIndex % 2 == 0 {
                    try await prepareMode01()
                    let rpmResult = try await session.command("010C")
                    append(rpmResult)
                    rpm = decodeEngineRPM(rpmResult.text)
                    let powerResult = try await session.command("019A")
                    append(powerResult)
                    if let hv = decodeHybridEv9A(powerResult.text) {
                        hvVoltage = hv.voltageV
                        hvCurrent = hv.currentA
                        hvPowerKW = hv.powerKW
                    }
                }
                statusMessage = "走行中：未知DID探索を停止し、発見済みDIDのみ収集中"
            } else if stoppedStable {
                statusMessage = "車速0 km/h安定。安全な場所でPに入れ、停車確認を再度ONにしてください"
            } else if let speed {
                statusMessage = String(
                    format: "未知DID探索待機：車速 %.0f km/h / 0確認 %d/3",
                    speed, tracker.consecutiveZeroSamples
                )
            } else {
                statusMessage = "車速不明：未知DID探索を停止中"
            }

            try await Task.sleep(nanoseconds: 500_000_000)
        }

        store.saveDriveSamplingState(
            sessionID: sessionID, at: Date(), seeds: scheduler.snapshots()
        )
        isDidScanPausedForSpeed = false
        return false
    }

    private func readScanSpeed() async throws -> Double? {
        try await selectHeader("ATSHDB33F1")
        let result = try await session.command("010D", timeout: 5.0)
        append(result)
        guard result.success, let value = decodeVehicleSpeed(result.text) else { return nil }
        speedKmh = value
        if value > 0 {
            stationaryConfirmed = false
        }
        return Double(value)
    }

    private func requestDidWithCompactRetry(ecu: String, did: UInt16) async -> DidProbeOutcome {
        let command = String(format: "22%04X", did)
        let started = Date()

        do {
            guard let header = physicalRequestHeaderCommand(for: ecu) else {
                return DidProbeOutcome(ecu: ecu, did: did, status: .error, rawText: "invalid ECU source")
            }
            try await selectHeader(header)

            let first = try await session.command(command, timeout: 5.0)
            append(first)
            var best = classifyUDS22Text(first.text, ecu: ecu, did: did, latencyMs: first.latencyMs)
            promoteCommandIfPositive(command, outcome: best)

            guard best.status == .positivePartial else { return best }

            var headerOff = false
            do {
                let h0 = try await session.command("ATH0", timeout: 3.0)
                append(h0)
                headerOff = h0.success
                if headerOff {
                    let retry = try await session.command(command, timeout: 7.0)
                    append(retry)
                    let candidate = classifyUDS22Text(retry.text, ecu: ecu, did: did, latencyMs: retry.latencyMs)
                    promoteCommandIfPositive(command, outcome: candidate)
                    if candidate.status == .positive ||
                        (candidate.status == .positivePartial && candidate.payload.count > best.payload.count) {
                        best = candidate
                    }
                }
            } catch {
                transcript.append("DID compact retry: \(error.localizedDescription)")
            }

            if headerOff {
                if let h1 = try? await session.command("ATH1", timeout: 3.0) { append(h1) }
                // ATH0/ATH1 changes output/header state outside selectHeader().
                // Force the next vehicle request to explicitly re-apply its CAN header.
                activeHeaderCommand = nil
            }
            return best
        } catch ElmCommandError.timeout {
            let latency = Date().timeIntervalSince(started) * 1000.0
            let synthetic = ElmCommandResult(
                command: command, raw: Data(), text: "DID DISCOVERY TIMEOUT",
                latencyMs: latency, success: false
            )
            recordCommand(synthetic)
            append(synthetic)
            return DidProbeOutcome(ecu: ecu, did: did, status: .timeout, latencyMs: latency, rawText: "timeout")
        } catch {
            return DidProbeOutcome(
                ecu: ecu, did: did, status: .error,
                latencyMs: Date().timeIntervalSince(started) * 1000.0,
                rawText: "\(type(of: error)): \(error)"
            )
        }
    }

    private func promoteCommandIfPositive(_ command: String, outcome: DidProbeOutcome) {
        guard outcome.status == .positive || outcome.status == .positivePartial,
              let store = captureStore, let sid = captureSessionID else { return }
        store.promoteLatestCommandSuccess(sessionID: sid, command: command)
    }

    private func refreshPositiveDids(flush: Bool = false) {
        guard let store = captureStore else { return }
        do {
            if flush { store.flush() }
            let rows = try store.positiveDidOutcomes(ecu: normalizedEcuSource(didScanEcu))
            positiveDids = rows
            didPositiveCount = rows.count
            didPartialCount = rows.filter { $0.status == .positivePartial }.count
        } catch {
            transcript.append("DID inventory error: \(error.localizedDescription)")
        }
    }

    private func saveBleSnapshot(store: CaptureStore, sessionID: Int64) {
        let inventory = ble.gattInventory.map {
            [
                "service_uuid": $0.serviceUUID,
                "uuid": $0.uuid,
                "properties": $0.properties
            ] as [String: Any]
        }
        var metadata: [String: Any] = ["gatt": inventory]
        if let name = ble.connectedDeviceName { metadata["name"] = name }
        if let write = ble.selectedWriteUUID { metadata["selected_write_uuid"] = write }
        if let notify = ble.selectedNotifyUUID { metadata["selected_notify_uuid"] = notify }

        guard JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            transcript.append("BLE metadata snapshot could not be serialized")
            return
        }
        store.saveDevice(
            sessionID: sessionID,
            kind: "ble",
            identifier: ble.connectedDeviceID?.uuidString ?? "unknown",
            metadataJSON: json
        )
    }

    private func prepareMode01() async throws {
        try await selectHeader("ATSHDB33F1")
    }

    private func selectHeader(_ headerCommand: String) async throws {
        let commands = elmCanHeaderSetupCommands(
            header: headerCommand,
            activeHeader: activeHeaderCommand,
            priority18Configured: priority18Configured
        )
        for command in commands {
            try await sendAT(command)
            if command == "ATCP18" {
                priority18Configured = true
            }
        }
        if !commands.isEmpty {
            activeHeaderCommand = headerCommand
        }
    }

    private func pollKnownCycle(requireComplete: Bool = false) async throws {
        let keys = ["010C", "010D", "0105", "015B", "019A"]
        let texts: [String]
        let successes: [Bool]
        if session.negotiatedM5CAN?.supportsOBD01 == true {
            // Five RPM/speed/coolant/SOC/HV requests, one BLE round-trip.
            // The device still serializes the five ECU queries.
            let (result, batch) = try await session.batchRead(
                group: .mode01, ids: keys, timeout: 10.0
            )
            append(result)
            texts = batch.items.map(\.responseText)
            successes = texts.map(elmResponseSuccess)
            // SQLite analysis expects the five reference commands individually.
            // Keep synthetic per-item rows alongside the original batch raw
            // command. Persist NULL for unknown per-item latency, not a measured 0ms.
            for (index, key) in keys.enumerated() {
                recordCommand(ElmCommandResult(
                    command: key,
                    raw: Data(texts[index].utf8),
                    text: texts[index],
                    latencyMs: 0,
                    success: successes[index]
                ), syntheticBatchItem: true)
            }
        } else {
            var results: [ElmCommandResult] = []
            for key in keys {
                let result = try await session.command(key)
                append(result)
                results.append(result)
            }
            texts = results.map(\.text)
            successes = results.map(\.success)
        }

        // Additional standard PIDs are queried individually after the known-signal
        // batch. The M5CAN v1.x batch protocol only guarantees the five known keys.
        if !requireComplete {
            for pid in selectedExtraPIDs.sorted() {
                try Task.checkCancellation()
                let cmd = String(format: "01%02X", pid)
                do {
                    let response = try await session.command(cmd)
                    append(response)
                    let readings = readStandardPID(pid, from: response.text, at: Date(),
                                                   latencyMs: response.latencyMs)
                    if readings.isEmpty {
                        standardPIDInventory.addFailure(pid: pid, status: .noData)
                        recordLifecycleEvent(kind: "PID_OPTIONAL_NO_DATA", note: "pid=\(cmd)")
                    }
                    for reading in readings {
                        standardPIDInventory.addReading(reading)
                        saveStandardPIDReading(reading)
                    }
                } catch {
                    // An optional extra PID must never stop baseline RPM/speed/HV.
                    standardPIDInventory.addFailure(pid: pid, status: .timeout)
                    recordLifecycleEvent(kind: "PID_OPTIONAL_ERROR", note: "pid=\(cmd) \(error)")
                }
            }
        }

        // These readings also feed the bounded automatic change-graph cache.
        // The existing live metrics still use their original decoders.
        let knownPIDs: [UInt8] = [0x0C, 0x0D, 0x05, 0x5B]
        for (index, pid) in knownPIDs.enumerated() {
            for reading in readStandardPID(pid, from: texts[index], at: Date()) {
                trackStandardReading(reading)
            }
        }
        let rpmValue = decodeEngineRPM(texts[0])
        let speedValue = decodeVehicleSpeed(texts[1])
        let coolantValue = decodeCoolantC(texts[2])
        let socValue = decodeBatterySOC(texts[3])
        let hybridValue = decodeHybridEv9A(texts[4])

        if requireComplete {
            let complete =
                successes[0] && rpmValue != nil &&
                successes[1] && speedValue != nil &&
                successes[2] && coolantValue != nil &&
                successes[3] && socValue != nil &&
                successes[4] && hybridValue != nil

            guard complete else {
                throw NSError(
                    domain: "HondaAnalyzer.KnownSignals",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "既知信号の確認に失敗しました。RPM/車速/水温/SOC/HV 9Aの全項目が有効にdecodeできる必要があります。"
                    ]
                )
            }
        }

        rpm = rpmValue
        speedKmh = speedValue
        if let speedValue, speedValue > 0 {
            stationaryConfirmed = false
        }
        coolantC = coolantValue
        socPercent = socValue
        if let hybridValue {
            hvVoltage = hybridValue.voltageV
            hvCurrent = hybridValue.currentA
            hvPowerKW = hybridValue.powerKW
        }

        liveSamples.append(
            LiveSignalSample(
                date: Date(),
                rpm: rpmValue,
                speedKmh: speedValue.map(Double.init),
                hvPowerKW: hybridValue?.powerKW
            )
        )
        if liveSamples.count > 120 {
            liveSamples.removeFirst(liveSamples.count - 120)
        }
    }

    private func sendAT(_ command: String) async throws {
        let result = try await session.command(command)
        append(result)
        if !result.success {
            throw NSError(
                domain: "HondaAnalyzer.ELM",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(command) failed: \(result.text)"]
            )
        }
    }

    private func commandIgnoringFailure(_ command: String) async throws -> ElmCommandResult {
        let result = try await session.command(command, timeout: 3.0)
        append(result)
        return result
    }

    private func recordRaw(_ data: Data) {
        guard let store = captureStore, let sid = captureSessionID else { return }
        let source = ble.selectedNotifyUUID.map { "ble:\($0)" } ?? "ble:kw905"
        store.appendRaw(
            sessionID: sid,
            at: Date(),
            layer: "BLE",
            source: source,
            payload: data
        )
    }

    private func recordCommand(_ result: ElmCommandResult,
                               syntheticBatchItem: Bool = false) {
        guard let store = captureStore, let sid = captureSessionID else { return }
        store.appendCommand(sessionID: sid, at: Date(), result: result,
                            syntheticBatchItem: syntheticBatchItem)
    }

    private func append(_ result: ElmCommandResult) {
        let response = result.text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        transcript.append(String(format: "%@  %.1f ms  %@", result.command, result.latencyMs, response))
        if transcript.count > 200 { transcript.removeFirst(transcript.count - 200) }
    }
}
