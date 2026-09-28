import XCTest
@testable import BFGCore

/// Port of `CommunicationModeResolverTest`.
final class CommunicationModeResolverTests: XCTestCase {

    func testStandardReadbackUsesRawBfgData() {
        let decision = CommunicationModeResolver.resolve(
            profile: 0x51, bfgSoc: 99, bfgCapacity: 26000, disSoc: 99, disVoltage: 6660,
            dashboardVersion: 0x0259, bfgVersion: 0x0429, scannedCapacity: -1)

        XCTAssertEqual(decision.mode, .standard)
        XCTAssertEqual(99, decision.resolvedSoc)
        XCTAssertEqual(26000, decision.resolvedCapacity)
        XCTAssertTrue(decision.writeSupported)
    }

    func testFirmware286WithZeroCoreUsesScannedCapacity() {
        let decision = CommunicationModeResolver.resolve(
            profile: 0x50, bfgSoc: 134, bfgCapacity: 0, disSoc: 99, disVoltage: 7576,
            dashboardVersion: 0x0432, bfgVersion: 0x0286, scannedCapacity: 26000)

        XCTAssertEqual(decision.mode, .capacityScanCompat)
        XCTAssertEqual(26000, decision.resolvedCapacity)
        XCTAssertTrue(decision.writeSupported)
    }

    func testFirmware286WithNormalCapacityUsesSameStandardWritePath() {
        let decision = CommunicationModeResolver.resolve(
            profile: 0x50, bfgSoc: 99, bfgCapacity: 26000, disSoc: 99, disVoltage: 7576,
            dashboardVersion: 0x0432, bfgVersion: 0x0286, scannedCapacity: -1)

        XCTAssertEqual(decision.mode, .standard)
        XCTAssertEqual(26000, decision.resolvedCapacity)
        XCTAssertTrue(decision.writeSupported)
    }

    func testUnknownInvalidCombinationDoesNotEnableWriting() {
        let decision = CommunicationModeResolver.resolve(
            profile: 0x50, bfgSoc: 134, bfgCapacity: 0, disSoc: 99, disVoltage: 7576,
            dashboardVersion: 0x0433, bfgVersion: 0x0285, scannedCapacity: -1)

        XCTAssertEqual(decision.mode, .unsupported)
        XCTAssertEqual(-1, decision.resolvedCapacity)
        XCTAssertFalse(decision.writeSupported)
    }

    func testFirmwareVersionDoesNotCreateCapacityWithoutScanEvidence() {
        let decision = CommunicationModeResolver.resolve(
            profile: 0x50, bfgSoc: 134, bfgCapacity: 0, disSoc: 99, disVoltage: 7576,
            dashboardVersion: 0x0432, bfgVersion: 0x0286, scannedCapacity: -1)

        XCTAssertEqual(decision.mode, .unsupported)
        XCTAssertFalse(decision.writeSupported)
    }

    func testUnverifiedMeter499UsesFocusedCapacityScanCompatibility() {
        let decision = CommunicationModeResolver.resolve(
            profile: 0x01, bfgSoc: 91, bfgCapacity: 20000, disSoc: 91, disVoltage: 7793,
            dashboardVersion: 0x0222, bfgVersion: 0x0499, scannedCapacity: 20000)

        XCTAssertEqual(decision.mode, .capacityScanCompat)
        XCTAssertEqual(20000, decision.resolvedCapacity)
        XCTAssertTrue(decision.writeSupported)
    }

    func testInvalidCapacityWithoutScanEvidenceStaysReadOnly() {
        let decision = CommunicationModeResolver.resolve(
            profile: 0x21, bfgSoc: 99, bfgCapacity: 0, disSoc: 99, disVoltage: 6489,
            dashboardVersion: 0x0259, bfgVersion: 0x0200, scannedCapacity: -1)

        XCTAssertEqual(decision.mode, .unsupported)
        XCTAssertFalse(decision.writeSupported)
    }
}
