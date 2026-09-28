/// Port of `com.bfgtools.calibration.core.DashboardVoltageResolver`.
///
/// Resolves the dashboard's nominal voltage from the paired live energy and
/// remaining-capacity values exposed by DIS registers 0x1E and 0x44.
///
/// The quotient is used only for identification. This type never writes a
/// dashboard register.
public enum DashboardVoltageResolver {
    public struct Reading {
        public let nominalVoltage: Int
        public let calculatedVoltage: Double

        public var isKnown: Bool { nominalVoltage > 0 }
    }

    private static let supportedVoltages = [48, 60, 72]
    private static let maxDistanceVolts = 4.5

    public static func resolve(energyWh: Int, remainingCapacityMah: Int) -> Reading {
        if energyWh <= 0 || remainingCapacityMah < 500 {
            return Reading(nominalVoltage: -1, calculatedVoltage: .nan)
        }
        let calculated = Double(energyWh) * 1000.0 / Double(remainingCapacityMah)
        if !calculated.isFinite || calculated < 35.0 || calculated > 85.0 {
            return Reading(nominalVoltage: -1, calculatedVoltage: calculated)
        }

        var nearest = -1
        var distance = Double.greatestFiniteMagnitude
        for candidate in supportedVoltages {
            let currentDistance = abs(calculated - Double(candidate))
            if currentDistance < distance {
                nearest = candidate
                distance = currentDistance
            }
        }
        return Reading(nominalVoltage: distance <= maxDistanceVolts ? nearest : -1,
                       calculatedVoltage: calculated)
    }
}
