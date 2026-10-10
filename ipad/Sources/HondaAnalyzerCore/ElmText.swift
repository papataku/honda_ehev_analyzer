import Foundation

public struct ElmHexRow: Equatable, Sendable {
    public let canID: String?
    public let data: Data
}
public struct IsoTpMessage: Equatable, Sendable {
    public let canID: String?
    public let payload: Data
}
public struct IsoTpPartial: Equatable, Sendable {
    public let canID: String?
    public let payload: Data
    public let totalLength: Int?
}

private struct IsoTpActive { var total: Int; var buffer: Data; var nextSequence: Int }
private struct Caf1Block { let payload: Data; let total: Int; let complete: Bool }

private func isHex(_ string: String) -> Bool {
    guard !string.isEmpty else { return false }
    return string.utf8.allSatisfy {
        (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0)
    }
}

private func compactHex(_ line: String) -> String? {
    let compact = line.filter { !$0.isWhitespace }
    guard !compact.isEmpty, compact.count.isMultiple(of: 2), isHex(compact) else { return nil }
    return compact.uppercased()
}

private func hexData(_ string: String) -> Data? {
    let bytes = Array(string.utf8)
    guard bytes.count.isMultiple(of: 2) else { return nil }
    func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }
    var result = Data()
    var index = 0
    while index < bytes.count {
        guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
        result.append((high << 4) | low)
        index += 2
    }
    return result
}

public func parseHexRows(_ text: String) -> [ElmHexRow] {
    var output: [ElmHexRow] = []
    for line in text.replacingOccurrences(of: ">", with: "\n").split(whereSeparator: { $0.isNewline }) {
        guard let compact = compactHex(String(line)) else { continue }
        var canID: String?
        var body = compact
        if compact.count >= 10 {
            let header = String(compact.prefix(8))
            if header.hasPrefix("18DA") || header.hasPrefix("18DB") {
                canID = header
                body = String(compact.dropFirst(8))
            }
        }
        guard !body.isEmpty, let data = hexData(body) else { continue }
        output.append(ElmHexRow(canID: canID, data: data))
    }
    return output
}

private func caf1Blocks(_ text: String) -> [Caf1Block] {
    let lines = text
        .replacingOccurrences(of: ">", with: "\n")
        .split(whereSeparator: { $0.isNewline })
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    func segment(_ line: String) -> Data? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let label = line[..<colon].filter { !$0.isWhitespace }
        guard !label.isEmpty, isHex(String(label)) else { return nil }
        let bodyStart = line.index(after: colon)
        let body = line[bodyStart...].filter { !$0.isWhitespace }
        guard !body.isEmpty, body.count.isMultiple(of: 2), isHex(String(body)) else { return nil }
        return hexData(String(body))
    }

    var output: [Caf1Block] = []
    var i = 0
    while i < lines.count {
        let lengthToken = lines[i].filter { !$0.isWhitespace }
        guard lengthToken.count == 3,
              isHex(String(lengthToken)),
              i + 1 < lines.count,
              segment(lines[i + 1]) != nil,
              let total = Int(lengthToken, radix: 16) else {
            i += 1
            continue
        }
        var data = Data()
        var j = i + 1
        while j < lines.count, let part = segment(lines[j]) {
            data.append(part)
            j += 1
            if data.count >= total { break }
        }
        let received = Data(data.prefix(total))
        output.append(Caf1Block(payload: received, total: total, complete: data.count >= total))
        i = max(j, i + 1)
    }
    return output
}

public func isoTpMessages(_ text: String) -> [IsoTpMessage] {
    var output: [IsoTpMessage] = caf1Blocks(text)
        .filter(\.complete)
        .map { IsoTpMessage(canID: nil, payload: $0.payload) }
    var active: [String: IsoTpActive] = [:]

    for row in parseHexRows(text) {
        let bytes = [UInt8](row.data)
        guard let first = bytes.first else { continue }
        let pci = first >> 4
        let key = row.canID ?? ""

        if pci == 0x0 {
            let count = Int(first & 0x0F)
            if count > 0, count <= 7, count <= bytes.count - 1 {
                output.append(IsoTpMessage(canID: row.canID, payload: Data(bytes[1...count])))
                continue
            }
        }
        if pci == 0x1, bytes.count >= 2 {
            let total = Int(first & 0x0F) << 8 | Int(bytes[1])
            let buffer = Data(bytes.dropFirst(2))
            if buffer.count >= total {
                output.append(IsoTpMessage(canID: row.canID, payload: Data(buffer.prefix(total))))
            } else {
                active[key] = IsoTpActive(total: total, buffer: buffer, nextSequence: 1)
            }
            continue
        }
        if pci == 0x2, var current = active[key] {
            let sequence = Int(first & 0x0F)
            guard sequence == (current.nextSequence & 0x0F) else {
                active.removeValue(forKey: key)
                continue
            }
            if bytes.count > 1 { current.buffer.append(contentsOf: bytes.dropFirst()) }
            current.nextSequence = (current.nextSequence + 1) & 0x0F
            if current.buffer.count >= current.total {
                output.append(IsoTpMessage(canID: row.canID, payload: Data(current.buffer.prefix(current.total))))
                active.removeValue(forKey: key)
            } else {
                active[key] = current
            }
            continue
        }
        if pci == 0x3 { continue }
        output.append(IsoTpMessage(canID: row.canID, payload: row.data))
    }
    return output
}

public func isoTpPartialMessages(_ text: String) -> [IsoTpPartial] {
    var output = caf1Blocks(text)
        .filter { !$0.complete && !$0.payload.isEmpty }
        .map { IsoTpPartial(canID: nil, payload: $0.payload, totalLength: $0.total) }
    var active: [String: IsoTpActive] = [:]

    for row in parseHexRows(text) {
        let bytes = [UInt8](row.data)
        guard let first = bytes.first else { continue }
        let pci = first >> 4
        let key = row.canID ?? ""
        if pci == 0x1, bytes.count >= 2 {
            let total = Int(first & 0x0F) << 8 | Int(bytes[1])
            active[key] = IsoTpActive(total: total, buffer: Data(bytes.dropFirst(2)), nextSequence: 1)
            continue
        }
        if pci == 0x2, var current = active[key] {
            let sequence = Int(first & 0x0F)
            if sequence == (current.nextSequence & 0x0F) {
                if bytes.count > 1 { current.buffer.append(contentsOf: bytes.dropFirst()) }
                current.nextSequence = (current.nextSequence + 1) & 0x0F
                if current.buffer.count >= current.total {
                    active.removeValue(forKey: key)
                } else {
                    active[key] = current
                }
            } else {
                if !current.buffer.isEmpty {
                    output.append(IsoTpPartial(canID: row.canID, payload: current.buffer, totalLength: current.total))
                }
                active.removeValue(forKey: key)
            }
        }
    }

    for (key, current) in active where !current.buffer.isEmpty && current.buffer.count < current.total {
        output.append(IsoTpPartial(canID: key.isEmpty ? nil : key, payload: current.buffer, totalLength: current.total))
    }
    return output
}

public func findServicePayload(_ text: String, prefix: Data) -> (payload: Data, canID: String?)? {
    var hits: [(Data, String?)] = []
    for message in isoTpMessages(text) {
        guard let range = message.payload.range(of: prefix) else { continue }
        hits.append((Data(message.payload[range.upperBound...]), message.canID))
    }
    guard let first = hits.first else { return nil }
    var payload = Data()
    for hit in hits where hit.1 == first.1 { payload.append(hit.0) }
    return (payload, first.1)
}

public func findOBDPayload(_ text: String, mode: UInt8, pid: UInt8) -> Data? {
    findServicePayload(text, prefix: Data([mode &+ 0x40, pid]))?.payload
}

public func findUDS22Payload(_ text: String, did: UInt16) -> (payload: Data, canID: String?)? {
    findServicePayload(text, prefix: Data([0x62, UInt8(did >> 8), UInt8(did & 0xFF)]))
}
