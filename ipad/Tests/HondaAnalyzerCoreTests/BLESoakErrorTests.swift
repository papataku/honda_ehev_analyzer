import XCTest
@testable import HondaAnalyzerCore

@MainActor final class ErrorTransport: ElmByteTransport {
    var onReceive: ((Data) -> Void)?
    var writes: [String] = []
    func emit(_ text: String) { onReceive?(Data(text.utf8)) }
    func write(_ data: Data) throws {
        let c = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        writes.append(c)
        switch c {
        case "ATZ", "ATI": emit("M5CAN v0.4 ELM-CAN compatible\r>")
        case "ATM5CAP": emit("M5CAN-CAPS PROTO=1.1 FW=test BATCH=16 OPS=OBD01,UDS22 STREAM=0 LEASE=IMPLICIT\r>")
        case "2220FF": emit("NO DATA\r>")
        case "22FE08": emit("18DAF101 03 7F 22 31\r>")
        case "22FE09": emit("18DAF101 03 7F 22 33\r>")
        case "222012": emit("18DAF101 10 0A 62 20 12 AA BB CC\rBUFFER FULL\r>")
        case "22FFFF": break // no bytes and no prompt: real command timeout
        case "ATM5B01:2012,20FF,FE08": emit("M5ITEM:01:2012\r18DAF101 05 62 20 12 AA BB\rM5ITEM:01:20FF\rNO DATA\rM5ITEM:01:FE08\r18DAF101 03 7F 22 31\rM5DONE\r>")
        case "010C": emit("18DAF101 04 41 0C 1F 40\r>")
        default: emit("OK\r>")
        }
    }
}
final class BLESoakErrorTests: XCTestCase {
    @MainActor func testNoDataNrcAndPartialDoNotClearNegotiation() async throws {
        let transport = ErrorTransport()
        // Use one shared transport to observe commands; never fake BLE callbacks.
        let active = ElmCommandSession(transport: transport)
        _ = await active.initialize()
        let expected: [(String, UInt16, DidProbeStatus, UInt8?)] = [
            ("2220FF", 0x20FF, .noData, nil),
            ("22FE08", 0xFE08, .nrc, 0x31),
            ("22FE09", 0xFE09, .nrc, 0x33),
            ("222012", 0x2012, .positivePartial, nil)
        ]
        for (command, did, status, nrc) in expected {
            let result = try await active.command(command)
            let classified = classifyUDS22Text(result.text, ecu: "01", did: did)
            XCTAssertEqual(classified.status, status)
            XCTAssertEqual(classified.nrc, nrc)
            XCTAssertNotNil(active.negotiatedM5CAN)
            let rpm = try await active.command("010C")
            XCTAssertEqual(decodeEngineRPM(rpm.text), 2000)
        }
        XCTAssertEqual(transport.writes.filter { $0 == "ATZ" }.count, 1)
    }
    @MainActor func testMixedBatchRetainsPositiveAndErrorItems() async throws {
        let transport = ErrorTransport()
        let active = ElmCommandSession(transport: transport)
        _ = await active.initialize()
        let (result, batch) = try await active.batchRead(group: .ecu01ReadDID, ids: ["2012", "20FF", "FE08"])
        XCTAssertFalse(result.success) // whole text contains NO DATA
        XCTAssertEqual(batch.items.count, 3) // individual good data must survive
        let statuses = zip(batch.items, [UInt16(0x2012), 0x20FF, 0xFE08]).map {
            classifyUDS22Text($0.0.responseText, ecu: "01", did: $0.1).status
        }
        XCTAssertEqual(statuses, [.positive, .noData, .nrc])
        XCTAssertNotNil(active.negotiatedM5CAN)
        let rpm = try await active.command("010C")
        XCTAssertEqual(decodeEngineRPM(rpm.text), 2000)
    }
    @MainActor func testNoPromptTimeoutThenLateReplyCanRecoverWithoutReconnect() async throws {
        let transport = ErrorTransport()
        let session = ElmCommandSession(transport: transport)
        _ = await session.initialize()
        do {
            _ = try await session.command("22FFFF", timeout: 0.02)
            XCTFail("expected timeout")
        } catch {
            guard case ElmCommandError.timeout = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertNotNil(session.negotiatedM5CAN)
        transport.emit("NO DATA\r>") // late old prompt while no next request pending
        let rpm = try await session.command("010C")
        XCTAssertEqual(decodeEngineRPM(rpm.text), 2000)
        XCTAssertEqual(transport.writes.filter { $0 == "ATZ" }.count, 1)
    }
}
