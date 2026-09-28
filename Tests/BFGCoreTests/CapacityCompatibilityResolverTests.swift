import XCTest
@testable import BFGCore

/// Port of `CapacityCompatibilityResolverTest`.
final class CapacityCompatibilityResolverTests: XCTestCase {

    func testAbnormalZeroCoreUsesMatching0eAnd0fCapacity() {
        let result = CapacityCompatibilityResolver.resolve(expectedCapacity: 26000, readings: [
            [26000, 26000, 26000],
            [26000, 26000, 26000],
            [2570, 2570, 2570],
            [0, 0, 0],
            [2, 2, 2]
        ])

        XCTAssertEqual(26000, result.selectedCapacity)
        XCTAssertEqual(0x0E, result.selectedRegister)
    }

    func testUnstableNoiseIsRejected() {
        let result = CapacityCompatibilityResolver.resolve(expectedCapacity: 26000, readings: [
            [18000, 22000, 26000],
            [21000, 23000, 25000],
            [2000, 2100, 2200],
            [0, 0, 0],
            [2, 2, 2]
        ])

        XCTAssertEqual(-1, result.selectedCapacity)
        XCTAssertEqual(-1, result.selectedRegister)
    }

    func testStable0eMatchingProfileCanStandAlone() {
        let result = CapacityCompatibilityResolver.resolve(expectedCapacity: 18000, readings: [
            [18000, 18000, 17999],
            [-1, -1, -1],
            [15000, 14000, 13000],
            [0, 0, 0],
            [0, 0, 0]
        ])

        XCTAssertEqual(18000, result.selectedCapacity)
        XCTAssertEqual(0x0E, result.selectedRegister)
    }

    func testChangingRemainingCapacityIsNotUsedByItself() {
        let result = CapacityCompatibilityResolver.resolve(expectedCapacity: 26000, readings: [
            [0, 0, 0],
            [0, 0, 0],
            [20000, 19950, 19900],
            [0, 0, 0],
            [2, 2, 2]
        ])

        XCTAssertEqual(-1, result.selectedCapacity)
    }
}
