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

#if canImport(SQLite3)
    func testCaptureStorePersistsTerminalDidResumeState() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("honda-ipad-test-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        }

        let store = try CaptureStore(url: url)
        let sid = try store.createSession()
        store.saveDidScan(
            sessionID: sid,
            at: Date(),
            outcome: DidProbeOutcome(
                ecu: "01", did: 0x2019, status: .positivePartial,
                latencyMs: 170, payload: Data([1, 2, 3]), responseCanID: "18DAF101"
            )
        )
        store.saveDidScan(
            sessionID: sid,
            at: Date(),
            outcome: DidProbeOutcome(ecu: "01", did: 0x2020, status: .nrc, nrc: 0x31)
        )
        store.saveDidScan(
            sessionID: sid,
            at: Date(),
            outcome: DidProbeOutcome(ecu: "01", did: 0x2021, status: .noData)
        )
        store.flush()

        let completed = try store.completedDids(ecu: "01", start: 0x2000, end: 0x20FF)
        XCTAssertTrue(completed.contains(0x2019))
        XCTAssertTrue(completed.contains(0x2020))
        XCTAssertFalse(completed.contains(0x2021))

        let positives = try store.positiveDidOutcomes(ecu: "01")
        XCTAssertEqual(positives.count, 1)
        XCTAssertEqual(positives[0].did, 0x2019)
        XCTAssertEqual(positives[0].status, .positivePartial)
        XCTAssertEqual(positives[0].payload, Data([1, 2, 3]))
    }
#endif

    func testEcuResponderCensusUsesOnly18DAF1SourceIDs() {
        let text = """
        18DAF10104410C1F40
        18DAF10204410C0000
        18DAF10604410C0000
        18DB33F102010C
        >
        """
        let responders = ecuResponders(in: text)
        XCTAssertEqual(responders.map(\.source), ["01", "02", "06"])
        XCTAssertEqual(responseEcuSource(from: "18DAF1EF"), "EF")
        XCTAssertNil(responseEcuSource(from: "18DB33F1"))
    }

    func testSafeEcuCensusAllowListStaysReadOnly() {
        XCTAssertEqual(safeEcuCensusRequests.count, 6)
        for request in safeEcuCensusRequests {
            XCTAssertTrue(isReadOnlyVehicleCommand(request.command))
            XCTAssertTrue(request.headerCommand.hasPrefix("ATSH"))
        }
    }

    func testSession15StyleLongDidIsPositivePartial() {
        let text =
            "18DAF10110F6622019FFFFFF\r" +
            "18DAF10121FFFFFFFFFFFFFF\r" +
            "18DAF10122FFFFFFFFFFFFFF\r" +
            "18DAF10123FF000000000000\r" +
            "18DAF1012400000003CF03CD\r" +
            "18DAF1012503CE03CB03C903\r" +
            "18DAF10126CB03CB03CE03CA\r" +
            "18DAF1012703CD03C903D003\r" +
            "18DAF10128C803CD03CA03CA\r" +
            "18DAF1012903CB03ED03D203\r" +
            "18DAF1012AED03C803CD03CE\r" +
            "BUFFER FULL\r\r>"
        let outcome = classifyUDS22Text(text, ecu: "01", did: 0x2019, latencyMs: 170)
        XCTAssertEqual(outcome.status, .positivePartial)
        XCTAssertEqual(outcome.responseCanID, "18DAF101")
        XCTAssertGreaterThan(outcome.payload.count, 50)
    }

    func testHeaderlessCAF1CompleteAndPartialDidResponses() {
        let complete = "00A\r0: 62 20 19 01 02 03\r1: 04 05 06 07\r\r>"
        let full = classifyUDS22Text(complete, ecu: "01", did: 0x2019)
        XCTAssertEqual(full.status, .positive)
        XCTAssertEqual(full.payload, Data([1, 2, 3, 4, 5, 6, 7]))
        XCTAssertEqual(full.responseCanID, "18DAF101")

        let partial = "00A\r0:622019010203\rBUFFER FULL\r>"
        let cut = classifyUDS22Text(partial, ecu: "01", did: 0x2019)
        XCTAssertEqual(cut.status, .positivePartial)
        XCTAssertEqual(cut.payload, Data([1, 2, 3]))
        XCTAssertEqual(cut.responseCanID, "18DAF101")
    }

    func testEcuResponderCensusExtractsUniquePhysicalResponders() {
        let text = """
        18DAF10103410D2A
        18DAF10104410C1F40
        18DAF10E03410550
        18DB33F103410D2A
        >
        """
        let responders = ecuResponders(in: text)
        XCTAssertEqual(responders.map(\.source), ["01", "0E"])
        XCTAssertEqual(responders.map(\.responseCanID), ["18DAF101", "18DAF10E"])
        XCTAssertEqual(responseEcuSource(from: "18DAF1EF"), "EF")
        XCTAssertNil(responseEcuSource(from: "18DB33F1"))
    }

    func testSafeEcuCensusRequestListIsReadOnlyOnly() {
        XCTAssertFalse(safeEcuCensusRequests.isEmpty)
        for item in safeEcuCensusRequests {
            XCTAssertTrue(isReadOnlyVehicleCommand(item.command))
        }
    }

    func testAdaptiveDidStrategyMatchesMacOrderingPrimitives() {
        XCTAssertEqual(
            didKnownPriority(start: 0x1F00, end: 0x2100).first,
            UInt16(0x2000)
        )
        XCTAssertEqual(
            didKnownPriority(start: 0x1F00, end: 0x2100).last,
            UInt16(0x20FF)
        )

        let heads = didSectorHeads(start: 0x0000, end: 0xFFFF, width: 4)
        XCTAssertEqual(heads.count, 64)
        XCTAssertEqual(Array(heads.prefix(4)), [0x0000, 0x0001, 0x0002, 0x0003])
        XCTAssertEqual(Array(heads.suffix(4)), [0xF000, 0xF001, 0xF002, 0xF003])

        let sentinels = didPageSentinels(
            sector: 2,
            start: 0x2000,
            end: 0x22FF
        )
        XCTAssertEqual(
            sentinels,
            [0x2000, 0x2080, 0x2100, 0x2180, 0x2200, 0x2280]
        )
    }

    func testAdaptiveDidStrategyPrioritizesEvidenceButNeverChangesCoverage() {
        let sectorScores = [2: 200, 0: 0, 1: 100]
        XCTAssertEqual(
            didPrioritizedSectors(start: 0x0000, end: 0x2FFF, scores: sectorScores),
            [2, 1, 0]
        )

        let pageScores = [0x22: 100, 0x20: 300, 0x21: 200]
        XCTAssertEqual(
            didPrioritizedPages(sector: 2, start: 0x2000, end: 0x22FF, scores: pageScores),
            [0x20, 0x21, 0x22]
        )

        XCTAssertEqual(didOutcomeInterestScore(status: .positive, nrc: nil), 100)
        XCTAssertEqual(didOutcomeInterestScore(status: .positivePartial, nrc: nil), 100)
        XCTAssertEqual(didOutcomeInterestScore(status: .nrc, nrc: 0x22), 25)
        XCTAssertEqual(didOutcomeInterestScore(status: .nrc, nrc: 0x31), 0)
        let estimate = didEstimatedScanSeconds(
            ecuCount: 1, start: 0x0000, end: 0xFFFF, rateHz: 10
        )
        XCTAssertNotNil(estimate)
        XCTAssertEqual(estimate ?? 0, 6553.6, accuracy: 0.001)
    }

#if canImport(SQLite3)
    func testDidScanHistoryUnionsTerminalResultsAcrossCaptureFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("honda-ipad-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstURL = dir.appendingPathComponent("first.sqlite3")
        let secondURL = dir.appendingPathComponent("second.sqlite3")

        let first = try CaptureStore(url: firstURL)
        let firstSession = try first.createSession()
        first.saveDidScan(
            sessionID: firstSession,
            at: Date(),
            outcome: DidProbeOutcome(ecu: "01", did: 0x2012, status: .positive)
        )
        first.saveDidScan(
            sessionID: firstSession,
            at: Date(),
            outcome: DidProbeOutcome(ecu: "01", did: 0x2014, status: .nrc, nrc: 0x31)
        )
        first.flush()

        let second = try CaptureStore(url: secondURL)
        let secondSession = try second.createSession()
        second.saveDidScan(
            sessionID: secondSession,
            at: Date(),
            outcome: DidProbeOutcome(ecu: "01", did: 0x2025, status: .positivePartial)
        )
        second.saveDidScan(
            sessionID: secondSession,
            at: Date(),
            outcome: DidProbeOutcome(ecu: "01", did: 0x2026, status: .noData)
        )
        second.flush()

        let history = loadDidScanHistory(
            from: [firstURL, secondURL],
            ecu: "01",
            start: 0x2000,
            end: 0x20FF
        )

        XCTAssertEqual(history.completed, Set([0x2012, 0x2014, 0x2025]))
        XCTAssertEqual(history.positiveHints, Set([0x2012, 0x2025]))
        XCTAssertFalse(history.completed.contains(0x2026))
    }
#endif

}
