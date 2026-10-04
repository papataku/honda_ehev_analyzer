import SwiftUI
import HondaAnalyzerCore

struct ContentView: View {
    @StateObject private var model = AnalyzerViewModel()
    @State private var showConnectionScreen = true

    var body: some View {
        Group {
            if showConnectionScreen || model.ble.state != "ready" {
                BLEConnectionView(model: model) {
                    showConnectionScreen = false
                }
            } else {
                AnalyzerWorkspace(model: model) {
                    showConnectionScreen = true
                }
            }
        }
    }
}

private struct BLEConnectionView: View {
    @ObservedObject var model: AnalyzerViewModel
    let onContinue: () -> Void

    @State private var hideUnnamed = true
    @State private var nameFilter = ""

    private var filteredDevices: [BLEDevice] {
        model.ble.devices
            .filter { device in
                let name = normalizedName(device.name)
                if hideUnnamed && name == nil { return false }
                if !nameFilter.isEmpty {
                    guard let name else { return false }
                    return name.localizedCaseInsensitiveContains(nameFilter)
                }
                return true
            }
            .sorted { lhs, rhs in
                let left = normalizedName(lhs.name)
                let right = normalizedName(rhs.name)

                switch (left, right) {
                case let (l?, r?):
                    let order = l.localizedStandardCompare(r)
                    if order != .orderedSame { return order == .orderedAscending }
                    return lhs.rssi > rhs.rssi
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.rssi > rhs.rssi
                }
            }
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section("Bluetooth接続") {
                    LabeledContent("状態", value: stateLabel)

                    if model.ble.state == "ready" {
                        LabeledContent(
                            "接続先",
                            value: model.ble.connectedDeviceName ?? "名称不明"
                        )
                        if let notify = model.ble.selectedNotifyUUID {
                            LabeledContent("Notify", value: notify)
                        }
                        if let write = model.ble.selectedWriteUUID {
                            LabeledContent("Write", value: write)
                        }

                        Button {
                            onContinue()
                        } label: {
                            Label("解析画面へ", systemImage: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button("切断", role: .destructive) {
                            model.ble.disconnect()
                        }
                    } else {
                        Button {
                            toggleScan()
                        } label: {
                            if model.ble.state == "scanning" {
                                Label("スキャン停止", systemImage: "stop.circle")
                            } else {
                                Label("5秒スキャン", systemImage: "dot.radiowaves.left.and.right")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.isLivePolling || model.isDidScanning)
                    }
                }

                Section("表示フィルタ") {
                    Toggle("名前なしを除外", isOn: $hideUnnamed)

                    TextField("名前で絞り込み", text: $nameFilter)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    LabeledContent("検出", value: "\(model.ble.devices.count) 台")
                    LabeledContent("表示", value: "\(filteredDevices.count) 台")
                }

                Section("使い方") {
                    Text("KW905は名前付きBLEデバイスとして見つかる前提です。通常は「名前なしを除外」をONのまま使用してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("デバイスを選ぶとGATT探索まで進み、readyになれば解析画面へ自動で移動します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Honda Analyzer")
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 360)
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bluetoothデバイス")
                            .font(.largeTitle.bold())
                        Text("接続するKW905を選択")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.ble.state == "scanning" {
                        ProgressView()
                        Text("スキャン中")
                            .foregroundStyle(.secondary)
                    }
                }

                if filteredDevices.isEmpty {
                    ContentUnavailableView {
                        Label(
                            model.ble.state == "scanning" ? "検索中…" : "デバイスがありません",
                            systemImage: "antenna.radiowaves.left.and.right.slash"
                        )
                    } description: {
                        if hideUnnamed {
                            Text("名前付きデバイスだけ表示しています。必要なら左の「名前なしを除外」をOFFにしてください。")
                        } else {
                            Text("左の「5秒スキャン」を押してBLEデバイスを検索してください。")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredDevices) { device in
                                Button {
                                    connect(device)
                                } label: {
                                    HStack(spacing: 16) {
                                        Image(systemName: "dot.radiowaves.left.and.right")
                                            .font(.title2)
                                            .frame(width: 36)

                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(normalizedName(device.name) ?? "名称不明")
                                                .font(.headline)
                                            Text(device.id.uuidString)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        VStack(alignment: .trailing, spacing: 4) {
                                            Text("RSSI \(device.rssi)")
                                                .font(.subheadline.monospacedDigit())
                                            Text(signalDescription(device.rssi))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(16)
                                    .contentShape(Rectangle())
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    "\(normalizedName(device.name) ?? "名称不明")、RSSI \(device.rssi)、Bluetoothデバイス"
                                )
                                .accessibilityHint("ダブルタップして接続します")
                                .disabled(model.ble.state == "connecting" || model.ble.state == "discovering-gatt")
                            }
                        }
                    }
                }

                if model.ble.state == "connecting" || model.ble.state == "discovering-gatt" {
                    HStack {
                        ProgressView()
                        Text(model.ble.state == "connecting" ? "接続中…" : "GATT確認中…")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            .padding(22)
        }
        .onChange(of: model.ble.state) { _, newValue in
            if newValue == "ready" {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if model.ble.state == "ready" {
                        onContinue()
                    }
                }
            }
        }
    }

    private var stateLabel: String {
        switch model.ble.state {
        case "idle": return "待機"
        case "scanning": return "スキャン中"
        case "connecting": return "接続中"
        case "discovering-gatt": return "GATT確認中"
        case "ready": return "接続完了"
        case "disconnected": return "切断"
        case "connect-failed": return "接続失敗"
        case "gatt-error": return "GATTエラー"
        case "bluetooth-unavailable": return "Bluetooth利用不可"
        default: return model.ble.state
        }
    }

    private func normalizedName(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func signalDescription(_ rssi: Int) -> String {
        if rssi >= -55 { return "強い" }
        if rssi >= -70 { return "良好" }
        if rssi >= -85 { return "弱い" }
        return "かなり弱い"
    }

    private func toggleScan() {
        if model.ble.state == "scanning" {
            model.ble.stopScan()
            return
        }

        model.ble.startScan()
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                if model.ble.state == "scanning" {
                    model.ble.stopScan()
                }
            }
        }
    }

    private func connect(_ device: BLEDevice) {
        do {
            try model.ble.connect(to: device.id)
        } catch {
            model.statusMessage = "BLE接続開始失敗: \(error.localizedDescription)"
        }
    }
}

private struct AnalyzerWorkspace: View {
    @ObservedObject var model: AnalyzerViewModel
    let onOpenConnection: () -> Void
    @State private var showFullScanConfirmation = false

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 320), spacing: 12)
    ]
    private let markers = ["STOP", "EV", "ENGINE ON", "ACCEL", "CRUISE", "REGEN"]

    var body: some View {
        NavigationSplitView {
            List {
                Section("接続") {
                    HStack {
                        Circle()
                            .fill(model.ble.state == "ready" ? .green : .secondary)
                            .frame(width: 9, height: 9)
                        Text(model.ble.connectedDeviceName ?? "KW905")
                        Spacer()
                        Text(model.ble.state)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        onOpenConnection()
                    } label: {
                        Label("Bluetooth接続画面", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(model.isDidScanning)
                }

                Section("記録") {
                    if model.isRecording {
                        Button("記録終了") { model.stopRecording() }
                            .disabled(model.isDidScanning)
                        Text(model.recordingFile)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("SQLite記録開始") { model.startRecording() }
                            .disabled(model.ble.state != "ready" || model.isDidScanning)
                        if let url = model.recordingURL {
                            ShareLink(item: url) {
                                Label("直前のSQLiteを共有", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }

                Section("詳細操作") {
                    DisclosureGroup("通信・ライブ取得") {
                        Button("ELM初期化を再実行") { model.initializeELM() }
                            .disabled(model.ble.state != "ready" || model.isBusy || model.isLivePolling || model.isDidScanning)
                        Button("既知信号を1回取得") { model.readKnownSignals() }
                            .disabled(model.ble.state != "ready" || model.isBusy || model.isLivePolling || model.isDidScanning)

                        if model.isLivePolling {
                            Button("ライブ取得停止", role: .destructive) { model.stopLivePolling() }
                        } else {
                            Button("既知信号ライブ取得開始") { model.startLivePolling() }
                                .disabled(model.ble.state != "ready" || model.isBusy || model.isDidScanning)
                        }
                    }
                }

                Section("DID探索（停車のみ）") {
                    Toggle("1. 完全停止・Pレンジを確認", isOn: $model.stationaryConfirmed)

                    Button("2. 安全な既知要求でECU候補を確認") {
                        model.runSafeEcuCensus()
                    }
                    .disabled(
                        model.ble.state != "ready" ||
                        !model.isRecording ||
                        !model.stationaryConfirmed ||
                        !model.elmInitialized ||
                        !model.knownSignalsValidated ||
                        model.isBusy ||
                        model.isLivePolling ||
                        model.isDidScanning
                    )

                    if !model.observedEcus.isEmpty {
                        Text("3. 対象ECUを選択")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        ForEach(model.observedEcus) { ecu in
                            Button {
                                model.selectDidEcu(ecu.source)
                            } label: {
                                HStack {
                                    Text("ECU source \(ecu.source)")
                                    Spacer()
                                    Text(ecu.responseCanID)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("ECU名/役割は未確定です")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("ECU source")
                        TextField("01", text: $model.didScanEcu)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }

                    DisclosureGroup("探索設定") {
                        Picker("探索速度", selection: $model.didScanRateHz) {
                            Text("2 req/s").tag(2.0)
                            Text("5 req/s").tag(5.0)
                            Text("8 req/s").tag(8.0)
                            Text("10 req/s").tag(10.0)
                        }

                        Toggle(
                            "走行検出時は一時停止し、0 km/h安定後に自動再開",
                            isOn: $model.autoResumeDidScanAfterStop
                        )

                        Text("走行中は010Dだけ監視し、DID要求は送信しません。0 km/hを3回連続確認してから再開します。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text("短時間確認: 2000–20FF / 全範囲: adaptive 0000–FFFF")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if model.isDidScanning {
                        Button("探索を安全に停止", role: .destructive) {
                            model.stopDidScan()
                        }
                    } else {
                        Button("4A. 短時間 2000–20FF 探索 / 再開") {
                            model.startDidScan2000Range()
                        }
                        .disabled(
                            model.ble.state != "ready" ||
                            !model.isRecording ||
                            !model.stationaryConfirmed ||
                            !model.elmInitialized ||
                            !model.knownSignalsValidated ||
                            model.observedEcus.isEmpty ||
                            model.isBusy ||
                            model.isLivePolling
                        )

                        Button("4B. 全範囲 0000–FFFF 探索 / 再開") {
                            showFullScanConfirmation = true
                        }
                        .disabled(
                            model.ble.state != "ready" ||
                            !model.isRecording ||
                            !model.stationaryConfirmed ||
                            model.observedEcus.isEmpty ||
                            model.isBusy ||
                            model.isLivePolling
                        )

                        Text("順序: 2000帯 → 16領域先頭 → 0x100ページ代表 → 反応ページ深掘り → 未探索全埋め。過去のiPad SQLiteもresumeに使用します。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: model.didScanProgress)
                    Text(model.didScanCurrent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Positive \(model.didPositiveCount) / partial \(model.didPartialCount)")
                        .font(.caption)
                }

                Section("状態") {
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Honda Analyzer")
            .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Honda Analyzer")
                                .font(.largeTitle.bold())
                            Text("RP8 e:HEV / evidence-first vehicle analysis")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isRecording {
                            Label("REC", systemImage: "record.circle.fill")
                        }
                        if model.isLivePolling {
                            Label("LIVE", systemImage: "waveform.path.ecg")
                        }
                        if model.isDidScanPausedForSpeed {
                            Label("DID PAUSE", systemImage: "pause.circle.fill")
                        } else if model.isDidScanning {
                            Label("DID", systemImage: "magnifyingglass")
                        }
                        if model.isBusy { ProgressView() }
                    }

                    SessionWorkflowPanel(
                        model: model,
                        onOpenConnection: onOpenConnection
                    )

                    VehicleSafetyBanner(model: model)

                    if model.knownSignalsValidated {
                        OperationModeCards(model: model)
                    }

                    LazyVGrid(columns: columns, spacing: 12) {
                        MetricCard(title: "ENGINE RPM", value: model.rpm.map { String(format: "%.0f", $0) } ?? "--", unit: "rpm")
                        MetricCard(title: "SPEED", value: model.speedKmh.map(String.init) ?? "--", unit: "km/h")
                        MetricCard(title: "COOLANT", value: model.coolantC.map(String.init) ?? "--", unit: "°C")
                        MetricCard(title: "HV SOC", value: model.socPercent.map { String(format: "%.1f", $0) } ?? "--", unit: "%")
                        MetricCard(title: "HV VOLTAGE", value: model.hvVoltage.map { String(format: "%.1f", $0) } ?? "--", unit: "V")
                        MetricCard(title: "HV CURRENT", value: model.hvCurrent.map { String(format: "%.1f", $0) } ?? "--", unit: "A")
                        MetricCard(title: "HV POWER", value: model.hvPowerKW.map { String(format: "%.1f", $0) } ?? "--", unit: "kW")
                    }

                    GroupBox("Drive markers") {
                        HStack {
                            ForEach(markers, id: \.self) { marker in
                                Button(marker) { model.addMarker(marker) }
                                    .disabled(!model.isRecording || model.isDidScanning)
                            }
                        }
                    }

                    GroupBox("Positive DID inventory") {
                        if model.positiveDids.isEmpty {
                            Text("まだPositive DIDは保存されていません")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(model.positiveDids.enumerated()), id: \.offset) { _, item in
                                    HStack {
                                        Text("ECU \(item.ecu)")
                                            .frame(width: 70, alignment: .leading)
                                        Text(String(format: "%04X", item.did))
                                            .font(.system(.body, design: .monospaced))
                                            .frame(width: 60, alignment: .leading)
                                        Text(item.status == .positivePartial ? "部分" : "完全")
                                            .frame(width: 50, alignment: .leading)
                                        Text(item.responseCanID ?? "—")
                                            .font(.system(.caption, design: .monospaced))
                                        Spacer()
                                        Text("\(item.payload.count) B")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    GroupBox("ELM transcript") {
                        Text(model.transcript.suffix(40).joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("GATT") {
                        VStack(alignment: .leading) {
                            ForEach(Array(model.ble.gattInventory.enumerated()), id: \.offset) { _, item in
                                Text("\(item.serviceUUID) / \(item.uuid) / \(item.properties.joined(separator: ", "))")
                                    .font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
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
            Text("0000–FFFFは数時間規模です。走行を検出するとDID送信は一時停止し、0 km/h安定後に再開します。結果はSQLiteへ逐次保存され、別日に続きから再開できます。")
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(value)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value) \(unit)")
    }
}
