import Foundation

public enum DidProbeStatus: String, Equatable, Sendable {
    case positive
    case positivePartial = "positive_partial"
    case nrc
    case noData = "no_data"
    case timeout
    case error
    case stoppedSpeed = "stopped_speed"
}

public struct DidProbeOutcome: Equatable, Sendable {
    public let ecu: String
    public let did: UInt16
    public let status: DidProbeStatus
    public let latencyMs: Double?
    public let nrc: UInt8?
    public let payload: Data
    public let responseCanID: String?
    public let rawText: String

    public init(
        ecu: String,
        did: UInt16,
        status: DidProbeStatus,
        latencyMs: Double? = nil,
        nrc: UInt8? = nil,
        payload: Data = Data(),
        responseCanID: String? = nil,
        rawText: String = ""
    ) {
        self.ecu = ecu.uppercased()
        self.did = did
        self.status = status
        self.latencyMs = latencyMs
        self.nrc = nrc
        self.payload = payload
        self.responseCanID = responseCanID
        self.rawText = rawText
    }
}

public func normalizedEcuSource(_ ecu: String) -> String? {
    var value = ecu.uppercased().replacingOccurrences(of: "0X", with: "")
    value = value.filter { !$0.isWhitespace }
    guard value.count == 2, UInt8(value, radix: 16) != nil else { return nil }
    return value
}

public func physicalRequestID(for ecu: String) -> String? {
    normalizedEcuSource(ecu).map { "18DA\($0)F1" }
}

public func physicalRequestHeaderCommand(for ecu: String) -> String? {
    normalizedEcuSource(ecu).map { "ATSHDA\($0)F1" }
}

public func expectedResponseID(for ecu: String) -> String? {
    normalizedEcuSource(ecu).map { "18DAF1\($0)" }
}

public func classifyUDS22Text(
    _ text: String,
    ecu: String,
    did: UInt16,
    latencyMs: Double? = nil
) -> DidProbeOutcome {
    let normalized = normalizedEcuSource(ecu) ?? ecu.uppercased()
    let expected = expectedResponseID(for: ecu)
    let prefix = Data([0x62, UInt8(did >> 8), UInt8(did & 0xFF)])

    for message in isoTpMessages(text) {
        if let canID = message.canID, let expected, canID.uppercased() != expected {
            continue
        }

        if message.payload.starts(with: prefix) {
            return DidProbeOutcome(
                ecu: normalized,
                did: did,
                status: .positive,
                latencyMs: latencyMs,
                payload: Data(message.payload.dropFirst(3)),
                responseCanID: message.canID ?? expected,
                rawText: text
            )
        }

        let bytes = [UInt8](message.payload)
        if bytes.count >= 3, bytes[0] == 0x7F, bytes[1] == 0x22 {
            return DidProbeOutcome(
                ecu: normalized,
                did: did,
                status: .nrc,
                latencyMs: latencyMs,
                nrc: bytes[2],
                responseCanID: message.canID,
                rawText: text
            )
        }
    }

    for fragment in isoTpPartialMessages(text) {
        if let canID = fragment.canID, let expected, canID.uppercased() != expected {
            continue
        }
        if fragment.payload.starts(with: prefix) {
            return DidProbeOutcome(
                ecu: normalized,
                did: did,
                status: .positivePartial,
                latencyMs: latencyMs,
                payload: Data(fragment.payload.dropFirst(3)),
                responseCanID: fragment.canID ?? expected,
                rawText: text
            )
        }
    }

    if text.uppercased().contains("NO DATA") {
        return DidProbeOutcome(ecu: normalized, did: did, status: .noData, latencyMs: latencyMs, rawText: text)
    }

    return DidProbeOutcome(ecu: normalized, did: did, status: .error, latencyMs: latencyMs, rawText: text)
}
