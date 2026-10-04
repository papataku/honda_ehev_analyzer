import Foundation

@MainActor
public protocol ElmByteTransport: AnyObject {
    var onReceive: ((Data) -> Void)? { get set }
    func write(_ data: Data) throws
}

public struct ElmCommandResult: Equatable, Sendable {
    public let command: String
    public let raw: Data
    public let text: String
    public let latencyMs: Double
    public let success: Bool

    public init(command: String, raw: Data, text: String, latencyMs: Double, success: Bool) {
        self.command = command
        self.raw = raw
        self.text = text
        self.latencyMs = latencyMs
        self.success = success
    }
}

public enum ElmCommandError: LocalizedError {
    case busy
    case timeout
    case unsafeCommand(String)

    public var errorDescription: String? {
        switch self {
        case .busy: return "Another ELM command is already in progress"
        case .timeout: return "ELM command timed out"
        case .unsafeCommand(let command): return "Blocked non-read-only vehicle command: \(command)"
        }
    }
}

public let elmInitCommands = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATAL", "ATCAF1", "ATCFC1", "ATSP7"]
public let elmMetaCommands = ["ATI", "ATDP", "ATDPN", "AT@1"]

public func elmResponseSuccess(_ text: String) -> Bool {
    let upper = text.uppercased()
    let failures = [
        "?", "ERROR", "UNABLE TO CONNECT", "BUS ERROR", "CAN ERROR",
        "NO DATA", "STOPPED", "BUFFER FULL", "FB ERROR", "LV RESET", "ACT ALERT"
    ]
    return !failures.contains { upper.contains($0) }
}

@MainActor
public final class ElmCommandSession {
    public var onRawReceive: ((Data) -> Void)?
    public var onResult: ((ElmCommandResult) -> Void)?

    private struct Pending {
        let id: UUID
        let command: String
        let started: Date
        let continuation: CheckedContinuation<ElmCommandResult, Error>
    }

    private let transport: ElmByteTransport
    private let framer = ElmPromptFramer()
    private var pending: Pending?

    public init(transport: ElmByteTransport) {
        self.transport = transport
        transport.onReceive = { [weak self] data in self?.receive(data) }
    }

    public func command(_ command: String, timeout: TimeInterval = 5.0) async throws -> ElmCommandResult {
        guard pending == nil else { throw ElmCommandError.busy }
        guard isReadOnlyVehicleCommand(command) else { throw ElmCommandError.unsafeCommand(command) }

        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()

        return try await withCheckedThrowingContinuation { continuation in
            pending = Pending(id: id, command: normalized, started: Date(), continuation: continuation)
            do {
                try transport.write(Data((normalized + "\r").utf8))
            } catch {
                pending = nil
                continuation.resume(throwing: error)
                return
            }

            Task { @MainActor [weak self] in
                let nanos = UInt64(max(0.01, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                self?.timeout(id: id)
            }
        }
    }

    public func initialize() async -> [ElmCommandResult] {
        var results: [ElmCommandResult] = []
        for command in elmInitCommands + elmMetaCommands {
            do {
                results.append(try await self.command(command, timeout: command == "ATZ" ? 8.0 : 5.0))
            } catch {
                results.append(ElmCommandResult(
                    command: command,
                    raw: Data(),
                    text: "\(type(of: error)): \(error)",
                    latencyMs: 0,
                    success: false
                ))
            }
        }
        return results
    }

    private func receive(_ data: Data) {
        onRawReceive?(data)
        let responses = framer.feed(data)
        guard let response = responses.first, let current = pending else { return }
        pending = nil
        let result = ElmCommandResult(
            command: current.command,
            raw: response.raw,
            text: response.text,
            latencyMs: Date().timeIntervalSince(current.started) * 1000.0,
            success: elmResponseSuccess(response.text)
        )
        onResult?(result)
        current.continuation.resume(returning: result)
    }

    private func timeout(id: UUID) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        current.continuation.resume(throwing: ElmCommandError.timeout)
    }
}
