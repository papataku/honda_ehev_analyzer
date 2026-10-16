import Foundation

/// Standard Mode 01 inventory, independent of the live dashboard and unknown-DID scanner.
/// Each responder is tracked separately; a bitmap bit is not proof of a valid sample.
public struct StandardPIDDefinition: Sendable, Equatable {
    public let pid: UInt8
    public let name: String
    public let unit: String
    public let formula: String
    public let bytes: Int
    public init(_ pid: UInt8, _ name: String, _ unit: String, _ formula: String, _ bytes: Int = 1) {
        self.pid = pid; self.name = name; self.unit = unit; self.formula = formula; self.bytes = bytes
    }
}

public let standardPIDCatalog: [UInt8: StandardPIDDefinition] = {
    let definitions: [StandardPIDDefinition] = [
        .init(0x04, "計算エンジン負荷", "%", "A*100/255"),
        .init(0x05, "冷却水温", "°C", "A-40"),
        .init(0x0B, "吸気マニホールド圧", "kPa", "A"),
        .init(0x0C, "エンジン回転数", "rpm", "(256*A+B)/4", 2),
        .init(0x0D, "車速", "km/h", "A"),
        .init(0x0F, "吸気温", "°C", "A-40"),
        .init(0x10, "MAF", "g/s", "(256*A+B)/100", 2),
        .init(0x11, "スロットル開度", "%", "A*100/255"),
        .init(0x1F, "エンジン始動後時間", "s", "256*A+B", 2),
        .init(0x2F, "燃料残量", "%", "A*100/255"),
        .init(0x33, "大気圧", "kPa", "A"),
        .init(0x42, "ECU電源電圧", "V", "(256*A+B)/1000", 2),
        .init(0x43, "絶対負荷", "%", "(256*A+B)*100/255", 2),
        .init(0x45, "相対スロットル", "%", "A*100/255"),
        .init(0x47, "スロットルB", "%", "A*100/255"),
        .init(0x48, "スロットルC", "%", "A*100/255"),
        .init(0x49, "アクセル位置D", "%", "A*100/255"),
        .init(0x4A, "アクセル位置E", "%", "A*100/255"),
        .init(0x4B, "アクセル位置F", "%", "A*100/255"),
        .init(0x4C, "指令スロットル", "%", "A*100/255"),
        .init(0x5A, "相対アクセル", "%", "A*100/255"),
        .init(0x5B, "HV SOC", "%", "A*100/255"),
        .init(0x5C, "油温", "°C", "A-40"),
        .init(0x5E, "燃料流量", "L/h", "(256*A+B)/20", 2),
        .init(0x61, "要求トルク", "%", "A-125"),
        .init(0x62, "実トルク", "%", "A-125"),
        .init(0x63, "基準トルク", "N·m", "256*A+B", 2),
        .init(0x9A, "Hybrid/EV電圧・電流", "V/A", "mask; V=CD/64, I=signed(EF)/10", 6)
    ]
    return Dictionary(uniqueKeysWithValues: definitions.map { ($0.pid, $0) })
}()

public let standardBitmapPIDs: [UInt8] = stride(from: 0, through: 0xE0, by: 0x20).map { UInt8($0) }
public func isStandardBitmapPID(_ pid: UInt8) -> Bool { standardBitmapPIDs.contains(pid) }

public struct StandardPIDBitmap: Equatable, Sendable {
    public let canID: String?
    public let base: UInt8
    public let mask: UInt32
    public let supported: Set<UInt8>
}

public func parseStandardPIDBitmaps(_ text: String, base: UInt8) -> [StandardPIDBitmap] {
    guard isStandardBitmapPID(base) else { return [] }
    return allMode01Payloads(text, pid: base).compactMap { item in
        guard item.data.count >= 4 else { return nil }
        let mask = item.data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let supported = Set((0..<32).compactMap { bit -> UInt8? in
            guard (mask & (UInt32(1) << (31 - bit))) != 0 else { return nil }
            let pid = Int(base) + bit + 1
            guard pid <= 0xFF else { return nil }
            return UInt8(pid)
        })
        return StandardPIDBitmap(canID: item.canID, base: base, mask: mask, supported: supported)
    }
}

public enum StandardPIDSampleStatus: String, Codable, Sendable {
    case bitmapOnly = "bitmap_only"
    case decoded
    case uninterpreted
    case shortResponse = "short_response"
    case noData = "no_data"
    case timeout
}

/// A row represents one response from one ECU to one PID request.
/// latencyMs is nil for synthetic per-item batch replies (not zero).
public struct StandardPIDReading: Codable, Equatable, Sendable {
    public let pid: UInt8
    public let responseCANID: String?
    public let timestamp: Date
    public let status: StandardPIDSampleStatus
    public let payloadHex: String
    public let value: Double?
    public let unit: String?
    public let latencyMs: Double?

    public init(pid: UInt8, responseCANID: String?, timestamp: Date, status: StandardPIDSampleStatus,
                payloadHex: String, value: Double?, unit: String?, latencyMs: Double?) {
        self.pid = pid
        self.responseCANID = responseCANID
        self.timestamp = timestamp
        self.status = status
        self.payloadHex = payloadHex
        self.value = value
        self.unit = unit
        self.latencyMs = latencyMs
    }
    public var identifier: String {
        String(format: "01%02X", pid) + "@" + (responseCANID ?? "unidentified")
    }
}

private func standardPIDValue(_ pid: UInt8, _ p: [UInt8]) -> Double? {
    guard let d = standardPIDCatalog[pid], p.count >= d.bytes else { return nil }
    let a = Double(p[0])
    let ab = p.count >= 2 ? Double(UInt16(p[0]) << 8 | UInt16(p[1])) : 0
    switch pid {
    case 0x04, 0x11, 0x2F, 0x45, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x5A, 0x5B: return a * 100 / 255
    case 0x05, 0x0F, 0x5C: return a - 40
    case 0x0B, 0x0D, 0x33: return a
    case 0x0C: return ab / 4
    case 0x10: return ab / 100
    case 0x1F, 0x63: return ab
    case 0x42: return ab / 1000
    case 0x43: return ab * 100 / 255
    case 0x5E: return ab / 20
    case 0x61, 0x62: return a - 125
    default: return nil // PID 9A yields multiple independently derived values.
    }
}

public func readStandardPID(_ pid: UInt8, from text: String, at timestamp: Date = Date(),
                            latencyMs: Double? = nil) -> [StandardPIDReading] {
    allMode01Payloads(text, pid: pid).map { item in
        let payload = [UInt8](item.data)
        let definition = standardPIDCatalog[pid]
        let value = standardPIDValue(pid, payload)
        let status: StandardPIDSampleStatus
        if let definition, payload.count < definition.bytes {
            status = .shortResponse
        } else if value != nil {
            status = .decoded
        } else {
            status = .uninterpreted
        }
        return StandardPIDReading(
            pid: pid, responseCANID: item.canID, timestamp: timestamp,
            status: status,
            payloadHex: payload.map { String(format: "%02X", $0) }.joined(),
            value: value, unit: definition?.unit, latencyMs: latencyMs
        )
    }
}

public struct StandardPIDInventoryRow: Identifiable, Codable, Sendable {
    public let id: String
    public let pid: UInt8
    public let responseCANID: String?
    public var name: String
    public var unit: String
    public var formula: String
    public var bitmapSupported: Bool
    public var attempts: Int
    public var successfulSamples: Int
    public var latestStatus: StandardPIDSampleStatus
    public var firstSampleAt: Date?
    public var lastSampleAt: Date?
    public var latestValue: Double?
    public var minimum: Double?
    public var maximum: Double?
    public var lastPayloadHex: String
    public var dataBytes: Int
    public var effectiveHz: Double? {
        guard successfulSamples > 1, let firstSampleAt, let lastSampleAt,
              lastSampleAt > firstSampleAt else { return nil }
        return Double(successfulSamples - 1) / lastSampleAt.timeIntervalSince(firstSampleAt)
    }
}

public struct StandardPIDInventory {
    public private(set) var rows: [String: StandardPIDInventoryRow] = [:]
    public init() {}

    public mutating func addBitmap(_ result: StandardPIDBitmap) {
        for pid in result.supported where !isStandardBitmapPID(pid) {
            let id = Self.identifier(pid: pid, canID: result.canID)
            var row = rows[id] ?? Self.empty(pid: pid, canID: result.canID)
            row.bitmapSupported = true
            rows[id] = row
        }
    }

    /// A failed request has no trustworthy responding CAN ID. Charge it to the
    /// ECUs that previously advertised support, without fabricating a new responder.
    public mutating func addFailure(pid: UInt8, status: StandardPIDSampleStatus) {
        guard status == .noData || status == .timeout else { return }
        for key in rows.keys {
            guard var row = rows[key], row.pid == pid else { continue }
            row.attempts += 1
            row.latestStatus = status
            rows[key] = row
        }
    }

    public mutating func addReading(_ reading: StandardPIDReading) {
        let id = Self.identifier(pid: reading.pid, canID: reading.responseCANID)
        var row = rows[id] ?? Self.empty(pid: reading.pid, canID: reading.responseCANID)
        row.attempts += 1
        row.latestStatus = reading.status
        row.lastPayloadHex = reading.payloadHex
        row.dataBytes = reading.payloadHex.count / 2
        if reading.status == .decoded || reading.status == .uninterpreted {
            row.successfulSamples += 1
            row.firstSampleAt = row.firstSampleAt ?? reading.timestamp
            row.lastSampleAt = reading.timestamp
        }
        if let value = reading.value {
            row.latestValue = value
            row.minimum = min(row.minimum ?? value, value)
            row.maximum = max(row.maximum ?? value, value)
        }
        rows[id] = row
    }

    public var sortedRows: [StandardPIDInventoryRow] { rows.values.sorted { $0.id < $1.id } }

    private static func identifier(pid: UInt8, canID: String?) -> String {
        String(format: "01%02X", pid) + "@" + (canID ?? "unidentified")
    }
    private static func empty(pid: UInt8, canID: String?) -> StandardPIDInventoryRow {
        let d = standardPIDCatalog[pid]
        return StandardPIDInventoryRow(
            id: identifier(pid: pid, canID: canID), pid: pid, responseCANID: canID,
            name: d?.name ?? "未同定", unit: d?.unit ?? "", formula: d?.formula ?? "",
            bitmapSupported: false, attempts: 0, successfulSamples: 0,
            latestStatus: .bitmapOnly, firstSampleAt: nil, lastSampleAt: nil,
            latestValue: nil, minimum: nil, maximum: nil, lastPayloadHex: "", dataBytes: 0
        )
    }
}

/// JSON/CSV can be shared without leaking raw BLE frames; SQLite remains the full provenance.
public func standardPIDJSON(_ rows: [StandardPIDInventoryRow]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(rows)
}

public func standardPIDCSV(_ rows: [StandardPIDInventoryRow]) -> String {
    func quote(_ string: String) -> String { "\"" + string.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    let header = "id,can_id,pid,name,unit,formula,bitmap_supported,attempts,samples,status,latest,min,max,effective_hz,payload_hex"
    let lines: [String] = rows.map { r in
        let latest = r.latestValue.map { String($0) } ?? ""
        let minimum = r.minimum.map { String($0) } ?? ""
        let maximum = r.maximum.map { String($0) } ?? ""
        let rate = r.effectiveHz.map { String($0) } ?? ""
        let values: [String] = [
            r.id, r.responseCANID ?? "", String(format: "%02X", r.pid),
            r.name, r.unit, r.formula,
            r.bitmapSupported ? "true" : "false",
            String(r.attempts), String(r.successfulSamples), r.latestStatus.rawValue,
            latest, minimum, maximum, rate, r.lastPayloadHex
        ]
        return values.map { quote($0) }.joined(separator: ",")
    }
    return ([header] + lines).joined(separator: "\n") + "\n"
}
