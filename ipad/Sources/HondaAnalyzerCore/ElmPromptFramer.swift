import Foundation

public struct ElmResponse: Equatable, Sendable {
    public let raw: Data
    public let text: String
    public init(raw: Data, text: String) { self.raw = raw; self.text = text }
}

public final class ElmPromptFramer: @unchecked Sendable {
    private var buffer = Data()
    public init() {}

    public func feed(_ chunk: Data) -> [ElmResponse] {
        buffer.append(chunk)
        var responses: [ElmResponse] = []
        while let prompt = buffer.firstIndex(of: 0x3E) {
            let end = buffer.index(after: prompt)
            let raw = Data(buffer[..<end])
            buffer.removeSubrange(..<end)
            responses.append(ElmResponse(raw: raw, text: String(decoding: raw, as: UTF8.self)))
        }
        return responses
    }

    public func reset() { buffer.removeAll(keepingCapacity: true) }

    public var pending: Data { buffer }
}
