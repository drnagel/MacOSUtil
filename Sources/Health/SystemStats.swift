import Foundation
import Darwin

/// Una lectura instantánea de CPU, memoria y disco (para el widget de la barra de menús).
/// Todo se lee con llamadas al sistema, sin lanzar procesos ni pedir permisos.
public struct SystemSnapshot: Sendable, Equatable {
    /// Uso total de CPU entre la lectura anterior y esta (0…1). nil en la primera lectura.
    public var cpu: Double?
    public var memoryUsed: Int64
    public var memoryTotal: Int64
    public var pressure: MemoryPressure
    public var swapUsed: Int64
    public var diskFree: Int64
    public var diskTotal: Int64
    public var uptime: TimeInterval

    public var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    public var diskUsedFraction: Double { diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) : 0 }
}

/// Presión de memoria tal como la calcula macOS (`kern.memorystatus_vm_pressure_level`).
public enum MemoryPressure: Int, Sendable, Comparable {
    case normal = 1, warning = 2, critical = 4

    public static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rawValue < b.rawValue }
}

/// Lee el estado del sistema. Guarda los contadores de CPU de la lectura anterior para calcular el uso.
public final class SystemSampler: @unchecked Sendable {
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private let lock = NSLock()

    public init() {}

    public func sample() -> SystemSnapshot {
        let cpu: Double? = lock.withLock {
            guard let now = Self.cpuTicks() else { return nil }
            defer { lastTicks = now }
            guard let last = lastTicks, now.total > last.total else { return nil }
            return Double(now.busy - last.busy) / Double(now.total - last.total)
        }
        let mem = Self.memory()
        let disk = Self.disk()
        return SystemSnapshot(cpu: cpu, memoryUsed: mem.used, memoryTotal: Int64(ProcessInfo.processInfo.physicalMemory),
                              pressure: Self.pressure(), swapUsed: Self.swap(),
                              diskFree: disk.free, diskTotal: disk.total, uptime: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: Lecturas

    /// Contadores acumulados de todos los núcleos: (ocupado, total).
    static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// Memoria en uso como la cuenta Monitor de Actividad: activa (menos la que se puede liberar) + fija + comprimida.
    static func memory() -> (used: Int64, total: Int64) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        guard r == KERN_SUCCESS else { return (0, total) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = Int64(pageSize)
        let appMemory = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let used = (appMemory + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        return (max(0, min(used, total)), total)
    }

    static func pressure() -> MemoryPressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    static func swap() -> Int64 {
        var xsu = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsu, &size, nil, 0) == 0 else { return 0 }
        return Int64(xsu.xsu_used)
    }

    static func disk() -> (free: Int64, total: Int64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
        return (v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeTotalCapacity ?? 0))
    }
}
