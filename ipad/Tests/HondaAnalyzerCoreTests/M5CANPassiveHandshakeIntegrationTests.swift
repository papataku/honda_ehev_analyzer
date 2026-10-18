import Foundation
import XCTest
@testable import HondaAnalyzerCore

/// Golden adapter capability fixture: corresponds to the physical-TX-disabled
/// M5CAN PlatformIO build, never a vehicle-capable protocol 1.2.
@MainActor
private final class PassiveM5CANFake: ElmByteTransport {
    var onReceive: ((Data) -> Void)?
    private(set) var commands: [String] = []
    var capability = "M5CAN-CAPS PROTO=1.2 FW=0.4.4-phase3f-demo-touch " +
        "BATCH=16 OPS=OBD01,UDS22 STREAM=0 LEASE=IMPLICIT " +
        "UDS_ECUS=01,02,06,0E,EF TX=OFF"
    var omitCapabilityReply = false
    var atzIdentity = "M5CAN ELM327 compatible"
    var atiIdentity = "M5CAN ELM327 compatible"

    func write(_ data: Data) throws {
        let command = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        commands.append(command)
        switch command {
        case "ATZ":
            onReceive?(Data((atzIdentity + "\r>").utf8))
        case "ATI":
            onReceive?(Data((atiIdentity + "\r>").utf8))
        case "ATM5CAP":
            if !omitCapabilityReply {
                onReceive?(Data((capability + "\r>").utf8))
            }
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
    func testInvalidAdvertisedCapabilitiesNeverFallBackToELM() async throws {
        let baseline = PassiveM5CANFake().capability
        let malformed = [
            baseline.replacingOccurrences(of: "TX=OFF", with: "TX=ON"),
            baseline.replacingOccurrences(of: "TX=OFF", with: "TX=READ_ONLY"),
            baseline.replacingOccurrences(of: " TX=OFF", with: ""),
            baseline.replacingOccurrences(of: "PROTO=1.2", with: "PROTO=2.0"),
            "M5CAN-CAPS PROTO=1.2 FW=0.5 BATCH=16 OPS=UDS22 STREAM=0",
            "OK"
        ]
        for reply in malformed {
            let fake = PassiveM5CANFake()
            fake.capability = reply
            let session = ElmCommandSession(transport: fake)
            _ = await session.initialize()
            XCTAssertTrue(session.identifiesAsM5CAN)
            XCTAssertNil(session.negotiatedM5CAN)
            XCTAssertTrue(session.m5canCapabilitiesRejected, reply)

            let before = fake.commands.count
            for command in ["010C", "222012", "ATM5B01:2012", "ATM5TX1"] {
                do {
                    _ = try await session.command(command)
                    XCTFail("malformed M5CAN-CAPS should reject \(command)")
                } catch ElmCommandError.m5canUnrecognizedCapabilities {
                    // No BLE diagnostic write (and no lease request).
                } catch {
                    XCTFail("unexpected \(command): \(error)")
                }
            }
            do {
                _ = try await session.batchRead(group: .ecu01ReadDID, ids: ["2012"])
                XCTFail("malformed M5CAN-CAPS must not issue a batch")
            } catch ElmCommandError.m5canUnrecognizedCapabilities {
                // Expected.
            }
            XCTAssertEqual(fake.commands.count, before)
            // Metadata remains accessible for diagnostics; no vehicle TX.
            let info = try await session.command("ATI")
            XCTAssertTrue(info.success)
        }
    }

    @MainActor
    func testATZIdentifiedM5CANCannotBeDowngradedByGenericATI() async throws {
        let fake = PassiveM5CANFake()
        fake.atiIdentity = "ELM327 v1.5"
        let session = ElmCommandSession(transport: fake)
        _ = await session.initialize()
        XCTAssertTrue(session.identifiesAsM5CAN)
        XCTAssertTrue(fake.commands.contains("ATM5CAP"))
        XCTAssertTrue(session.negotiatedM5CAN?.isPassiveDiagnosticBench == true)
        let count = fake.commands.count
        do {
            _ = try await session.command("010C")
            XCTFail("Generic ATI cannot override earlier M5CAN ATZ identity")
        } catch ElmCommandError.m5canPassiveTransmitDisabled {
            // Expected.
        }
        XCTAssertEqual(fake.commands.count, count)
    }

    @MainActor
    func testM5CANATZWithFailedATICannotTransmit() async throws {
        let fake = PassiveM5CANFake()
        fake.atiIdentity = "ERROR"
        let session = ElmCommandSession(transport: fake)
        _ = await session.initialize()
        XCTAssertTrue(session.identifiesAsM5CAN)
        XCTAssertTrue(session.m5canCapabilitiesRejected)
        XCTAssertNil(session.negotiatedM5CAN)
        XCTAssertFalse(fake.commands.contains("ATM5CAP"))
        let count = fake.commands.count
        do {
            _ = try await session.command("010C")
            XCTFail("Unverified M5CAN after failed ATI cannot transmit")
        } catch ElmCommandError.m5canUnrecognizedCapabilities {
            // Expected.
        }
        XCTAssertEqual(fake.commands.count, count)
    }

    @MainActor
    func testCapabilityTimeoutNeverFallsBackToRawVehicleRequests() async throws {
        let transport = PassiveM5CANFake()
        transport.omitCapabilityReply = true
        let session = ElmCommandSession(transport: transport)
        _ = await session.initialize() // timeout is intentionally 2 seconds
        XCTAssertTrue(session.identifiesAsM5CAN)
        XCTAssertNil(session.negotiatedM5CAN)
        XCTAssertTrue(session.m5canCapabilitiesRejected)
        let count = transport.commands.count
        XCTAssertEqual(transport.commands.last, "ATM5CAP")
        do {
            _ = try await session.command("010C")
            XCTFail("CAPS timeout must not fall back to legacy CAN TX")
        } catch ElmCommandError.m5canUnrecognizedCapabilities {
            // Expected, with no additional BLE write or TX lease request.
        }
        XCTAssertEqual(transport.commands.count, count)

        // Reinitializing with explicit old-firmware '?' is a new handshake,
        // never reuse the prior timeout's state or claim a future protocol.
        transport.omitCapabilityReply = false
        transport.capability = "?"
        _ = await session.initialize()
        XCTAssertFalse(session.m5canCapabilitiesRejected)
        _ = try await session.command("010D")
        XCTAssertEqual(transport.commands.last, "010D")
    }

    @MainActor
    func testUnsupportedOldCapabilitiesRetainLegacyFallbackAndReconnectClearsLock() async throws {
        let fake = PassiveM5CANFake()
        fake.capability = "?"
        let session = ElmCommandSession(transport: fake)
        _ = await session.initialize()
        XCTAssertTrue(session.identifiesAsM5CAN)
        XCTAssertFalse(session.m5canCapabilitiesRejected)
        XCTAssertNil(session.negotiatedM5CAN)
        _ = try await session.command("010C")
        XCTAssertEqual(Array(fake.commands.suffix(2)), ["ATM5TX1", "010C"])

        // Device replacement must clear a previously rejected profile.
        session.resetProtocolNegotiation()
        fake.capability = "M5CAN-CAPS PROTO=2.0 FW=2 BATCH=16 OPS=UDS22 STREAM=0 TX=OFF"
        _ = await session.initialize()
        XCTAssertTrue(session.m5canCapabilitiesRejected)
        session.resetProtocolNegotiation()
        XCTAssertFalse(session.m5canCapabilitiesRejected)
        fake.capability = "?"
        _ = await session.initialize()
        XCTAssertFalse(session.m5canCapabilitiesRejected)
        _ = try await session.command("010D")
        XCTAssertEqual(fake.commands.last, "010D")
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
