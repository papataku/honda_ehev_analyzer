import SwiftUI
import HondaAnalyzerCore

@MainActor
final class AnalyzerViewModel: ObservableObject {
    let ble: KW905BLETransport
    private let session: ElmCommandSession

    @Published var isBusy = false
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

                let rpmResult = try await session.command("010C")
                append(rpmResult)
                rpm = decodeEngineRPM(rpmResult.text)

                let speedResult = try await session.command("010D")
                append(speedResult)
                speedKmh = decodeVehicleSpeed(speedResult.text)

                let coolantResult = try await session.command("0105")
                append(coolantResult)
                coolantC = decodeCoolantC(coolantResult.text)

                let socResult = try await session.command("015B")
                append(socResult)
                socPercent = decodeBatterySOC(socResult.text)

                let hybridResult = try await session.command("019A")
                append(hybridResult)
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
            throw NSError(
                domain: "HondaAnalyzer.ELM",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(command) failed: \(result.text)"]
            )
        }
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
