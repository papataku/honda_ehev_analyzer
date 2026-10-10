import Foundation

public struct StationaryResumeTracker: Equatable, Sendable {
    public let requiredZeroSamples: Int
    public let zeroThresholdKmh: Double
    public private(set) var consecutiveZeroSamples: Int = 0

    public init(requiredZeroSamples: Int = 3, zeroThresholdKmh: Double = 0.1) {
        self.requiredZeroSamples = max(1, requiredZeroSamples)
        self.zeroThresholdKmh = max(0, zeroThresholdKmh)
    }

    @discardableResult
    public mutating func observe(speedKmh: Double?) -> Bool {
        guard let speedKmh, speedKmh <= zeroThresholdKmh else {
            consecutiveZeroSamples = 0
            return false
        }
        consecutiveZeroSamples += 1
        return consecutiveZeroSamples >= requiredZeroSamples
    }

    public mutating func reset() {
        consecutiveZeroSamples = 0
    }
}

/**
 Stable 0 km/h is necessary, but never sufficient, to restart unknown DID
 enumeration after a moving interval. The human must reconfirm P/parking.
 The adapter does not have a validated gear-position PID.
 */
public func mayResumeUnknownDID(stableZero: Bool, parkingConfirmed: Bool) -> Bool {
    stableZero && parkingConfirmed
}
