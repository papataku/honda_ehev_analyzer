import Foundation

/// Test-mode admission: never authorize reads from an unverified live adapter.
public enum BLESoakPolicy {
    public static let pids = ["010C", "010D", "0105", "015B", "019A"]
    public static func demoVerified(_ reply: String) -> Bool {
        guard let cap = M5CANCapabilities.parse(reply), cap.supportsOBD01 else { return false }
        let tokens = reply.components(separatedBy: .whitespacesAndNewlines)
        return tokens.contains("MODE=DEMO") && tokens.contains("DEMO=1")
    }
    public static func validRunID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) ||
            (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
