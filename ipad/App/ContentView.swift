import SwiftUI
import UIKit
import HondaAnalyzerCore

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AnalyzerViewModel()
    @State private var showConnectionScreen = true

    /// This is an idle auto-lock policy, not a background execution entitlement.
    /// SQLite recording keeps the display awake even if BLE temporarily drops.
    private var requiresAwakeDisplay: Bool {
        model.isRecording || model.isLivePolling ||
        model.isDidScanning || model.isDriveCollecting || model.isStandardPIDSurveying
    }

    var body: some View {
        Group {
            if showConnectionScreen {
                BLEConnectionView(model: model) {
                    showConnectionScreen = false
                }
            } else {
                FinalAnalyzerWorkspace(model: model) {
                    showConnectionScreen = true
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.isRecording || model.ble.state != "ready" {
                        HStack(spacing: 10) {
                            if model.isRecording {
                                Label("SQLite記録中・自動スリープ防止中", systemImage: "record.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            if model.ble.state != "ready" {
                                Label("BLE中断：記録は保持されています", systemImage: "wifi.slash")
                                Spacer(minLength: 4)
                                Button("再接続") { showConnectionScreen = true }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial)
                    }
                }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = requiresAwakeDisplay
        }
        .onChange(of: requiresAwakeDisplay) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
            model.recordLifecycleEvent(kind: "DISPLAY_IDLE_LOCK", note: awake ? "disabled" : "enabled")
        }
        .onChange(of: scenePhase) { _, phase in
            let label: String
            switch phase {
            case .active: label = "active"
            case .inactive: label = "inactive"
            case .background: label = "background"
            @unknown default: label = "unknown"
            }
            model.recordLifecycleEvent(kind: "APP_SCENE_PHASE", note: label)
            if phase == .active {
                UIApplication.shared.isIdleTimerDisabled = requiresAwakeDisplay
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
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

                if model.isRecording {
                    Section("記録の状態") {
                        Label("SQLite記録中・自動スリープ防止中", systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                        Text("Bluetoothが切断されても記録ファイルは保持されます。再接続後、解析画面で通信を再確認してください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    Text("KW905またはM5CAN-Dialは名前付きBLEデバイスとして表示されます。通常は「名前なしを除外」をONのまま使用してください。")
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
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor, Color.teal],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 58, height: 58)
                        Image(systemName: "gauge.with.dots.needle.50percent")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bluetoothデバイス")
                            .font(.largeTitle.bold())
                        Text("接続するBLE ELMデバイスを選択")
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

                if let recovery = recoveryMessage {
                    AnalyzerCard("接続できませんでした", systemImage: "exclamationmark.triangle") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(recovery)
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Button {
                                model.ble.disconnect()
                                toggleScan()
                            } label: {
                                Label("再スキャン", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
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

    private var recoveryMessage: String? {
        switch model.ble.state {
        case "connect-failed":
            return "接続に失敗しました。KW905またはM5CAN-Dialが他の端末へ接続中でないか確認して、再スキャンしてください。"
        case "gatt-error":
            return "GATT情報の取得に失敗しました。アダプタの電源を入れ直してから再スキャンしてください。"
        case "bluetooth-unavailable":
            return "iPadのBluetoothが利用できません。BluetoothをONにし、Honda AnalyzerのBluetooth権限を確認してください。"
        default:
            return nil
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

