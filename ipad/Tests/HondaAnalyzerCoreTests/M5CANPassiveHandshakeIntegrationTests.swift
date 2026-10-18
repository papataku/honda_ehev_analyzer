import Foundation
import XCTest
@testable import HondaAnalyzerCore

/// Golden adapter capability fixture: corresponds to the physical-TX-disabled
/// M5CAN PlatformIO build, never a vehicle-capable protocol 1.2.
@MainActor
private final class PassiveM5CANFake: ElmByteTransport {
    var onReceive: ((Data) -> Void)?
    private(set) var commands: [String] = []
    let capability = "M5CAN-CAPS PROTO=1.2 FW=0.4.4-phase3f-demo-touch " +
        "BATCH=16 OPS=OBD01,UDS22 STREAM=0 LEASE=IMPLICIT " +
        "UDS_ECUS=01,02,06,0E,EF TX=OFF"

    func write(_ data: Data) throws {
        let command = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        commands.append(command)
        switch command {
        case "ATZ", "ATI":
            onReceive?(Data("M5CAN ELM327 compatible\r>".utf8))
        case "ATM5CAP":
            onReceive?(Data((capability + "\r>").utf8))
        default:
            onReceive?(Data("OK\r>".utf8))
        }
    }
}

final class M5CANPassiveHandshakeIntegrationTests: XCTestCase {
    @MainActor
    func testNegotiatedPassiveCapabilityBlocksAllPhysicalReads() async throws {
        let transport = PassiveM5CANFake()
        let session = ElmCommandSession(transport: transport)
        _ = await session.initialize()

        XCTAssertTrue(session.identifiesAsM5CAN)
        let caps = try XCTUnwrap(session.negotiatedM5CAN)
        XCTAssertEqual(caps.major, 1)
        XCTAssertEqual(caps.minor, 2)
        XCTAssertTrue(caps.isPassiveDiagnosticBench)
        XCTAssertEqual(caps.advertisedPhysicalUDSEcus,
                       Set(["01", "02", "06", "0E", "EF"]))
        let commandCount = transport.commands.count

        for command in ["010C", "22" + "2012", "ATM5B00:010C",
                        "ATM5B01:2012", "ATM5R12:02:2012", "ATM5TX1"] {
            do {
                _ = try await session.command(command)
                XCTFail("TX=OFF must deny diagnostic command \(command)")
            } catch ElmCommandError.m5canPassiveTransmitDisabled {
                // Expected, and no BLE write for this request.
            } catch ElmCommandError.unsafeCommand {
                // The legacy safety gate additionally denies unrecognized
                // experimental commands; still no BLE diagnostic write.
                XCTAssertEqual(command, "ATM5R12:02:2012")
            } catch {
                XCTFail("unexpected error for \(command): \(error)")
            }
        }
        XCTAssertEqual(transport.commands.count, commandCount)

        do {
            _ = try await session.batchRead(group: .mode01, ids: ["010C"])
            XCTFail("TX-disabled device must not start batched vehicle data")
        } catch ElmCommandError.m5canPassiveTransmitDisabled {
            // Expected
        }
        XCTAssertEqual(transport.commands.count, commandCount)

        session.resetProtocolNegotiation()
        XCTAssertNil(session.negotiatedM5CAN)
        XCTAssertFalse(session.identifiesAsM5CAN)
    }

    @MainActor
    func testLegacyNormalM5CAN1Point1RemainsParseable() throws {
        let response = "M5CAN-CAPS PROTO=1.1 FW=0.4.4 BATCH=16 " +
            "OPS=OBD01,UDS22 STREAM=0 LEASE=IMPLICIT"
        let cap = try XCTUnwrap(M5CANCapabilities.parse(response))
        XCTAssertFalse(cap.isPassiveDiagnosticBench)
        XCTAssertEqual(cap.advertisedPhysicalUDSEcus, Set(["01"]))
        XCTAssertTrue(cap.supportsUDS22)
    }

    @MainActor
    func testPassiveCapabilityNotMistakenForPhysicalTransmitPermission() throws {
        let cap = try XCTUnwrap(M5CANCapabilities.parse(PassiveM5CANFake().capability))
        XCTAssertTrue(cap.isPassiveDiagnosticBench)
        for ecu in cap.advertisedPhysicalUDSEcus where ecu != "01" {
            XCTAssertFalse(PhysicalUDS22Compatibility.allows(
                ecu: ecu, m5canRestricted: true
            ))
        }
        // TX=READ_ONLY must not become supported without a separately
        // reviewed protocol implementation and new safety gates.
        XCTAssertNil(M5CANCapabilities.parse(
            PassiveM5CANFake().capability.replacingOccurrences(
                of: "TX=OFF", with: "TX=READ_ONLY"
            )
        ))
    }
}
