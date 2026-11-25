import Foundation

/// Un ajuste de energía de `pmset` que MacOSUtil sabe explicar.
public struct PowerSetting: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// Interruptor: 1 = activado.
        case toggle
        /// Minutos; 0 = nunca.
        case minutes([Int])
    }

    public var id: String { key }
    public let key: String
    public let title: String
    public let description: String
    public let kind: Kind
    /// Aviso de lo que se pierde al cambiarlo, si lo hay.
    public let caveat: String?
}

public enum Power {
    public typealias Source = AdminCommand.PowerSource

    /// Ajustes que se muestran, en orden. Solo aparecen los que `pmset -g custom` lista en este Mac.
    public static let settings: [PowerSetting] = [
        .init(key: "displaysleep", title: L("Apagar la pantalla tras"), description: L("Minutos sin actividad hasta apagar la pantalla."),
              kind: .minutes([0, 2, 5, 10, 15, 20, 30, 60]), caveat: nil),
        .init(key: "sleep", title: L("Reposo del Mac tras"), description: L("Minutos sin actividad hasta dormir el Mac."),
              kind: .minutes([0, 5, 10, 15, 20, 30, 60, 120]), caveat: L("«Nunca» evita cortes en descargas largas pero gasta más energía.")),
        .init(key: "disksleep", title: L("Reposo de los discos tras"), description: L("Minutos hasta parar los discos mecánicos. No afecta a los SSD."),
              kind: .minutes([0, 5, 10, 20, 30, 60]), caveat: nil),
        .init(key: "lowpowermode", title: L("Modo de bajo consumo"), description: L("Reduce el rendimiento para gastar menos energía y hacer menos ruido."),
              kind: .toggle, caveat: nil),
        .init(key: "powernap", title: L("Power Nap"), description: L("Durante el reposo despierta de vez en cuando para el correo, iCloud y las copias de Time Machine."),
              kind: .toggle, caveat: L("Al desactivarlo, el correo y las copias se ponen al día al despertar.")),
        .init(key: "tcpkeepalive", title: L("Mantener la red durante el reposo"), description: L("Mantiene la conexión para Buscar mi Mac y el acceso remoto."),
              kind: .toggle, caveat: L("Al desactivarlo, Buscar mi Mac no localiza el Mac mientras duerme.")),
        .init(key: "womp", title: L("Despertar por acceso a la red"), description: L("Permite despertar el Mac desde la red (compartir archivos, pantalla)."),
              kind: .toggle, caveat: nil),
        .init(key: "proximitywake", title: L("Despertar con dispositivos cercanos"), description: L("Despierta al acercar un iPhone o Apple Watch con tu cuenta."),
              kind: .toggle, caveat: nil),
        .init(key: "lidwake", title: L("Despertar al abrir la tapa"), description: L("Solo en portátiles."),
              kind: .toggle, caveat: nil),
        .init(key: "autorestart", title: L("Arrancar tras un corte de luz"), description: L("Enciende el Mac solo cuando vuelve la corriente."),
              kind: .toggle, caveat: nil),
        .init(key: "ttyskeepawake", title: L("No dormir con sesiones remotas"), description: L("Evita el reposo mientras hay una sesión de terminal remota (ssh) activa."),
              kind: .toggle, caveat: nil),
    ]

    public static func setting(_ key: String) -> PowerSetting? { settings.first { $0.key == key } }

    /// Valores actuales por fuente de energía (`pmset -g custom`, no necesita contraseña).
    public static func read() -> [Source: [String: Int]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "custom"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// «Battery Power:» → batería, «AC Power:» → corriente. Cada línea: `clave   valor`.
    public static func parse(_ text: String) -> [Source: [String: Int]] {
        var result: [Source: [String: Int]] = [:]
        var current: Source?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") {
                current = line.hasPrefix("Battery") ? .battery : (line.hasPrefix("AC") ? .charger : nil)
                continue
            }
            guard let src = current else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let v = Int(parts.last!) else { continue }
            let key = parts.dropLast().joined(separator: " ")
            result[src, default: [:]][key] = v
        }
        return result
    }
}

/// Valores de energía originales (antes de MacOSUtil), para «Restaurar».
/// ~/Library/Application Support/MacOSUtil/power.json   { "-c:powernap": 1, … }
public final class PowerStore: @unchecked Sendable {
    public let url: URL
    private var originals: [String: Int]
    private let lock = NSLock()

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacOSUtil/power.json")
    }

    public init(url: URL = PowerStore.defaultURL) {
        self.url = url
        originals = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
    }

    static func key(_ s: Power.Source, _ setting: String) -> String { "\(s.rawValue):\(setting)" }

    public var isEmpty: Bool { lock.withLock { originals.isEmpty } }
    public var count: Int { lock.withLock { originals.count } }

    public func original(_ s: Power.Source, _ setting: String) -> Int? { lock.withLock { originals[Self.key(s, setting)] } }

    /// Guarda el valor original solo la primera vez que se cambia.
    public func remember(_ s: Power.Source, _ setting: String, value: Int) throws {
        try mutate { if $0[Self.key(s, setting)] == nil { $0[Self.key(s, setting)] = value } }
    }

    public func forget(_ s: Power.Source, _ setting: String) throws { try mutate { $0[Self.key(s, setting)] = nil } }

    /// Comandos para volver a los valores originales.
    public func restoreCommands() -> [AdminCommand] {
        lock.withLock {
            originals.sorted { $0.key < $1.key }.compactMap { k, v in
                let parts = k.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let s = Power.Source(rawValue: parts[0]) else { return nil }
                return .pmset(source: s, setting: parts[1], value: v)
            }
        }
    }

    public func clear() throws { try mutate { $0 = [:] } }

    private func mutate(_ change: (inout [String: Int]) -> Void) throws {
        try lock.withLock {
            change(&originals)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(originals).write(to: url, options: .atomic)
        }
    }
}

/// Indexación de Spotlight por volumen (`mdutil -s` se lee sin contraseña).
private final class Statuses: @unchecked Sendable {
    private var values: [(indexing: Bool?, detail: String)]
    private let lock = NSLock()
    init(count: Int) { values = Array(repeating: (nil, ""), count: count) }
    func set(_ i: Int, _ v: (indexing: Bool?, detail: String)) { lock.withLock { values[i] = v } }
    func get(_ i: Int) -> (indexing: Bool?, detail: String) { lock.withLock { values[i] } }
}

public enum Spotlight {
    public struct Volume: Identifiable, Hashable, Sendable {
        public var id: String { path }
        public let name: String
        public let path: String
        /// nil si no se pudo saber (p. ej. volumen sin soporte de índice).
        public let indexing: Bool?
        public let detail: String
    }

    public static func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var candidates: [(name: String, path: String)] = []
        for u in urls {
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard v?.volumeIsBrowsable ?? true, v?.volumeIsLocal ?? true else { continue }
            let path = u.path
            guard path == "/" || (path.hasPrefix("/Volumes/") && !path.dropFirst(9).contains("/")) else { continue }
            candidates.append((v?.volumeName ?? (path as NSString).lastPathComponent, path))
        }
        // En paralelo: un disco que no responde no retrasa a los demás.
        let statuses = Statuses(count: candidates.count)
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in statuses.set(i, status(candidates[i].path)) }
        let result = candidates.enumerated().map { i, c in
            let s = statuses.get(i)
            return Volume(name: c.name, path: c.path, indexing: s.indexing, detail: s.detail)
        }
        return result
    }

    /// `mdutil -s` puede quedarse colgado con discos externos dormidos o que no responden: se corta a los 4 s.
    public static func status(_ path: String, timeout: TimeInterval = 4) -> (indexing: Bool?, detail: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        p.arguments = ["-s", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return (nil, error.localizedDescription) }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return (nil, L("El disco no responde (¿está dormido o desconectándose?)"))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return parseStatus(String(decoding: data, as: UTF8.self))
    }

    public static func parseStatus(_ text: String) -> (indexing: Bool?, detail: String) {
        let t = text.lowercased()
        if t.contains("indexing enabled") { return (true, L("Indexando")) }
        if t.contains("indexing disabled") { return (false, L("Indexación desactivada")) }
        if t.contains("indexing and searching disabled") { return (false, L("Indexación y búsqueda desactivadas")) }
        let last = text.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return (nil, last.isEmpty ? L("Estado desconocido") : last)
    }
}
