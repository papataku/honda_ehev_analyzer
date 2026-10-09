import SwiftUI
import HondaAnalyzerCore

struct DrivingAnalysisPage: View {
    @ObservedObject var model: AnalyzerViewModel
    let onOpenDiscovery: () -> Void
    let onOpenDashboard: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AnalyzerDesign.pageSpacing) {
                PageHeader(
                    title: "走行解析",
                    subtitle: "発見済みDIDの時系列・モーター/発電機信号候補を検出",
                    systemImage: "chart.xyaxis.line"
                )

                AnalyzerCard("開始前のチェック", systemImage: "checkmark.shield") {
                    VStack(alignment: .leading, spacing: 10) {
                        requirementRow(
                            "BLEデバイスへ接続",
                            satisfied: model.ble.state == "ready",
                            note: "KW905または自作ELM互換機"
                        )
                        requirementRow(
                            "SQLite記録を開始",
                            satisfied: model.isRecording,
                            note: "RAWと既知信号の記録を残します"
                        )
                        requirementRow(
                            "ELM初期化・既知信号確認",
                            satisfied: model.elmInitialized && model.knownSignalsValidated,
                            note: "RPM・車速・HV電力を読み取れる状態"
                        )
                        requirementRow(
                            "発見済みDIDがある",
                            satisfied: !model.driveCandidates.isEmpty,
                            note: "未発見なら、停車・P確認後に探索してください"
                        )
                        if model.isDriveCollecting {
                            StatusPill(text: "安全に停車するまで収集を続けています", systemImage: "record.circle.fill", style: .active)
                        } else if canStart {
                            StatusPill(text: "走行解析を開始できます", systemImage: "checkmark.circle.fill", style: .good)
                        } else {
                            Text("未完了の項目を確認してください。開始できない理由は下の収集カードにも表示されます。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if model.ble.state != "ready" || !model.isRecording ||
                            !model.elmInitialized || !model.knownSignalsValidated {
                            Button {
                                onOpenDashboard()
                            } label: {
                                Label("ダッシュボードで開始準備", systemImage: "arrow.right")
                            }
                            .buttonStyle(.bordered)
                        }
                        if model.driveCandidates.isEmpty {
                            Button {
                                onOpenDiscovery()
                            } label: {
                                Label("停車中のDID探索へ", systemImage: "arrow.right")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                AnalyzerCard("走行データ収集", systemImage: "car.side") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("出発前に「走行解析を開始」を押し、iPadを固定してください。動いている間は発見済みの信号だけを繰り返し保存します。停車中は自動的に待機します。")
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
                        LabeledContent("管理しているDID", value: "\(model.driveCandidates.count)件")
                        LabeledContent("優先して取得", value: "\(model.driveSamplingSummary.active)件")
                        LabeledContent("初期評価中", value: "\(model.driveSamplingSummary.learning)件")
                        LabeledContent("取得頻度を低減", value: "\(model.driveSamplingSummary.watch)件")
                        LabeledContent("通常取得を休止・定期再確認", value: "\(model.driveSamplingSummary.dormant)件")
                        Text(model.driveCurrent)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if !canStart && !model.isDriveCollecting {
                            Text(startUnavailableReason)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .accessibilityLabel("開始できない理由：\(startUnavailableReason)")
                        }
                        if model.isDriveCollecting {
                            Text("運転中は画面を操作しないでください。停止操作は安全に停車してから行ってください。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                AnalyzerCard("発見済みDID", systemImage: "cpu") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("過去に完全なPositive応答があったDIDを全件管理します。固定の24件上限はありません。値が変わらないDIDは低頻度にし、走行状態が変わったら再確認します。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("更新") { model.refreshDriveCandidates() }
                                .buttonStyle(.bordered)
                                .disabled(model.isDriveCollecting || model.isDidScanning)
                        }
                        if model.driveCandidates.isEmpty {
                            Text("まだ収集できる信号がありません。停車中にDID探索で応答のある項目を見つけてください。")
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 180), spacing: 8)],
                                alignment: .leading
                            ) {
                                ForEach(Array(model.driveCandidates.prefix(48))) { item in
                                    Label(item.label, systemImage: "checkmark.circle")
                                        .font(.caption.monospaced())
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                            if model.driveCandidates.count > 48 {
                                Text("ほか \(model.driveCandidates.count - 48)件も管理・取得対象です。表示は48件に省略しています。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("変化なし＝永久停止ではありません。7回連続で同じ値なら12秒、走行状態をまたいで12回連続なら90秒間隔へ移し、値が変わればすぐ優先取得へ戻します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                AnalyzerCard("モーター/発電機候補解析", systemImage: "chart.xyaxis.line") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("保存したデータから、車速やエンジン回転数と一緒に変化する値を探します。「候補スコア」は発見の優先度で、信号の正しさの確率ではありません。")
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
                                        Text(String(format: "候補スコア %.2f", item.score))
                                            .font(.caption.monospacedDigit())
                                    }
                                    HStack(spacing: 8) {
                                        Text(item.classification)
                                            .font(.caption.weight(.semibold))
                                        Text("仮説・未検証")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                    Text("相関係数 r：車速 \(correlation(item.speedCorrelation)) / EV時車速 \(correlation(item.evSpeedCorrelation)) / エンジン回転 \(correlation(item.engineCorrelation)) / HV電力 \(correlation(item.hvPowerCorrelation))")
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

                        DisclosureGroup("解析結果の見方・専門用語") {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("DID：ECU内部のデータを読み出すための識別番号です。")
                                Text("Positive：ECUが値を返したこと。意味が特定できたわけではありません。")
                                Text("EV区間：車速があり、エンジンRPMが低い時の参考区間です。")
                                Text("相関係数r：-1〜+1の変動の似かたです。±1に近くても因果関係や単位の証明にはなりません。")
                                Text("発電機候補：エンジンと連動するだけの別信号も含みます。複数ログで照合が必要です。")
                                Text("確定の目安：EV/発電/回生を含む複数走行で同じオフセット・倍率が再現すること。")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
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

    private func requirementRow(_ title: String, satisfied: Bool, note: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: satisfied ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(satisfied ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(satisfied ? "完了" : "未完了")
                .font(.caption.weight(.semibold))
                .foregroundStyle(satisfied ? .green : .orange)
        }
        .accessibilityElement(children: .combine)
    }

    private var startUnavailableReason: String {
        if model.ble.state != "ready" { return "Bluetooth接続が必要です。ダッシュボードの開始準備へ戻ってください。" }
        if !model.isRecording { return "最初にSQLite記録を開始してください。" }
        if !model.elmInitialized || !model.knownSignalsValidated {
            return "ELM初期化と既知信号の確認を完了してください。"
        }
        if model.driveCandidates.isEmpty {
            return "収集対象のDIDがありません。安全な停車/P確認後にDID探索を行ってください。"
        }
        if model.isLivePolling { return "ライブ表示を停止してから走行解析を開始してください。" }
        if model.isDidScanning { return "DID探索を停止してから走行解析を開始してください。" }
        if model.isBusy { return "通信処理が終わってから開始できます。" }
        return "準備完了"
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
