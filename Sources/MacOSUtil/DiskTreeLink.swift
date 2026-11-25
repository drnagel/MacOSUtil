import AppKit

/// Enlace con DiskTree (~/ClaudeCode/DiskTreeMac), que se encarga de todo lo relacionado con el espacio en disco.
/// Usa los enlaces `disktree://` para abrirla en una pestaña o carpeta concreta.
/// Con una DiskTree más antigua, sin enlaces, solo abre la app.
enum DiskTreeLink {
    static let bundleID = "local.disktree.DiskTree"
    static let scheme = "disktree"

    /// Lugares de DiskTree a los que se puede saltar. Los nombres de pestaña son los de `disktree://open?tab=`.
    enum Destination: Hashable {
        case tab(String)
        case folder(String)
        case scan

        var url: URL? {
            var c = URLComponents()
            c.scheme = DiskTreeLink.scheme
            switch self {
            case .tab(let t): c.host = "open"; c.queryItems = [URLQueryItem(name: "tab", value: t)]
            case .folder(let p): c.host = "folder"; c.queryItems = [URLQueryItem(name: "path", value: p)]
            case .scan: c.host = "scan"
            }
            return c.url
        }
    }

    static var appURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        let candidates = [
            "/Applications/DiskTree.app",
            NSHomeDirectory() + "/Applications/DiskTree.app",
            NSHomeDirectory() + "/ClaudeCode/DiskTreeMac/build/DiskTree.app",
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// `true` si la DiskTree instalada declara el esquema `disktree://` en su Info.plist.
    static func supportsLinks(_ app: URL? = appURL) -> Bool {
        guard let app, let info = Bundle(url: app)?.infoDictionary,
              let types = info["CFBundleURLTypes"] as? [[String: Any]] else { return false }
        return types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains(scheme) ?? false }
    }

    static func open() {
        guard let url = appURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    /// Abre DiskTree en `destination`. Si la versión instalada no entiende enlaces, solo la abre.
    static func open(_ destination: Destination) {
        guard let app = appURL else { return }
        guard supportsLinks(app), let link = destination.url else { return open() }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([link], withApplicationAt: app, configuration: config)
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
