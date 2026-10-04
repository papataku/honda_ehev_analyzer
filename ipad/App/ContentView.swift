import SwiftUI
import HondaAnalyzerCore

struct ContentView: View {
    @StateObject private var model = AnalyzerViewModel()
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    private let markers = ["STOP", "EV", "ENGINE ON", "ACCEL", "CRUISE", "REGEN"]

    var body: some View {
        NavigationSplitView {
            List {
                Section("KW905 BLE") {
                    Text("状態: \(model.ble.state)")
                    Button("5秒スキャン") {
                        model.ble.startScan()
                        Task {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            await MainActor.run { model.ble.stopScan() }
                        }
                    }
                    .disabled(model.isBusy || model.isLivePolling || model.isDidScanning)

                    ForEach(model.ble.devices) { device in
                        Button { try? model.ble.connect(to: device.id) } label: {
                            VStack(alignment: .leading) {
                                Text(device.name ?? "名称不明")
                                Text("RSSI \(device.rssi)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(model.isDidScanning)
                    }
                }

                Section("記録") {
                    if model.isRecording {
                        Button("記録終了") { model.stopRecording() }
                            .disabled(model.isDidScanning)
                        Text(model.recordingFile).font(.caption).foregroundStyle(.secondary)
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

                Section("ELM / 車両") {
                    Button("ELM初期化") { model.initializeELM() }
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

                Section("DID探索（停車のみ）") {
                    Toggle("完全停止・Pレンジを確認", isOn: $model.stationaryConfirmed)

                    Button("既知の安全な要求でECU候補を確認") {
                        model.runSafeEcuCensus()
                    }
                    .disabled(
                        model.ble.state != "ready" ||
                        !model.isRecording ||
                        !model.stationaryConfirmed ||
                        model.isBusy ||
                        model.isLivePolling ||
                        model.isDidScanning
                    )

                    if !model.observedEcus.isEmpty {
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

                    Picker("探索速度", selection: $model.didScanRateHz) {
                        Text("2 req/s").tag(2.0)
                        Text("5 req/s").tag(5.0)
                        Text("8 req/s").tag(8.0)
                        Text("10 req/s").tag(10.0)
                    }

                    Text("初期対象: 2000–20FF")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if model.isDidScanning {
                        Button("探索を安全に停止", role: .destructive) { model.stopDidScan() }
                    } else {
                        Button("2000–20FF 探索 / 再開") { model.startDidScan2000Range() }
                            .disabled(
                                model.ble.state != "ready" ||
                                !model.isRecording ||
                                !model.stationaryConfirmed ||
                                model.isBusy ||
                                model.isLivePolling
                            )
                    }

                    ProgressView(value: model.didScanProgress)
                    Text(model.didScanCurrent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Positive \(model.didPositiveCount) / partial \(model.didPartialCount)")
                        .font(.caption)
                }

                Section("状態") {
                    Text(model.statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Honda Analyzer")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("RP8 Live").font(.largeTitle.bold())
                        Spacer()
                        if model.isRecording { Label("REC", systemImage: "record.circle.fill") }
                        if model.isLivePolling { Label("LIVE", systemImage: "waveform.path.ecg") }
                        if model.isDidScanning { Label("DID", systemImage: "magnifyingglass") }
                        if model.isBusy { ProgressView() }
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
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(value).font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
