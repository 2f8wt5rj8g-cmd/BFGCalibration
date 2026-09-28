/// Ninebot wire frames, ported from the constants and builders in `BfgBleClient`.
///
/// Frame layout: `5A A5 LEN SRC DST CMD INDEX DATA...`
/// `LEN` covers the data segment only. `CMD 0x02` is write-with-reply,
/// `0x01` is read.
///
/// These live in the portable core rather than the iOS target so they are
/// covered by the same tests that run on Linux.
public enum NinebotFrame {
    /// Phone/client.
    public static let srcPhone = 0x3E
    /// BLE board.
    public static let srcBleBoard = 0x04
    /// BFG metering module.
    public static let dstBfg = 0x10
    /// Dashboard (DIS).
    public static let dstDashboard = 0x01
    /// Centre controller.
    public static let dstCentre = 0x09

    public static let maxProfileVerifyAttempts = 4
    public static let maxCapacityVerifyAttempts = 3
    public static let maxDisVerifyAttempts = 4

    // MARK: - Fixed frames

    public static let preComm = Hex.literal("5AA5003E045B00")
    public static let readProfile = Hex.literal("5AA5013E10010001")
    public static let readSoc = Hex.literal("5AA5013E10010201")
    public static let readCapacity = Hex.literal("5AA5013E10011C02")

    // Official app dynamic config (device_type 88 / 14354 / 14360):
    // final dashboard battery/SOC and VRLA voltage are read from DIS, not
    // directly from BFG.
    public static let readDisBattery = Hex.literal("5AA5013E0101B502")
    public static let readDisVrlaVoltage = Hex.literal("5AA5013E0101B102")
    public static let readDisBfgVersion = Hex.literal("5AA5013E01013D02")
    public static let readDisDashboardVersion = Hex.literal("5AA5013E01011A02")
    public static let readColorDisplayVersion = Hex.literal("5AA5013E0101D102")
    public static let readCentreControllerVersion = Hex.literal("5AA5013E09010202")

    /// Confirmed paired DIS values: energy(Wh) / remaining capacity(Ah) = nominal voltage.
    public static let readDisEnergyWh = Hex.literal("5AA5013E01011E02")
    public static let readDisRemainingCapacity = Hex.literal("5AA5013E01014402")
    public static let readDisConfig = Hex.literal("5AA5013E01019202")

    /// `SET_PWD` header; the 32-byte password follows.
    public static let setPasswordHeader = Hex.literal("5AA5203E045C00")
    /// `AUTH` header; the 14-byte serial follows.
    public static let authenticateHeader = Hex.literal("5AA50E3E045D00")

    // MARK: - Builders

    public enum Failure: Swift.Error, Equatable {
        case serialMustBe14Bytes
    }

    /// Ninebot packet: 5A A5 LEN SRC DST CMD INDEX DATA
    /// LEN is data segment length only. CMD 0x02 = write with reply.
    public static func writeProfile(_ profile: Int) -> [UInt8] {
        [0x5A, 0xA5, 0x01, 0x3E, 0x10, 0x02, 0x00, UInt8(profile & 0xFF)]
    }

    public static func readBfgWord(register: Int) -> [UInt8] {
        [0x5A, 0xA5, 0x01, 0x3E, 0x10, 0x01, UInt8(register & 0xFF), 0x02]
    }

    public static func authenticate(serial14: [UInt8]) throws -> [UInt8] {
        guard serial14.count == 14 else { throw Failure.serialMustBe14Bytes }
        var out = authenticateHeader
        out.append(contentsOf: serial14)
        return out
    }

    /// Builds the `SET_PWD` request that hands the vehicle a freshly generated
    /// 32-byte pairing password.
    public static func setPassword(password32: [UInt8]) -> [UInt8] {
        var out = setPasswordHeader
        out.append(contentsOf: password32)
        return out
    }

    // MARK: - Parsing

    public static func isFrame(_ plain: [UInt8]?, src: Int, dst: Int, cmd: Int) -> Bool {
        guard let plain, plain.count >= 7 else { return false }
        return plain[0] == 0x5A && plain[1] == 0xA5
            && Int(plain[3]) == src && Int(plain[4]) == dst && Int(plain[5]) == cmd
    }

    /// Little-endian 16-bit read, matching the dashboard's `LE16` encoding.
    public static func readLe16(_ plain: [UInt8], offset: Int) -> Int {
        Int(plain[offset]) | (Int(plain[offset + 1]) << 8)
    }
}
