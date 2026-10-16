import XCTest
@testable import HondaAnalyzerCore

final class HondaAnalyzerCoreTests: XCTestCase {
    func testM5CANCapabilityVersionNegotiationAndFallback() {
        let good = "M5CAN-CAPS PROTO=1.0 FW=0.3.3-phase3d-ble BATCH=16 OPS=OBD01,UDS22 STREAM=0\r>"
        let supported = M5CANCapabilities.parse(good)
        XCTAssertEqual(supported?.major, 1)
        XCTAssertEqual(supported?.minor, 0)
        XCTAssertEqual(supported?.firmwareVersion, "0.3.3-phase3d-ble")
        XCTAssertEqual(supported?.maxBatchIDs, 16)
        XCTAssertEqual(supported?.supportsOBD01, true)
        XCTAssertEqual(supported?.supportsUDS22, true)
        XCTAssertEqual(supported?.supportsStreaming, false)
        XCTAssertEqual(supported?.usesImplicitLease, false) // v1.0 fallback
        let implicit = M5CANCapabilities.parse(
            "M5CAN-CAPS PROTO=1.1 FW=0.4.1-phase3d-implicit BATCH=16 OPS=OBD01,UDS22 STREAM=0 LEASE=IMPLICIT>"
        )
        XCTAssertEqual(implicit?.usesImplicitLease, true)
        XCTAssertNil(M5CANCapabilities.parse(
            "M5CAN-CAPS PROTO=1.1 FW=0.4.1 BATCH=16 OPS=OBD01 STREAM=0 LEASE=UNKNOWN>"
        ))
        XCTAssertNotNil(M5CANCapabilities.parse(
            "M5CAN-CAPS PROTO=1.1 FW=0.4.0 BATCH=8 OPS=OBD01 STREAM=0>"
        ))
        let future = M5CANCapabilities.parse(
            "M5CAN-CAPS PROTO=1.2 FW=0.5.0 BATCH=8 OPS=OBD01,RAWCAN STREAM=0>"
        )
        XCTAssertEqual(future?.supportsOBD01, true)
        XCTAssertEqual(future?.supportsUDS22, false)
        XCTAssertNil(M5CANCapabilities.parse(
            "M5CAN-CAPS PROTO=2.0 FW=2.0 BATCH=16 OPS=OBD01,UDS22 STREAM=1>"
        ))
        XCTAssertNil(M5CANCapabilities.parse(
            "M5CAN-CAPS PROTO=1.0 FW=0.3 BATCH=64 OPS=OBD01 STREAM=0>"
        ))
        XCTAssertNil(M5CANCapabilities.parse("ELM327 v1.5>"))
        XCTAssertNil(M5CANCapabilities.parse("M5CAN v0.3 ELM-CAN compatible>"))
        XCTAssertNil(M5CANCapabilities.parse("?"))
    }

    func testM5CANBatchBuildAndTaggedParse() {
        let mode = M5CANBatchGroup.mode01
        let pids = ["010C", "010D", "0105", "015B", "019A"]
        XCTAssertEqual(mode.command(ids: pids, capacity: 16),
                       "ATM5B00:010C,010D,0105,015B,019A")
        XCTAssertNil(mode.command(ids: ["2E12"], capacity: 16))
        XCTAssertNil(mode.command(ids: Array(repeating: "010C", count: 17), capacity: 16))
        XCTAssertEqual(M5CANBatchGroup.ecu01ReadDID.command(ids: ["2012"], capacity: 16),
                       "ATM5B01:2012")

        let reply = """
        M5ITEM:00:010C\r
        18DAF10104410C144C\r
        M5ITEM:00:010D\r
        18DAF10103410D28\r
        M5ITEM:00:0105\r
        18DAF10103410555\r
        M5ITEM:00:015B\r
        NO DATA\r
        M5ITEM:00:019A\r
        18DAF1011008419A0700401F\r
        18DAF1012100035555555555\r
        M5DONE\r>
        """
        let parsed = M5CANBatchResponse.parse(reply, group: mode, ids: pids)
        XCTAssertEqual(parsed?.items.count, 5)
        XCTAssertEqual(parsed?.items[0].key, "00:010C")
        XCTAssertEqual(parsed?.items[3].responseText, "NO DATA")
        XCTAssertTrue(parsed?.items[4].responseText.contains("18DAF10121") == true)
        XCTAssertNil(M5CANBatchResponse.parse(
            reply.replacingOccurrences(of: "M5DONE", with: "BUSY"),
            group: mode, ids: pids))
        XCTAssertNil(M5CANBatchResponse.parse(
            reply.replacingOccurrences(of: "M5ITEM:00:010D", with: "M5ITEM:00:010C"),
            group: mode, ids: pids))
    }

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
    func testM5CANSessionAutomaticallyRenewsShortTxLease() async throws {
        final class FakeTransport: ElmByteTransport {
            var onReceive: ((Data) -> Void)?
            var writes: [String] = []
            func write(_ data: Data) throws {
                writes.append(String(decoding: data, as: UTF8.self))
            }
            func emit(_ text: String) {
                onReceive?(Data(text.utf8))
            }
        }

        let transport = FakeTransport()
        let session = ElmCommandSession(transport: transport)

        let identify = Task { try await session.command("ATI", timeout: 1.0) }
        await Task.yield()
        XCTAssertEqual(transport.writes, ["ATI\r"])
        transport.emit("M5CAN v0.3 ELM-CAN compatible\r>")
        _ = try await identify.value

        let rpm = Task { try await session.command("010C", timeout: 1.0) }
        await Task.yield()
        XCTAssertEqual(transport.writes.last, "ATM5TX1\r")
        transport.emit("OK\r>")
        await Task.yield()
        XCTAssertEqual(transport.writes.last, "010C\r")
        transport.emit("18DAF10104410C1F40\r>")
        _ = try await rpm.value

        let speed = Task { try await session.command("010D", timeout: 1.0) }
        await Task.yield()
        XCTAssertEqual(transport.writes.last, "010D\r")
        XCTAssertEqual(transport.writes.filter { $0 == "ATM5TX1\r" }.count, 1)
        transport.emit("18DAF10103410D2A\r>")
        _ = try await speed.value
    }

    @MainActor
    func testImplicitLeaseAvoidsRedundantBLEMessages() async throws {
        final class FakeTransport: ElmByteTransport {
            var onReceive: ((Data) -> Void)?
            var writes: [String] = []
            func write(_ data: Data) throws {
                let command = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                writes.append(command)
                if command == "ATZ" || command == "ATI" {
                    onReceive?(Data("M5CAN v0.4 ELM-CAN compatible\r>".utf8))
                } else if command == "ATM5CAP" {
                    onReceive?(Data(
                        "M5CAN-CAPS PROTO=1.1 FW=0.4.1-phase3d-implicit BATCH=16 OPS=OBD01,UDS22 STREAM=0 LEASE=IMPLICIT\r>".utf8
                    ))
                } else if command == "ATM5B00:010C,010D" {
                    onReceive?(Data(
                        "M5ITEM:00:010C\r18DAF10104410C1F40\rM5ITEM:00:010D\r18DAF10103410D28\rM5DONE\r>".utf8
                    ))
                } else if command == "010C" {
                    onReceive?(Data("18DAF10104410C1F40\r>".utf8))
                } else {
                    onReceive?(Data("OK\r>".utf8))
                }
            }
        }
        let fake = FakeTransport()
        let session = ElmCommandSession(transport: fake)
        let initResults = await session.initialize()
        XCTAssertTrue(initResults.allSatisfy(\.success))
        XCTAssertEqual(session.negotiatedM5CAN?.usesImplicitLease, true)

        let (_, result) = try await session.batchRead(
            group: .mode01, ids: ["010C", "010D"], timeout: 2.0
        )
        XCTAssertEqual(result.items.count, 2)
        _ = try await session.command("010C", timeout: 2.0)

        XCTAssertEqual(fake.writes.filter { $0 == "ATM5TX1" }.count, 0)
        XCTAssertEqual(fake.writes.filter { $0.hasPrefix("ATM5B00:") }.count, 1)
        XCTAssertEqual(fake.writes.filter { $0 == "010C" }.count, 1)
    }

    @MainActor
    func testSwitchFromM5CANToKW905ClearsLeaseCommand() async throws {
        final class FakeTransport: ElmByteTransport {
            var onReceive: ((Data) -> Void)?
            var writes: [String] = []
            func write(_ data: Data) throws {
                writes.append(String(decoding: data, as: UTF8.self))
            }
            func emit(_ text: String) { onReceive?(Data(text.utf8)) }
        }
        let transport = FakeTransport()
        let session = ElmCommandSession(transport: transport)

        let m5 = Task { try await session.command("ATI", timeout: 1.0) }
        await Task.yield()
        transport.emit("M5CAN v0.3 ELM-CAN compatible\r>")
        _ = try await m5.value

        // The next adapter's reset identifies itself as a normal ELM327.
        let kw = Task { try await session.command("ATZ", timeout: 1.0) }
        await Task.yield()
        transport.emit("ELM327 v1.5\r>")
        _ = try await kw.value

        let countBefore = transport.writes.count
        let rpm = Task { try await session.command("010C", timeout: 1.0) }
        await Task.yield()
        XCTAssertEqual(transport.writes.count, countBefore + 1)
        XCTAssertEqual(transport.writes.last, "010C\r")
        transport.emit("18DAF10104410C1F40\r>")
        _ = try await rpm.value
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

    func testCaptureTimestampPreservesFractionalSeconds() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let text = captureTimestamp(date)
        XCTAssertTrue(text.contains("."))
        XCTAssertTrue(text.hasSuffix("Z"))
        XCTAssertNotNil(ISO8601DateFormatter.fractional.date(from: text))
    }


    func testHighRatePollingDelayCanRunAt20To100HzOrUnthrottled() {
        XCTAssertEqual(
            pollingDelaySeconds(
                requestCount: 1,
                targetRequestRateHz: 20,
                elapsedSeconds: 0.010
            ),
            0.040,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            pollingDelaySeconds(
                requestCount: 5,
                targetRequestRateHz: 50,
                elapsedSeconds: 0.070
            ),
            0.030,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            pollingDelaySeconds(
                requestCount: 1,
                targetRequestRateHz: 100,
                elapsedSeconds: 0.020
            ),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            pollingDelaySeconds(
                requestCount: 1,
                targetRequestRateHz: 100,
                elapsedSeconds: 0,
                unthrottled: true
            ),
            0,
            accuracy: 0.0001
        )
    }

    func testAggressiveCustomAdapterTimingIsExplicitOptIn() {
        let compatible = elmDidPollingTimingProfile(
            targetRateHz: 50,
            unthrottled: false,
            aggressive: false
        )
        XCTAssertEqual(compatible.setup, ["ATAT2", "ATST0F"])

        let fast20 = elmDidPollingTimingProfile(
            targetRateHz: 20,
            unthrottled: false,
            aggressive: true
        )
        XCTAssertEqual(fast20.setup, ["ATAT2", "ATST0A"])

        let fast50 = elmDidPollingTimingProfile(
            targetRateHz: 50,
            unthrottled: false,
            aggressive: true
        )
        XCTAssertEqual(fast50.setup, ["ATAT2", "ATST04"])

        let maxRate = elmDidPollingTimingProfile(
            targetRateHz: 100,
            unthrottled: true,
            aggressive: true
        )
        XCTAssertEqual(maxRate.setup, ["ATAT2", "ATST02"])
        XCTAssertEqual(maxRate.restore, ["ATAT1", "ATST32"])
    }


    func testElmCanHeaderPriorityIsConfiguredOnlyOnce() {
        XCTAssertEqual(
            elmCanHeaderSetupCommands(
                header: "ATSHDB33F1",
                activeHeader: nil,
                priority18Configured: false
            ),
            ["ATCP18", "ATSHDB33F1"]
        )
        XCTAssertEqual(
            elmCanHeaderSetupCommands(
                header: "ATSHDA01F1",
                activeHeader: "ATSHDB33F1",
                priority18Configured: true
            ),
            ["ATSHDA01F1"]
        )
        XCTAssertEqual(
            elmCanHeaderSetupCommands(
                header: "ATSHDA01F1",
                activeHeader: "ATSHDA01F1",
                priority18Configured: true
            ),
            []
        )
        // After ATZ or reconnect, the priority must be sent again.
        XCTAssertEqual(
            elmCanHeaderSetupCommands(
                header: "ATSHDB33F1",
                activeHeader: nil,
                priority18Configured: false
            ),
            ["ATCP18", "ATSHDB33F1"]
        )
    }


    func testDriveAllowlistRejectsPartialAndIdentityDIDs() {
        XCTAssertTrue(isDrivingSampleCandidate(
            did: 0x2012, payloadLength: 36, status: "positive"
        ))
        XCTAssertTrue(isDrivingSampleCandidate(
            did: 0xE480, payloadLength: 26, status: "positive"
        ))
        XCTAssertTrue(isDrivingSampleCandidate(
            did: 0xE600, payloadLength: 1, status: "positive"
        ))
        XCTAssertFalse(isDrivingSampleCandidate(
            did: 0xF110, payloadLength: 17, status: "positive"
        ))
        XCTAssertFalse(isDrivingSampleCandidate(
            did: 0x2019, payloadLength: 64, status: "positive_partial"
        ))
        XCTAssertFalse(isDrivingSampleCandidate(
            did: 0xE480, payloadLength: 0, status: "positive"
        ))
    }

    func testMotorCandidateScoringUsesEVSpeedCorrelation() {
        let start = 1_700_000_000.0
        var refs: [DriveReference] = []
        for i in 0..<30 {
            let speed = Double(10 + i * 2)
            let power: Double = (i % 2 == 0) ? 12.0 : -8.0
            refs.append(DriveReference(
                time: start + Double(i),
                speed: speed,
                engineRPM: 0.0,
                hvPower: power
            ))
        }
        let rows: [DrivePayloadSample] = (0..<30).map { i in
            let raw = UInt16((10 + i * 2) * 64)
            return DrivePayloadSample(
                time: start + Double(i), ecu: "01", did: 0x2012,
                payload: Data([UInt8(raw >> 8), UInt8(raw & 0xFF)])
            )
        }
        let ranked = rankDriveFields(samples: rows, references: refs)
        XCTAssertFalse(ranked.isEmpty)
        XCTAssertEqual(ranked.first?.did, 0x2012)
        XCTAssertTrue(ranked.contains {
            $0.classification == "駆動モーター回転系候補" &&
                abs($0.evSpeedCorrelation ?? 0) > 0.95
        })

        let stable: [DrivePayloadSample] = (0..<30).map { i in
            DrivePayloadSample(
                time: start + Double(i), ecu: "01", did: 0xE480,
                payload: Data([0x00, 0x00, 0x00])
            )
        }
        XCTAssertTrue(rankDriveFields(samples: stable, references: refs).isEmpty)
    }

    func testDriveCandidateLoaderUsesCompletePositiveFromSQLite() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("drive-test-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try CaptureStore(url: path)
        let session = try store.createSession()
        for (did, status, payload) in [
            (UInt16(0x2012), DidProbeStatus.positive, Data(repeating: 0x33, count: 36)),
            (UInt16(0xE480), DidProbeStatus.positive, Data(repeating: 0x24, count: 26)),
            (UInt16(0xF110), DidProbeStatus.positive, Data(repeating: 0x31, count: 17)),
            (UInt16(0x2019), DidProbeStatus.positivePartial, Data(repeating: 0x11, count: 40))
        ] {
            let outcome = DidProbeOutcome(
                ecu: "01", did: did, status: status,
                payload: payload, responseCanID: "18DAF101"
            )
            store.saveDidScan(sessionID: session, at: Date(), outcome: outcome)
        }
        store.flush()
        let candidates = loadDriveDIDCandidates(from: [path])
        XCTAssertEqual(candidates.map(\.did), [0x2012, 0xE480])
        let record = DidProbeOutcome(
            ecu: "01", did: 0x2012, status: .positive,
            latencyMs: 12.0, payload: Data([0x12, 0x34]),
            responseCanID: "18DAF101"
        )
        store.saveDriveSample(sessionID: session, at: Date(), outcome: record)
        store.flush()
    }


    func testUnknownScanResumeRequiresStableZeroAndFreshParkConfirmation() {
        XCTAssertFalse(mayResumeUnknownDID(stableZero: false, parkingConfirmed: false))
        XCTAssertFalse(mayResumeUnknownDID(stableZero: true, parkingConfirmed: false))
        XCTAssertFalse(mayResumeUnknownDID(stableZero: false, parkingConfirmed: true))
        XCTAssertTrue(mayResumeUnknownDID(stableZero: true, parkingConfirmed: true))
    }


    func testAdaptiveDrivePollingSuspendsUnchangedButNeverPermanentlyDropsDID() {
        let candidate = DriveDID(
            ecu: "01", did: 0xE480, responseCanID: "18DAF101", payloadLength: 4
        )
        let scheduler = AdaptiveDriveDIDScheduler(candidates: [candidate])
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let same = Data([0x00, 0x11, 0x22, 0x33])
        for i in 0..<15 {
            let context: DriveOperatingContext = i < 8 ? .ev : .engine
            _ = scheduler.observe(
                candidate, payload: same,
                at: t.addingTimeInterval(Double(i) * 2), context: context
            )
        }
        XCTAssertEqual(scheduler.summary.total, 1)
        XCTAssertEqual(scheduler.summary.dormant, 1)
        XCTAssertNil(scheduler.next(
            now: t.addingTimeInterval(32), context: .engine
        ))

        // A new driving condition wakes up a dormant candidate.
        let recheck = scheduler.next(
            now: t.addingTimeInterval(33), context: .regeneration
        )
        XCTAssertEqual(recheck?.did, candidate.did)
        let wake = scheduler.observe(
            candidate, payload: Data([0, 0x11, 0x23, 0x33]),
            at: t.addingTimeInterval(33), context: .regeneration
        )
        XCTAssertEqual(wake?.current, .active)
        XCTAssertEqual(scheduler.summary.active, 1)
        XCTAssertEqual(scheduler.summary.dormant, 0)
    }

    func testAdaptiveDrivePollingErrorsBackOffWithoutFalseStableDecision() {
        let candidate = DriveDID(
            ecu: "01", did: 0xE600, responseCanID: "18DAF101", payloadLength: 2
        )
        let scheduler = AdaptiveDriveDIDScheduler(candidates: [candidate])
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<12 {
            _ = scheduler.observe(
                candidate, payload: nil,
                at: t.addingTimeInterval(Double(i) * 60), context: .ev
            )
        }
        XCTAssertEqual(scheduler.summary.failedSamples, 12)
        XCTAssertEqual(scheduler.summary.dormant, 0)
        XCTAssertEqual(scheduler.summary.learning, 1)
        XCTAssertNil(scheduler.next(
            now: t.addingTimeInterval(11 * 60 + 5),
            context: .ev
        ))
    }

    func testAdaptiveSchedulerMaintainsBeyond24PositiveDIDs() {
        let candidates: [DriveDID] = (0..<100).map { index in
            DriveDID(
                ecu: "01",
                did: UInt16(0xE400 + index),
                responseCanID: "18DAF101",
                payloadLength: 4
            )
        }
        let scheduler = AdaptiveDriveDIDScheduler(candidates: candidates)
        XCTAssertEqual(scheduler.summary.total, 100)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var observed = Set<String>()
        for index in 0..<100 {
            guard let next = scheduler.next(
                now: start, context: .ev
            ) else {
                XCTFail("candidate unexpectedly missing at index \(index)")
                return
            }
            observed.insert(next.id)
            _ = scheduler.observe(
                next, payload: Data([0, 0, 0, 1]),
                at: start, context: .ev
            )
        }
        XCTAssertEqual(observed.count, 100)
        scheduler.addCandidates(candidates)
        XCTAssertEqual(scheduler.summary.total, 100)
        scheduler.addCandidates([
            DriveDID(ecu: "01", did: 0xF200, responseCanID: "18DAF101", payloadLength: 4)
        ])
        XCTAssertEqual(scheduler.summary.total, 101)
    }

    func testHistoricalPositiveInventoryIsNotLimitedTo24Entries() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("adaptive-drive-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try CaptureStore(url: path)
        let sid = try store.createSession()
        for index in 0..<35 {
            store.saveDidScan(
                sessionID: sid, at: Date(),
                outcome: DidProbeOutcome(
                    ecu: "01", did: UInt16(0xE400 + index),
                    status: .positive, payload: Data([0x00, 0x01]),
                    responseCanID: "18DAF101"
                )
            )
        }
        store.flush()
        XCTAssertEqual(loadDriveDIDCandidates(from: [path]).count, 35)
        XCTAssertEqual(loadDriveDIDCandidates(from: [path], limit: 24).count, 24)
        store.saveDrivePlan(
            sessionID: sid, at: Date(),
            candidates: loadDriveDIDCandidates(from: [path])
        )
        store.flush()
    }


    func testAdaptivePriorityPersistsAcrossSQLiteSessions() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("adaptive-state-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try CaptureStore(url: path)
        let sid = try store.createSession()
        let candidate = DriveDID(
            ecu: "01", did: 0xE600,
            responseCanID: "18DAF101", payloadLength: 3
        )
        let prior = AdaptiveDriveDIDScheduler(candidates: [candidate])
        let initial = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<15 {
            _ = prior.observe(
                candidate, payload: Data([0x13, 0x21, 0x42]),
                at: initial.addingTimeInterval(Double(i)),
                context: i < 8 ? .ev : .engine
            )
        }
        XCTAssertEqual(prior.summary.dormant, 1)
        store.saveDriveSamplingState(
            sessionID: sid, at: Date(), seeds: prior.snapshots()
        )
        store.flush()
        let seeds = loadDriveSamplingSeeds(from: [path])
        XCTAssertEqual(seeds.count, 1)
        XCTAssertEqual(seeds[0].priority, .dormant)
        XCTAssertEqual(seeds[0].lastPayload, Data([0x13, 0x21, 0x42]))
        let restored = AdaptiveDriveDIDScheduler(candidates: [candidate])
        restored.restore(seeds)
        XCTAssertEqual(restored.summary.dormant, 1)
        // Reconnect does not permanently suppress probing.
        let next = restored.next(
            now: Date(), context: .engine
        )
        XCTAssertEqual(next?.did, candidate.did)
        _ = restored.observe(
            candidate, payload: Data([0x13, 0x21, 0x43]),
            at: Date(), context: .engine
        )
        XCTAssertEqual(restored.summary.active, 1)
    }

}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
    func testStationaryResumeTrackerRequiresStableZeroAndResetsOnMotionOrUnknown() {
        var tracker = StationaryResumeTracker(requiredZeroSamples: 3)

        XCTAssertFalse(tracker.observe(speedKmh: 12))
        XCTAssertEqual(tracker.consecutiveZeroSamples, 0)

        XCTAssertFalse(tracker.observe(speedKmh: 0))
        XCTAssertEqual(tracker.consecutiveZeroSamples, 1)

        XCTAssertFalse(tracker.observe(speedKmh: 0))
        XCTAssertEqual(tracker.consecutiveZeroSamples, 2)

        XCTAssertFalse(tracker.observe(speedKmh: nil))
        XCTAssertEqual(tracker.consecutiveZeroSamples, 0)

        XCTAssertFalse(tracker.observe(speedKmh: 0))
        XCTAssertFalse(tracker.observe(speedKmh: 0))
        XCTAssertTrue(tracker.observe(speedKmh: 0))
        XCTAssertEqual(tracker.consecutiveZeroSamples, 3)

        XCTAssertFalse(tracker.observe(speedKmh: 1))
        XCTAssertEqual(tracker.consecutiveZeroSamples, 0)
    }

}
