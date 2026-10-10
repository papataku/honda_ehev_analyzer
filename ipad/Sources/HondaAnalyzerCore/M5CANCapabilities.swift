import Foundation

/// The device name/ATI text is never sufficient to enable M5CAN-only commands.
/// Features are enabled ONLY after a successful versioned capability exchange.
public struct M5CANCapabilities: Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let firmwareVersion: String
    public let maxBatchIDs: Int
    public let supportsOBD01: Bool
    public let supportsUDS22: Bool
    public let supportsStreaming: Bool

    public var description: String {
        "M5CAN protocol \(major).\(minor), firmware \(firmwareVersion), batch ≤\(maxBatchIDs)"
    }

    public static func parse(_ reply: String) -> M5CANCapabilities? {
        guard let line = reply
            .components(separatedBy: .newlines)
            .map({
                $0.trimmingCharacters(
                    in: .whitespacesAndNewlines.union(
                        CharacterSet(charactersIn: ">")
                    )
                )
            })
            .first(where: { $0.hasPrefix("M5CAN-CAPS ") })
        else { return nil }

        var fields: [String: String] = [:]
        for word in line.split(separator: " ").dropFirst() {
            let parts = word.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let key = String(parts[0]), value = String(parts[1])
            guard fields[key] == nil else { return nil }
            fields[key] = value
        }
        guard let protocolText = fields["PROTO"] else { return nil }
        let components = protocolText.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              major == 1, minor >= 0,
              let firmware = fields["FW"], !firmware.isEmpty,
              let batchText = fields["BATCH"],
              let batch = Int(batchText), (1...16).contains(batch),
              let opsText = fields["OPS"],
              let stream = fields["STREAM"], stream == "0" || stream == "1"
        else { return nil }

        let ops = Set(opsText.split(separator: ",").map(String.init))
        // Protocol 1.x may add new optional operations. Ignore features we
        // do not understand; activate only explicitly known capabilities.
        guard ops.contains("OBD01") || ops.contains("UDS22") else { return nil }
        return M5CANCapabilities(
            major: major, minor: minor, firmwareVersion: firmware,
            maxBatchIDs: batch, supportsOBD01: ops.contains("OBD01"),
            supportsUDS22: ops.contains("UDS22"),
            supportsStreaming: stream == "1"
        )
    }
}

public enum M5CANBatchGroup: String, Sendable {
    case mode01 = "00"
    case ecu01ReadDID = "01"

    public func command(ids: [String], capacity: Int) -> String? {
        guard !ids.isEmpty, ids.count <= capacity, capacity <= 16 else { return nil }
        let compact = ids.map { $0.uppercased().filter { !$0.isWhitespace } }
        for item in compact {
            guard item.count == 4, UInt16(item, radix: 16) != nil else { return nil }
            if self == .mode01 && !["010C", "010D", "0105", "015B", "019A"].contains(item) {
                return nil
            }
        }
        return "ATM5B\(rawValue):\(compact.joined(separator: ","))"
    }
}

public struct M5CANBatchItem: Equatable, Sendable {
    public let key: String
    public let responseText: String
}

public struct M5CANBatchResponse: Equatable, Sendable {
    public let items: [M5CANBatchItem]

    public static func parse(_ text: String, group: M5CANBatchGroup, ids: [String])
        -> M5CANBatchResponse? {
        let expected = ids.map { "\(group.rawValue):\($0.uppercased())" }
        var items: [M5CANBatchItem] = []
        var key: String?
        var lines: [String] = []
        var finished = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line == ">" { continue }
            if finished { return nil }
            if line == "M5DONE" {
                if let key { items.append(M5CANBatchItem(key: key, responseText: lines.joined(separator: "\r"))) }
                finished = true
                key = nil
                lines = []
            } else if line.hasPrefix("M5ITEM:") {
                if let key { items.append(M5CANBatchItem(key: key, responseText: lines.joined(separator: "\r"))) }
                let label = String(line.dropFirst("M5ITEM:".count))
                guard items.count < expected.count, label == expected[items.count] else { return nil }
                key = label
                lines = []
            } else {
                guard key != nil else { return nil }
                lines.append(line)
            }
        }
        guard finished, items.count == expected.count,
              items.map(\.key) == expected else { return nil }
        return M5CANBatchResponse(items: items)
    }
}
