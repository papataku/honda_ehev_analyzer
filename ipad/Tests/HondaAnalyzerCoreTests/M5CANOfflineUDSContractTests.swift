import XCTest
@testable import HondaAnalyzerCore

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
