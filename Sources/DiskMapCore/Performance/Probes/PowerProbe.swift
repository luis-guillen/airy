import Foundation
import IOKit
import Synchronization
import IOKit.ps
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

/// Batería interna y fuente de alimentación. Solo IOKit público (`IOPS*` + registro `AppleSmartBattery`).
public enum BatteryProbe {
    /// Ligereza (M7): la batería cambia despacio; se lee como mucho cada 30 s, no en cada muestra de 1,5 s.
    public static let cacheSeconds: TimeInterval = 30
    static let throttle = BatteryThrottle(maxAge: cacheSeconds)

    /// `read()` con caché de `cacheSeconds`.
    public static func cached(now: Date = Date()) -> BatteryReading? {
        throttle.value(now: now, read: read)
    }

    /// nil sin batería interna (Mac de sobremesa).
    public static func read() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = (desc[kIOPSCurrentCapacityKey] as? NSNumber)?.intValue else { continue }
            let max = (desc[kIOPSMaxCapacityKey] as? NSNumber)?.intValue ?? 100
            let percent = max > 0 ? Swift.min(100, Swift.max(0, current * 100 / max)) : current
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let smart = smartBatteryProperties()
            return BatteryReading(
                percent: percent, isCharging: charging, onACPower: onACPower(info),
                cycleCount: (smart?["CycleCount"] as? NSNumber)?.intValue,
                healthPercent: health(rawMax: (smart?["AppleRawMaxCapacity"] as? NSNumber)?.intValue,
                                      design: (smart?["DesignCapacity"] as? NSNumber)?.intValue))
        }
        return nil
    }

    /// AppleRawMaxCapacity / DesignCapacity × 100, acotada a 0…100.
    static func health(rawMax: Int?, design: Int?) -> Int? {
        guard let rawMax, let design, design > 0 else { return nil }
        return Swift.min(100, Swift.max(0, Int((Double(rawMax) / Double(design) * 100).rounded())))
    }

    public static func onACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        return onACPower(info)
    }

    private static func onACPower(_ info: CFTypeRef) -> Bool {
        guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSACPowerValue
    }

    /// Solo las tres claves que se usan (no el diccionario entero del registro).
    private static func smartBatteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var result: [String: Any] = [:]
        for key in ["CycleCount", "AppleRawMaxCapacity", "DesignCapacity"] {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() {
                result[key] = value
            }
        }
        return result
    }
}

/// Recuerda la última lectura (también «sin batería») durante `maxAge` segundos.
final class BatteryThrottle: Sendable {
    private let maxAge: TimeInterval
    private let state = Mutex<(date: Date, reading: BatteryReading?)?>(nil)

    init(maxAge: TimeInterval) { self.maxAge = maxAge }

    func value(now: Date, read: () -> BatteryReading?) -> BatteryReading? {
        if let cached = state.withLock({ $0 }) {
            let age = now.timeIntervalSince(cached.date)
            if age >= 0 && age < maxAge { return cached.reading }
        }
        let reading = read()
        state.withLock { $0 = (now, reading) }
        return reading
    }
}
