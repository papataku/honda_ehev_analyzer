import Foundation

/// A separate, explicit opt-in for read-only stationary discovery.
/// A displayed 0 km/h is never treated as proof of Park gear.
public struct AutomaticZeroSpeedGate: Sendable {
    public let minimumSamples: Int
    public let minimumStableSeconds: TimeInterval
    public let maximumSampleGapSeconds: TimeInterval
    public let maximumAgeSeconds: TimeInterval

    public private(set) var consecutiveZero = 0
    public private(set) var firstZeroAt: Date?
    public private(set) var lastZeroAt: Date?
    public private(set) var blockedReason = "車速未確認"

    public init(minimumSamples: Int = 3,
                minimumStableSeconds: TimeInterval = 5,
                maximumSampleGapSeconds: TimeInterval = 3,
                maximumAgeSeconds: TimeInterval = 1.5) {
        self.minimumSamples = max(3, minimumSamples)
        self.minimumStableSeconds = max(3, minimumStableSeconds)
        self.maximumSampleGapSeconds = max(0.5, maximumSampleGapSeconds)
        self.maximumAgeSeconds = max(0.1, maximumAgeSeconds)
    }

    public mutating func observe(speedKmh: Double?, at date: Date) {
        guard let speed = speedKmh, speed.isFinite, speed >= 0, speed <= 0.1 else {
            reset(reason: speedKmh == nil ? "車速未取得・通信失敗" : "走行中または車速異常")
            return
        }
        if let lastZeroAt,
           date.timeIntervalSince(lastZeroAt) < 0 ||
           date.timeIntervalSince(lastZeroAt) > maximumSampleGapSeconds {
            reset(reason: "車速更新間隔が長すぎます")
        }
        firstZeroAt = firstZeroAt ?? date
        lastZeroAt = date
        consecutiveZero += 1
        blockedReason = "車速0安定確認中"
    }

    public func canProbe(at now: Date) -> Bool {
        guard consecutiveZero >= minimumSamples,
              let firstZeroAt, let lastZeroAt else { return false }
        let age = now.timeIntervalSince(lastZeroAt)
        return age >= 0 && age <= maximumAgeSeconds &&
               now.timeIntervalSince(firstZeroAt) >= minimumStableSeconds
    }

    public mutating func reset(reason: String) {
        consecutiveZero = 0
        firstZeroAt = nil
        lastZeroAt = nil
        blockedReason = reason
    }
}

/// A previous manual Park confirmation is only meaningful while every
/// subsequently sampled vehicle speed remains valid and stationary.
/// Invalidate on any motion or unreliable/missing speed; never carry the
/// confirmation over a drive-stop-drive cycle or transport data gap.
public enum ParkConfirmationGuard {
    public static func requiresNewConfirmation(speedKmh: Double?) -> Bool {
        guard let speedKmh, speedKmh.isFinite else { return true }
        return speedKmh < 0 || speedKmh > 0.1
    }
}

/// One action per scheduler turn. No simultaneous commands can share the ELM lane.
public enum UnifiedAcquisitionAction: String, Equatable, Sendable {
    case baseline
    case supportedPIDBitmap
    case standardPID
    case knownDrivingDID
    case stationaryUnknownDID
    case idle
}

public struct UnifiedAcquisitionPlanner: Sendable {
    public private(set) var backgroundTurns = 0
    public init() {}

    public mutating func next(isMoving: Bool, zeroSpeedAuthorized: Bool,
                              hasBitmap: Bool, hasStandardPID: Bool,
                              hasKnownDID: Bool, hasUnknownDID: Bool) -> UnifiedAcquisitionAction {
        backgroundTurns += 1
        // Every turn starts with a baseline sample in the calling loop. The
        // background lane consumes at most ONE additional task afterward.
        if zeroSpeedAuthorized && hasUnknownDID && backgroundTurns.isMultiple(of: 2) {
            return .stationaryUnknownDID
        }
        if hasBitmap { return .supportedPIDBitmap }
        if hasStandardPID && backgroundTurns.isMultiple(of: 3) { return .standardPID }
        if isMoving && hasKnownDID { return .knownDrivingDID }
        if zeroSpeedAuthorized && hasUnknownDID { return .stationaryUnknownDID }
        return .idle
    }
}


/// M5CAN PROTO 1.1 currently supports physical UDS22 only on ECU01.
/// Observing an ECU's Mode01 response is NOT proof of physical UDS routing.
/// This conservative capability gate must be revisited only after the adapter
/// negotiates a versioned, explicitly advertised multi-ECU capability.
/// KW905/ordinary ELM access is not restricted by M5CAN's private allowlist.
public enum PhysicalUDS22Compatibility {
    /// Device name can only RESTRICT diagnostic traffic; it never grants a capability.
    /// If a M5CAN capability handshake fails, remain on the safe ECU01-only path.
    public static func restrictionApplies(
        negotiatedM5CAN: Bool, identifiedM5CAN: Bool, adapterName: String?
    ) -> Bool {
        negotiatedM5CAN || identifiedM5CAN ||
            (adapterName?.uppercased().contains("M5CAN") ?? false)
    }

    public static func allows(ecu: String, m5canRestricted: Bool) -> Bool {
        guard ecu.count == 2, let source = UInt8(ecu, radix: 16) else {
            return false
        }
        return !m5canRestricted || source == 0x01
    }
}
