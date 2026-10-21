import Darwin
import Foundation
import IOKit

/// Accumulated disk (IOKit) and network (sysctl) counters. Public APIs only.
public enum IOProbe {
    /// Σ "Statistics" of each `IOBlockStorageDriver`: "Bytes (Read)" and "Bytes (Write)".
    public static func disk() -> IOCounters? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue()
                    as? [String: Any] else { continue }
            found = true
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return found ? IOCounters(read: read, written: written) : nil
    }

    /// `NET_RT_IFLIST2` with 64-bit counters (`if_data64`): ibytes = down, obytes = up.
    public static func network() -> IOCounters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var down: UInt64 = 0, up: UInt64 = 0
        var offset = 0
        buffer.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let size = Int(header.ifm_msglen)
                guard size > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(msg.ifm_index), &nameBuffer) != nil,
                       countsInterface(name: String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                                       isLoopback: msg.ifm_flags & IFF_LOOPBACK != 0) {
                        down &+= msg.ifm_data.ifi_ibytes
                        up &+= msg.ifm_data.ifi_obytes
                    }
                }
                offset += size
            }
        }
        return IOCounters(read: down, written: up)
    }

    /// Out with `lo*`, `utun*` and `ipsec*`: the tunnel already counts on its carrier interface.
    static func countsInterface(name: String, isLoopback: Bool) -> Bool {
        if isLoopback || name.hasPrefix("lo") { return false }
        return !(name.hasPrefix("utun") || name.hasPrefix("ipsec"))
    }
}
