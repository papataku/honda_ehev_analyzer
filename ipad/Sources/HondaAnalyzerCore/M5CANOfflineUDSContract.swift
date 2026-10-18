import Foundation

/// The adapter's offline UDS22 routing grammar used only for host/simulator
/// compatibility testing. The actual command sender never consults this type
/// and it does not grant physical CAN permissions for any ECU.
public struct M5CANOfflineUDSContract: Equatable, Sendable {
    public let advertisedECUs: Set<String>

    /// Refuses missing or non-disabled TX fields even if firmware claims
    /// support for more physical ECUs. Never parse this as an authorization.
    public static func parse(_ response: String) -> M5CANOfflineUDSContract? {
        guard let capabilities = M5CANCapabilities.parse(response),
              capabilities.major == 1, capabilities.minor == 2,
              capabilities.supportsUDS22 else { return nil }

        guard let line = response.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines.union(
                CharacterSet(charactersIn: ">"))) })
            .first(where: { $0.hasPrefix("M5CAN-CAPS ") })
        else { return nil }

        var fields: [String: String] = [:]
        for part in line.split(separator: " ").dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1,
                                  omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = String(pair[0])
            guard fields[key] == nil else { return nil }
            fields[key] = String(pair[1])
        }
        guard fields["TX"] == "DISABLED",
              fields["ROUTE"] == "R12",
              fields["UDS_ECUS"] != nil,
              capabilities.advertisedPhysicalUDSEcus.contains("01")
        else { return nil }

        return M5CANOfflineUDSContract(
            advertisedECUs: capabilities.advertisedPhysicalUDSEcus
        )
    }

    /// Produces a host-test vector, not a command that may be sent to a car.
    /// This is deliberately separate from ElmCommandSession.command().
    public func testOnlyRouteVector(ecu: String, did: String) -> String? {
        guard advertisedECUs.contains(ecu),
              ecu.count == 2, ecu.uppercased() == ecu,
              did.count == 4, did.uppercased() == did,
              UInt8(ecu, radix: 16) != nil,
              UInt16(did, radix: 16) != nil
        else { return nil }
        return "ATM5R12:\(ecu):\(did)"
    }
}
