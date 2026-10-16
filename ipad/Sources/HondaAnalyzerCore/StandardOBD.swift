import Foundation

public struct Mode01Payload: Equatable, Sendable {
    public let canID: String?
    public let data: Data
}

public struct HybridEvData: Equatable, Sendable {
    public let supportMask: UInt8
    public let mode: UInt8
    public let voltageV: Double?
    public let currentA: Double?
    public var powerKW: Double? {
        guard let voltageV, let currentA else { return nil }
        return voltageV * currentA / 1000.0
    }
}

public func allMode01Payloads(_ text: String, pid: UInt8) -> [Mode01Payload] {
    let prefix = Data([0x41, pid])
    return isoTpMessages(text).compactMap { message in
        guard let range = message.payload.range(of: prefix) else { return nil }
        return Mode01Payload(canID: message.canID, data: Data(message.payload[range.upperBound...]))
    }
}

public func decodeEngineRPM(_ text: String) -> Double? {
    guard let payload = allMode01Payloads(text, pid: 0x0C).first?.data, payload.count >= 2 else { return nil }
    let b = [UInt8](payload)
    return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
}
public func decodeVehicleSpeed(_ text: String) -> Int? {
    allMode01Payloads(text, pid: 0x0D).first?.data.first.map(Int.init)
}
public func decodeCoolantC(_ text: String) -> Int? {
    allMode01Payloads(text, pid: 0x05).first?.data.first.map { Int($0) - 40 }
}
public func decodeBatterySOC(_ text: String) -> Double? {
    allMode01Payloads(text, pid: 0x5B).first?.data.first.map { Double($0) * 100.0 / 255.0 }
}

public func decodeHybridEv9A(_ text: String) -> HybridEvData? {
    guard let payload = allMode01Payloads(text, pid: 0x9A).first?.data, payload.count >= 6 else { return nil }
    let p = [UInt8](payload)
    let support = p[0]
    let voltage: Double? = (support & 0x02) != 0
        ? Double(UInt16(p[2]) << 8 | UInt16(p[3])) * 0.015625 : nil
    let signedCurrent = Int16(bitPattern: UInt16(p[4]) << 8 | UInt16(p[5]))
    let current: Double? = (support & 0x04) != 0 ? Double(signedCurrent) * 0.1 : nil
    return HybridEvData(supportMask: support, mode: p[1], voltageV: voltage, currentA: current)
}
