import Foundation
import XCTest
@testable import HondaAnalyzerCore

@MainActor
private final class OfflineCapsFixtureTransport: ElmByteTransport {
    var onReceive: ((Data) -> Void)?
    var sentCommands: [String] = []
    func write(_ data: Data) throws {
        let command = String(decoding: data, as: UTF8.self)
        sentCommands.append(command)
        let reply: String
        switch command {
        case "ATI\r":
            reply = "M5CAN v0.4 ELM-CAN compatible"
        case "ATM5CAP\r":
            reply = "M5CAN-CAPS PROTO=1.1 FW=0.4.4 BATCH=16 " +
                "OPS=OBD01,UDS22 STREAM=0 LEASE=IMPLICIT"
        case "ATM5CAPD\r":
            reply = "M5CAN-CAPS PROTO=1.2 FW=0.4.4 BATCH=16 " +
                "OPS=OBD01,UDS22 STREAM=0 LEASE=IMPLICIT " +
                "UDS_ECUS=01,02,06,0E,EF ROUTE=R12 TX=DISABLED"
        default:
            reply = "?"
        }
        onReceive?(Data((reply + "\r>").utf8))
    }
}

final class M5CANOfflineUDSContractTests: XCTestCase {
    private let prefix =
        "M5CAN-CAPS PROTO=1.2 FW=0.4.4 BATCH=16 OPS=OBD01,UDS22 " +
        "STREAM=0 LEASE=IMPLICIT UDS_ECUS=01,02,06,0E,EF ROUTE=R12"

    func testAdapterGoldenContractHasNoTransmissionPermission() throws {
        let contract = try XCTUnwrap(M5CANOfflineUDSContract.parse(
            prefix + " TX=DISABLED\r>"
        ))
        XCTAssertEqual(contract.advertisedECUs,
                       Set(["01", "02", "06", "0E", "EF"]))
        for ecu in ["01", "02", "06", "0E", "EF"] {
            XCTAssertEqual(contract.testOnlyRouteVector(ecu: ecu, did: "2012"),
                           "ATM5R12:\(ecu):2012")
            XCTAssertEqual(contract.testOnlyRouteVector(ecu: ecu, did: "E480"),
                           "ATM5R12:\(ecu):E480")
        }
        XCTAssertNil(contract.testOnlyRouteVector(ecu: "03", did: "2012"))
        XCTAssertNil(contract.testOnlyRouteVector(ecu: "0e", did: "2012"))
        XCTAssertNil(contract.testOnlyRouteVector(ecu: "02", did: "2G12"))
        XCTAssertNil(contract.testOnlyRouteVector(ecu: "02", did: "201"))
        // Simulator contract MUST NOT change the production ECU01-only gate.
        XCTAssertFalse(PhysicalUDS22Compatibility.allows(
            ecu: "02", m5canRestricted: true
        ))
    }

    func testNeverAcceptActualTXorImplicitAuthorization() {
        for suffix in [
            "",
            " TX=ENABLED",
            " TX=1",
            " TX=READONLY",
            " TX=DISABLED TX=ENABLED",
            " TX=DISABLED ROUTE=R12",
            " TX=DISABLED UDS_ECUS=02,06"
        ] {
            XCTAssertNil(M5CANOfflineUDSContract.parse(prefix + suffix), suffix)
        }
        XCTAssertNil(M5CANOfflineUDSContract.parse(
            prefix.replacingOccurrences(of: "PROTO=1.2", with: "PROTO=1.1") +
                " TX=DISABLED"
        ))
        XCTAssertNil(M5CANOfflineUDSContract.parse(
            prefix.replacingOccurrences(of: "PROTO=1.2", with: "PROTO=1.3") +
                " TX=DISABLED"
        ))
    }

    @MainActor
    func testOfflineMetadataExchangeDoesNotSendVehicleRequest() async throws {
        let transport = OfflineCapsFixtureTransport()
        let session = ElmCommandSession(transport: transport)
        let identity = try await session.command("ATI")
        XCTAssertTrue(identity.success)
        XCTAssertTrue(session.identifiesAsM5CAN)

        let legacy = try await session.command("ATM5CAP")
        XCTAssertEqual(M5CANCapabilities.parse(legacy.text)?.minor, 1)
        let offline = try await session.command("ATM5CAPD")
        let contract = try XCTUnwrap(M5CANOfflineUDSContract.parse(offline.text))
        XCTAssertEqual(contract.testOnlyRouteVector(ecu: "02", did: "2012"),
                       "ATM5R12:02:2012")
        XCTAssertEqual(transport.sentCommands,
                       ["ATI\r", "ATM5CAP\r", "ATM5CAPD\r"])
        XCTAssertFalse(PhysicalUDS22Compatibility.allows(
            ecu: "02", m5canRestricted: session.identifiesAsM5CAN
        ))
    }

    func testMissingExplicitRoutingListFailsClosed() {
        let missing = prefix.replacingOccurrences(
            of: " UDS_ECUS=01,02,06,0E,EF", with: ""
        )
        XCTAssertNil(M5CANOfflineUDSContract.parse(missing + " TX=DISABLED"))
        XCTAssertNil(M5CANOfflineUDSContract.parse(
            "M5CAN-CAPS PROTO=1.1 FW=0.4.4 BATCH=16 " +
            "OPS=OBD01,UDS22 STREAM=0 LEASE=IMPLICIT"
        ))
        XCTAssertNil(M5CANOfflineUDSContract.parse("?\r>"))
    }
}
