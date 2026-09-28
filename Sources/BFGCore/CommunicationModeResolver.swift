/// Port of `com.bfgtools.calibration.core.CommunicationModeResolver`.
/// Chooses a readback strategy from validated normal or repeated compatibility reads.
public enum CommunicationModeResolver {
    public enum Mode {
        case standard
        case capacityScanCompat
        case unsupported
    }

    public struct Decision {
        public let mode: Mode
        public let resolvedSoc: Int
        public let resolvedCapacity: Int
        public let writeSupported: Bool
        public let reason: String
    }

    public static func resolve(profile: Int,
                               bfgSoc: Int,
                               bfgCapacity: Int,
                               disSoc: Int,
                               disVoltage: Int,
                               dashboardVersion: Int,
                               bfgVersion: Int,
                               scannedCapacity: Int) -> Decision {
        let expectedCapacity = BfgProfileCatalog.expectedCore(profile)
        let profileValid = expectedCapacity > 0
        let bfgSocValid = isSocValid(bfgSoc)
        let disSocValid = isSocValid(disSoc)
        let fullBfgReadbackValid = profileValid && bfgSocValid && bfgCapacity == expectedCapacity

        let compatibilityEvidence = isCapacityPlausible(scannedCapacity)
        let anySocValid = bfgSocValid || disSocValid
        if profileValid && compatibilityEvidence && anySocValid {
            return Decision(mode: .capacityScanCompat,
                            resolvedSoc: bfgSocValid ? bfgSoc : disSoc,
                            resolvedCapacity: scannedCapacity,
                            writeSupported: true,
                            reason: "固件版本较旧或常规容量异常；已通过重复扫描识别有效容量")
        }

        if fullBfgReadbackValid {
            return Decision(mode: .standard,
                            resolvedSoc: bfgSoc,
                            resolvedCapacity: bfgCapacity,
                            writeSupported: true,
                            reason: "BFG Profile、SOC和容量回读一致")
        }

        let fallbackSoc = disSocValid ? disSoc : bfgSoc
        return Decision(mode: .unsupported,
                        resolvedSoc: fallbackSoc,
                        resolvedCapacity: -1,
                        writeSupported: false,
                        reason: "通信组合尚未验证，关键BFG回读不一致")
    }

    public static func label(_ mode: Mode) -> String {
        switch mode {
        case .standard: return "标准完整回读"
        case .capacityScanCompat: return "兼容模式"
        case .unsupported: return "未验证通信组合"
        }
    }

    private static func isSocValid(_ value: Int) -> Bool {
        value >= 0 && value <= 100
    }

    private static func isCapacityPlausible(_ value: Int) -> Bool {
        value >= 5000 && value <= 100000
    }
}
