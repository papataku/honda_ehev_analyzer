import SwiftUI
import HondaAnalyzerCore

/// Intent-first page: novice operators can see prerequisites, next action and
/// export locations without needing to know Mode 01 commands or ECU topology.
struct StandardPIDPage: View {
    @ObservedObject var model: AnalyzerViewModel
    @State private var showOnlyResponses = false

    private var ready: Bool {
        model.isRecording && model.ble.state == "ready" &&
        model.elmInitialized && model.knownSignalsValidated
    }

    private var rows: [StandardPIDInventoryRow] {
        let all = model.standardPIDInventory.sortedRows
        return showOnlyResponses ? all.filter { $0.successfulSamples > 0 } : all
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AnalyzerDesign.pageSpacing) {
                PageHeader(
                    title: "追加メーター候補",
                    subtitle: "標準PIDと記録済み信号から、実車で表示できる項目を調べます",
                    systemImage: "list.bullet.rectangle"
                )
                AnalyzerCard("初めて使う方へ", systemImage: "questionmark.circle") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. ダッシュボードでBluetooth接続 → SQLite記録開始 → 通信初期化 → 既知信号確認を実行します。")
                        Text("2. ここで「標準PIDを調べる」を押します。対応有無と実際の応答を分けて記録します。")
                        Text("3. 候補を確認し、ライブで見たい項目を最大4つ選びます。選択後はダッシュボードからライブ表示を開始します。")
                        Text("4. 取得を停止 → SQLite記録を終了し、CSV・JSON・SQLiteを共有します。")
                        Text("注意：対応bitmapだけでは実測可能と判定しません。未知DIDの意味を勝手に確定しません。")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                AnalyzerCard("調査の状態", systemImage: "magnifyingglass.circle") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(model.isRecording ? "SQLite記録中（画面の自動スリープを防止）" : "SQLite記録が必要です",
                              systemImage: model.isRecording ? "record.circle.fill" : "circle")
                        Text(model.standardPIDProgress)
                            .font(.headline)
                        if model.isStandardPIDSurveying {
                            ProgressView()
                            Text("応答のないPIDは再試行します。通信状況によって完了までの時間が変わります。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("安全に調査を中止", role: .destructive) {
                                model.stopStandardPIDSurvey()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                model.startStandardPIDSurvey()
                            } label: {
                                Label("標準PIDを調べる", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!ready || model.isBusy || model.isLivePolling ||
                                      model.isDidScanning || model.isDriveCollecting)
                        }
                        if !ready {
                            Text("次の操作：ダッシュボードで接続・記録・初期化・既知信号確認を順に完了してください。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Text("確認項目：応答ECU別の標準PID。未知DID探索はこの操作では実行しません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                AnalyzerCard("候補一覧と継続取得", systemImage: "checklist") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("実際に応答したPIDだけを表示", isOn: $showOnlyResponses)
                        Text("取得数はPID/ECU別です。0は有効値、—は未取得です。取得Hzはその項目の実測期間から算出します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("ライブで追加するPIDは最大4件。既知のRPM・速度・水温・SOC・HV 9Aの取得は維持します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(row.name).font(.headline)
                                    Text(String(format: "01%02X", row.pid))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if row.successfulSamples > 0, !isReferencePID(row.pid) {
                                        Button(model.selectedExtraPIDs.contains(row.pid) ? "追加解除" : "ライブに追加") {
                                            model.toggleExtraPID(row.pid)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(model.isLivePolling || model.isBusy ||
                                                  (!model.selectedExtraPIDs.contains(row.pid) &&
                                                   model.selectedExtraPIDs.count >= 4))
                                    }
                                }
                                Text("応答CAN ID: \(row.responseCANID ?? "不明") ・ 状態: \(row.latestStatus.rawValue)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text("対応bitmap: \(row.bitmapSupported ? "あり" : "未確認") ・ 実応答: \(row.successfulSamples)回 ・ 最新: \(row.latestValue.map { String(format: "%.2f", $0) } ?? "—") \(row.unit)")
                                    .font(.callout)
                                Text("実効: \(row.effectiveHz.map { String(format: "%.2f Hz", $0) } ?? "未計測") ・ 範囲: \(format(row.minimum))〜\(format(row.maximum)) ・ 長さ: \(row.dataBytes)バイト")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !row.formula.isEmpty {
                                    Text("換算: \(row.formula)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("未同定：RAWのみ保存、単位と意味は未確定")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                        if rows.isEmpty {
                            Text("まだ結果がありません。上の調査を開始してください。")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                AnalyzerCard("既存のHonda独自DIDと計算値", systemImage: "waveform.path.ecg") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("標準019Aの1回の応答からHV電圧・HV電流・HV電力を得ます。3件の独立PID要求ではありません。")
                            .font(.callout)
                        LabeledContent("HV電圧", value: model.hvVoltage.map { String(format: "%.1f V", $0) } ?? "未取得")
                        LabeledContent("HV電流", value: model.hvCurrent.map { String(format: "%.1f A", $0) } ?? "未取得")
                        LabeledContent("HV電力（V×A/1000）", value: model.hvPowerKW.map { String(format: "%.1f kW", $0) } ?? "未取得")
                        Divider()
                        Text("既知DID：過去の完全なPositive応答から取得候補になったものです。意味は未同定のままです。")
                            .font(.callout)
                        Text("完全Positive候補 \(model.driveCandidates.count)件")
                            .font(.headline)
                        ForEach(Array(model.driveCandidates.prefix(40))) { did in
                            HStack {
                                Text(did.label)
                                    .font(.caption.monospaced())
                                Spacer()
                                Text("CAN \(did.responseCanID ?? "不明") / \(did.payloadLength)B / 意味未同定")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if model.driveCandidates.count > 40 {
                            Text("残り \(model.driveCandidates.count - 40)件は走行解析画面で確認してください。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        let partial = model.positiveDids.filter { $0.status == .positivePartial }
                        if !partial.isEmpty {
                            Text("不完全応答 \(partial.count)件：末尾不足のため継続取得候補には含めません。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                AnalyzerCard("結果の共有", systemImage: "square.and.arrow.up") {
                    VStack(alignment: .leading, spacing: 12) {
                        if let url = model.latestPIDCSVURL {
                            ShareLink(item: url) {
                                Label("候補一覧CSVを共有", systemImage: "tablecells")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if let url = model.latestPIDJSONURL {
                            ShareLink(item: url) {
                                Label("換算式と状態をJSONで共有", systemImage: "curlybraces")
                            }
                            .buttonStyle(.bordered)
                        }
                        Text("完全なBLE RAW・ELMコマンド・イベントは同じセッション名のSQLiteに保存されます。ダッシュボードで記録終了後、セッション画面から共有してください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: AnalyzerDesign.contentMaxWidth)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func isReferencePID(_ pid: UInt8) -> Bool {
        [0x0C, 0x0D, 0x05, 0x5B, 0x9A].contains(pid)
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }
}
