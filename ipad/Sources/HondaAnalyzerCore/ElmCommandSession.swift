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
    case m5canLeaseFailed(String)
    case dedicatedModeUnavailable

    public var errorDescription: String? {
        switch self {
        case .busy:
            return "Another ELM command is already in progress"
        case .timeout:
            return "ELM command timed out"
        case .unsafeCommand(let command):
            return "Blocked non-read-only vehicle command: \(command)"
        case .m5canLeaseFailed(let response):
            return "M5CAN TX lease could not be acquired: \(response)"
        case .dedicatedModeUnavailable:
            return "M5CAN専用通信に未対応のファームウェアです"
        }
    }
}

public let elmInitCommands = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATAL", "ATCAF1", "ATCFC1", "ATSP7"]
public let elmMetaCommands = ["ATI", "ATDP", "ATDPN", "AT@1"]

public func elmResponseSuccess(_ text: String) -> Bool {
    let upper = text.uppercased()
    let failures = [
        "?", "ERROR", "UNABLE TO CONNECT", "BUS ERROR", "CAN ERROR",
        "NO DATA", "STOPPED", "BUFFER FULL", "FB ERROR", "LV RESET", "ACT ALERT",
        "M5CAN TX LOCKED", "BUSY"
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

    private var isM5CAN = false
    public private(set) var negotiatedM5CAN: M5CANCapabilities?
    private var lastM5CANLeaseRenewal: Date?
    private let m5canLeaseRefreshSeconds: TimeInterval = 2.0

    public init(transport: ElmByteTransport) {
        self.transport = transport
        transport.onReceive = { [weak self] data in self?.receive(data) }
    }

    public func command(_ command: String, timeout: TimeInterval = 5.0) async throws -> ElmCommandResult {
        guard pending == nil else { throw ElmCommandError.busy }
        guard isReadOnlyVehicleCommand(command) else { throw ElmCommandError.unsafeCommand(command) }

        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)

        if shouldRenewM5CANLease(before: normalized) {
            let lease = try await sendCommand("ATM5TX1", timeout: min(timeout, 2.0))
            guard lease.success else {
                throw ElmCommandError.m5canLeaseFailed(lease.text)
            }
            lastM5CANLeaseRenewal = Date()
        }

        return try await sendCommand(normalized, timeout: timeout)
    }

    public func initialize() async -> [ElmCommandResult] {
        // Do not carry identity/capabilities across BLE connections.
        negotiatedM5CAN = nil
        isM5CAN = false
        lastM5CANLeaseRenewal = nil
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
        // Capability discovery is optional and only sent to verified M5CAN.
        // Legacy M5CAN, an incompatible future protocol, and all KW905
        // devices continue using the normal ELM request/response path.
        if isM5CAN && results.last(where: { $0.command == "ATI" })?.success == true {
            if let reply = try? await sendCommand("ATM5CAP", timeout: 2.0),
               reply.success {
                negotiatedM5CAN = M5CANCapabilities.parse(reply.text)
            }
        }
        return results
    }

    public func batchRead(
        group: M5CANBatchGroup, ids: [String], timeout: TimeInterval = 8.0
    ) async throws -> (ElmCommandResult, M5CANBatchResponse) {
        guard let cap = negotiatedM5CAN,
              (group == .mode01 ? cap.supportsOBD01 : cap.supportsUDS22),
              let command = group.command(ids: ids, capacity: cap.maxBatchIDs)
        else { throw ElmCommandError.dedicatedModeUnavailable }
        guard pending == nil else { throw ElmCommandError.busy }
        // 1 BLE command initiates a set of serialized read-only CAN queries.
        // It does not require or allow parallel ECU transactions.
        let lease = try await sendCommand("ATM5TX1", timeout: 2.0)
        guard lease.success else { throw ElmCommandError.m5canLeaseFailed(lease.text) }
        let response = try await sendCommand(command, timeout: timeout)
        // A single ECU may return NO DATA within an otherwise well-framed
        // batch. Preserve per-item results rather than discarding all samples.
        guard let parsed = M5CANBatchResponse.parse(
            response.text, group: group, ids: ids
        ) else { throw ElmCommandError.dedicatedModeUnavailable }
        return (response, parsed)
    }

    private func shouldRenewM5CANLease(before command: String) -> Bool {
        guard isM5CAN else { return false }
        let compact = command.uppercased().filter { !$0.isWhitespace }
        guard !compact.hasPrefix("AT"), isReadOnlyVehicleCommand(compact) else {
            return false
        }

        guard let last = lastM5CANLeaseRenewal else { return true }
        return Date().timeIntervalSince(last) >= m5canLeaseRefreshSeconds
    }

    private func sendCommand(_ normalized: String, timeout: TimeInterval) async throws -> ElmCommandResult {
        guard pending == nil else { throw ElmCommandError.busy }

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

        let upperResponse = response.text.uppercased()
        let upperCommand = current.command.uppercased().filter { !$0.isWhitespace }

        // Device identity must not persist after changing BLE adapters.
        // A fresh ATZ/ATI identifies the currently connected hardware.
        if upperCommand == "ATZ" || upperCommand == "ATI" {
            isM5CAN = upperResponse.contains("M5CAN")
            negotiatedM5CAN = nil
            lastM5CANLeaseRenewal = nil
        } else if upperResponse.contains("M5CAN") {
            isM5CAN = true
        }

        if upperCommand == "ATM5TX1", result.success {
            lastM5CANLeaseRenewal = Date()
        } else if upperCommand == "ATM5TX0" {
            lastM5CANLeaseRenewal = nil
        }

        // ATZ resets adapter state. M5CAN identifies itself in the ATZ reply,
        // so keep the detected adapter kind but invalidate the old lease.
        if upperCommand == "ATZ" {
            lastM5CANLeaseRenewal = nil
        }

        onResult?(result)
        current.continuation.resume(returning: result)
    }

    private func timeout(id: UUID) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        current.continuation.resume(throwing: ElmCommandError.timeout)
    }
}
