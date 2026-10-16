import XCTest
@testable import HondaAnalyzerCore

final class StandardPIDInventoryTests: XCTestCase {
    func testBitmapSeparatesResponderAndContinuesOnlyWhenAdvertised() {
        let response = "18DAF10106410010000001\r18DAF10206410080000000\r>"
        let maps = parseStandardPIDBitmaps(response, base: 0x00)
        XCTAssertEqual(maps.count, 2)
        XCTAssertEqual(maps[0].canID, "18DAF101")
        XCTAssertTrue(maps[0].supported.contains(0x04))
        XCTAssertTrue(maps[0].supported.contains(0x20))
        XCTAssertFalse(maps[1].supported.contains(0x20))
        XCTAssertTrue(maps[1].supported.contains(0x01))
        var inventory = StandardPIDInventory()
        for map in maps { inventory.addBitmap(map) }
        XCTAssertEqual(inventory.sortedRows.filter { $0.pid == 0x04 }.count, 1)
        XCTAssertFalse(inventory.sortedRows.contains { $0.pid == 0x20 })
        XCTAssertEqual(inventory.sortedRows.first(where: { $0.pid == 0x04 })?.latestStatus, .bitmapOnly)
    }

    func testShortBitmapNeverInventsSupportAndNoOverflowAtE0() {
        XCTAssertTrue(parseStandardPIDBitmaps("18DAF1010341E0FF\r>", base: 0xE0).isEmpty)
        let full = parseStandardPIDBitmaps("18DAF1010641E000000001\r>", base: 0xE0)
        XCTAssertEqual(full.count, 1)
        XCTAssertTrue(full[0].supported.isEmpty) // last bit is PID 0x100, beyond Mode01 byte range
    }

    func testResponseDecodePreservesCANIDAndValidZero() {
        let readings = readStandardPID(0x0D, from: "18DAF10103410D00\r>")
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings[0].responseCANID, "18DAF101")
        XCTAssertEqual(readings[0].status, .decoded)
        XCTAssertEqual(readings[0].value, 0)
        var inv = StandardPIDInventory()
        inv.addReading(readings[0])
        XCTAssertEqual(inv.sortedRows[0].minimum, 0)
        XCTAssertEqual(inv.sortedRows[0].successfulSamples, 1)
        XCTAssertNil(inv.sortedRows[0].effectiveHz)
    }

    func testUnknownAndShortDataNeverClaimDecoded() {
        let raw = readStandardPID(0x7A, from: "18DAF10103417A01\r>")
        XCTAssertEqual(raw.first?.status, .uninterpreted)
        XCTAssertNil(raw.first?.value)
        let short = readStandardPID(0x42, from: "18DAF10103414201\r>")
        XCTAssertEqual(short.first?.status, .shortResponse)
        XCTAssertNil(short.first?.value)
        XCTAssertTrue(readStandardPID(0x42, from: "NO DATA\r>").isEmpty)
    }

    func testStandardScalingAndPedalNonzeroBaseline() {
        let pedal = readStandardPID(0x49, from: "18DAF10103414933\r>")
        XCTAssertEqual(pedal.first?.value ?? -1, 20, accuracy: 0.1)
        let fuelRate = readStandardPID(0x5E, from: "18DAF10104415E0014\r>")
        XCTAssertEqual(fuelRate.first?.value ?? -1, 1.0, accuracy: 0.001)
        let signed = readStandardPID(0x61, from: "18DAF1010341617D\r>")
        XCTAssertEqual(signed.first?.value, 0)
    }

    func testInventorySamplingRateAndCSVJSONRoundTrip() throws {
        let first = Date(timeIntervalSince1970: 1000)
        let second = first.addingTimeInterval(2)
        var inventory = StandardPIDInventory()
        let r1 = readStandardPID(0x0D, from: "18DAF10103410D00\r>", at: first)[0]
        let r2 = readStandardPID(0x0D, from: "18DAF10103410D28\r>", at: second)[0]
        inventory.addReading(r1)
        inventory.addReading(r2)
        XCTAssertEqual(inventory.sortedRows[0].successfulSamples, 2)
        XCTAssertEqual(inventory.sortedRows[0].effectiveHz ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(inventory.sortedRows[0].minimum, 0)
        XCTAssertEqual(inventory.sortedRows[0].maximum, 40)
        let json = try standardPIDJSON(inventory.sortedRows)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([StandardPIDInventoryRow].self, from: json)
        XCTAssertEqual(decoded[0].id, "010D@18DAF101")
        XCTAssertTrue(standardPIDCSV(decoded).contains("010D@18DAF101"))
    }

    func testIncompleteISOTPIsPartialNotDecodedOrFabricated() {
        // First frame declares 8 payload bytes but only carries six; CF is absent.
        let broken = "18DAF1011008410C00100000\r>"
        let rows = readStandardPID(0x0C, from: broken)
        XCTAssertEqual(rows.first?.status, .partialResponse)
        XCTAssertNil(rows.first?.value)
        XCTAssertEqual(rows.first?.payloadHex, "00100000")
    }

    func testNoDataRemainsRetryableAndResponderBound() {
        var inventory = StandardPIDInventory()
        inventory.addBitmap(parseStandardPIDBitmaps("18DAF10106410010000000\r>", base: 0)[0])
        inventory.addFailure(pid: 0x04, status: .noData)
        XCTAssertEqual(inventory.sortedRows.count, 1)
        XCTAssertEqual(inventory.sortedRows[0].latestStatus, .noData)
        XCTAssertEqual(inventory.sortedRows[0].attempts, 1)
        XCTAssertEqual(inventory.sortedRows[0].successfulSamples, 0)
        XCTAssertEqual(inventory.sortedRows[0].responseCANID, "18DAF101")
        inventory.addReading(readStandardPID(0x04, from: "18DAF10103410400\r>")[0])
        XCTAssertEqual(inventory.sortedRows[0].latestStatus, .decoded)
        XCTAssertEqual(inventory.sortedRows[0].latestValue, 0)
    }

    func testHybrid9ADoesNotSilentlyClaimSingleFieldDecode() {
        // 019A is one PID with multiple derived values, not three extra PID reads.
        XCTAssertEqual(standardPIDCatalog[0x9A]?.bytes, 6)
        XCTAssertNil(readStandardPID(0x9A, from: "NO DATA\r>").first)
    }
}
