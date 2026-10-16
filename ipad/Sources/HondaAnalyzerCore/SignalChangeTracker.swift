import Foundation

public struct ObservedSignalPoint: Identifiable, Equatable, Sendable {
    public let date: Date
    public let value: Double
    public var id: Date { date }
}

public struct ObservedSignalTrend: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let unit: String
    public let isRawChange: Bool
    public let changeCount: Int
    public let lastUpdated: Date
    public let points: [ObservedSignalPoint]
}

/// The RAW bytes are evidence. For unidentified vendor DIDs, show how many
/// payload bytes changed between two responses, never assume a numeric signal.
public struct SignalChangeTracker {
    private struct Entry {
        var title: String
        var unit: String
        var raw: Data?
        var lastNumeric: Double?
        var rawMode: Bool
        var changeCount: Int = 0
        var lastUpdated: Date = .distantPast
        var points: [ObservedSignalPoint] = []
    }
    private var entries: [String: Entry] = [:]
    public let maxTracked: Int
    public let maxPoints: Int

    public init(maxTracked: Int = 128, maxPoints: Int = 90) {
        self.maxTracked = max(1, maxTracked)
        self.maxPoints = max(2, maxPoints)
    }

    public mutating func observePID(pid: UInt8, canID: String?, value: Double?,
                                   payload: Data, unit: String, name: String,
                                   at date: Date) {
        let id = String(format: "01%02X@", pid) + (canID ?? "unidentified")
        observe(id: id, name: name, payload: payload,
                value: value, unit: unit, at: date)
    }

    public mutating func observeDID(ecu: String, did: UInt16, payload: Data,
                                   at date: Date) {
        let id = "22" + String(format: "%04X", did) + "@" + ecu.uppercased()
        observe(id: id, name: "DID " + String(format: "%04X", did) +
                " / ECU " + ecu.uppercased(), payload: payload,
                value: nil, unit: "変更バイト数", at: date)
    }

    private mutating func observe(id: String, name: String, payload: Data,
                                  value: Double?, unit: String, at date: Date) {
        guard !payload.isEmpty, value?.isFinite ?? true else { return }
        if entries[id] == nil && entries.count >= maxTracked,
           let oldest = entries.min(by: { $0.value.lastUpdated < $1.value.lastUpdated })?.key {
            entries.removeValue(forKey: oldest)
        }
        var entry = entries[id] ?? Entry(title: name, unit: unit, rawMode: value == nil)
        let delta: Double
        let changed: Bool
        if let value {
            delta = value
            changed = entry.lastNumeric.map { $0 != value } ?? false
        } else {
            if let prev = entry.raw {
                let a = [UInt8](prev), b = [UInt8](payload)
                let comparable = min(a.count, b.count)
                let differences = (0..<comparable).reduce(0) { $0 + (a[$1] != b[$1] ? 1 : 0) }
                delta = Double(differences + abs(a.count - b.count))
                changed = delta > 0
            } else {
                delta = 0
                changed = false
            }
        }
        entry.title = name
        entry.unit = value == nil ? "変更バイト数" : unit
        entry.rawMode = value == nil
        entry.raw = payload
        entry.lastNumeric = value
        entry.lastUpdated = date
        if changed { entry.changeCount += 1 }
        entry.points.append(ObservedSignalPoint(date: date, value: delta))
        if entry.points.count > maxPoints {
            entry.points.removeFirst(entry.points.count - maxPoints)
        }
        entries[id] = entry
    }

    public func changingSignals(limit: Int = 6) -> [ObservedSignalTrend] {
        entries.compactMap { key, entry -> ObservedSignalTrend? in
            guard entry.changeCount > 0 else { return nil }
            return ObservedSignalTrend(
                id: key, title: entry.title, unit: entry.unit,
                isRawChange: entry.rawMode, changeCount: entry.changeCount,
                lastUpdated: entry.lastUpdated, points: entry.points
            )
        }.sorted {
            if $0.changeCount != $1.changeCount { return $0.changeCount > $1.changeCount }
            return $0.lastUpdated > $1.lastUpdated
        }.prefix(max(0, limit)).map { $0 }
    }
}
