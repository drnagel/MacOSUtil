import Foundation

/// Un perfil del asistente: un conjunto de ajustes y apps pensado para un tipo de uso.
/// `Catalog/profiles/<perfil>.json`. Referencia ajustes y apps por id.
public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    /// SF Symbol
    public let icon: String
    public let order: Int
    /// Ids de ajustes a activar (`finder.show-extensions`…).
    public let tweaks: [String]
    /// Ids de apps del catálogo (token del cask o `mas-<id>`).
    public let apps: [String]

    public init(id: String, title: String, description: String, icon: String, order: Int, tweaks: [String], apps: [String]) {
        self.id = id; self.title = title; self.description = description; self.icon = icon
        self.order = order; self.tweaks = tweaks; self.apps = apps
    }
}

public enum ProfileCatalog {
    public static func load(from catalogDir: URL) throws -> [Profile] {
        let dir = catalogDir.appendingPathComponent("profiles")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var profiles: [Profile] = []
        for f in files {
            do { profiles.append(try JSONDecoder().decode(Profile.self, from: Data(contentsOf: f))) }
            catch { throw ProfileError.invalid("\(f.lastPathComponent): \(error)") }
        }
        return profiles.sorted { ($0.order, $0.title) < ($1.order, $1.title) }
    }

    /// Comprueba que cada perfil solo usa ajustes y apps que existen en el catálogo.
    public static func validate(_ profiles: [Profile], tweakIDs: Set<String>, appIDs: Set<String>) -> [String] {
        var problems: [String] = []
        var ids: Set<String> = []
        for p in profiles {
            if !ids.insert(p.id).inserted { problems.append("\(p.id): perfil repetido") }
            if p.tweaks.isEmpty && p.apps.isEmpty { problems.append("\(p.id): perfil vacío") }
            for t in p.tweaks where !tweakIDs.contains(t) { problems.append("\(p.id): ajuste desconocido «\(t)»") }
            for a in p.apps where !appIDs.contains(a) { problems.append("\(p.id): app desconocida «\(a)»") }
            if Set(p.tweaks).count != p.tweaks.count { problems.append("\(p.id): ajustes repetidos") }
            if Set(p.apps).count != p.apps.count { problems.append("\(p.id): apps repetidas") }
        }
        return problems
    }
}

/// Archivo de configuración exportado (`.macosutil.json`): qué ajustes están activados y qué apps instaladas.
/// No guarda nombre de usuario, nombre del equipo ni rutas: solo ids del catálogo.
public struct SetupFile: Codable, Sendable, Equatable {
    public static let format = "macosutil-setup"
    public static let fileExtension = "macosutil.json"

    public var format: String = SetupFile.format
    public var version: Int = 1
    public var createdAt: Date
    /// Versión de macOS donde se exportó (informativa).
    public var macOS: String
    /// Perfil del que salió, si lo hay.
    public var profile: String?
    public var tweaks: [String]
    public var apps: [String]

    public init(createdAt: Date = Date(), macOS: String, profile: String?, tweaks: [String], apps: [String]) {
        // ISO 8601 guarda segundos: se redondea para que exportar → importar dé exactamente lo mismo.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.macOS = macOS; self.profile = profile
        self.tweaks = tweaks.sorted(); self.apps = apps.sorted()
    }

    public static var currentMacOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> SetupFile {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let file: SetupFile
        do { file = try dec.decode(SetupFile.self, from: data) } catch {
            throw ProfileError.invalid("No es un archivo de configuración de MacOSUtil.")
        }
        guard file.format == format else { throw ProfileError.invalid("Formato desconocido: \(file.format)") }
        guard file.version <= 1 else { throw ProfileError.invalid("Archivo de una versión más nueva de MacOSUtil (v\(file.version)).") }
        return file
    }

    /// Ids que no existen en este catálogo (p. ej. un archivo exportado con una versión más nueva).
    public func unknown(tweakIDs: Set<String>, appIDs: Set<String>) -> (tweaks: [String], apps: [String]) {
        (tweaks.filter { !tweakIDs.contains($0) }, apps.filter { !appIDs.contains($0) })
    }
}

/// La última configuración aplicada con el asistente, para «Reaplicar» tras una actualización de macOS.
/// ~/Library/Application Support/MacOSUtil/last-setup.json
public enum LastSetup {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacOSUtil/last-setup.json")
    }

    public static func load(from url: URL = defaultURL) -> SetupFile? {
        (try? Data(contentsOf: url)).flatMap { try? SetupFile.decode($0) }
    }

    public static func save(_ setup: SetupFile, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try setup.encoded().write(to: url, options: .atomic)
    }
}

public enum ProfileError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let why): why }
    }
}
