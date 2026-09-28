import XCTest
@testable import BFGCore

/// Port of `DashboardVoltageResolverTest`.
final class DashboardVoltageResolverTests: XCTestCase {

    func testResolvesConfirmed60VoltCapture() {
        let reading = DashboardVoltageResolver.resolve(energyWh: 1075, remainingCapacityMah: 17929)

        XCTAssertTrue(reading.isKnown)
        XCTAssertEqual(60, reading.nominalVoltage)
        XCTAssertEqual(59.96, reading.calculatedVoltage, accuracy: 0.02)
    }

    func testResolvesConfirmed72VoltCapture() {
        let reading = DashboardVoltageResolver.resolve(energyWh: 1310, remainingCapacityMah: 18200)

        XCTAssertTrue(reading.isKnown)
        XCTAssertEqual(72, reading.nominalVoltage)
        XCTAssertEqual(71.98, reading.calculatedVoltage, accuracy: 0.02)
    }

    func testRejectsMissingOrImplausibleValues() {
        XCTAssertFalse(DashboardVoltageResolver.resolve(energyWh: -1, remainingCapacityMah: 18200).isKnown)
        XCTAssertFalse(DashboardVoltageResolver.resolve(energyWh: 1310, remainingCapacityMah: 0).isKnown)
        XCTAssertFalse(DashboardVoltageResolver.resolve(energyWh: 1310, remainingCapacityMah: 5000).isKnown)
    }
}
