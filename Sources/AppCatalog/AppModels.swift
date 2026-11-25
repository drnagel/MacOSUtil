import Foundation

/// `Catalog/apps.json`: categorías de apps recomendadas.
public struct AppCatalogFile: Codable, Sendable {
    public let categories: [AppCategory]
}

public struct AppCategory: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// Nombre de SF Symbol.
    public let icon: String
    public let apps: [AppEntry]
}

/// Una app del catálogo. Se instala con Homebrew (`cask`) o se abre su página en la App Store (`appStore`).
public struct AppEntry: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let description: String
    /// Token del cask de Homebrew (p. ej. "rectangle").
    public let cask: String?
    /// Id numérico de la Mac App Store (p. ej. "937984704").
    public let appStore: String?
    /// Nombre del .app en /Applications. Solo hace falta para apps de la App Store;
    /// para casks se obtiene de Homebrew.
    public let appName: String?
    public let homepage: String?

    public var id: String { cask ?? "mas-\(appStore ?? name)" }

    public enum Source: Hashable, Sendable {
        case cask(String)
        case appStore(String)
    }

    public var source: Source? {
        if let cask { return .cask(cask) }
        if let appStore { return .appStore(appStore) }
        return nil
    }

    public var appStoreURL: URL? {
        appStore.flatMap { URL(string: "macappstore://apps.apple.com/app/id\($0)") }
    }
}

/// Estado de una app en este Mac.
public enum AppStatus: Equatable, Sendable {
    case notInstalled
    /// Instalada y gestionada por Homebrew.
    case brew(version: String, outdated: Bool)
    /// La app existe en /Applications pero no la instaló Homebrew (a mano o desde la App Store).
    case manual(path: String)
    /// Homebrew no conoce el cask (renombrado o eliminado).
    case unavailable
    /// Todavía no se ha consultado.
    case unknown

    public var isInstalled: Bool {
        switch self {
        case .brew, .manual: true
        default: false
        }
    }
}

/// Lo que Homebrew dice de un cask (`brew info --json=v2 --cask`).
public struct CaskInfo: Sendable, Equatable {
    public let token: String
    public let version: String
    /// Versión instalada por Homebrew, o `nil`.
    public let installed: String?
    public let outdated: Bool
    /// Rutas donde el cask deja sus .app (para detectar instalaciones manuales).
    public let appPaths: [String]
    /// Instala un .pkg o un instalador: necesita contraseña de administrador.
    public let needsAdmin: Bool
}

public enum AppCatalogError: LocalizedError {
    case notFound
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "No se encontró Catalog/apps.json."
        case .invalid(let why): "apps.json: \(why)"
        }
    }
}

public extension AppCatalogFile {
    /// Carga `apps.json` desde la carpeta del catálogo (la misma que encuentra `Catalog.locate()`).
    static func load(from catalogDir: URL) throws -> AppCatalogFile {
        let url = catalogDir.appendingPathComponent("apps.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw AppCatalogError.notFound }
        let file: AppCatalogFile
        do { file = try JSONDecoder().decode(AppCatalogFile.self, from: Data(contentsOf: url)) } catch {
            throw AppCatalogError.invalid(String(describing: error))
        }
        let problems = file.validate()
        if !problems.isEmpty { throw AppCatalogError.invalid(problems.joined(separator: "\n")) }
        return file
    }

    var allApps: [AppEntry] { categories.flatMap(\.apps) }

    func validate() -> [String] {
        var problems: [String] = []
        var ids: Set<String> = []
        for c in categories {
            if c.apps.isEmpty { problems.append("\(c.id): categoría vacía") }
            for a in c.apps {
                if a.source == nil { problems.append("\(a.name): falta «cask» o «appStore»") }
                if a.cask != nil && a.appStore != nil { problems.append("\(a.name): usa solo «cask» o «appStore»") }
                if let t = a.cask, !Homebrew.isValidToken(t) { problems.append("\(a.name): token de cask no válido «\(t)»") }
                if let s = a.appStore, Int(s) == nil { problems.append("\(a.name): id de App Store no numérico") }
                if a.appStore != nil && a.appName == nil { problems.append("\(a.name): las apps de App Store necesitan «appName»") }
                if !ids.insert(a.id).inserted { problems.append("\(a.id): repetida") }
            }
        }
        return problems
    }
}
