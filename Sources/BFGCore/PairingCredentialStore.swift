import Foundation

/// Port of `com.bfgtools.calibration.core.PairingCredentialStore`.
///
/// Pairing keys live only for this app process; a process restart requires
/// pairing again. This mirrors the Android contract exactly.
///
/// The Android version also had `purgeLegacy(Context)`, which cleared values a
/// previous release had written to SharedPreferences and the AndroidKeyStore.
/// Neither store exists on iOS and this port writes nothing to disk, so the
/// equivalent is `purgeAll()` — see the migration notes in the design document.
public final class PairingCredentialStore {
    private struct Entry {
        let serial: String
        var password: [UInt8]
    }

    private static var session: [String: Entry] = [:]
    private static let lock = NSLock()

    private init() { }

    /// Removes every in-memory key. On iOS this replaces the Android-only
    /// `purgeLegacy`, which existed to erase previously persisted material.
    public static func purgeAll() {
        lock.lock()
        defer { lock.unlock() }
        for (key, var entry) in session {
            for i in 0..<entry.password.count { entry.password[i] = 0 }
            session[key] = entry
        }
        session.removeAll()
    }

    public static func load(mac: String?) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return session[key(mac)]?.password
    }

    @discardableResult
    public static func save(mac: String?, serial: String?, password32: [UInt8]?) -> Bool {
        guard let mac, !mac.isEmpty,
              let serial, isValidSerial(serial),
              let password32, password32.count == 32
        else { return false }

        lock.lock()
        defer { lock.unlock() }
        if var old = session[key(mac)] {
            for i in 0..<old.password.count { old.password[i] = 0 }
        }
        session[key(mac)] = Entry(serial: serial, password: password32)
        return true
    }

    public static func loadRecords() -> [DeviceRecord] {
        lock.lock()
        defer { lock.unlock() }

        var records: [DeviceRecord] = []
        for (compact, entry) in session {
            guard compact.count == 12 else { continue }
            var mac = ""
            var index = compact.startIndex
            while index < compact.endIndex {
                if !mac.isEmpty { mac.append(":") }
                let next = compact.index(index, offsetBy: 2)
                mac.append(contentsOf: compact[index..<next])
                index = next
            }
            records.append(DeviceRecord(
                id: -1,
                mac: mac,
                sn: entry.serial,
                name: entry.serial,
                deviceType: "",
                password16: Array(entry.password.prefix(16)),
                source: "local_pair"))
        }
        return records
    }

    private static func key(_ mac: String?) -> String {
        (mac ?? "").replacingOccurrences(of: ":", with: "").uppercased()
    }

    private static func isValidSerial(_ serial: String) -> Bool {
        let pattern = "^[A-Za-z0-9]{14}$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(serial.startIndex..<serial.endIndex, in: serial)
        guard let match = regex.firstMatch(in: serial, range: range) else { return false }
        return match.range == range
    }
}
