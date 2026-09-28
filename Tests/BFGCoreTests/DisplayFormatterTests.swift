import XCTest
@testable import BFGCore

/// The page prints these strings as-is, so the exact shape is user-visible.
final class DisplayFormatterTests: XCTestCase {

    func testVoltageNameFollowsTheProfileNibble() {
        XCTAssertEqual("72V", DisplayFormatter.voltageName(0x10))
        XCTAssertEqual("60V", DisplayFormatter.voltageName(0x21))
        XCTAssertEqual("48V", DisplayFormatter.voltageName(0x32))
        XCTAssertEqual("Unknown", DisplayFormatter.voltageName(0x13))
    }

    func testCapacityDropsTheDecimalWhenItIsWhole() {
        XCTAssertEqual("26Ah", DisplayFormatter.capacityShort(26000))
        XCTAssertEqual("10.5Ah", DisplayFormatter.capacityShort(10500))
        XCTAssertEqual("0Ah", DisplayFormatter.capacityShort(0))
        XCTAssertEqual("未知", DisplayFormatter.capacityShort(-1))
    }

    func testBatteryVoltageTrimsTrailingZeroes() {
        XCTAssertEqual("60V", DisplayFormatter.batteryVoltage(6000))
        XCTAssertEqual("58.2V", DisplayFormatter.batteryVoltage(5820))
        XCTAssertEqual("58.25V", DisplayFormatter.batteryVoltage(5825))
        XCTAssertEqual("--V", DisplayFormatter.batteryVoltage(-1))
    }

    /// The dashboard allowlist is expressed as strings like "4.2.9", so these
    /// have to line up with `DashboardWritePolicy`'s raw values.
    func testFirmwareVersionMatchesTheAllowlistSpelling() {
        XCTAssertEqual("4.2.9", DisplayFormatter.firmwareVersion(0x0429))
        XCTAssertEqual("2.5.9", DisplayFormatter.firmwareVersion(0x0259))
        XCTAssertEqual("1.5.5", DisplayFormatter.firmwareVersion(0x0155))
        XCTAssertEqual("未读取到", DisplayFormatter.firmwareVersion(-1))
    }

    func testNominalVoltageAndSoc() {
        XCTAssertEqual("60V", DisplayFormatter.nominalVoltage(60))
        XCTAssertEqual("--V", DisplayFormatter.nominalVoltage(0))
        XCTAssertEqual("76", DisplayFormatter.soc(76))
        XCTAssertEqual("0", DisplayFormatter.soc(0))
        XCTAssertEqual("--", DisplayFormatter.soc(-1))
    }
}
