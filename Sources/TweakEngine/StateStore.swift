import Foundation

/// Guarda el valor que tenía cada clave antes de que MacOSUtil la tocara, para poder deshacer.
/// Archivo: ~/Library/Application Support/MacOSUtil/state.json
public final class StateStore: @unchecked Sendable {
    public struct Record: Codable, Sendable {
        public var appliedAt: Date
        /// Valor que tenía cada clave antes del primer cambio. Incluye dominio y clave para poder
        /// restaurar aunque el ajuste desaparezca del catálogo.
        public var originals: [Original]
    }

    public struct Original: Codable, Sendable {
        public let domain: String
        public let key: String
        public let currentHost: Bool
        public let stored: Preferences.Stored

        var slot: String { "\(currentHost ? "currentHost:" : "")\(domain):\(key)" }
    }

    private struct File: Codable {
        var version = 1
        var applied: [String: Record] = [:]
    }

    public let url: URL
    private var file: File
    private let lock = NSLock()

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacOSUtil/state.json")
    }

    public init(url: URL = StateStore.defaultURL) {
        self.url = url
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        file = (try? Data(contentsOf: url)).flatMap { try? dec.decode(File.self, from: $0) } ?? File()
    }

    public func record(for id: String) -> Record? { lock.withLock { file.applied[id] } }

    public var appliedIDs: [String] { lock.withLock { Array(file.applied.keys).sorted() } }

    /// Registra los originales solo la primera vez: si se aplica dos veces, el original sigue siendo el de antes de la app.
    func remember(_ id: String, originals: [Original]) throws {
        try lock.withLock {
            if var r = file.applied[id] {
                let known = Set(r.originals.map(\.slot))
                r.originals += originals.filter { !known.contains($0.slot) }
                file.applied[id] = r
            } else {
                file.applied[id] = Record(appliedAt: Date(), originals: originals)
            }
            try save()
        }
    }

    func forget(_ id: String) throws {
        try lock.withLock {
            file.applied[id] = nil
            try save()
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(file).write(to: url, options: .atomic)
    }
}
