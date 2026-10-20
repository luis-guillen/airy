import Foundation
import Darwin

/// Ticks por núcleo, topología P/E y arranque. Solo APIs públicas.
public enum CPUProbe {
    public static func ticks() -> [CoreTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let status = host_processor_info(machHost, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard status == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { i in
            let base = i * stride
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            return CoreTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                             idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    /// `hw.perflevel0` = rendimiento, `hw.perflevel1` = eficiencia (R3). nil si no hay perflevel0.
    public static func topology() -> CoreTopology? {
        guard let p = sysctlValue("hw.perflevel0.logicalcpu", as: Int32.self) else { return nil }
        let e = sysctlValue("hw.perflevel1.logicalcpu", as: Int32.self) ?? 0
        return CoreTopology(performance: Int(p), efficiency: Int(e))
    }

    public static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}
