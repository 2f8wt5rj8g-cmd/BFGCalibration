import XCTest
@testable import BFGCore

/// Covers the reverse lookup the write flow needs: the page sends the voltage
/// and capacity the user picked, and the client has to recover the profile byte.
final class BfgProfileCatalogTests: XCTestCase {

    func testVoltageCodeMatchesTheProfileNibble() {
        XCTAssertEqual(0, BfgProfileCatalog.voltageCode(forVoltage: 72))
        XCTAssertEqual(1, BfgProfileCatalog.voltageCode(forVoltage: 60))
        XCTAssertEqual(2, BfgProfileCatalog.voltageCode(forVoltage: 48))
        // Anything else is treated as the 60V family, matching Android.
        XCTAssertEqual(1, BfgProfileCatalog.voltageCode(forVoltage: 0))
        XCTAssertEqual(1, BfgProfileCatalog.voltageCode(forVoltage: 96))
    }

    func testCapacityResolvesToItsIndex() {
        XCTAssertEqual(0, BfgProfileCatalog.profileIndex(requestedMilliAh: 20000,
                                                        voltageCode: 0, preferring: -1))
        XCTAssertEqual(3, BfgProfileCatalog.profileIndex(requestedMilliAh: 36000,
                                                        voltageCode: 1, preferring: -1))
        // 18000 sits at index 2 and index 15; without a held index the lowest wins.
        XCTAssertEqual(2, BfgProfileCatalog.profileIndex(requestedMilliAh: 18000,
                                                        voltageCode: 2, preferring: -1))
        XCTAssertEqual(15, BfgProfileCatalog.profileIndex(requestedMilliAh: 18000,
                                                         voltageCode: 2, preferring: 15))
    }

    /// 10500 appears at both index 1 and index 4; the held index must survive.
    func testDuplicateCapacityKeepsTheCurrentIndex() {
        XCTAssertEqual(4, BfgProfileCatalog.profileIndex(requestedMilliAh: 10500,
                                                        voltageCode: 0, preferring: 4))
        XCTAssertEqual(1, BfgProfileCatalog.profileIndex(requestedMilliAh: 10500,
                                                        voltageCode: 0, preferring: 1))
        XCTAssertEqual(1, BfgProfileCatalog.profileIndex(requestedMilliAh: 10500,
                                                        voltageCode: 0, preferring: -1))
    }

    /// A stale index that no longer matches the requested capacity is ignored.
    func testStaleCurrentIndexIsIgnored() {
        XCTAssertEqual(3, BfgProfileCatalog.profileIndex(requestedMilliAh: 36000,
                                                        voltageCode: 0, preferring: 1))
    }

    /// Index 5 is 24500 at 48V rather than the table's 26000.
    func testVoltageSpecificExceptionIsHonoured() {
        XCTAssertEqual(5, BfgProfileCatalog.profileIndex(requestedMilliAh: 24500,
                                                        voltageCode: 2, preferring: -1))
        XCTAssertEqual(5, BfgProfileCatalog.profileIndex(requestedMilliAh: 26000,
                                                        voltageCode: 0, preferring: -1))
        XCTAssertEqual(-1, BfgProfileCatalog.profileIndex(requestedMilliAh: 26000,
                                                         voltageCode: 2, preferring: -1))
    }

    func testUnknownCapacityIsRejected() {
        XCTAssertEqual(-1, BfgProfileCatalog.profileIndex(requestedMilliAh: 12345,
                                                         voltageCode: 1, preferring: -1))
        XCTAssertEqual(-1, BfgProfileCatalog.profileIndex(requestedMilliAh: 0,
                                                         voltageCode: 1, preferring: -1))
    }

    /// Every entry in the table must survive a round trip through the picker.
    /// The held index is supplied because duplicate capacities are only
    /// distinguishable by it.
    func testEveryTableEntryRoundTrips() {
        for voltageCode in 0...2 {
            for index in 0...0xF {
                let profile = (index << 4) | voltageCode
                let capacity = BfgProfileCatalog.expectedCore(profile)
                XCTAssertEqual(index,
                               BfgProfileCatalog.profileIndex(requestedMilliAh: capacity,
                                                              voltageCode: voltageCode,
                                                              preferring: index),
                               "index \(index) voltageCode \(voltageCode)")
            }
        }
    }
}
