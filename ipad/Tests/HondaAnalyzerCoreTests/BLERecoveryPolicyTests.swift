import XCTest
@testable import HondaAnalyzerCore

final class BLERecoveryPolicyTests: XCTestCase {
    func testBoundedBackoff() {
        XCTAssertEqual(BLERecoveryPolicy.retryDelaysSeconds, [0, 1, 2, 4, 8, 16, 16, 16])
        XCTAssertEqual(BLERecoveryPolicy.retryDelaysSeconds.count, 8)
    }

    func testNoReconnectAfterManualDisconnectOrUnknownDevice() {
        XCTAssertFalse(BLERecoveryPolicy.shouldReconnect(
            enabled: true, hasKnownPeripheral: true, manualDisconnect: true,
            isRecording: true, isLivePolling: true, isDriving: false, isDidScanning: false))
        XCTAssertFalse(BLERecoveryPolicy.shouldReconnect(
            enabled: true, hasKnownPeripheral: false, manualDisconnect: false,
            isRecording: true, isLivePolling: false, isDriving: true, isDidScanning: false))
        XCTAssertFalse(BLERecoveryPolicy.shouldReconnect(
            enabled: false, hasKnownPeripheral: true, manualDisconnect: false,
            isRecording: true, isLivePolling: false, isDriving: true, isDidScanning: false))
    }

    func testReconnectDuringCollectionWithoutAutomaticallyResumingUnknownScan() {
        XCTAssertTrue(BLERecoveryPolicy.shouldReconnect(
            enabled: true, hasKnownPeripheral: true, manualDisconnect: false,
            isRecording: true, isLivePolling: false, isDriving: true, isDidScanning: false))
        XCTAssertTrue(BLERecoveryPolicy.shouldReconnect(
            enabled: true, hasKnownPeripheral: true, manualDisconnect: false,
            isRecording: false, isLivePolling: true, isDriving: false, isDidScanning: false))
        XCTAssertTrue(BLERecoveryPolicy.canAutoResume(.driving))
        XCTAssertTrue(BLERecoveryPolicy.canAutoResume(.live))
        XCTAssertFalse(BLERecoveryPolicy.canAutoResume(.unknownDidScan))
        XCTAssertFalse(BLERecoveryPolicy.canAutoResume(.recordingOnly))
    }
}
