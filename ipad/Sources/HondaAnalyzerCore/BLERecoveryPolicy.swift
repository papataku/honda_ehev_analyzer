import Foundation

/// Deliberately limited recovery policy. A new connection alone is not enough
/// to authorize reads: the caller must reinitialize ELM and validate signals.
public enum BLERecoveryActivity: String, Sendable {
    case recordingOnly, live, driving, unknownDidScan
}
public enum BLERecoveryPolicy {
    /// At most eight attempts, with bounded backoff instead of a tight loop.
    public static let retryDelaysSeconds: [Double] = [0, 1, 2, 4, 8, 16, 16, 16]

    public static func shouldReconnect(
        enabled: Bool, hasKnownPeripheral: Bool, manualDisconnect: Bool,
        isRecording: Bool, isLivePolling: Bool, isDriving: Bool, isDidScanning: Bool
    ) -> Bool {
        enabled && hasKnownPeripheral && !manualDisconnect &&
            (isRecording || isLivePolling || isDriving || isDidScanning)
    }

    /// Unknown DID discovery is *never* authorized merely by restoring BLE.
    public static func canAutoResume(_ activity: BLERecoveryActivity) -> Bool {
        switch activity {
        case .live, .driving: return true
        case .recordingOnly, .unknownDidScan: return false
        }
    }
}
