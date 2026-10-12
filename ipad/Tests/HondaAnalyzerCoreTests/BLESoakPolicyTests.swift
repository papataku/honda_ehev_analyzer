import XCTest
@testable import HondaAnalyzerCore
final class BLESoakPolicyTests: XCTestCase {
    func testNoReadOnLiveOrUnverifiedAdapter() {
        let cap = "M5CAN-CAPS FW=test PROTO=1.1 BATCH=16 OPS=OBD01,UDS22 STREAM=0 LEASE=IMPLICIT"
        XCTAssertTrue(BLESoakPolicy.demoVerified(cap + " DEMO=1 MODE=DEMO"))
        XCTAssertFalse(BLESoakPolicy.demoVerified(cap + " DEMO=1 MODE=CAN"))
        XCTAssertFalse(BLESoakPolicy.demoVerified(cap + " DEMO=1 MODE=DEMO_OFF"))
        XCTAssertFalse(BLESoakPolicy.demoVerified("M5CAN DEMO=1 MODE=DEMO"))
        XCTAssertFalse(BLESoakPolicy.demoVerified(cap))
    }
    func testOnlySafeRunPathsAndKnownPIDs() {
        XCTAssertTrue(BLESoakPolicy.validRunID("ipad-only-20261012"))
        XCTAssertFalse(BLESoakPolicy.validRunID("../../existing-session"))
        XCTAssertFalse(BLESoakPolicy.validRunID(""))
        XCTAssertFalse(BLESoakPolicy.validRunID("name\n"))
        XCTAssertFalse(BLESoakPolicy.validRunID(String(repeating: "a", count: 81)))
        XCTAssertEqual(BLESoakPolicy.pids, ["010C", "010D", "0105", "015B", "019A"])
    }
}
