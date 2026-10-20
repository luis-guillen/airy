import Foundation
import IOKit.pwr_mgt

/// Estado térmico sin grados (§5): `ProcessInfo.thermalState` + límite de velocidad de la CPU.
public enum ThermalProbe {
    public static func read() -> ThermalReading {
        reading(state: ProcessInfo.processInfo.thermalState, speedLimit: cpuSpeedLimit())
    }

    static func reading(state: ProcessInfo.ThermalState, speedLimit: Int?) -> ThermalReading {
        let level: ThermalLevel
        switch state {
        case .nominal: level = .nominal
        case .fair: level = .fair
        case .serious: level = .serious
        case .critical: level = .critical
        @unknown default: level = .nominal
        }
        // R5
        let throttling = (speedLimit.map { $0 < 100 } ?? false) || level >= .serious
        return ThermalReading(level: level, speedLimit: speedLimit, throttling: throttling)
    }

    /// `CPU_Speed_Limit` (100 = sin límite). nil si el sistema no lo publica.
    private static func cpuSpeedLimit() -> Int? {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyCPUPowerStatus(&dict) == kIOReturnSuccess, let dict else { return nil }
        let d = dict.takeRetainedValue() as NSDictionary
        return (d["CPU_Speed_Limit"] as? NSNumber)?.intValue
    }
}
