#if DEBUG
import SwiftUI
import Combine
import HondaAnalyzerCore

/// Explicit Mac launch argument only. Normal app workflows are unaffected.
@MainActor final class BLESoakController: ObservableObject {
    @Published var status = "準備中"
    @Published var completed = 0
    private let ble = KW905BLETransport()
    private var session: ElmCommandSession!
    private var observation: AnyCancellable?
    private var store: CaptureStore?
    private var sid: Int64 = 0
    private var task: Task<Void, Never>?
    private var ioError: String?
    private var failed = false
    private var file: FileHandle?
    private let started = Date()

    func event(_ kind: String, _ note: String) {
        let now = Date()
        store?.addEvent(sessionID: sid, at: now, kind: kind, note: note)
        let row: [String: Any] = ["utc": captureTimestamp(now), "uptime_s": ProcessInfo.processInfo.systemUptime, "kind": kind, "note": note]
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            do { try file?.write(contentsOf: data + Data([10])); try file?.synchronize() }
            catch { ioError = "log write: \(error)" }
        }
    }
    func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }
    func stop() { task?.cancel() }
    private func value(_ name: String, default fallback: String) -> String {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: name), a.indices.contains(i + 1) else { return fallback }
        return a[i + 1]
    }
    private func run() async {
        let scenario = value("--soak-scenario", default: "idle")
        let seconds = min(3600, max(1, Double(value("--soak-seconds", default: "60")) ?? 60))
        let keepAwake = value("--soak-keep-awake", default: "yes") == "yes"
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = keepAwake
        defer {
            ble.stopScan(); ble.disconnect()
            UIApplication.shared.isIdleTimerDisabled = previousIdle
            event("SOAK_END", "scenario=\(scenario) commands=\(completed) failed=\(failed) elapsed=\(Date().timeIntervalSince(started)) io_error=\(ioError ?? "none")")
            try? store?.closeSession(sid, status: failed ? "FAILED" : "CLOSED")
            try? file?.close()
        }
        do {
            guard ["idle", "single", "batch", "no-data"].contains(scenario) else { throw SoakError.invalidScenario }
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = documents.appendingPathComponent("BLESoak", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let runID = value("--soak-run-id", default: UUID().uuidString)
            // Host-created run IDs are restricted to safe filenames.
            guard BLESoakPolicy.validRunID(runID) else { throw SoakError.invalidScenario }
            let logURL = folder.appendingPathComponent(runID + ".jsonl")
            guard !FileManager.default.fileExists(atPath: logURL.path) else { throw SoakError.existingRun }
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            file = try FileHandle(forWritingTo: logURL)
            store = try CaptureStore(url: folder.appendingPathComponent(runID + ".sqlite3"))
            store?.onError = { [weak self] error in Task { @MainActor in self?.ioError = "\(error)" } }
            sid = try store!.createSession(gitCommit: Bundle.main.object(forInfoDictionaryKey: "SoakGitSHA") as? String, toolVersion: "ipad-ble-soak", vehicle: "DEMO ONLY")
            event("SOAK_START", "scenario=\(scenario) seconds=\(seconds) keep_awake=\(keepAwake) app_sha=\(Bundle.main.object(forInfoDictionaryKey: "SoakGitSHA") ?? "unknown")")
            observation = ble.$state.sink { [weak self] state in
                guard let self else { return }
                self.event("BLE_STATE", "state=\(state) reason=\(self.ble.lastDisconnectReason ?? "none")")
                if ["disconnected", "gatt-error", "connect-failed", "bluetooth-unavailable"].contains(state) {
                    self.session?.resetProtocolNegotiation()
                }
            }
            session = ElmCommandSession(transport: ble)
            session.onRawReceive = { [weak self] data in
                guard let self else { return }
                self.store?.appendRaw(sessionID: self.sid, at: Date(), layer: "BLE", source: "ble:notify", payload: data)
            }
            session.onResult = { [weak self] result in
                guard let self else { return }
                self.store?.appendCommand(sessionID: self.sid, at: Date(), result: result)
            }
            let scanDeadline = Date().addingTimeInterval(20)
            while ble.state == "idle" || ble.state == "bluetooth-unavailable" {
                guard Date() < scanDeadline else { throw SoakError.connection }
                try await Task.sleep(nanoseconds: 100_000_000)
                ble.startScan()
                if ble.state == "scanning" { break }
            }
            if ble.state != "scanning" { ble.startScan() }
            while !ble.devices.contains(where: { $0.name == "M5CAN-Dial" }) {
                guard Date() < scanDeadline else { throw SoakError.connection }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let target = ble.devices.first(where: { $0.name == "M5CAN-Dial" }) else { throw SoakError.connection }
            try ble.connect(to: target.id)
            let deadline = Date().addingTimeInterval(20)
            while ble.state != "ready" {
                guard Date() < deadline, !["disconnected", "connect-failed", "gatt-error"].contains(ble.state) else { throw SoakError.connection }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            event("GATT", "write=\(ble.selectedWriteUUID ?? "unknown") notify=\(ble.selectedNotifyUUID ?? "unknown")")
            // Init contains configuration/meta only; no vehicle read precedes DEMO verification.
            let initialized = await session.initialize()
            guard initialized.allSatisfy({ $0.success }) else { throw SoakError.initialization }
            let cap = try await session.command("ATM5CAP")
            guard BLESoakPolicy.demoVerified(cap.text) else { throw SoakError.demoRequired }
            event("DEMO_VERIFIED", cap.text)
            _ = try await session.command("ATCP18")
            _ = try await session.command("ATSHDB33F1")
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                try Task.checkCancellation()
                guard ble.state == "ready" else { throw SoakError.connection }
                if let ioError { throw SoakError.storage(ioError) }
                if scenario == "no-data" {
                    // Finite error fixture, not an unknown-DID scanner. The
                    // verified adapter DEMO path returns NO DATA for UDS.
                    let ids = ["20FF", "FE08", "FFFF"]
                    let (_, negative) = try await session.batchRead(group: .ecu01ReadDID, ids: ids)
                    let classifications = zip(negative.items, [UInt16(0x20FF), 0xFE08, 0xFFFF]).map {
                        classifyUDS22Text($0.0.responseText, ecu: "01", did: $0.1).status
                    }
                    guard classifications.allSatisfy({ $0 == .noData }), ble.state == "ready" else { throw SoakError.response }
                    event("EXPECTED_ERROR", "NO_DATA items=3 BLE=ready")
                    // Check the link and a fresh normal response immediately
                    // after a failed item/batch, with no reconnect/re-init.
                }
                if scenario == "batch" || scenario == "no-data" {
                    let (result, parsed) = try await session.batchRead(group: .mode01, ids: BLESoakPolicy.pids)
                    guard result.success, parsed.items.count == 5 else { throw SoakError.response }
                    completed += 1
                    event("SAMPLE", "batch=\(completed) latency_ms=\(result.latencyMs)")
                } else if scenario == "single" {
                    for command in BLESoakPolicy.pids {
                        let result = try await session.command(command)
                        guard result.success else { throw SoakError.response }
                        completed += 1
                        event("SAMPLE", "command=\(command) count=\(completed) latency_ms=\(result.latencyMs)")
                    }
                } else { event("IDLE_HEARTBEAT", "state=\(ble.state)") }
                status = "\(scenario): \(completed) 応答 / 残り \(Int(max(0, end.timeIntervalSinceNow)))秒"
                try await Task.sleep(nanoseconds: scenario == "idle" ? 1_000_000_000 : 200_000_000)
            }
            status = "試験終了: \(completed) 応答"
        } catch {
            failed = true; status = "試験停止: \(error)"
            event("SOAK_FAILURE", "\(error)")
        }
    }
    enum SoakError: Error { case connection, initialization, demoRequired, response, invalidScenario, existingRun, storage(String) }
}

struct BLESoakView: View {
    @StateObject private var test = BLESoakController()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack(spacing: 24) {
            Text("BLE机上耐久試験").font(.largeTitle)
            Text(test.status).font(.title2)
            Text("DEMO確認後に既知PIDのみ取得します。走行収集やDID探索は開始しません。")
            Button("試験を停止") { test.stop() }.buttonStyle(.borderedProminent)
        }.padding().task { test.start() }
        .onChange(of: phase) { value in test.event("APP_SCENE_PHASE", String(describing: value)) }
    }
}
#endif
