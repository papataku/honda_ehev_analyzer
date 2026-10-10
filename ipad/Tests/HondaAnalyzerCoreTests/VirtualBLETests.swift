import Foundation
import XCTest
@testable import HondaAnalyzerCore

final class VirtualBLETests: XCTestCase {
    private func reply(_ command: String, peripheral: SimulatedELMPeripheral) -> String {
        let chunks = peripheral.notificationChunks(for: Data((command + "\r").utf8))
        // Two separate GATT notification fragments, reassembled by the consumer.
        XCTAssertEqual(chunks.count, 2)
        return String(decoding: chunks.reduce(Data(), +), as: UTF8.self)
    }

    func testVirtualPeripheralDecodesKnownVehicleSignals() {
        let simulated = SimulatedELMPeripheral()
        XCTAssertEqual(decodeEngineRPM(reply("010C", peripheral: simulated)), 1200)
        XCTAssertEqual(decodeEngineRPM(reply("010C", peripheral: simulated)), 1440)
        XCTAssertEqual(decodeVehicleSpeed(reply("010D", peripheral: simulated)), 0)
        XCTAssertEqual(decodeCoolantC(reply("0105", peripheral: simulated)), 90)
        XCTAssertEqual(decodeBatterySOC(reply("015B", peripheral: simulated)) ?? -1, 60, accuracy: 0.001)
        let hybrid = decodeHybridEv9A(reply("019A", peripheral: simulated))
        XCTAssertEqual(hybrid?.voltageV ?? 0, 288, accuracy: 0.001)
        XCTAssertEqual(hybrid?.currentA ?? 0, -10, accuracy: 0.001)
        XCTAssertEqual(hybrid?.powerKW ?? 0, -2.88, accuracy: 0.001)
        XCTAssertEqual(findUDS22Payload(reply("222012", peripheral: simulated), did: 0x2012)?.payload,
                       Data([0xAA, 0xBB, 0xCC]))
    }

    func testMovingScenarioAndUnknownDIDAreSafe() {
        let simulated = SimulatedELMPeripheral()
        simulated.vehicleState = .moving
        XCTAssertEqual(decodeVehicleSpeed(reply("010D", peripheral: simulated)), 42)
        XCTAssertTrue(reply("222013", peripheral: simulated).contains("NO DATA"))
        XCTAssertEqual(reply("2E201200", peripheral: simulated), "?\r>")
    }

    @MainActor
    func testElmInitializationAndFragmentedGATTNotifications() async throws {
        @MainActor
        final class VirtualTransport: ElmByteTransport {
            var onReceive: ((Data) -> Void)?
            let peripheral = SimulatedELMPeripheral()

            func write(_ data: Data) throws {
                for part in peripheral.notificationChunks(for: data) {
                    onReceive?(part)
                }
            }
        }

        let transport = VirtualTransport()
        let session = ElmCommandSession(transport: transport)
        let results = await session.initialize()
        XCTAssertEqual(results.count, elmInitCommands.count + elmMetaCommands.count)
        XCTAssertTrue(results.allSatisfy(\.success), "\(results.filter { !$0.success })")
        let rpm = try await session.command("010C")
        XCTAssertTrue(rpm.success)
        XCTAssertEqual(decodeEngineRPM(rpm.text), 1200)
        XCTAssertGreaterThan(transport.peripheral.commandCount, 13)
    }
}
