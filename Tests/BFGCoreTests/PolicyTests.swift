import XCTest
@testable import BFGCore

/// Port of `BfgProfileVoltageTest`.
final class BfgProfileVoltageTests: XCTestCase {
    func testProfileVoltageOrderMatchesObservedVehicleProfiles() {
        XCTAssertEqual(72, BfgProfileCatalog.nominalVoltage(0x20))
        XCTAssertEqual(60, BfgProfileCatalog.nominalVoltage(0x21))
        XCTAssertEqual(48, BfgProfileCatalog.nominalVoltage(0x22))
    }
}

/// Port of `AuthRepairOfferTest`.
final class AuthRepairOfferTests: XCTestCase {
    func testOffersRepairOnlyForAuthTimeout() {
        XCTAssertTrue(AuthRepairOffer.isAuthTimeout("AUTH无回复"))
        XCTAssertFalse(AuthRepairOffer.isAuthTimeout("PRE_COMM无回复"))
        XCTAssertFalse(AuthRepairOffer.isAuthTimeout("GATT连接失败"))
        XCTAssertFalse(AuthRepairOffer.isAuthTimeout("AUTH被车辆拒绝"))
        XCTAssertFalse(AuthRepairOffer.isAuthTimeout(nil))
    }

    func testDirectRepairRequiresFullVehicleIdentity() {
        XCTAssertTrue(AuthRepairOffer.hasExactVehicleIdentity(mac: "AA:BB:CC:DD:EE:FF",
                                                              serial: "TEST0000000001"))
        XCTAssertFalse(AuthRepairOffer.hasExactVehicleIdentity(mac: "AA:BB:CC:DD:EE:FF",
                                                               serial: "SHORT"))
        XCTAssertFalse(AuthRepairOffer.hasExactVehicleIdentity(mac: "AA:BB:CC:DD:EE:FF",
                                                               serial: ""))
        XCTAssertFalse(AuthRepairOffer.hasExactVehicleIdentity(mac: "AA:BB:CC:DD:EE",
                                                               serial: "TEST0000000001"))
    }
}

/// Port of `WriteAccessPolicyTest`.
final class WriteAccessPolicyTests: XCTestCase {
    func testNPrefixIsReadOnly() {
        XCTAssertTrue(WriteAccessPolicy.isReadOnlySerial("N1234567890123"))
        XCTAssertTrue(WriteAccessPolicy.isReadOnlySerial(" n1234567890123 "))
        XCTAssertFalse(WriteAccessPolicy.isReadOnlySerial("J3222"))
        XCTAssertFalse(WriteAccessPolicy.isReadOnlySerial(""))
    }

    func testUnknownMeterNeedsExtraWarning() {
        XCTAssertFalse(WriteAccessPolicy.needsMeterCompatibilityWarning(0x0286))
        XCTAssertFalse(WriteAccessPolicy.needsMeterCompatibilityWarning(0x0429))
        XCTAssertTrue(WriteAccessPolicy.needsMeterCompatibilityWarning(0x0285))
        XCTAssertTrue(WriteAccessPolicy.needsMeterCompatibilityWarning(0x0428))
        XCTAssertTrue(WriteAccessPolicy.needsMeterCompatibilityWarning(-1))
    }
}

/// Port of `DashboardWritePolicyTest`.
final class DashboardWritePolicyTests: XCTestCase {
    func testExactCombinationAllowed() {
        XCTAssertTrue(DashboardWritePolicy.allows(dashboard: 0x0259, colorDisplay: 0x0155,
                                                  centre: 0x05CA, meter: 0x0429))
    }

    func testEveryMismatchOrMissingValueBlocks() {
        XCTAssertFalse(DashboardWritePolicy.allows(dashboard: -1, colorDisplay: 0x0155,
                                                   centre: 0x05CA, meter: 0x0429))
        XCTAssertFalse(DashboardWritePolicy.allows(dashboard: 0x0259, colorDisplay: -1,
                                                   centre: 0x05CA, meter: 0x0429))
        XCTAssertFalse(DashboardWritePolicy.allows(dashboard: 0x0259, colorDisplay: 0x0155,
                                                   centre: -1, meter: 0x0429))
        XCTAssertFalse(DashboardWritePolicy.allows(dashboard: 0x0259, colorDisplay: 0x0155,
                                                   centre: 0x05CA, meter: -1))
        XCTAssertFalse(DashboardWritePolicy.allows(dashboard: 0x0432, colorDisplay: 0x0155,
                                                   centre: 0x05CA, meter: 0x0429))
        XCTAssertFalse(DashboardWritePolicy.allows(dashboard: 0x0259, colorDisplay: 0x0154,
                                                   centre: 0x05CA, meter: 0x0429))
        XCTAssertFalse(DashboardWritePolicy.allows(dashboard: 0x0259, colorDisplay: 0x0155,
                                                   centre: 0x05C9, meter: 0x0429))
        XCTAssertFalse(DashboardWritePolicy.allows(dashboard: 0x0259, colorDisplay: 0x0155,
                                                   centre: 0x05CA, meter: 0x0286))
    }
}

/// Port of `PostWriteCheckPolicyTest`.
final class PostWriteCheckPolicyTests: XCTestCase {
    func testMismatchNeverCountsAsConfirmedWrite() {
        XCTAssertFalse(PostWriteCheckPolicy.targetMatches(actualProfile: 0x51, expectedProfile: 0x71,
                                                          actualDisRaw: 0x52, expectedDisRaw: -1))
        XCTAssertFalse(PostWriteCheckPolicy.targetMatches(actualProfile: 0x51, expectedProfile: -1,
                                                          actualDisRaw: 0x52, expectedDisRaw: 0x51))
        XCTAssertTrue(PostWriteCheckPolicy.targetMatches(actualProfile: 0x71, expectedProfile: 0x71,
                                                         actualDisRaw: 0x52, expectedDisRaw: -1))
        XCTAssertTrue(PostWriteCheckPolicy.targetMatches(actualProfile: 0x51, expectedProfile: -1,
                                                         actualDisRaw: 0x52, expectedDisRaw: 0x52))
    }

    func testTemporaryZeroCapacityRetriesButIsBounded() {
        XCTAssertTrue(PostWriteCheckPolicy.capacityPending(soc: 28, remainingCapacityRaw: 0))
        XCTAssertFalse(PostWriteCheckPolicy.capacityPending(soc: 0, remainingCapacityRaw: 0))
        XCTAssertFalse(PostWriteCheckPolicy.capacityPending(soc: 28, remainingCapacityRaw: 6200))
        XCTAssertTrue(PostWriteCheckPolicy.shouldRetry(readsCompleted: 1, targetMatches: true,
                                                       capacityPending: true))
        XCTAssertTrue(PostWriteCheckPolicy.shouldRetry(readsCompleted: 2, targetMatches: false,
                                                       capacityPending: false))
        XCTAssertFalse(PostWriteCheckPolicy.shouldRetry(readsCompleted: 3, targetMatches: true,
                                                        capacityPending: true))
        XCTAssertFalse(PostWriteCheckPolicy.shouldRetry(readsCompleted: 3, targetMatches: false,
                                                        capacityPending: false))
    }
}

/// Port of `TimedRiskGateTest`.
final class TimedRiskGateTests: XCTestCase {
    func testDashboardRequiresThirtySecondsAndCheck() {
        let readyAt = Int64(1000 + TimedRiskGate.dashboardSeconds * 1000)
        XCTAssertFalse(TimedRiskGate.canProceed(elapsedRealtime: readyAt - 1, readyAt: readyAt, checked: true))
        XCTAssertFalse(TimedRiskGate.canProceed(elapsedRealtime: readyAt, readyAt: readyAt, checked: false))
        XCTAssertTrue(TimedRiskGate.canProceed(elapsedRealtime: readyAt, readyAt: readyAt, checked: true))
    }

    func testMeterRequiresThreeSecondsAndCheck() {
        let readyAt = Int64(1000 + TimedRiskGate.meterSeconds * 1000)
        XCTAssertFalse(TimedRiskGate.canProceed(elapsedRealtime: readyAt - 1, readyAt: readyAt, checked: true))
        XCTAssertFalse(TimedRiskGate.canProceed(elapsedRealtime: readyAt, readyAt: readyAt, checked: false))
        XCTAssertTrue(TimedRiskGate.canProceed(elapsedRealtime: readyAt, readyAt: readyAt, checked: true))
    }
}

/// Port of `RegisterReadPlanTest`.
final class RegisterReadPlanTests: XCTestCase {
    func testRequestsAreReadOnlyAndBoundedToTwoModules() throws {
        XCTAssertEqual([0x5A, 0xA5, 1, 0x3E, 1, 1, 0x92, 2],
                       try RegisterReadPlan.request(module: RegisterReadPlan.dashboard, index: 0x92))
        XCTAssertEqual([0x5A, 0xA5, 1, 0x3E, 0x10, 1, 0, 1],
                       try RegisterReadPlan.request(module: RegisterReadPlan.meter, index: 0))
        XCTAssertEqual(2, try RegisterReadPlan.length(module: RegisterReadPlan.meter, index: 0x1C))
        XCTAssertFalse(RegisterReadPlan.supports(0x02))
    }

    func testOtherControllersCannotBeProbed() {
        XCTAssertThrowsError(try RegisterReadPlan.request(module: 0x02, index: 0x00)) { error in
            XCTAssertEqual(error as? RegisterReadPlan.Failure, .unsupportedScanTarget)
        }
    }
}

/// Port of `PairingCredentialStoreTest`.
final class PairingCredentialStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PairingCredentialStore.purgeAll()
    }

    func testKeysStayInSessionMemoryAndAreCopied() throws {
        let mac = "AA:BB:CC:DD:EE:89"
        var original = [UInt8](repeating: 7, count: 32)
        XCTAssertTrue(PairingCredentialStore.save(mac: mac, serial: "TEST0000000001",
                                                  password32: original))

        original[0] = 9
        let loaded = try XCTUnwrap(PairingCredentialStore.load(mac: mac))
        XCTAssertEqual(7, loaded[0])

        // Mutating the returned copy must not touch the stored value.
        var returnedCopy = try XCTUnwrap(PairingCredentialStore.load(mac: mac))
        returnedCopy[1] = 2
        XCTAssertEqual(2, returnedCopy[1])
        XCTAssertEqual(7, PairingCredentialStore.load(mac: mac)![1])

        let expected = [UInt8](repeating: 7, count: 16)
        XCTAssertEqual(expected, Array(PairingCredentialStore.load(mac: mac)!.prefix(16)))
        XCTAssertNil(PairingCredentialStore.load(mac: "AA:BB:CC:DD:EE:88"))
    }

    func testMalformedSerialIsRejected() {
        XCTAssertFalse(PairingCredentialStore.save(mac: "AA:BB:CC:DD:EE:89", serial: "SHORT",
                                                   password32: [UInt8](repeating: 7, count: 32)))
        XCTAssertFalse(PairingCredentialStore.save(mac: "AA:BB:CC:DD:EE:89", serial: "TEST0000000001",
                                                   password32: [UInt8](repeating: 7, count: 16)))
    }

    func testLoadRecordsRebuildsColonSeparatedMac() {
        XCTAssertTrue(PairingCredentialStore.save(mac: "AA:BB:CC:DD:EE:89",
                                                  serial: "TEST0000000001",
                                                  password32: [UInt8](repeating: 7, count: 32)))
        let records = PairingCredentialStore.loadRecords()
        XCTAssertEqual(1, records.count)
        XCTAssertEqual("AA:BB:CC:DD:EE:89", records[0].mac)
        XCTAssertEqual("TEST0000000001", records[0].effectiveSn)
        XCTAssertEqual("local_pair", records[0].source)
    }
}
