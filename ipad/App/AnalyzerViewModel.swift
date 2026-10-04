import SwiftUI
import HondaAnalyzerCore

@MainActor
final class AnalyzerViewModel: ObservableObject {
    let ble: KW905BLETransport
    private let session: ElmCommandSession
    private var captureStore: CaptureStore?
    private var captureSessionID: Int64?

    @Published var isBusy = false
    @Published var isRecording = false
    @Published var recordingFile = ""
    @Published var statusMessage = "KW905へ接続してください"
    @Published var rpm: Double?
    @Published var speedKmh: Int?
    @Published var coolantC: Int?
    @Published var socPercent: Double?
    @Published var hvVoltage: Double?
    @Published var hvCurrent: Double?
    @Published var hvPowerKW: Double?
    @Published var transcript: [String] = []

    init() {
        let transport = KW905BLETransport()
        self.ble = transport
        self.session = ElmCommandSession(transport: transport)

        session.onRawReceive = { [weak self] data in self?.recordRaw(data) }
        session.onResult = { [weak self] result in self?.recordCommand(result) }
    }

    func startRecording() {
        guard captureStore == nil else { return }
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let folder = documents.appendingPathComponent("HondaAnalyzerSessions", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = folder.appendingPathComponent("session-\(stamp).sqlite3")
            let store = try CaptureStore(url: url)
            store.onError = { [weak self] error in
                self?.statusMessage = "記録エラー: \(error.localizedDescription)"
            }
            let sid = try store.createSession(toolVersion: "ipad-native")
            captureStore = store
            captureSessionID = sid
            recordingFile = url.lastPathComponent
            isRecording = true
            statusMessage = "記録開始"
        } catch {
            statusMessage = "記録開始失敗: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard let store = captureStore, let sid = captureSessionID else { return }
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
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "ELM初期化中"
        Task {
            let results = await session.initialize()
            for result in results { append(result) }
            let failed = results.filter { !$0.success }
            statusMessage = failed.isEmpty ? "ELM初期化完了" : "ELM初期化完了（失敗 \(failed.count)件）"
            isBusy = false
        }
    }

    func readKnownSignals() {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "既知信号を取得中"

        Task {
            do {
                try await sendAT("ATCP18")
                try await sendAT("ATSHDB33F1")

                let rpmResult = try await session.command("010C"); append(rpmResult)
                rpm = decodeEngineRPM(rpmResult.text)

                let speedResult = try await session.command("010D"); append(speedResult)
                speedKmh = decodeVehicleSpeed(speedResult.text)

                let coolantResult = try await session.command("0105"); append(coolantResult)
                coolantC = decodeCoolantC(coolantResult.text)

                let socResult = try await session.command("015B"); append(socResult)
                socPercent = decodeBatterySOC(socResult.text)

                let hybridResult = try await session.command("019A"); append(hybridResult)
                if let hybrid = decodeHybridEv9A(hybridResult.text) {
                    hvVoltage = hybrid.voltageV
                    hvCurrent = hybrid.currentA
                    hvPowerKW = hybrid.powerKW
                }
                statusMessage = "既知信号取得完了"
            } catch {
                statusMessage = "取得失敗: \(error.localizedDescription)"
                transcript.append("ERROR  \(error)")
            }
            isBusy = false
        }
    }

    private func sendAT(_ command: String) async throws {
        let result = try await session.command(command)
        append(result)
        if !result.success {
            throw NSError(domain: "HondaAnalyzer.ELM", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(command) failed: \(result.text)"])
        }
    }

    private func recordRaw(_ data: Data) {
        guard let store = captureStore, let sid = captureSessionID else { return }
        store.appendRaw(sessionID: sid, at: Date(), layer: "ble", source: "kw905", payload: data)
    }

    private func recordCommand(_ result: ElmCommandResult) {
        guard let store = captureStore, let sid = captureSessionID else { return }
        store.appendCommand(sessionID: sid, at: Date(), result: result)
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
