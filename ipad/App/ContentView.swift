import SwiftUI
import HondaAnalyzerCore

struct ContentView: View {
    @StateObject private var ble = KW905BLETransport()

    var body: some View {
        NavigationSplitView {
            List {
                Section("KW905 BLE") {
                    Text("状態: \(ble.state)")
                    Button("5秒スキャン") {
                        ble.startScan()
                        Task {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            await MainActor.run { ble.stopScan() }
                        }
                    }
                    ForEach(ble.devices) { device in
                        Button {
                            try? ble.connect(to: device.id)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(device.name ?? "名称不明")
                                Text("\(device.id.uuidString)  RSSI \(device.rssi)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Honda Analyzer")
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                Text("iPad Native Analyzer").font(.largeTitle.bold())
                Text("Phase 1: KW905 BLE接続とMac版互換のELM/OBD/UDS解析コア")
                    .foregroundStyle(.secondary)
                GroupBox("GATT") {
                    if ble.gattInventory.isEmpty {
                        Text("接続後にGATT characteristicを表示します").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(ble.gattInventory.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading) {
                                Text(item.uuid)
                                Text("\(item.serviceUUID)  \(item.properties.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Spacer()
            }.padding()
        }
    }
}
