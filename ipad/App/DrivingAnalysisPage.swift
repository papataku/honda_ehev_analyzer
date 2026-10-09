import SwiftUI
import HondaAnalyzerCore

struct DrivingAnalysisPage: View {
    @ObservedObject var model: AnalyzerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AnalyzerDesign.pageSpacing) {
                PageHeader(
                    title: "走行解析",
                    subtitle: "発見済みDIDの時系列・モーター/発電機信号候補を検出",
                    systemImage: "chart.xyaxis.line"
                )

                AnalyzerCard("走行データ収集", systemImage: "car.side") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("走行中は発見済みのPositive DIDとRPM・車速・HV電力だけを繰り返し収集。未知DID探索はしません。停車中の探索は別ページで、安全な場所でP確認後に実施してください。")
                            .font(.callout)
                        HStack {
                            StatusPill(
                                text: model.isDriveCollecting ? "収集中" : "待機",
                                systemImage: model.isDriveCollecting ? "record.circle.fill" : "pause.circle",
                                style: model.isDriveCollecting ? .active : .neutral
                            )
                            Spacer()
                            if model.isDriveCollecting {
                                Button("収集停止", role: .destructive) {
                                    model.stopDriveCollection()
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button("走行解析を開始") {
                                    model.startDriveCollection()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!canStart)
                            }
                        }
                        LabeledContent("有効DIDサンプル", value: "\(model.driveCollectedCount)件")
                        LabeledContent("収集対象DID", value: "\(model.driveCandidates.count)件")
                        Text(model.driveCurrent)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                AnalyzerCard("発見済みDID", systemImage: "cpu") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("完全なPositive応答のみ。未確定DIDの網羅探索は走行中に行いません。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("更新") { model.refreshDriveCandidates() }
                                .buttonStyle(.bordered)
                                .disabled(model.isDriveCollecting || model.isDidScanning)
                        }
                        if model.driveCandidates.isEmpty {
                            Text("候補なし。停車中にDID探索を行いPositiveを記録してください。")
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 180), spacing: 8)],
                                alignment: .leading
                            ) {
                                ForEach(model.driveCandidates) { item in
                                    Label(item.label, systemImage: "checkmark.circle")
                                        .font(.caption.monospaced())
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }
                }

                AnalyzerCard("モーター/発電機候補解析", systemImage: "chart.xyaxis.line") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("DIDペイロードを複数の整数型・バイト順として検証し、EV区間の車速、エンジンRPM、HV電力との相関を調べます。順位は候補であり、単位や信号の意味を確定するものではありません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("この記録を解析") {
                            model.analyzeDriveRecording()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isDriveCollecting || model.isDidScanning || model.isLivePolling || model.recordingURL == nil)

                        if !model.analyzedRecordingName.isEmpty {
                            Text("解析ファイル：\(model.analyzedRecordingName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if model.driveFieldCandidates.isEmpty {
                            Text("収集後に解析してください。同じDIDが8点以上、かつ車速/RPMが変化するデータが必要です。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(model.driveFieldCandidates.prefix(25))) { item in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text("ECU \(item.ecu) DID \(String(format: "%04X", item.did))")
                                            .font(.subheadline.monospaced().bold())
                                        Text(item.field)
                                            .font(.caption.monospaced())
                                        Spacer()
                                        Text(String(format: "%.2f", item.score))
                                            .font(.subheadline.monospacedDigit())
                                    }
                                    Text(item.classification)
                                        .font(.caption.weight(.semibold))
                                    Text("車速 \(correlation(item.speedCorrelation)) / EV \(correlation(item.evSpeedCorrelation)) / RPM \(correlation(item.engineCorrelation)) / HV \(correlation(item.hvPowerCorrelation))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("\(item.samples)点 / raw \(item.minValue.formatted())〜\(item.maxValue.formatted()) / スケール未確定")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: AnalyzerDesign.contentMaxWidth)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if !model.isDriveCollecting && !model.isDidScanning {
                model.refreshDriveCandidates()
            }
        }
    }

    private var canStart: Bool {
        model.ble.state == "ready" && model.isRecording &&
        model.elmInitialized && model.knownSignalsValidated &&
        !model.driveCandidates.isEmpty && !model.isBusy &&
        !model.isLivePolling && !model.isDidScanning
    }

    private func correlation(_ x: Double?) -> String {
        x.map { String(format: "%.2f", $0) } ?? "—"
    }
}
