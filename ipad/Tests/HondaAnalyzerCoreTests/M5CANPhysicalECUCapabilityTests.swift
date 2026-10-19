import XCTest
@testable import HondaAnalyzerCore

final class M5CANPhysicalECUCapabilityTests: XCTestCase {
    private let legacy =
        "M5CAN-CAPS PROTO=1.1 FW=0.4.4 BATCH=16 OPS=OBD01,UDS22 STREAM=0 LEASE=IMPLICIT"

    func testLegacyM5CAN11RemainsECU01Only() throws {
        let caps = try XCTUnwrap(M5CANCapabilities.parse(legacy + "\r>"))
        XCTAssertEqual(caps.major, 1)
        XCTAssertEqual(caps.minor, 1)
        XCTAssertEqual(caps.advertisedPhysicalUDSEcus, Set(["01"]))
        XCTAssertTrue(caps.supportsOBD01)
        XCTAssertTrue(caps.supportsUDS22)
        XCTAssertTrue(caps.usesImplicitLease)
        XCTAssertFalse(caps.isPassiveDiagnosticBench)
    }

    func testFutureCapabilityListIsOnlyAnAdapterClaim() throws {
        let future = "M5CAN-CAPS PROTO=1.2 FW=0.5.0 BATCH=16 " +
            "OPS=OBD01,UDS22 STREAM=0 LEASE=IMPLICIT UDS_ECUS=01,02,06,0E,EF TX=OFF"
        let caps = try XCTUnwrap(M5CANCapabilities.parse(future))
        XCTAssertTrue(caps.isPassiveDiagnosticBench)
        XCTAssertEqual(caps.advertisedPhysicalUDSEcus, Set(["01", "02", "06", "0E", "EF"]))
        // The existing iPad's independent physical send gate is still ECU01 only.
        XCTAssertFalse(PhysicalUDS22Compatibility.allows(ecu: "02", m5canRestricted: true))
        XCTAssertTrue(PhysicalUDS22Compatibility.allows(ecu: "01", m5canRestricted: true))
    }

    func testMinorBumpWithoutExplicitListNeverEnablesAdditionalECUs() throws {
        let caps = try XCTUnwrap(M5CANCapabilities.parse(
            legacy.replacingOccurrences(of: "PROTO=1.1", with: "PROTO=1.2") + " TX=OFF"
        ))
        XCTAssertTrue(caps.isPassiveDiagnosticBench)
        XCTAssertEqual(caps.advertisedPhysicalUDSEcus, Set(["01"]))
    }

    func testMalformedOrPrematureECUAllowlistFailsClosed() {
        let prefix = "M5CAN-CAPS PROTO=1.2 FW=0.5 BATCH=16 " +
            "OPS=OBD01,UDS22 STREAM=0 LEASE=IMPLICIT TX=OFF"
        for field in [
            "UDS_ECUS=", "UDS_ECUS=01,", "UDS_ECUS=01,02,02",
            "UDS_ECUS=01,00", "UDS_ECUS=01,FF", "UDS_ECUS=01,F1",
            "UDS_ECUS=01,GG", "UDS_ECUS=01,2", "UDS_ECUS=01,0e",
            "UDS_ECUS=02,06", "UDS_ECUS=01,,02",
            "UDS_ECUS=01,02 UDS_ECUS=01,03"
        ] {
            XCTAssertNil(M5CANCapabilities.parse(prefix + " " + field), field)
        }
        XCTAssertNil(M5CANCapabilities.parse(legacy + " UDS_ECUS=01,02"))
        XCTAssertNil(M5CANCapabilities.parse(legacy + " TX=OFF"))
        XCTAssertNil(M5CANCapabilities.parse(
            prefix.replacingOccurrences(of: " TX=OFF", with: "") +
            " UDS_ECUS=01,02"
        ))
        XCTAssertNil(M5CANCapabilities.parse(
            prefix.replacingOccurrences(of: "TX=OFF", with: "TX=READ_ONLY") +
            " UDS_ECUS=01,02"
        ))
        XCTAssertNil(M5CANCapabilities.parse(
            prefix.replacingOccurrences(of: "TX=OFF", with: "TX=ON") +
            " UDS_ECUS=01,02"
        ))
        XCTAssertNil(M5CANCapabilities.parse(
            prefix.replacingOccurrences(of: "OPS=OBD01,UDS22", with: "OPS=OBD01") +
            " UDS_ECUS=01,02"
        ))
    }

    func testUnknownProtocolMajorIsNotAccepted() {
        XCTAssertNil(M5CANCapabilities.parse(
            legacy.replacingOccurrences(of: "PROTO=1.1", with: "PROTO=2.0")
        ))
    }
}
