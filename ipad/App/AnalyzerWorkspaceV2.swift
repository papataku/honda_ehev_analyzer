import SwiftUI
import Charts
import HondaAnalyzerCore

enum AnalyzerSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case driving
    case discovery
    case sessions
    case technical
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "ダッシュボード"
        case .driving: return "走行解析"
        case .discovery: return "DID探索"
        case .sessions: return "セッション"
        case .technical: return "技術情報"
        case .settings: return "設定"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.50percent"
        case .driving: return "chart.xyaxis.line"
        case .discovery: return "magnifyingglass.circle"
        case .sessions: return "externaldrive.fill"
        case .technical: return "terminal"
        case .settings: return "gearshape"
        }
    }
}

struct FinalAnalyzerWorkspace: View {
    @ObservedObject var model: AnalyzerViewModel
    let onOpenConnection: () -> Void

    @State private var selection: AnalyzerSection? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(AnalyzerSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .safeAreaInset(edge: .bottom) {
                connectionFooter
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            .navigationTitle("Honda Analyzer")
            .navigationSplitViewColumnWidth(
                min: 220,
                ideal: AnalyzerDesign.sidebarWidth,
                max: 310
            )
        } detail: {
            Group {
                switch selection ?? .dashboard {
                case .dashboard:
                    DashboardPage(model: model, onOpenConnection: onOpenConnection)
                case .driving:
                    DrivingAnalysisPage(model: model)
                case .discovery:
                    DiscoveryPage(model: model)
                case .sessions:
                    SessionsPage(model: model) { url in
                        model.analyzeDriveRecording(url)
                        selection = .driving
                    }
                case .technical:
                    TechnicalPage(model: model)
                case .settings:
                    SettingsPage(model: model, onOpenConnection: onOpenConnection)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var connectionFooter: some View {
        AnalyzerCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(model.ble.state == "ready" ? .green : .secondary)
                        .frame(width: 9, height: 9)
                    Text(model.ble.connectedDeviceName ?? "KW905")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                }

                Text(model.ble.state == "ready" ? "接続済み" : model.ble.state)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    onOpenConnection()
                } label: {
                    Label("Bluetooth接続", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isDidScanning)
            }
        }
    }
}

private struct DashboardPage: View {
    @ObservedObject var model: AnalyzerViewModel
    let onOpenConnection: () -> Void

    private let metricColumns = [
        GridItem(.adaptive(minimum: 180, maximum: 300), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AnalyzerDesign.pageSpacing) {
                HStack(alignment: .top) {
                    PageHeader(
                        title: "ダッシュボード",
                        subtitle: "接続・記録・通信状態と主要e:HEV信号",
                        systemImage: "gauge.with.dots.needle.50percent"
                    )

                    Spacer()

                    HStack(spacing: 8) {
                        if model.isRecording {
                            StatusPill(text: "REC", systemImage: "record.circle.fill", style: .active)
                        }
                        if model.isLivePolling {
                            StatusPill(text: "LIVE", systemImage: "waveform.path.ecg", style: .good)
                        }
                        if model.isDriveCollecting {
                            StatusPill(text: "DRIVE", systemImage: "chart.xyaxis.line", style: .active)
                        }
                        if model.isDidScanPausedForSpeed {
                            StatusPill(text: "DID PAUSE", systemImage: "pause.circle.fill", style: .warning)
                        } else if model.isDidScanning {
                            StatusPill(text: "DID", systemImage: "magnifyingglass", style: .active)
                        }
                    }
                }

                SessionWorkflowPanel(
                    model: model,
                    onOpenConnection: onOpenConnection
                )

                VehicleSafetyBanner(model: model)

                if model.knownSignalsValidated {
                    OperationModeCards(model: model)
                }

                LazyVGrid(columns: metricColumns, spacing: 12) {
                    DashboardMetric(title: "ENGINE RPM", value: model.rpm.map { String(format: "%.0f", $0) } ?? "--", unit: "rpm", symbol: "gauge.open.with.lines.needle.67percent.and.arrowtriangle")
                    DashboardMetric(title: "SPEED", value: model.speedKmh.map(String.init) ?? "--", unit: "km/h", symbol: "speedometer")
                    DashboardMetric(title: "COOLANT", value: model.coolantC.map(String.init) ?? "--", unit: "°C", symbol: "thermometer.medium")
                    DashboardMetric(title: "HV SOC", value: model.socPercent.map { String(format: "%.1f", $0) } ?? "--", unit: "%", symbol: "battery.50percent")
                    DashboardMetric(title: "HV VOLTAGE", value: model.hvVoltage.map { String(format: "%.1f", $0) } ?? "--", unit: "V", symbol: "bolt.fill")
                    DashboardMetric(title: "HV CURRENT", value: model.hvCurrent.map { String(format: "%.1f", $0) } ?? "--", unit: "A", symbol: "arrow.up.arrow.down")
                    DashboardMetric(title: "HV POWER", value: model.hvPowerKW.map { String(format: "%.1f", $0) } ?? "--", unit: "kW", symbol: "waveform.path.ecg")
                }

                if model.liveSamples.count >= 2 {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300), spacing: 12)],
                        spacing: 12
                    ) {
                        LiveTrendCard(
                            title: "RPM trend",
                            unit: "rpm",
                            samples: model.liveSamples,
                            value: { $0.rpm }
                        )

                        LiveTrendCard(
                            title: "HV Power trend",
                            unit: "kW",
                            samples: model.liveSamples,
                            value: { $0.hvPowerKW }
                        )
                    }
                }

                if model.isRecording {
                    AnalyzerCard("イベントマーカー", systemImage: "bookmark.fill") {
                        FlowLayout(spacing: 8) {
                            ForEach(["STOP", "EV", "ENGINE ON", "ACCEL", "CRUISE", "REGEN"], id: \.self) { marker in
                                Button(marker) {
                                    model.addMarker(marker)
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.isDidScanning)
                            }
                        }
                    }
                }

                SessionExportPanel(model: model)
            }
            .frame(maxWidth: AnalyzerDesign.contentMaxWidth)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct DiscoveryPage: View {
    @ObservedObject var model: AnalyzerViewModel
    @State private var showFullScanConfirmation = false

    private var selectedObservedEcu: Bool {
        model.observedEcus.contains { $0.source == normalizedSource(model.didScanEcu) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AnalyzerDesign.pageSpacing) {
                PageHeader(
                    title: "DID探索",
                    subtitle: "停車中のみ。read-only UDS 0x22で未知信号を探索",
                    systemImage: "magnifyingglass.circle"
                )

                VehicleSafetyBanner(model: model)

                AnalyzerCard("安全条件", systemImage: "shield.checkered") {
                    VStack(alignment: .leading, spacing: 12) {
                        SafetyRow(
                            title: "SQLite記録",
                            detail: "RAW証拠を保存中",
                            complete: model.isRecording
                        )
                        SafetyRow(
                            title: "ELM初期化",
                            detail: "現在の記録内で完了",
                            complete: model.elmInitialized
                        )
                        SafetyRow(
                            title: "既知信号確認",
                            detail: "RPM/車速/水温/SOC/HV 9Aをdecode済み",
                            complete: model.knownSignalsValidated
                        )

                        Toggle(
                            "1. 完全停止・Pレンジを確認",
                            isOn: $model.stationaryConfirmed
                        )
                        .font(.headline)
                    }
                }

                AnalyzerCard("ECU選択", systemImage: "cpu") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("2. 安全な既知要求でECU候補を確認") {
                            model.runSafeEcuCensus()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.ble.state != "ready" ||
                            !model.isRecording ||
                            !model.stationaryConfirmed ||
                            !model.elmInitialized ||
                            !model.knownSignalsValidated ||
                            model.isBusy ||
                            model.isLivePolling ||
                            model.isDriveCollecting ||
                            model.isDidScanning
                        )

                        if model.observedEcus.isEmpty {
                            Text("まだECU候補を確認していません。")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("3. 実際に応答したECU sourceを選択")
                                .font(.subheadline.weight(.semibold))

                            FlowLayout(spacing: 8) {
                                ForEach(model.observedEcus) { ecu in
                                    Button {
                                        model.selectDidEcu(ecu.source)
                                    } label: {
                                        HStack(spacing: 6) {
                                            if normalizedSource(model.didScanEcu) == ecu.source {
                                                Image(systemName: "checkmark.circle.fill")
                                            }
                                            Text("source \(ecu.source)")
                                            Text(ecu.responseCanID)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }

                            Text("ECU名や役割はCAN IDだけでは決めません。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                AnalyzerCard("探索", systemImage: "scope") {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.isDidScanning {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.didScanCurrent)
                                        .font(.headline)
                                    Text("Positive \(model.didPositiveCount) / partial \(model.didPartialCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("安全に停止", role: .destructive) {
                                    model.stopDidScan()
                                }
                                .buttonStyle(.bordered)
                            }

                            ProgressView(value: model.didScanProgress)
                        } else {
                            HStack(spacing: 12) {
                                Button("4A. 2000–20FF 短時間探索") {
                                    model.startDidScan2000Range()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!canStartScan)

                                Button("4B. 0000–FFFF 全範囲") {
                                    showFullScanConfirmation = true
                                }
                                .buttonStyle(.bordered)
                                .disabled(!canStartScan)
                            }

                            Text("全範囲は2000帯→sector→page代表→反応page→未探索全埋めの順で進み、過去SQLiteからresumeします。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        DisclosureGroup("探索設定") {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("探索速度", selection: $model.didScanRateHz) {
                                    Text("5 req/s").tag(5.0)
                                    Text("10 req/s").tag(10.0)
                                    Text("20 req/s").tag(20.0)
                                    Text("50 req/s").tag(50.0)
                                    Text("100 req/s").tag(100.0)
                                }
                                .pickerStyle(.menu)
                                .disabled(model.didScanUnthrottled)

                                Toggle(
                                    "アプリ側のレート制限なし",
                                    isOn: $model.didScanUnthrottled
                                )

                                if model.isDidScanning {
                                    LabeledContent(
                                        "実効DIDレート",
                                        value: String(
                                            format: "%.1f DID/s",
                                            model.didScanEffectiveRateHz
                                        )
                                    )
                                }

                                Toggle(
                                    "高性能ELM互換機向け短時間タイムアウト",
                                    isOn: $model.aggressiveElmTimingEnabled
                                )

                                Text("高性能モードはATSTを短くします。自作アダプタや十分に検証したECUでのみ使用してください。応答の遅いECUではfalse timeoutの可能性があります。")
                                    .font(.caption)
                                    .foregroundStyle(.orange)

                                Toggle(
                                    "走行中は既知DID収集、0 km/h安定かつP再確認後に探索再開",
                                    isOn: $model.autoResumeDidScanAfterStop
                                )

                                DisclosureGroup("高度な設定：ECU source手入力") {
                                    TextField("01", text: $model.didScanEcu)
                                        .textInputAutocapitalization(.characters)
                                        .autocorrectionDisabled()
                                        .textFieldStyle(.roundedBorder)

                                    Text("未観測sourceでは探索開始できません。通常は上の候補から選択してください。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                }

                if model.isDidScanning || !model.positiveDids.isEmpty {
                    AnalyzerCard("Positive DID", systemImage: "checkmark.circle") {
                        if model.positiveDids.isEmpty {
                            HStack {
                                ProgressView()
                                Text("探索中…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            VStack(spacing: 8) {
                                ForEach(Array(model.positiveDids.enumerated()), id: \.offset) { _, item in
                                    HStack {
                                        Text("ECU \(item.ecu)")
                                            .frame(width: 70, alignment: .leading)
                                        Text(String(format: "%04X", item.did))
                                            .font(.body.monospaced())
                                            .frame(width: 65, alignment: .leading)
                                        Text(item.status == .positivePartial ? "partial" : "complete")
                                            .foregroundStyle(item.status == .positivePartial ? .orange : .green)
                                        Spacer()
                                        Text("\(item.payload.count) B")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: AnalyzerDesign.contentMaxWidth)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            "全範囲DID探索を開始しますか？",
            isPresented: $showFullScanConfirmation,
            titleVisibility: .visible
        ) {
            Button("停車中に全範囲探索を開始") {
                model.longDidScanAcknowledged = true
                model.startAdaptiveFullDidScan()
                model.longDidScanAcknowledged = false
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("0000–FFFFは数時間規模です。走行検出中はDID送信を止め、0 km/h安定後に再開します。結果はSQLiteへ逐次保存されます。")
        }
    }

    private var canStartScan: Bool {
        model.ble.state == "ready" &&
        model.isRecording &&
        model.stationaryConfirmed &&
        model.elmInitialized &&
        model.knownSignalsValidated &&
        !model.observedEcus.isEmpty &&
        selectedObservedEcu &&
        !model.isBusy &&
        !model.isLivePolling &&
        !model.isDriveCollecting
    }

    private func normalizedSource(_ source: String) -> String? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard text.count == 2, Int(text, radix: 16) != nil else { return nil }
        return text
    }
}

private struct SessionsPage: View {
    @ObservedObject var model: AnalyzerViewModel
    let onAnalyze: (URL) -> Void
    @State private var files: [SessionFileInfo] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AnalyzerDesign.pageSpacing) {
                HStack {
                    PageHeader(
                        title: "セッション",
                        subtitle: "iPadに保存されたSQLiteログを確認・共有",
                        systemImage: "externaldrive.fill"
                    )
                    Spacer()
                    Button {
                        reload()
                    } label: {
                        Label("更新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                if model.isRecording {
                    AnalyzerCard("記録中", systemImage: "record.circle.fill") {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.recordingFile)
                                    .font(.headline)
                                Text("現在のセッションは終了後に共有できます。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusPill(text: "REC", systemImage: "record.circle.fill", style: .active)
                        }
                    }
                }

                if files.isEmpty {
                    ContentUnavailableView(
                        "保存済みセッションなし",
                        systemImage: "externaldrive",
                        description: Text("SQLite記録を終了するとここに表示されます。")
                    )
                    .frame(minHeight: 320)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(files) { file in
                            AnalyzerCard {
                                HStack(spacing: 14) {
                                    Image(systemName: "cylinder.split.1x2")
                                        .font(.title2)
                                        .foregroundStyle(.tint)
                                        .frame(width: 34)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.displayName)
                                            .font(.headline)
                                        Text(file.dateText)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Text(file.sizeText)
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.secondary)

                                    Button {
                                        onAnalyze(file.url)
                                    } label: {
                                        Label("信号解析", systemImage: "chart.xyaxis.line")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(model.isDriveCollecting || model.isDidScanning || model.isLivePolling)
                                    ShareLink(item: file.url) {
                                        Label("共有", systemImage: "square.and.arrow.up")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: AnalyzerDesign.contentMaxWidth)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .task { reload() }
        .refreshable { reload() }
        .onChange(of: model.isRecording) { _, _ in
            reload()
        }
    }

    private func reload() {
        files = SessionFileInfo.load().filter { file in
            guard model.isRecording, let active = model.recordingURL else { return true }
            return file.url != active
        }
    }
}

private struct TechnicalPage: View {
    @ObservedObject var model: AnalyzerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AnalyzerDesign.pageSpacing) {
                PageHeader(
                    title: "技術情報",
                    subtitle: "ELM transcript・GATT・診断状態",
                    systemImage: "terminal"
                )

                AnalyzerCard("GATT", systemImage: "antenna.radiowaves.left.and.right") {
                    if model.ble.gattInventory.isEmpty {
                        Text("GATT情報はまだありません。")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(model.ble.gattInventory.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(item.serviceUUID) / \(item.uuid)")
                                        .font(.body.monospaced())
                                    Text(item.properties.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                AnalyzerCard("ELM transcript", systemImage: "terminal") {
                    if model.transcript.isEmpty {
                        Text("まだ通信ログはありません。")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(model.transcript.suffix(120).joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                AnalyzerCard("現在の状態", systemImage: "info.circle") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("BLE", value: model.ble.state)
                        LabeledContent("ELM初期化", value: model.elmInitialized ? "完了" : "未完了")
                        LabeledContent("既知信号", value: model.knownSignalsValidated ? "確認済み" : "未確認")
                        LabeledContent("記録", value: model.isRecording ? "記録中" : "停止")
                        LabeledContent("DID", value: model.didScanCurrent)
                        LabeledContent(
                            "ライブ実効レート",
                            value: String(format: "%.1f req/s", model.liveEffectiveRequestRateHz)
                        )
                        LabeledContent(
                            "DID実効レート",
                            value: String(format: "%.1f DID/s", model.didScanEffectiveRateHz)
                        )
                        Text(model.statusMessage)
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
}

private struct SettingsPage: View {
    @ObservedObject var model: AnalyzerViewModel
    let onOpenConnection: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AnalyzerDesign.pageSpacing) {
                PageHeader(
                    title: "設定",
                    subtitle: "安全動作と探索設定",
                    systemImage: "gearshape"
                )

                AnalyzerCard("Bluetooth", systemImage: "antenna.radiowaves.left.and.right") {
                    LabeledContent(
                        "接続先",
                        value: model.ble.connectedDeviceName ?? "未接続"
                    )
                    Button("Bluetooth接続画面を開く") {
                        onOpenConnection()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isDidScanning)
                }

                AnalyzerCard("アダプタ性能", systemImage: "bolt.horizontal.circle") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("自作ELM327互換機の性能に合わせて、アプリ側の待ち時間を引き上げられます。コマンド自体は安全のため1要求ずつ直列送信します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("ライブ監視 目標req/s", selection: $model.livePollingRequestRateHz) {
                            Text("5").tag(5.0)
                            Text("10").tag(10.0)
                            Text("20").tag(20.0)
                            Text("50").tag(50.0)
                            Text("100").tag(100.0)
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.livePollingUnthrottled || model.isLivePolling)

                        Toggle(
                            "ライブ監視：アプリ側レート制限なし",
                            isOn: $model.livePollingUnthrottled
                        )
                        .disabled(model.isLivePolling)

                        LabeledContent(
                            "ライブ実効レート",
                            value: String(format: "%.1f req/s", model.liveEffectiveRequestRateHz)
                        )

                        Divider()

                        Picker("DID探索 目標req/s", selection: $model.didScanRateHz) {
                            Text("5").tag(5.0)
                            Text("10").tag(10.0)
                            Text("20").tag(20.0)
                            Text("50").tag(50.0)
                            Text("100").tag(100.0)
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.didScanUnthrottled || model.isDidScanning)

                        Toggle(
                            "DID探索：アプリ側レート制限なし",
                            isOn: $model.didScanUnthrottled
                        )
                        .disabled(model.isDidScanning)

                        LabeledContent(
                            "DID実効レート",
                            value: String(format: "%.1f DID/s", model.didScanEffectiveRateHz)
                        )

                        Toggle(
                            "高性能ELM互換機向け短時間タイムアウト",
                            isOn: $model.aggressiveElmTimingEnabled
                        )
                        .disabled(model.isDidScanning)

                        Text("高性能モードでは20Hz以上でATSTを段階的に短縮します。false timeoutを避けるため、まず20 req/sから実測して上げてください。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                AnalyzerCard("DID探索の安全動作", systemImage: "magnifyingglass.circle") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(
                            "走行検出時は一時停止し、0 km/h安定後に自動再開",
                            isOn: $model.autoResumeDidScanAfterStop
                        )

                        Text("一時停止中は010Dだけを確認し、未知DID要求は送りません。0 km/hを3回連続確認して再開します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                AnalyzerCard("安全方針", systemImage: "shield.checkered") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("未知自動探索はUDS 0x22のみ", systemImage: "checkmark.circle.fill")
                        Label("走行中はDID探索を送信しない", systemImage: "checkmark.circle.fill")
                        Label("RAW証拠をSQLiteへ保存", systemImage: "checkmark.circle.fill")
                        Label("ECU役割はCAN IDだけで決めない", systemImage: "checkmark.circle.fill")
                    }
                    .font(.subheadline)
                }
            }
            .frame(maxWidth: AnalyzerDesign.contentMaxWidth)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct DashboardMetric: View {
    let title: String
    let value: String
    let unit: String
    let symbol: String

    var body: some View {
        AnalyzerCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(value)
                            .font(.system(.title, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                        Text(unit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value) \(unit)")
    }
}

private struct LiveTrendCard: View {
    let title: String
    let unit: String
    let samples: [LiveSignalSample]
    let value: (LiveSignalSample) -> Double?

    var body: some View {
        AnalyzerCard(title, systemImage: "chart.xyaxis.line") {
            Chart {
                ForEach(samples) { sample in
                    if let y = value(sample) {
                        LineMark(
                            x: .value("Time", sample.date),
                            y: .value(unit, y)
                        )
                        .interpolationMethod(.catmullRom)
                    }
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 150)
        }
    }
}

private struct SafetyRow: View {
    let title: String
    let detail: String
    let complete: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(complete ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct SessionFileInfo: Identifiable {
    let url: URL
    let modified: Date
    let size: Int64

    var id: URL { url }
    var displayName: String { url.deletingPathExtension().lastPathComponent }
    var dateText: String {
        modified.formatted(date: .abbreviated, time: .shortened)
    }
    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func load() -> [SessionFileInfo] {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return [] }

        let folder = documents.appendingPathComponent(
            "HondaAnalyzerSessions",
            isDirectory: true
        )

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { $0.pathExtension.lowercased() == "sqlite3" }
            .compactMap { url in
                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                )
                return SessionFileInfo(
                    url: url,
                    modified: values?.contentModificationDate ?? .distantPast,
                    size: Int64(values?.fileSize ?? 0)
                )
            }
            .sorted { $0.modified > $1.modified }
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), spacing: spacing)],
            alignment: .leading,
            spacing: spacing
        ) {
            content
        }
    }
}
