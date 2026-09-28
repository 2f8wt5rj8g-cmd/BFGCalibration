/// Port of `com.bfgtools.calibration.core.DisVoltageConfig`.
/// DIS 0x92 voltage selector. Independent of the BFG Profile encoding.
public enum DisVoltageConfig {
    public enum Failure: Swift.Error, Equatable {
        /// Current value unrecognised — writing is forbidden rather than guessed.
        case unrecognisedSelector
        case unsupportedVoltage
        case invalidTarget
    }

    public static func nominalVoltage(_ raw: Int) -> Int {
        guard raw >= 0, raw <= 0xFF else { return -1 }
        switch raw & 0x0F {
        case 1: return 72
        case 2: return 60
        case 3: return 48
        default: return -1
        }
    }

    public static func target(currentRaw: Int, voltage: Int) throws -> Int {
        guard nominalVoltage(currentRaw) >= 0 else { throw Failure.unrecognisedSelector }
        let lowNibble: Int
        switch voltage {
        case 72: lowNibble = 1
        case 60: lowNibble = 2
        case 48: lowNibble = 3
        default: throw Failure.unsupportedVoltage
        }
        return (currentRaw & 0xF0) | lowNibble
    }

    public static func isObserved(_ raw: Int) -> Bool {
        raw == 0xC1 || raw == 0xC2 || raw == 0x51 || raw == 0x52 || raw == 0x53
    }

    public static func requiresExtraWarning(currentRaw: Int, targetRaw: Int) -> Bool {
        !isObserved(currentRaw) || !isObserved(targetRaw)
    }

    public static func writePacket(_ targetRaw: Int) throws -> [UInt8] {
        guard nominalVoltage(targetRaw) >= 0 else { throw Failure.invalidTarget }
        // Ninebot packet: length 2, phone -> DIS, write-with-reply, 0x92, LE16.
        return [0x5A, 0xA5, 0x02, 0x3E, 0x01, 0x02, 0x92, UInt8(targetRaw), 0x00]
    }
}
