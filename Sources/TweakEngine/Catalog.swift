import Foundation

/// Carga el catálogo de ajustes desde `Catalog/tweaks/*.json`.
public struct Catalog: Sendable {
    public let categories: [TweakCategory]
    public let source: URL

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

    /// Busca el catálogo: variable MACOSUTIL_CATALOG, dentro de la app (Contents/Resources/Catalog)
    /// o subiendo desde el ejecutable hasta la raíz del repo (para `swift run` y el selftest).
    public static func locate() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["MACOSUTIL_CATALOG"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("Catalog")) }
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
            if c.tweaks.isEmpty { problems.append("\(c.id): categoría vacía") }
            for t in c.tweaks {
                if !ids.insert(t.id).inserted { problems.append("\(t.id): id repetido") }
                if !t.id.hasPrefix(c.id + ".") { problems.append("\(t.id): el id debe empezar por «\(c.id).»") }
                if t.actions.isEmpty { problems.append("\(t.id): sin acciones") }
                for case .defaults(let a) in t.actions {
                    if let other = slots[a.slot], other != t.id {
                        problems.append("\(t.id): \(a.slot) ya lo usa \(other)")
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
            if case .keyNotFound(let k, _) = e { return "\(path): falta «\(k.stringValue)»" }
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
        case .notFound: "No se encontró la carpeta Catalog."
        case .invalidFile(let f, let why): "\(f): \(why)"
        case .invalidContent(let p): "Catálogo inválido:\n" + p.joined(separator: "\n")
        }
    }
}
