import Foundation

/// Carga el catálogo de ajustes desde `Catalog/tweaks/*.json`.
public struct Catalog: Sendable {
    public let categories: [TweakCategory]
    public let source: URL

    public init(categories: [TweakCategory], source: URL) {
        self.categories = categories
        self.source = source
    }

    public var allTweaks: [Tweak] { categories.flatMap(\.tweaks) }

    public func tweak(_ id: String) -> Tweak? { allTweaks.first { $0.id == id } }

    public static func load(from dir: URL) throws -> Catalog {
        let tweaksDir = dir.appendingPathComponent("tweaks")
        let files = try FileManager.default.contentsOfDirectory(at: tweaksDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var cats: [TweakCategory] = []
        for f in files {
            do {
                cats.append(try JSONDecoder().decode(TweakCategory.self, from: Data(contentsOf: f)))
            } catch {
                throw CatalogError.invalidFile(f.lastPathComponent, Self.describe(error))
            }
        }
        let catalog = Catalog(categories: cats.sorted { ($0.order, $0.title) < ($1.order, $1.title) }, source: dir)
        let problems = catalog.validate()
        if !problems.isEmpty { throw CatalogError.invalidContent(problems) }
        return catalog
    }

    /// Catálogo descargado y verificado (`CatalogUpdater`).
    public static var downloadedDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacOSUtil/Catalog")
    }

    /// Versión de una carpeta de catálogo (`catalog.json`), 0 si no la tiene.
    public static func version(of dir: URL) -> Int {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("catalog.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return json["version"] as? Int ?? 0
    }

    /// Busca el catálogo: variable MACOSUTIL_CATALOG; el descargado si es más nuevo que el incluido; dentro de la
    /// app (Contents/Resources/Catalog); o subiendo desde el ejecutable hasta la raíz del repo (`swift run`, selftest).
    public static func locate() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["MACOSUTIL_CATALOG"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("Catalog")
            if fm.fileExists(atPath: downloadedDir.appendingPathComponent("tweaks").path),
               version(of: downloadedDir) > version(of: bundled) {
                candidates.append(downloadedDir)
            }
            candidates.append(bundled)
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(dir.appendingPathComponent("Catalog"))
            dir.deleteLastPathComponent()
        }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Catalog"))
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("tweaks").path) }
    }

    /// Reglas que el JSON no puede expresar: ids únicos, una clave no puede pertenecer a dos ajustes, etc.
    public func validate() -> [String] {
        var problems: [String] = []
        var ids: Set<String> = []
        var slots: [String: String] = [:]
        for c in categories {
            if c.tweaks.isEmpty && c.links.isEmpty { problems.append(L("\(c.id): categoría vacía")) }
            for l in c.links {
                if !ids.insert(l.id).inserted { problems.append(L("\(l.id): id repetido")) }
                if !l.id.hasPrefix(c.id + ".") { problems.append(L("\(l.id): el id debe empezar por «\(c.id).»")) }
                if l.settingsURL == nil { problems.append(L("\(l.id): solo se permiten URLs \(SettingsPaneLink.scheme):")) }
            }
            for t in c.tweaks {
                if !ids.insert(t.id).inserted { problems.append(L("\(t.id): id repetido")) }
                if !t.id.hasPrefix(c.id + ".") { problems.append(L("\(t.id): el id debe empezar por «\(c.id).»")) }
                if t.actions.isEmpty { problems.append(L("\(t.id): sin acciones")) }
                if let v = t.tested, (Int(v) ?? 0) < 15 { problems.append(L("\(t.id): «tested» debe ser una versión mayor de macOS (15 o más)")) }
                for case .defaults(let a) in t.actions {
                    if let other = slots[a.slot], other != t.id {
                        problems.append(L("\(t.id): \(a.slot) ya lo usa \(other)"))
                    }
                    slots[a.slot] = t.id
                }
            }
        }
        return problems
    }

    private static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        switch e {
        case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c):
            let path = c.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            if case .keyNotFound(let k, _) = e { return L("\(path): falta «\(k.stringValue)»") }
            return "\(path): \(c.debugDescription)"
        @unknown default: return e.localizedDescription
        }
    }
}

public enum CatalogError: LocalizedError {
    case notFound
    case invalidFile(String, String)
    case invalidContent([String])

    public var errorDescription: String? {
        switch self {
        case .notFound: L("No se encontró la carpeta Catalog.")
        case .invalidFile(let f, let why): "\(f): \(why)"
        case .invalidContent(let p): L("Catálogo inválido:") + "\n" + p.joined(separator: "\n")
        }
    }
}
