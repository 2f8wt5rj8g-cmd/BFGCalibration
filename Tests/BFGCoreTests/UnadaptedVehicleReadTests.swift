import XCTest
@testable import BFGCore

/// Reading a vehicle whose firmware the static table cannot interpret.
///
/// The table exists to turn a *target capacity* into a profile byte for a write.
/// Reading does not need it: the vehicle reports its own capacity either way, and
/// the repeated probes can measure it. Withholding that number said less than
/// showing it for what it is — the value comes from the vehicle, only its
/// interpretation is unconfirmed. The write gate is untouched by any of this.
final class UnadaptedVehicleReadTests: XCTestCase {

    private func unresolved(bfgCapacity: Int, scannedCapacity: Int = -1) -> BfgBleClient.Result {
        let result = BfgBleClient.Result()
        result.mode = .unsupported
        result.bfgCapacity = bfgCapacity
        result.scannedCapacity = scannedCapacity
        return result
    }

    func testUnresolvedFirmwareStillShowsTheVehicleReading() {
        let result = unresolved(bfgCapacity: 22000)
        XCTAssertEqual(22000, result.displayBeforeCapacity)
        XCTAssertTrue(result.capacityIsUnverified,
                      "车辆自报值必须被标注为未验证，而不是当作已确认读数")
    }

    func testMeasuredProbeBeatsTheSingleRegisterReading() {
        // The compatibility sweep cross-checks five registers; when it resolved a
        // value it is the stronger evidence of the two.
        let result = unresolved(bfgCapacity: 22000, scannedCapacity: 26000)
        XCTAssertEqual(26000, result.displayBeforeCapacity)
    }

    func testImplausibleReadingIsStillWithheld() {
        // A register value that cannot be a capacity is not shown at all — the
        // point is to surface a real reading, not to surface any number.
        let result = unresolved(bfgCapacity: 12)
        XCTAssertEqual(-1, result.displayBeforeCapacity)
        XCTAssertFalse(result.capacityIsUnverified)
    }

    func testResolvedCombinationIsNotLabelledUnverified() {
        let result = BfgBleClient.Result()
        result.mode = .standard
        result.resolvedBeforeCapacityRaw = 26000
        XCTAssertEqual(26000, result.displayBeforeCapacity)
        XCTAssertFalse(result.capacityIsUnverified)
    }

    func testUnresolvedCombinationStillRefusesToWrite() {
        // The whole point of surfacing the value is that it does not become
        // trustworthy. Nothing here may open the write path.
        let result = unresolved(bfgCapacity: 22000, scannedCapacity: 26000)
        XCTAssertFalse(result.writeSupported)
        let decision = CommunicationModeResolver.resolve(
            profile: 0x5F, bfgSoc: 76, bfgCapacity: 22000,
            disSoc: 76, disVoltage: 5820,
            dashboardVersion: 0x0259, bfgVersion: 0x0429, scannedCapacity: 26000)
        XCTAssertEqual(.unsupported, decision.mode)
        XCTAssertFalse(decision.writeSupported,
                       "表不认识的档位字节必须继续拒绝写入")
    }

    /// The probe is the only way to learn what an unlisted profile byte holds, so
    /// it has to run even when the meter firmware is one the table knows.
    func testCompatibilityProbeRunsForAnUnlistedProfileByte() {
        let unlisted = BfgProfileCatalog.expectedCore(0x5F)
        XCTAssertLessThanOrEqual(unlisted, 0, "0x5F 应当落在静态表之外（电压位非法）")
        let listed = BfgProfileCatalog.expectedCore(0x51)
        XCTAssertGreaterThan(listed, 0)
    }
}
