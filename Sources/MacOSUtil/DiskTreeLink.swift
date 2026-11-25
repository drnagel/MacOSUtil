import AppKit

/// Enlace con DiskTree (~/ClaudeCode/DiskTreeMac), que se encarga de todo lo relacionado con el espacio en disco.
/// Fase 0: abrir la app. Más adelante: esquema de URL para abrir una pestaña o carpeta concreta y,
/// en la Fase 3, el motor compartido `DiskTreeCore`.
enum DiskTreeLink {
    static let bundleID = "local.disktree.DiskTree"

    static var appURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        let candidates = [
            "/Applications/DiskTree.app",
            NSHomeDirectory() + "/Applications/DiskTree.app",
            NSHomeDirectory() + "/ClaudeCode/DiskTreeMac/build/DiskTree.app",
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func open() {
        guard let url = appURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}

/// Espacio del volumen de arranque.
struct VolumeInfo {
    let total: Int64
    let available: Int64

    static func current() -> VolumeInfo {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
        return VolumeInfo(total: Int64(v?.volumeTotalCapacity ?? 0),
                          available: v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    var usedFraction: Double { total > 0 ? Double(total - available) / Double(total) : 0 }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
