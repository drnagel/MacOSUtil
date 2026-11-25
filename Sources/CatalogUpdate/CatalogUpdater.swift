import Foundation
import TweakEngine

/// Descarga el catálogo oficial firmado y lo instala en
/// ~/Library/Application Support/MacOSUtil/Catalog si es válido y más nuevo que el que se usa ahora.
/// Solo se conecta cuando se pide (menú «Buscar actualizaciones del catálogo»).
public enum CatalogUpdater {
    public enum Outcome: Equatable, Sendable {
        case updated(version: Int)
        case upToDate(version: Int)
    }

    /// Versión del catálogo que la app usa ahora.
    public static var currentVersion: Int {
        Catalog.locate().flatMap { try? CatalogManifest.read(from: $0).version } ?? 0
    }

    public static func check(url: URL = CatalogBundle.remoteURL, publicKey: String = CatalogBundle.publicKey) async throws -> Outcome {
        let session = URLSession(configuration: .ephemeral)
        let data = try await download(url, session)
        let sig = try await download(url.appendingPathExtension("sig"), session)
        let bundle = try CatalogBundle.verify(data, signature: String(decoding: sig, as: UTF8.self), publicKey: publicKey)
        let current = currentVersion
        guard bundle.version > current else { return .upToDate(version: current) }
        try install(bundle)
        return .updated(version: bundle.version)
    }

    /// Escribe el catálogo en una carpeta temporal, lo valida y solo entonces sustituye al descargado anterior.
    public static func install(_ bundle: CatalogBundle, into target: URL = Catalog.downloadedDir) throws {
        let fm = FileManager.default
        let staging = target.deletingLastPathComponent().appendingPathComponent("Catalog-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try bundle.write(to: staging)
            let problems = CatalogBundle.validate(dir: staging)
            guard problems.isEmpty else {
                throw CatalogUpdateError.invalid(L("El catálogo descargado no es válido:") + "\n" + problems.prefix(10).joined(separator: "\n"))
            }
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: target)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    static func download(_ url: URL, _ session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("MacOSUtil", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch {
            throw CatalogUpdateError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CatalogUpdateError.network("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard data.count < 5_000_000 else { throw CatalogUpdateError.invalid(L("El catálogo descargado es demasiado grande.")) }
        return data
    }
}
