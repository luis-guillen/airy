import Foundation
import Darwin

/// Memoria como el Monitor de Actividad (R4). Solo APIs públicas: `host_statistics64` y `sysctl`.
public enum MemoryProbe {
    public static func read() -> MemoryStats? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        guard let total = sysctlValue("hw.memsize", as: UInt64.self), total > 0 else { return nil }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        let level = sysctlValue("kern.memorystatus_vm_pressure_level", as: Int32.self)
        return stats(vm: vm, pageSize: Int64(pageSize), total: Int64(total),
                     swap: swapOK ? swap : nil, pressureLevel: level)
    }

    static func stats(vm: vm_statistics64, pageSize: Int64, total: Int64, swap: xsw_usage?,
                      pressureLevel: Int32?) -> MemoryStats {
        let appPages = max(0, Int64(vm.internal_page_count) - Int64(vm.purgeable_count))
        let app = appPages * pageSize
        let wired = Int64(vm.wire_count) * pageSize
        let compressed = Int64(vm.compressor_page_count) * pageSize
        let used = app + wired + compressed
        let cache = (Int64(vm.external_page_count) + Int64(vm.purgeable_count)) * pageSize
        let free = max(0, total - used - cache)
        return MemoryStats(total: total, used: used, appMemory: app, wired: wired, compressed: compressed,
                           fileCache: cache, free: free,
                           pressure: pressureLevel.flatMap(pressure(level:)),
                           swapUsed: swap.map { Int64($0.xsu_used) } ?? 0,
                           swapTotal: swap.map { Int64($0.xsu_total) } ?? 0)
    }

    static func pressure(level: Int32) -> MemoryPressure? {
        switch level {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: nil
        }
    }
}

/// Lee un entero de `sysctlbyname` (nil si no existe).
func sysctlValue<T: FixedWidthInteger>(_ name: String, as: T.Type) -> T? {
    var value: T = 0
    var size = MemoryLayout<T>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
}
