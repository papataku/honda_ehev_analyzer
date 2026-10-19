import Foundation
import XCTest
@testable import HondaAnalyzerCore

@MainActor
private final class IdentityReplyTransport: ElmByteTransport {
    var onReceive: ((Data) -> Void)?
    var reply = "M5CAN v0.4 ELM-CAN compatible"
    func write(_ data: Data) throws {
        // Respond synchronously to a metadata command, like a fake BLE peer.
        let command = String(decoding: data, as: UTF8.self)
        precondition(command == "ATI\r")
        onReceive?(Data((reply + "\r>").utf8))
    }
}

final class M5CANIdentityRestrictionTests: XCTestCase {
    @MainActor
    func testATIIdentityRestrictsWhenCapabilitiesAreMissing() async throws {
        let fake = IdentityReplyTransport()
        let session = ElmCommandSession(transport: fake)
        let response = try await session.command("ATI")
        XCTAssertTrue(response.success)
        XCTAssertTrue(session.identifiesAsM5CAN)
        XCTAssertNil(session.negotiatedM5CAN)
        XCTAssertTrue(PhysicalUDS22Compatibility.restrictionApplies(
            negotiatedM5CAN: session.negotiatedM5CAN != nil,
            identifiedM5CAN: session.identifiesAsM5CAN,
            adapterName: "KW905"
        ))
        XCTAssertFalse(PhysicalUDS22Compatibility.allows(
            ecu: "02", m5canRestricted: true
        ))
    }

    @MainActor
    func testIdentityDoesNotPersistAcrossAdapterChange() async throws {
        let fake = IdentityReplyTransport()
        let session = ElmCommandSession(transport: fake)
        _ = try await session.command("ATI")
        XCTAssertTrue(session.identifiesAsM5CAN)
        session.resetProtocolNegotiation()
        XCTAssertFalse(session.identifiesAsM5CAN)
        XCTAssertNil(session.negotiatedM5CAN)
        fake.reply = "ELM327 v1.5"
        let result = try await session.command("ATI")
        XCTAssertTrue(result.success)
        XCTAssertFalse(session.identifiesAsM5CAN)
        XCTAssertFalse(PhysicalUDS22Compatibility.restrictionApplies(
            negotiatedM5CAN: session.negotiatedM5CAN != nil,
            identifiedM5CAN: session.identifiesAsM5CAN,
            adapterName: "KW905"
        ))
    }
}
