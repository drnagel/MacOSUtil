import Foundation
import CryptoKit
import TweakEngine
import AppCatalog
import Profiles

/// El catálogo empaquetado en un solo archivo firmado (`dist/catalog.json` + `dist/catalog.json.sig`).
///
/// - Se genera con `MacOSUtil --catalog bundle` a partir de la carpeta `Catalog/` y se firma con Ed25519.
///   La clave privada solo la tiene quien publica (`~/.config/macosutil/catalog-signing.key`).
/// - La app lleva la clave pública y solo acepta catálogos firmados con ella, de una versión más nueva que la
///   suya y que pasen la misma validación que el catálogo incluido.
/// - Solo contiene JSON declarativo: no hay forma de que un catálogo ejecute comandos.
public struct CatalogBundle: Codable, Sendable, Equatable {
    public static let format = "macosutil-catalog"

    public var format: String = CatalogBundle.format
    /// Versión del catálogo (`Catalog/catalog.json`). Solo se instala uno más nuevo que el actual.
    public var version: Int
    public var createdAt: Date
    /// Ruta relativa → contenido del archivo JSON.
    public var files: [String: String]

    /// Clave pública con la que se firma el catálogo oficial (Ed25519, base64).
    public static let publicKey = "MsfJ/7l4LjECVqLDcmotkiJFLkKzB4BlD/eTbtX0MWQ="

    /// Dónde se publica el catálogo oficial.
    public static let remoteURL = URL(string: "https://raw.githubusercontent.com/drnagel/MacOSUtil/main/dist/catalog.json")!

    /// Solo estos nombres: impide escribir fuera de la carpeta del catálogo.
    static let allowedPath = try! NSRegularExpression(pattern: #"^(apps\.json|catalog\.json|tweaks/[a-z0-9-]+\.json|profiles/[a-z0-9-]+\.json)$"#)

    public static func isAllowed(_ path: String) -> Bool {
        allowedPath.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil
    }

    // MARK: Crear

    /// Empaqueta una carpeta de catálogo.
    public static func make(from dir: URL, createdAt: Date = Date()) throws -> CatalogBundle {
        let version = try CatalogManifest.read(from: dir).version
        var files: [String: String] = [:]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw CatalogUpdateError.invalid(L("No se pudo leer \(dir.path)"))
        }
        for case let url as URL in walker where url.pathExtension == "json" {
            let rel = String(url.path.dropFirst(dir.path.count + 1))
            guard isAllowed(rel) else { throw CatalogUpdateError.invalid(L("Archivo no permitido en el catálogo: \(rel)")) }
            files[rel] = try String(contentsOf: url, encoding: .utf8)
        }
        let rounded = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        return CatalogBundle(version: version, createdAt: rounded, files: files)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    // MARK: Firmar y verificar

    public static func sign(_ data: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        try privateKey.signature(for: data).base64EncodedString()
    }

    /// Comprueba la firma y devuelve el catálogo si es válido.
    public static func verify(_ data: Data, signature: String, publicKey: String = CatalogBundle.publicKey) throws -> CatalogBundle {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw CatalogUpdateError.invalid(L("La clave pública del catálogo no es válida."))
        }
        guard let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(sig, for: data) else {
            throw CatalogUpdateError.badSignature
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let bundle = try? dec.decode(CatalogBundle.self, from: data), bundle.format == format else {
            throw CatalogUpdateError.invalid(L("No es un catálogo de MacOSUtil."))
        }
        guard bundle.files.keys.allSatisfy(isAllowed) else {
            throw CatalogUpdateError.invalid(L("El catálogo contiene rutas no permitidas."))
        }
        return bundle
    }

    // MARK: Escribir y validar

    /// Escribe los archivos en `dir` (que no debe existir).
    public func write(to dir: URL) throws {
        let fm = FileManager.default
        for (rel, text) in files {
            let url = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// La misma validación que el catálogo incluido en la app, más que cada texto esté en todos los idiomas.
    public static func validate(dir: URL) -> [String] {
        var problems: [String] = []
        var tweakIDs: Set<String> = []
        var appIDs: Set<String> = []
        do {
            let c = try Catalog.load(from: dir)
            problems += c.validate()
            tweakIDs = Set(c.categories.flatMap { $0.tweaks.map(\.id) })
        } catch { problems.append(error.localizedDescription) }
        do {
            let a = try AppCatalogFile.load(from: dir)
            problems += a.validate()
            appIDs = Set(a.allApps.map(\.id))
        } catch { problems.append(error.localizedDescription) }
        do {
            let p = try ProfileCatalog.load(from: dir)
            problems += ProfileCatalog.validate(p, tweakIDs: tweakIDs, appIDs: appIDs)
        } catch { problems.append(error.localizedDescription) }
        do { _ = try CatalogManifest.read(from: dir) } catch { problems.append(error.localizedDescription) }
        problems += TranslationCheck.problems(in: dir)
        return problems
    }
}

/// `Catalog/catalog.json`: versión del catálogo.
public struct CatalogManifest: Codable, Sendable {
    public var version: Int

    public static func read(from dir: URL) throws -> CatalogManifest {
        let url = dir.appendingPathComponent("catalog.json")
        guard let data = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(CatalogManifest.self, from: data), m.version > 0 else {
            throw CatalogUpdateError.invalid(L("Falta catalog.json con la versión del catálogo."))
        }
        return m
    }
}

/// Cada `title` y `description` del catálogo debe estar en todos los idiomas de la app.
enum TranslationCheck {
    static let required = ["en", "es"]

    static func problems(in dir: URL) -> [String] {
        var problems: [String] = []
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        for case let url as URL in walker where url.pathExtension == "json" && url.lastPathComponent != "catalog.json" {
            let rel = String(url.path.dropFirst(dir.path.count + 1))
            guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            walk(json, path: rel, into: &problems)
        }
        return problems
    }

    static func walk(_ node: Any, path: String, into problems: inout [String]) {
        if let dict = node as? [String: Any] {
            let id = dict["id"] as? String ?? dict["cask"] as? String ?? dict["name"] as? String
            for key in ["title", "description"] {
                guard let value = dict[key] else { continue }
                let label = "\(path) · \(id ?? "?") · \(key)"
                if value is String {
                    problems.append(L("\(label): falta traducir (es un texto simple, debe ser { \"en\": …, \"es\": … })"))
                } else if let t = value as? [String: String] {
                    for lang in required where (t[lang] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                        problems.append(L("\(label): falta el idioma «\(lang)»"))
                    }
                }
            }
            for (k, v) in dict where k != "title" && k != "description" { walk(v, path: path, into: &problems) }
        } else if let list = node as? [Any] {
            for v in list { walk(v, path: path, into: &problems) }
        }
    }
}

public enum CatalogUpdateError: LocalizedError, Equatable {
    case invalid(String)
    case badSignature
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let why): why
        case .badSignature: L("La firma del catálogo no es válida: no se instala.")
        case .network(let why): L("No se pudo descargar el catálogo: \(why)")
        }
    }
}
