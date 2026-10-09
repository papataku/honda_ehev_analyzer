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

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        workflowStepViews
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        WorkflowStepRow(number: 1, title: "BLE", subtitle: model.ble.connectedDeviceName ?? "BLE ELM接続", complete: model.ble.state == "ready")
                        WorkflowStepRow(number: 2, title: "記録", subtitle: "SQLite", complete: model.isRecording)
                        WorkflowStepRow(number: 3, title: "通信", subtitle: "ELM初期化", complete: model.elmInitialized)
                        WorkflowStepRow(number: 4, title: "確認", subtitle: "既知信号", complete: model.knownSignalsValidated)
                    }
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
                        .disabled(model.isBusy || model.isDidScanning || model.isDriveCollecting || model.isLivePolling)
                    }
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var workflowStepViews: some View {
        WorkflowStep(
            number: 1,
            title: "BLE",
            subtitle: model.ble.connectedDeviceName ?? "BLE ELM接続",
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
        if model.ble.state != "ready" { return "BLE ELMデバイスへ接続" }
        if !model.isRecording { return "セッション記録を開始" }
        if !model.elmInitialized { return "車両通信を初期化" }
        if !model.knownSignalsValidated { return "既知信号を1回確認" }
        return "準備完了。目的に応じてモードを選択"
    }

    private var nextActionDetail: String {
        if model.ble.state != "ready" {
            return "Bluetooth接続画面でKW905またはM5CAN-Dialを選択します。"
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
        return "次は下の3つから目的を選んでください。モーター回転数を調べるなら「走行解析」です。"
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

private struct WorkflowStepRow: View {
    let number: Int
    let title: String
    let subtitle: String
    let complete: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(complete ? Color.accentColor : Color.secondary.opacity(0.14))
                    .frame(width: 30, height: 30)
                if complete {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.caption.bold())
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
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
    let onOpenDriving: () -> Void
    let onOpenDiscovery: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("何をしたいですか？")
                .font(.title2.bold())
            Text("目的を選ぶだけで進められます。信号の意味を調べたい場合は「走行解析」、新しい信号を探したい場合は「DID探索」です。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 12) {
                AnalyzerCard("1. 車両データを見る", systemImage: "gauge.with.dots.needle.50percent") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("RPM・車速・水温・SOC・HV電力をリアルタイム表示。未知DIDにはアクセスしません。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if model.isLivePolling {
                            StatusPill(text: "表示中", systemImage: "waveform.path.ecg", style: .good)
                            Text(String(format: "実効 %.1f req/s", model.liveEffectiveRequestRateHz))
                                .font(.caption.monospacedDigit())
                            Button("表示を停止", role: .destructive) {
                                model.stopLivePolling()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                model.startLivePolling()
                            } label: {
                                Label("ライブ表示を開始", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!ready || model.isDriveCollecting || model.isDidScanning || model.isBusy)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                AnalyzerCard("2. モーター信号を調べる", systemImage: "chart.xyaxis.line") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("走行中に既知のDIDを何度も記録し、モーター回転・発電機・トルクの候補を分析します。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if model.isDriveCollecting {
                            StatusPill(text: "収集中", systemImage: "record.circle.fill", style: .active)
                        }
                        Button {
                            onOpenDriving()
                        } label: {
                            Label("走行解析を開く", systemImage: "arrow.right.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                AnalyzerCard("3. 未知の信号を探す", systemImage: "magnifyingglass.circle") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("安全に停車しPレンジを確認してから、未調査のDIDを探します。信号待ちでは実施しません。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if model.isDidScanning {
                            StatusPill(
                                text: model.isDidScanPausedForSpeed ? "走行監視中" : "探索中",
                                systemImage: "magnifyingglass",
                                style: model.isDidScanPausedForSpeed ? .warning : .active
                            )
                        }
                        Button {
                            onOpenDiscovery()
                        } label: {
                            Label("DID探索を開く", systemImage: "arrow.right.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var ready: Bool {
        model.ble.state == "ready" && model.isRecording &&
        model.elmInitialized && model.knownSignalsValidated
    }
}

struct VehicleSafetyBanner: View {
    @ObservedObject var model: AnalyzerViewModel

    var body: some View {
        if model.isDidScanPausedForSpeed {
            Label(
                "車速検出で未知DID探索を停止中。走行中は発見済みPositive DIDと既知信号のみ収集します。0 km/hが安定し、Pを再確認したら探索を再開します。",
                systemImage: "pause.circle.fill"
            )
            .font(.callout.weight(.semibold))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        } else if model.isDidScanning {
            Label(
                "停車・P確認で未知DIDを探索中。車速監視で動きを検出すると未知DID要求を中断します。",
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
                    if model.isLivePolling || model.isDidScanning || model.isDriveCollecting || model.isBusy {
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
                    .disabled(model.isLivePolling || model.isDidScanning || model.isDriveCollecting || model.isBusy)
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
