import SwiftUI

struct SessionWorkflowPanel: View {
    @ObservedObject var model: AnalyzerViewModel
    let onOpenConnection: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("開始準備")
                            .font(.title2.bold())
                        Text("上から順に完了すると、解析ログを欠かさず残せます。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(readinessLabel, systemImage: readinessSymbol)
                        .font(.subheadline.weight(.semibold))
                }

                HStack(spacing: 10) {
                    WorkflowStep(
                        number: 1,
                        title: "BLE",
                        subtitle: model.ble.connectedDeviceName ?? "KW905接続",
                        complete: model.ble.state == "ready"
                    )
                    WorkflowConnector(complete: model.ble.state == "ready")
                    WorkflowStep(
                        number: 2,
                        title: "記録",
                        subtitle: "SQLite",
                        complete: model.isRecording
                    )
                    WorkflowConnector(complete: model.isRecording)
                    WorkflowStep(
                        number: 3,
                        title: "通信",
                        subtitle: "ELM初期化",
                        complete: model.elmInitialized
                    )
                    WorkflowConnector(complete: model.elmInitialized)
                    WorkflowStep(
                        number: 4,
                        title: "確認",
                        subtitle: "既知信号",
                        complete: model.knownSignalsValidated
                    )
                }

                Divider()

                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: nextActionSymbol)
                        .font(.title2)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("次にやること")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(nextActionTitle)
                            .font(.headline)
                        Text(nextActionDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let actionTitle = nextActionButtonTitle {
                        Button(actionTitle) {
                            performNextAction()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.isBusy || model.isDidScanning)
                    }
                }
            }
            .padding(6)
        }
    }

    private var readinessLabel: String {
        if model.ble.state != "ready" { return "未接続" }
        if !model.isRecording { return "記録待ち" }
        if !model.elmInitialized { return "通信準備中" }
        if !model.knownSignalsValidated { return "信号確認待ち" }
        return "準備完了"
    }

    private var readinessSymbol: String {
        model.knownSignalsValidated ? "checkmark.seal.fill" : "circle.dotted"
    }

    private var nextActionTitle: String {
        if model.ble.state != "ready" { return "KW905へ接続" }
        if !model.isRecording { return "セッション記録を開始" }
        if !model.elmInitialized { return "車両通信を初期化" }
        if !model.knownSignalsValidated { return "既知信号を1回確認" }
        return "準備完了。目的に応じてモードを選択"
    }

    private var nextActionDetail: String {
        if model.ble.state != "ready" {
            return "Bluetooth接続画面でKW905を選択します。"
        }
        if !model.isRecording {
            return "先に記録を始めると、ELM初期化からRAW証拠が残ります。"
        }
        if !model.elmInitialized {
            return "安全なAT初期化だけを実行し、CAN 29bit通信を準備します。"
        }
        if !model.knownSignalsValidated {
            return "RPM・車速・水温・SOC・HV電圧/電流が読めることを確認します。"
        }
        return "走行中はライブ監視、停車時だけDID探索を使います。"
    }

    private var nextActionSymbol: String {
        if model.ble.state != "ready" { return "antenna.radiowaves.left.and.right" }
        if !model.isRecording { return "record.circle" }
        if !model.elmInitialized { return "cable.connector" }
        if !model.knownSignalsValidated { return "checkmark.circle" }
        return "checkmark.seal.fill"
    }

    private var nextActionButtonTitle: String? {
        if model.ble.state != "ready" { return "接続画面" }
        if !model.isRecording { return "記録開始" }
        if !model.elmInitialized { return "通信初期化" }
        if !model.knownSignalsValidated { return "信号確認" }
        return nil
    }

    private func performNextAction() {
        if model.ble.state != "ready" {
            onOpenConnection()
        } else if !model.isRecording {
            model.startRecording()
        } else if !model.elmInitialized {
            model.initializeELM()
        } else if !model.knownSignalsValidated {
            model.readKnownSignals()
        }
    }
}

private struct WorkflowStep: View {
    let number: Int
    let title: String
    let subtitle: String
    let complete: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(complete ? Color.accentColor : Color.secondary.opacity(0.14))
                    .frame(width: 34, height: 34)
                if complete {
                    Image(systemName: "checkmark")
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.subheadline.bold())
                }
            }

            Text(title)
                .font(.caption.bold())
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 78)
    }
}

private struct WorkflowConnector: View {
    let complete: Bool

    var body: some View {
        Rectangle()
            .fill(complete ? Color.accentColor : Color.secondary.opacity(0.18))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 34)
    }
}

struct OperationModeCards: View {
    @ObservedObject var model: AnalyzerViewModel

    var body: some View {
        HStack(spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("走行中：ライブ監視", systemImage: "gauge.with.dots.needle.50percent")
                        .font(.headline)
                    Text("既知の標準信号だけを継続取得します。未知DID探索は行いません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if model.isLivePolling {
                        Button("ライブ取得停止", role: .destructive) {
                            model.stopLivePolling()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("ライブ取得開始") {
                            model.startLivePolling()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.ble.state != "ready" ||
                            !model.elmInitialized ||
                            model.isBusy ||
                            model.isDidScanning
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("停車中：DID探索", systemImage: "magnifyingglass.circle")
                        .font(.headline)
                    Text("Pレンジ・0 km/h確認後だけ、read-only UDS 0x22探索を実行します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Image(systemName: model.stationaryConfirmed ? "checkmark.shield.fill" : "shield")
                        Text(model.stationaryConfirmed ? "停車確認済み" : "左ペインで停車確認が必要")
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct VehicleSafetyBanner: View {
    @ObservedObject var model: AnalyzerViewModel

    var body: some View {
        if model.isDidScanPausedForSpeed {
            Label(
                "車速を検出したためDID探索を一時停止中。走行中は010Dだけ監視し、0 km/h安定後に自動再開します。",
                systemImage: "pause.circle.fill"
            )
            .font(.callout.weight(.semibold))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        } else if model.isDidScanning {
            Label(
                "停車中のread-only DID探索中。車速を検出するとDID送信を即停止します。",
                systemImage: "shield.checkered"
            )
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}


struct SessionExportPanel: View {
    @ObservedObject var model: AnalyzerViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("セッション終了・ログ共有", systemImage: "square.and.arrow.up")
                    .font(.headline)

                if model.isRecording {
                    if model.isLivePolling || model.isDidScanning || model.isBusy {
                        Text("取得処理を停止してからSQLite記録を終了してください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("取得が終わったら記録を正常終了し、その後SQLiteを共有できます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("SQLite記録を終了") {
                        model.stopRecording()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isLivePolling || model.isDidScanning || model.isBusy)
                } else if let url = model.recordingURL {
                    Text("記録は正常終了しています。Macでの詳細解析や共有用にSQLiteを渡せます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ShareLink(item: url) {
                        Label("直前のSQLiteを共有", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("記録を開始すると、ここに終了・共有操作が表示されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
