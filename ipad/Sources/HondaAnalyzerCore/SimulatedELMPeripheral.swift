import Foundation

/// A deterministic virtual ELM327 endpoint for the iPadOS Simulator.
/// This is a GATT/ELM *protocol model*, not ESP32 instruction-set emulation.
/// It never touches Bluetooth hardware or a vehicle.
public final class SimulatedELMPeripheral {
    public enum VehicleState {
        case parked
        case moving
    }

    public static let identifier = UUID(uuidString: "A1100000-0000-4000-8000-000000000905")!
    public static let advertisedName = "ESP32-ELM327-SIM"
    public var vehicleState: VehicleState = .parked
    public var notificationIntervalMs = 15
    public private(set) var commandCount = 0
    private var rpmSamples = 0

    public init() {}

    /// Simulate characteristic Write -> fragmented Notify packets.
    /// The output follows the same CR + ELM prompt framing as the real adapter.
    public func notificationChunks(for write: Data) -> [Data] {
        let command = String(decoding: write, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { !$0.isWhitespace }
        commandCount += 1
        let response = reply(to: command)
        let bytes = Array(response.utf8)
        guard bytes.count > 2 else { return [Data(bytes)] }
        let split = max(1, bytes.count / 2)
        return [Data(bytes[..<split]), Data(bytes[split...])]
    }

    private func reply(to command: String) -> String {
        guard isReadOnlyVehicleCommand(command) else { return "?\r>" }
        switch command {
        case "ATZ": return "ELM327 v1.5 SIM\r\r>"
        case "ATI": return "ELM327 v1.5 SIM\r>"
        case "ATDP": return "ISO 15765-4 CAN (29 bit ID, 500 kbaud)\r>"
        case "ATDPN": return "7\r>"
        case "AT@1": return "ESP32 Virtual ELM327\r>"
        case "010C":
            // Sample advances on each RPM request, so Live Poll is visibly alive.
            let rpm = 1200 + (rpmSamples % 12) * 240
            rpmSamples += 1
            return String(format: "18DAF10104410C%04X\r>", rpm * 4)
        case "010D":
            return vehicleState == .parked
                ? "18DAF10103410D00\r>"
                : "18DAF10103410D2A\r>"
        case "0105": return "18DAF10103410582\r>" // 90 C
        case "015B": return "18DAF10103415B99\r>" // 60% SOC
        case "019A":
            // ISO-TP 8-byte payload: 41 9A 06 01 48 00 FF 9C
            // 288 V, -10 A = -2.88 kW (charging).
            return "18DAF1011008419A06014800\r18DAF10121FF9C\r>"
        case "222012":
            return "18DAF10106622012AABBCC\r>"
        default:
            if command.hasPrefix("AT") { return "OK\r>" }
            return "NO DATA\r>"
        }
    }
}
