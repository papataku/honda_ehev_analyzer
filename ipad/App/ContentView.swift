import SwiftUI
import HondaAnalyzerCore

struct ContentView: View {
    @StateObject private var model = AnalyzerViewModel()
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

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
                    .disabled(model.isBusy)

                    ForEach(model.ble.devices) { device in
                        Button { try? model.ble.connect(to: device.id) } label: {
                            VStack(alignment: .leading) {
                                Text(device.name ?? "名称不明")
                                Text("RSSI \(device.rssi)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("ELM / 車両") {
                    Button("ELM初期化") { model.initializeELM() }
                        .disabled(model.ble.state != "ready" || model.isBusy)
                    Button("既知信号を取得") { model.readKnownSignals() }
                        .disabled(model.ble.state != "ready" || model.isBusy)
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
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding()
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
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
