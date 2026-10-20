#if canImport(CoreBluetooth) && canImport(Combine)
import Foundation
import Combine
import CoreBluetooth

public struct BLEDevice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String?
    public let rssi: Int
}
public struct GattCharacteristicInfo: Equatable, Sendable {
    public let serviceUUID: String
    public let uuid: String
    public let properties: [String]
}
public enum BLETransportError: LocalizedError {
    case unknownDevice, notReady
    public var errorDescription: String? {
        switch self {
        case .unknownDevice: return "BLE device is no longer available"
        case .notReady: return "BLE ELM transport is not ready"
        }
    }
}

public final class KW905BLETransport: NSObject, ObservableObject, ElmByteTransport {
    @Published public private(set) var devices: [BLEDevice] = []
    @Published public private(set) var state = "idle"
    @Published public private(set) var gattInventory: [GattCharacteristicInfo] = []
    @Published public private(set) var connectedDeviceID: UUID?
    @Published public private(set) var connectedDeviceName: String?
    @Published public private(set) var selectedWriteUUID: String?
    @Published public private(set) var selectedNotifyUUID: String?
    public var onReceive: ((Data) -> Void)?

    /// Enabled only by --ble-sim on the iPadOS Simulator. Never on physical devices.
    public let simulationEnabled: Bool
    private let virtualPeripheral = SimulatedELMPeripheral()
    private var virtualGeneration = 0
    private var central: CBCentralManager!
    private var discovered: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    public override init() {
#if targetEnvironment(simulator)
        simulationEnabled = ProcessInfo.processInfo.arguments.contains("--ble-sim")
#else
        simulationEnabled = false
#endif
        super.init()
        if !simulationEnabled {
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    public func startScan() {
        if simulationEnabled {
            devices = [BLEDevice(id: SimulatedELMPeripheral.identifier,
                                 name: SimulatedELMPeripheral.advertisedName, rssi: -42)]
            state = "scanning"
            return
        }
        guard central.state == .poweredOn else { state = "bluetooth-unavailable"; return }
        devices = []; discovered = [:]; state = "scanning"
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    public func stopScan() {
        if simulationEnabled {
            if state == "scanning" { state = "idle" }
            return
        }
        central.stopScan()
        if state == "scanning" { state = "idle" }
    }
    public func connect(to id: UUID) throws {
        if simulationEnabled {
            guard id == SimulatedELMPeripheral.identifier,
                  devices.contains(where: { $0.id == id }) else {
                throw BLETransportError.unknownDevice
            }
            stopScan()
            state = "connecting"
            virtualGeneration += 1
            let generation = virtualGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(75)) { [weak self] in
                guard let self, self.virtualGeneration == generation else { return }
                self.gattInventory = [
                    GattCharacteristicInfo(serviceUUID: "FFF0", uuid: "FFF1", properties: ["notify"]),
                    GattCharacteristicInfo(serviceUUID: "FFF0", uuid: "FFF2", properties: ["write"])
                ]
                self.connectedDeviceID = id
                self.connectedDeviceName = SimulatedELMPeripheral.advertisedName
                self.selectedWriteUUID = "FFF2"
                self.selectedNotifyUUID = "FFF1"
                self.state = "ready"
            }
            return
        }
        guard let target = discovered[id] else { throw BLETransportError.unknownDevice }
        stopScan(); state = "connecting"; peripheral = target; target.delegate = self; central.connect(target)
    }
    public func disconnect() {
        if simulationEnabled {
            virtualGeneration += 1  // Drop delayed notifications from prior connection.
            connectedDeviceID = nil
            connectedDeviceName = nil
            selectedWriteUUID = nil
            selectedNotifyUUID = nil
            gattInventory = []
            state = "disconnected"
            return
        }
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }
    public func write(_ data: Data) throws {
        if simulationEnabled {
            guard state == "ready" else { throw BLETransportError.notReady }
            let chunks = virtualPeripheral.notificationChunks(for: data)
            let generation = virtualGeneration
            for (index, chunk) in chunks.enumerated() {
                let ms = (index + 1) * virtualPeripheral.notificationIntervalMs
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
                    guard let self, self.virtualGeneration == generation,
                          self.state == "ready" else { return }
                    self.onReceive?(chunk)
                }
            }
            return
        }
        guard let peripheral, let characteristic = writeCharacteristic else { throw BLETransportError.notReady }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    private func refreshGattAndChoosePair() {
        guard let peripheral else { return }
        let pairs: [(CBService, CBCharacteristic)] = (peripheral.services ?? []).flatMap { svc in
            (svc.characteristics ?? []).map { (svc, $0) }
        }
        gattInventory = pairs.map { svc, ch in
            GattCharacteristicInfo(serviceUUID: svc.uuid.uuidString, uuid: ch.uuid.uuidString, properties: propertyNames(ch.properties))
        }
        func canWrite(_ c: CBCharacteristic) -> Bool { c.properties.contains(.writeWithoutResponse) || c.properties.contains(.write) }
        func canNotify(_ c: CBCharacteristic) -> Bool { c.properties.contains(.notify) || c.properties.contains(.indicate) }

        let both = pairs
            .filter { canWrite($0.1) && canNotify($0.1) }
            .sorted {
                $0.1.properties.contains(.writeWithoutResponse) &&
                !$1.1.properties.contains(.writeWithoutResponse)
            }
        if let selected = both.first {
            configure(write: selected.1, notify: selected.1)
            return
        }

        let writes = pairs
            .filter { canWrite($0.1) }
            .sorted {
                $0.1.properties.contains(.writeWithoutResponse) &&
                !$1.1.properties.contains(.writeWithoutResponse)
            }
        let notifies = pairs.filter { canNotify($0.1) }

        for write in writes {
            if let notify = notifies.first(where: { $0.0.uuid == write.0.uuid }) {
                configure(write: write.1, notify: notify.1)
                return
            }
        }

        if let write = writes.first, let notify = notifies.first {
            configure(write: write.1, notify: notify.1)
        }
    }

    private func configure(write: CBCharacteristic, notify: CBCharacteristic) {
        guard writeCharacteristic == nil, let peripheral else { return }
        writeCharacteristic = write
        notifyCharacteristic = notify
        selectedWriteUUID = write.uuid.uuidString
        selectedNotifyUUID = notify.uuid.uuidString
        connectedDeviceID = peripheral.identifier
        connectedDeviceName = peripheral.name
        peripheral.setNotifyValue(true, for: notify)
        state = "ready"
    }
    private func propertyNames(_ p: CBCharacteristicProperties) -> [String] {
        var r: [String] = []
        if p.contains(.writeWithoutResponse) { r.append("write-without-response") }
        if p.contains(.write) { r.append("write") }
        if p.contains(.notify) { r.append("notify") }
        if p.contains(.indicate) { r.append("indicate") }
        if p.contains(.read) { r.append("read") }
        return r
    }
}

extension KW905BLETransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { state = "bluetooth-unavailable" }
        else if state == "bluetooth-unavailable" { state = "idle" }
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        discovered[peripheral.identifier] = peripheral
        let item = BLEDevice(id: peripheral.identifier,
                             name: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                             rssi: RSSI.intValue)
        if let i = devices.firstIndex(where: { $0.id == item.id }) { devices[i] = item }
        else { devices.append(item); devices.sort { ($0.name ?? "") < ($1.name ?? "") } }
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = "discovering-gatt"; writeCharacteristic = nil; notifyCharacteristic = nil; gattInventory = []
        peripheral.discoverServices(nil)
    }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = "connect-failed"
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        writeCharacteristic = nil
        notifyCharacteristic = nil
        selectedWriteUUID = nil
        selectedNotifyUUID = nil
        connectedDeviceID = nil
        connectedDeviceName = nil
        state = "disconnected"
    }
}

extension KW905BLETransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { state = "gatt-error"; return }
        for service in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: service) }
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { state = "gatt-error"; return }
        refreshGattAndChoosePair()
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic == notifyCharacteristic, let value = characteristic.value else { return }
        onReceive?(value)
    }
}
#endif
