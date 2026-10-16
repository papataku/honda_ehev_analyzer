import XCTest
@testable import HondaAnalyzerCore

final class UnifiedAcquisitionTests: XCTestCase {
    func testStoplightZeroRequiresFiveSecondsAndFreshRepeatedSamples() {
        var gate = AutomaticZeroSpeedGate()
        let t = Date(timeIntervalSince1970: 1_000)
        gate.observe(speedKmh: 12, at: t)
        XCTAssertFalse(gate.canProbe(at: t))
        for offset in 1...5 {
            gate.observe(speedKmh: 0, at: t.addingTimeInterval(Double(offset)))
            XCTAssertFalse(gate.canProbe(at: t.addingTimeInterval(Double(offset))))
        }
        gate.observe(speedKmh: 0, at: t.addingTimeInterval(6))
        XCTAssertTrue(gate.canProbe(at: t.addingTimeInterval(6)))
        XCTAssertFalse(gate.canProbe(at: t.addingTimeInterval(8)))
    }

    func testInvalidSpeedAndTransportGapForceReset() {
        var gate = AutomaticZeroSpeedGate()
        let t = Date(timeIntervalSince1970: 1_000)
        for x in 0...5 {
            gate.observe(speedKmh: 0, at: t.addingTimeInterval(Double(x)))
        }
        XCTAssertTrue(gate.canProbe(at: t.addingTimeInterval(5)))
        gate.observe(speedKmh: nil, at: t.addingTimeInterval(5.5))
        XCTAssertFalse(gate.canProbe(at: t.addingTimeInterval(5.5)))
        gate.observe(speedKmh: 0, at: t.addingTimeInterval(6))
        gate.observe(speedKmh: 0, at: t.addingTimeInterval(10))
        XCTAssertEqual(gate.consecutiveZero, 1)
        XCTAssertFalse(gate.canProbe(at: t.addingTimeInterval(10)))
        gate.observe(speedKmh: .nan, at: t.addingTimeInterval(11))
        XCTAssertFalse(gate.canProbe(at: t.addingTimeInterval(11)))
    }

    func testMotionStopsUnknownDIDAndNeverInterpretsZeroAsPark() {
        var gate = AutomaticZeroSpeedGate()
        let t = Date(timeIntervalSince1970: 1_000)
        for x in 0...5 { gate.observe(speedKmh: 0, at: t.addingTimeInterval(Double(x))) }
        XCTAssertTrue(gate.canProbe(at: t.addingTimeInterval(5)))
        gate.observe(speedKmh: 1, at: t.addingTimeInterval(5.1))
        XCTAssertFalse(gate.canProbe(at: t.addingTimeInterval(5.1)))
        // The older manual scanner remains independently gated by P.
        XCTAssertFalse(mayResumeUnknownDID(stableZero: true, parkingConfirmed: false))
    }

    func testPriorityNeverSchedulesUnknownWhenMovingOrSpeedIsUncertain() {
        var planner = UnifiedAcquisitionPlanner()
        for _ in 0..<30 {
            let action = planner.next(isMoving: true, zeroSpeedAuthorized: false,
                                      hasBitmap: false, hasStandardPID: false,
                                      hasKnownDID: true, hasUnknownDID: true)
            XCTAssertEqual(action, .knownDrivingDID)
        }
        for _ in 0..<30 {
            let action = planner.next(isMoving: false, zeroSpeedAuthorized: false,
                                      hasBitmap: false, hasStandardPID: false,
                                      hasKnownDID: false, hasUnknownDID: true)
            XCTAssertEqual(action, .idle)
        }
    }

    func testPlannerSharesOnlyOneBackgroundTaskPerBaselineCycle() {
        var p = UnifiedAcquisitionPlanner()
        let first = p.next(isMoving: false, zeroSpeedAuthorized: true,
                           hasBitmap: true, hasStandardPID: true,
                           hasKnownDID: true, hasUnknownDID: true)
        XCTAssertEqual(first, .supportedPIDBitmap)
        let second = p.next(isMoving: false, zeroSpeedAuthorized: true,
                            hasBitmap: true, hasStandardPID: true,
                            hasKnownDID: true, hasUnknownDID: true)
        XCTAssertEqual(second, .stationaryUnknownDID)
    }

    func testAutomaticallyShowsChangingNumericsButHidesConstantOnes() {
        var tracker = SignalChangeTracker(maxTracked: 6, maxPoints: 4)
        let now = Date(timeIntervalSince1970: 1_000)
        for i in 0..<6 {
            tracker.observePID(pid: 0x0C, canID: "18DAF101",
                               value: Double(i * 100), payload: Data([UInt8(i)]),
                               unit: "rpm", name: "Engine", at: now.addingTimeInterval(Double(i)))
            tracker.observePID(pid: 0x05, canID: "18DAF101",
                               value: 90, payload: Data([90]), unit: "°C",
                               name: "Coolant", at: now.addingTimeInterval(Double(i)))
        }
        let shown = tracker.changingSignals()
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].changeCount, 5)
        XCTAssertEqual(shown[0].points.count, 4)
        XCTAssertTrue(shown[0].points.last?.value == 500)
        XCTAssertFalse(shown[0].isRawChange)
    }

    func testUnknownDIDGraphIsByteDeltaNotInventedRPM() {
        var tracker = SignalChangeTracker()
        let t = Date(timeIntervalSince1970: 1000)
        tracker.observeDID(ecu: "0E", did: 0x2600, payload: Data([0, 0, 1]),
                           at: t)
        XCTAssertTrue(tracker.changingSignals().isEmpty)
        tracker.observeDID(ecu: "0E", did: 0x2600, payload: Data([0, 2, 3]),
                           at: t.addingTimeInterval(1))
        let result = tracker.changingSignals()
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isRawChange)
        XCTAssertEqual(result[0].unit, "変更バイト数")
        XCTAssertEqual(result[0].points.last?.value, 2)
    }

    func testMemoryBoundAndNoGraphOnUnchangedPayload() {
        var tracker = SignalChangeTracker(maxTracked: 2, maxPoints: 3)
        let t = Date(timeIntervalSince1970: 1000)
        for i in 0..<30 {
            tracker.observeDID(ecu: "01", did: UInt16(0x2000 + i),
                               payload: Data([1, 1, 1]),
                               at: t.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(tracker.changingSignals().count, 0)
    }
}
