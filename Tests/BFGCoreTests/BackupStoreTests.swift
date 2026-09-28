import XCTest
import Foundation
@testable import BFGCore

/// The parameter backup is the only way back from a destructive write, so its
/// retention rules are checked directly rather than inferred from the UI.
final class BackupStoreTests: XCTestCase {

    private var suiteName = ""
    private var store: BackupStore!

    override func setUp() {
        super.setUp()
        suiteName = "bfg-backup-tests-\(UUID().uuidString)"
        store = BackupStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        store = nil
        super.tearDown()
    }

    private let serial = "TEST0000000001"

    func testMissingBackupIsNotValid() {
        XCTAssertFalse(store.firstBackup(serial: serial).valid)
        XCTAssertFalse(store.prewriteBackup(serial: serial).valid)
        XCTAssertEqual(-1, store.lastConfirmedProfile(serial: serial))
        XCTAssertEqual(-1, store.disConfigBackup(serial: serial))
    }

    /// The first backup is the original parameters, so it must survive later writes.
    func testFirstBackupIsWrittenOnlyOnce() {
        store.saveFirstBackupIfAbsent(serial: serial, profile: 0x31, capacity: 26000)
        let first = store.firstBackup(serial: serial)
        XCTAssertTrue(first.valid)
        XCTAssertEqual(0x31, first.profile)
        XCTAssertEqual(26000, first.capacity)

        store.saveFirstBackupIfAbsent(serial: serial, profile: 0x21, capacity: 10500)
        XCTAssertEqual(0x31, store.firstBackup(serial: serial).profile)
        XCTAssertEqual(26000, store.firstBackup(serial: serial).capacity)
    }

    func testOriginalDashboardBytesAreWrittenOnlyOnce() {
        store.saveDisConfigBackupIfAbsent(serial: serial, raw: 0xC2)
        XCTAssertEqual(0xC2, store.disConfigBackup(serial: serial))
        store.saveDisConfigBackupIfAbsent(serial: serial, raw: 0xC1)
        XCTAssertEqual(0xC2, store.disConfigBackup(serial: serial))
    }

    /// An unreadable dashboard config must not be recorded as a recoverable value.
    func testUnrecognisedDashboardBytesAreNotStored() {
        store.saveDisConfigBackupIfAbsent(serial: serial, raw: 0xC0)
        XCTAssertEqual(-1, store.disConfigBackup(serial: serial))
    }

    func testPrewriteSnapshotReplacesThePreviousOne() {
        XCTAssertTrue(store.savePrewriteSnapshot(serial: serial, profile: 0x31,
                                                 capacity: 26000, disConfigRaw: 0xC2))
        XCTAssertTrue(store.savePrewriteSnapshot(serial: serial, profile: 0x21,
                                                 capacity: 18000, disConfigRaw: 0xC1))
        let recent = store.prewriteBackup(serial: serial)
        XCTAssertEqual(0x21, recent.profile)
        XCTAssertEqual(18000, recent.capacity)
    }

    /// Saving a snapshot before any read has landed leaves nothing to restore.
    func testSnapshotWithoutReadingsLeavesNoBackup() {
        XCTAssertTrue(store.savePrewriteSnapshot(serial: serial, profile: -1,
                                                 capacity: -1, disConfigRaw: -1))
        XCTAssertFalse(store.prewriteBackup(serial: serial).valid)
        XCTAssertFalse(store.firstBackup(serial: serial).valid)
    }

    /// Establishing the permanent backups is a side effect of the first snapshot.
    func testSnapshotAlsoEstablishesTheFirstBackup() {
        XCTAssertTrue(store.savePrewriteSnapshot(serial: serial, profile: 0x31,
                                                 capacity: 26000, disConfigRaw: 0xC2))
        XCTAssertEqual(0x31, store.firstBackup(serial: serial).profile)
        XCTAssertEqual(0xC2, store.disConfigBackup(serial: serial))
    }

    func testBackupsAreKeptPerVehicle() {
        store.saveFirstBackupIfAbsent(serial: serial, profile: 0x31, capacity: 26000)
        store.saveFirstBackupIfAbsent(serial: "OTHER0000000002", profile: 0x21, capacity: 18000)
        XCTAssertEqual(0x31, store.firstBackup(serial: serial).profile)
        XCTAssertEqual(0x21, store.firstBackup(serial: "OTHER0000000002").profile)
    }

    /// Without a serial there is no vehicle to attribute a backup to, so sharing
    /// one bucket between every vehicle would be worse than storing nothing.
    func testEmptySerialIsRefused() {
        store.saveFirstBackupIfAbsent(serial: "", profile: 0x31, capacity: 26000)
        store.saveFirstBackupIfAbsent(serial: "   ", profile: 0x31, capacity: 26000)
        XCTAssertFalse(store.firstBackup(serial: "").valid)
        XCTAssertFalse(store.firstBackup(serial: "   ").valid)
        XCTAssertFalse(store.savePrewriteSnapshot(serial: "", profile: 1,
                                                  capacity: 1, disConfigRaw: 1))
    }

    /// The page only offers the second restore button when the two differ.
    func testAlternativesDiffer() {
        store.saveFirstBackupIfAbsent(serial: serial, profile: 0x31, capacity: 26000)
        XCTAssertFalse(store.alternativesDiffer(serial: serial))

        store.savePrewriteSnapshot(serial: serial, profile: 0x31, capacity: 26000,
                                   disConfigRaw: 0xC2)
        XCTAssertFalse(store.alternativesDiffer(serial: serial))

        store.savePrewriteSnapshot(serial: serial, profile: 0x21, capacity: 18000,
                                   disConfigRaw: 0xC2)
        XCTAssertTrue(store.alternativesDiffer(serial: serial))
    }

    func testLastConfirmedTargetIsRecorded() {
        store.saveLastConfirmed(serial: serial, profile: 0x31)
        XCTAssertEqual(0x31, store.lastConfirmedProfile(serial: serial))
    }

    func testDescriptionNamesVoltageAndCapacity() {
        store.saveFirstBackupIfAbsent(serial: serial, profile: 0x31, capacity: 26000)
        let text = store.firstBackup(serial: serial).description
        XCTAssertTrue(text.hasPrefix("60V · 26Ah"), text)
        XCTAssertEqual("未保存", BackupStore.Backup(profile: -1, capacity: -1, time: 0).description)
    }
}
