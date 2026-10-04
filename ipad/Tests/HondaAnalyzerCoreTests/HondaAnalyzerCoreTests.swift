import XCTest
@testable import HondaAnalyzerCore

final class HondaAnalyzerCoreTests: XCTestCase {
    func testPromptFramerHandlesFragmentsAndMergedResponses() {
        let framer = ElmPromptFramer()
        XCTAssertTrue(framer.feed(Data("41 0C".utf8)).isEmpty)
        let responses = framer.feed(Data(" 1F 40>OK>tail".utf8))
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(responses[0].text, "41 0C 1F 40>")
        XCTAssertEqual(responses[1].text, "OK>")
        XCTAssertEqual(String(decoding: framer.pending, as: UTF8.self), "tail")
    }

    func testReadOnlyGuardMatchesPythonPolicy() {
        XCTAssertTrue(isReadOnlyVehicleCommand("ATZ"))
        XCTAssertTrue(isReadOnlyVehicleCommand("01 0C"))
        XCTAssertTrue(isReadOnlyVehicleCommand("0902"))
        XCTAssertTrue(isReadOnlyVehicleCommand("22 2012"))
        XCTAssertFalse(isReadOnlyVehicleCommand("2E201200"))
        XCTAssertFalse(isReadOnlyVehicleCommand("1101"))
    }

    func testKnownStandardOBDDecoders() {
        XCTAssertEqual(decodeEngineRPM("18DAF10104410C1F40\r>"), 2000.0)
        XCTAssertEqual(decodeVehicleSpeed("18DAF10103410D64\r>"), 100)
        XCTAssertEqual(decodeCoolantC("18DAF10103410550\r>"), 40)
        let soc = decodeBatterySOC("18DAF10103415B80\r>")
        XCTAssertNotNil(soc)
        XCTAssertEqual(soc!, 128.0 * 100.0 / 255.0, accuracy: 0.0001)
    }

    func testHybridEv9AReassemblesIsoTpAndUsesSignedCurrent() {
        let text = """
        18DAF1011008419A06014800
        18DAF10121FF9C
        >
        """
        let value = decodeHybridEv9A(text)
        XCTAssertNotNil(value)
        XCTAssertEqual(value?.voltageV ?? 0, 288.0, accuracy: 0.0001)
        XCTAssertEqual(value?.currentA ?? 0, -10.0, accuracy: 0.0001)
        XCTAssertEqual(value?.powerKW ?? 0, -2.88, accuracy: 0.0001)
    }

    func testUDS22PayloadAndCanID() {
        let hit = findUDS22Payload("18DAF10106622012AABBCC\r>", did: 0x2012)
        XCTAssertEqual(hit?.canID, "18DAF101")
        XCTAssertEqual(hit?.payload, Data([0xAA, 0xBB, 0xCC]))
    }

    func testPartialIsoTpPreservesReceivedPrefix() {
        let text = """
        18DAF101101062201201020304
        18DAF1012105060708090A0B
        BUFFER FULL
        >
        """
        let partial = isoTpPartialMessages(text).first
        XCTAssertNotNil(partial)
        XCTAssertEqual(partial?.canID, "18DAF101")
        XCTAssertEqual(partial?.totalLength, 0x10)
        XCTAssertEqual(partial?.payload.prefix(3), Data([0x62, 0x20, 0x12]))
    }
    @MainActor
    func testElmCommandSessionSerializesAndFramesResponse() async throws {
        final class FakeTransport: ElmByteTransport {
            var onReceive: ((Data) -> Void)?
            var writes: [Data] = []
            func write(_ data: Data) throws { writes.append(data) }
            func emit(_ text: String) { onReceive?(Data(text.utf8)) }
        }

        let transport = FakeTransport()
        let session = ElmCommandSession(transport: transport)
        let task = Task { try await session.command("010C", timeout: 1.0) }
        await Task.yield()
        XCTAssertEqual(String(decoding: transport.writes.first ?? Data(), as: UTF8.self), "010C\r")
        transport.emit("18DAF10104410C")
        transport.emit("1F40\r>")
        let result = try await task.value
        XCTAssertTrue(result.success)
        XCTAssertEqual(decodeEngineRPM(result.text), 2000.0)
    }

    @MainActor
    func testElmCommandSessionBlocksUnsafeVehicleWrite() async {
        final class FakeTransport: ElmByteTransport {
            var onReceive: ((Data) -> Void)?
            func write(_ data: Data) throws {}
        }

        let session = ElmCommandSession(transport: FakeTransport())
        do {
            _ = try await session.command("2E201200")
            XCTFail("unsafe command should be blocked")
        } catch ElmCommandError.unsafeCommand {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    @MainActor
    func testElmSessionEvidenceHooksReceiveRawAndCommandResult() async throws {
        final class FakeTransport: ElmByteTransport {
            var onReceive: ((Data) -> Void)?
            func write(_ data: Data) throws {}
            func emit(_ data: Data) { onReceive?(data) }
        }

        let transport = FakeTransport()
        let session = ElmCommandSession(transport: transport)
        var rawChunks: [Data] = []
        var results: [ElmCommandResult] = []
        session.onRawReceive = { rawChunks.append($0) }
        session.onResult = { results.append($0) }

        let task = Task { try await session.command("010D", timeout: 1.0) }
        await Task.yield()
        transport.emit(Data("18DAF10103410D".utf8))
        transport.emit(Data("2A\r>".utf8))
        _ = try await task.value

        XCTAssertEqual(rawChunks.count, 2)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.command, "010D")
    }

    func testUDS22ClassifierMatchesExpectedResponder() {
        let positive = classifyUDS22Text(
            "18DAF10106622012AABBCC\r>",
            ecu: "01",
            did: 0x2012,
            latencyMs: 12.5
        )
        XCTAssertEqual(positive.status, .positive)
        XCTAssertEqual(positive.payload, Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(positive.responseCanID, "18DAF101")

        let negative = classifyUDS22Text(
            "18DAF101037F2231\r>",
            ecu: "01",
            did: 0x2013
        )
        XCTAssertEqual(negative.status, .nrc)
        XCTAssertEqual(negative.nrc, 0x31)
    }

    func testUDS22ClassifierPreservesPartialPositive() {
        let text = """
        18DAF101101062201901020304
        18DAF1012105060708090A0B
        BUFFER FULL
        >
        """
        let outcome = classifyUDS22Text(text, ecu: "01", did: 0x2019)
        XCTAssertEqual(outcome.status, .positivePartial)
        XCTAssertEqual(outcome.responseCanID, "18DAF101")
        XCTAssertEqual(outcome.payload.prefix(3), Data([0x01, 0x02, 0x03]))
    }

    func testUDS22ClassifierIgnoresWrongResponder() {
        let outcome = classifyUDS22Text(
            "18DAF10206622012AABBCC\r>",
            ecu: "01",
            did: 0x2012
        )
        XCTAssertEqual(outcome.status, .error)
        XCTAssertEqual(expectedResponseID(for: "01"), "18DAF101")
        XCTAssertEqual(physicalRequestID(for: "01"), "18DA01F1")
        XCTAssertEqual(physicalRequestHeaderCommand(for: "01"), "ATSHDA01F1")
    }

}
