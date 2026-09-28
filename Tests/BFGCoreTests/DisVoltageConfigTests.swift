import XCTest
@testable import BFGCore

/// Port of `DisVoltageConfigTest`.
final class DisVoltageConfigTests: XCTestCase {

    func testKnownFamiliesKeepTheirHighNibble() throws {
        XCTAssertEqual(0xC1, try DisVoltageConfig.target(currentRaw: 0xC2, voltage: 72))
        XCTAssertEqual(0xC2, try DisVoltageConfig.target(currentRaw: 0xC1, voltage: 60))
        XCTAssertEqual(0x51, try DisVoltageConfig.target(currentRaw: 0x52, voltage: 72))
        XCTAssertEqual(0x52, try DisVoltageConfig.target(currentRaw: 0x51, voltage: 60))
        XCTAssertEqual(0x53, try DisVoltageConfig.target(currentRaw: 0x51, voltage: 48))
    }

    func testUnknownFamilyIsComputableButNeedsWarning() throws {
        XCTAssertEqual(0xD1, try DisVoltageConfig.target(currentRaw: 0xD2, voltage: 72))
        XCTAssertTrue(DisVoltageConfig.requiresExtraWarning(currentRaw: 0xD2, targetRaw: 0xD1))
        XCTAssertTrue(DisVoltageConfig.requiresExtraWarning(currentRaw: 0xC1, targetRaw: 0xC3))
        XCTAssertFalse(DisVoltageConfig.requiresExtraWarning(currentRaw: 0x51, targetRaw: 0x53))
    }

    func testUnsupportedCurrentValueIsRejected() throws {
        XCTAssertEqual(-1, DisVoltageConfig.nominalVoltage(0xC0))
        XCTAssertEqual(-1, DisVoltageConfig.nominalVoltage(0x01C2))

        XCTAssertThrowsError(try DisVoltageConfig.target(currentRaw: 0xC0, voltage: 72)) { error in
            XCTAssertEqual(error as? DisVoltageConfig.Failure, .unrecognisedSelector)
        }
    }

    func testWritePacketUsesDashboardDestinationAndTwoByteLittleEndianValue() throws {
        XCTAssertEqual([0x5A, 0xA5, 0x02, 0x3E, 0x01, 0x02, 0x92, 0xC1, 0x00],
                       try DisVoltageConfig.writePacket(0xC1))
    }
}
