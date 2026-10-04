import Foundation

public struct ElmPollingTimingProfile: Equatable, Sendable {
    public let setup: [String]
    public let restore: [String]
    public let name: String

    public init(setup: [String], restore: [String], name: String) {
        self.setup = setup
        self.restore = restore
        self.name = name
    }
}

/// Returns the additional delay required after a group of requests to keep the
/// average request rate at or below the requested target.
///
/// A value of zero means the transport/ECU itself is already the bottleneck.
/// Unthrottled mode removes only app-side pacing; ElmCommandSession still waits
/// for each prompt before sending the next command.
public func pollingDelaySeconds(
    requestCount: Int,
    targetRequestRateHz: Double,
    elapsedSeconds: Double,
    unthrottled: Bool = false
) -> Double {
    guard !unthrottled,
          requestCount > 0,
          targetRequestRateHz > 0 else {
        return 0
    }

    let targetDuration = Double(requestCount) / targetRequestRateHz
    return max(0, targetDuration - max(0, elapsedSeconds))
}

/// ELM timeout/adaptive-timing presets for DID discovery.
///
/// Compatibility mode preserves the validated KW905 timing. Aggressive mode is
/// opt-in for fast custom ELM327-compatible hardware because shorter ATST values
/// can miss slow ECU responses.
public func elmDidPollingTimingProfile(
    targetRateHz: Double,
    unthrottled: Bool,
    aggressive: Bool
) -> ElmPollingTimingProfile {
    let restore = ["ATAT1", "ATST32"]

    if aggressive {
        if unthrottled || targetRateHz >= 100 {
            return ElmPollingTimingProfile(
                setup: ["ATAT2", "ATST02"],
                restore: restore,
                name: "高性能/超高速"
            )
        }
        if targetRateHz >= 50 {
            return ElmPollingTimingProfile(
                setup: ["ATAT2", "ATST04"],
                restore: restore,
                name: "高性能/50Hz"
            )
        }
        if targetRateHz >= 20 {
            return ElmPollingTimingProfile(
                setup: ["ATAT2", "ATST0A"],
                restore: restore,
                name: "高性能/20Hz"
            )
        }
    }

    if targetRateHz >= 8 {
        return ElmPollingTimingProfile(
            setup: ["ATAT2", "ATST0F"],
            restore: restore,
            name: "互換/高速"
        )
    }
    if targetRateHz >= 5 {
        return ElmPollingTimingProfile(
            setup: ["ATAT2", "ATST19"],
            restore: restore,
            name: "互換/中速"
        )
    }

    return ElmPollingTimingProfile(setup: [], restore: [], name: "互換/標準")
}
