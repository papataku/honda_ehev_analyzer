import Foundation

public struct EcuResponder: Equatable, Sendable, Identifiable {
    public let source: String
    public let responseCanID: String

    public var id: String { responseCanID }

    public init(source: String, responseCanID: String) {
        self.source = source.uppercased()
        self.responseCanID = responseCanID.uppercased()
    }
}

public func responseEcuSource(from canID: String) -> String? {
    let value = canID.uppercased()
    guard value.count == 8, value.hasPrefix("18DAF1") else { return nil }
    let source = String(value.suffix(2))
    guard UInt8(source, radix: 16) != nil else { return nil }
    return source
}

public func ecuResponders(in text: String) -> [EcuResponder] {
    var byID: [String: EcuResponder] = [:]
    for row in parseHexRows(text) {
        guard let canID = row.canID?.uppercased(),
              let source = responseEcuSource(from: canID) else { continue }
        byID[canID] = EcuResponder(source: source, responseCanID: canID)
    }
    return byID.values.sorted {
        if $0.source == $1.source { return $0.responseCanID < $1.responseCanID }
        return (Int($0.source, radix: 16) ?? 0) < (Int($1.source, radix: 16) ?? 0)
    }
}

public let safeEcuCensusRequests: [(name: String, command: String, headerCommand: String)] = [
    ("Supported PIDs", "0100", "ATSHDB33F1"),
    ("Engine RPM", "010C", "ATSHDB33F1"),
    ("Vehicle Speed", "010D", "ATSHDB33F1"),
    ("Coolant", "0105", "ATSHDB33F1"),
    ("Hybrid/EV PID 9A", "019A", "ATSHDB33F1"),
    ("Honda DID 2012", "222012", "ATSHDBEFF1")
]
