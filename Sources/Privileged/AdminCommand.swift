import Foundation

/// Las únicas operaciones que MacOSUtil ejecuta como administrador. Nunca «ejecutar un comando cualquiera»:
/// cada caso se valida antes de construir su línea de comandos.
public enum AdminCommand: Hashable, Sendable {
    /// `launchctl disable system/<label>`: el daemon no vuelve a arrancar (ni tras reiniciar).
    case daemonDisable(label: String)
    /// `launchctl bootout system/<label>`: lo detiene ahora.
    case daemonStop(label: String)
    /// `launchctl enable system/<label>`
    case daemonEnable(label: String)
    /// `launchctl bootstrap system <plist>`: lo vuelve a cargar.
    case daemonStart(plistPath: String)
    /// `pmset -a|-c|-b <ajuste> <valor>`
    case pmset(source: PowerSource, setting: String, value: Int)
    /// `mdutil -i on|off <volumen>`
    case spotlightIndexing(volume: String, enabled: Bool)
    /// `mdutil -E <volumen>`: borra el índice para que Spotlight lo reconstruya.
    case spotlightRebuild(volume: String)

    public enum PowerSource: String, Codable, Hashable, Sendable, CaseIterable {
        case all = "-a", charger = "-c", battery = "-b"
    }

    /// Ajustes de `pmset` que se permiten cambiar y su rango de valores.
    public static let pmsetAllowed: [String: ClosedRange<Int>] = [
        "displaysleep": 0...180, "sleep": 0...180, "disksleep": 0...180,
        "powernap": 0...1, "womp": 0...1, "tcpkeepalive": 0...1, "proximitywake": 0...1,
        "lowpowermode": 0...1, "autorestart": 0...1, "ttyskeepawake": 0...1, "lidwake": 0...1,
    ]

    static let launchDaemonsDir = "/Library/LaunchDaemons/"

    // MARK: Validación

    /// Comprueba que el comando solo toca lo que debe. Lanza `AdminError.rejected` con el motivo.
    public func validate() throws {
        switch self {
        case .daemonDisable(let l), .daemonStop(let l), .daemonEnable(let l):
            try Self.checkLabel(l)
        case .daemonStart(let path):
            try Self.checkDaemonPlist(path)
        case .pmset(_, let setting, let value):
            guard let range = Self.pmsetAllowed[setting] else { throw AdminError.rejected(L("Ajuste de energía no permitido: \(setting)")) }
            guard range.contains(value) else { throw AdminError.rejected(L("Valor fuera de rango para \(setting): \(value)")) }
        case .spotlightIndexing(let v, _), .spotlightRebuild(let v):
            try Self.checkVolume(v)
        }
    }

    /// Etiquetas de launchd de terceros: sin espacios ni barras, y nunca de Apple.
    static func checkLabel(_ label: String) throws {
        guard label.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$"#, options: .regularExpression) != nil else {
            throw AdminError.rejected(L("Etiqueta de servicio no válida: \(label)"))
        }
        guard !label.lowercased().hasPrefix("com.apple.") else {
            throw AdminError.rejected(L("Los servicios de Apple no se tocan: \(label)"))
        }
    }

    /// Comprobación de la ruta sin tocar el disco: directamente en /Library/LaunchDaemons, sin `..`.
    public static func isDaemonPlistPath(_ path: String) -> Bool {
        (path as NSString).standardizingPath == path && path.hasPrefix(launchDaemonsDir) && path.hasSuffix(".plist")
            && !path.dropFirst(launchDaemonsDir.count).contains("/")
    }

    /// Solo plists que estén directamente en /Library/LaunchDaemons, sin `..` ni enlaces simbólicos.
    static func checkDaemonPlist(_ path: String) throws {
        guard isDaemonPlistPath(path) else {
            throw AdminError.rejected(L("Ruta de daemon no permitida: \(path)"))
        }
        let name = (path as NSString).lastPathComponent
        guard !name.lowercased().hasPrefix("com.apple.") else { throw AdminError.rejected(L("Los servicios de Apple no se tocan: \(name)")) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard attrs?[.type] as? FileAttributeType == .typeRegular else {
            throw AdminError.rejected(L("No es un archivo normal: \(path)"))
        }
    }

    /// «/» o un volumen montado en /Volumes/<nombre>.
    static func checkVolume(_ volume: String) throws {
        if volume == "/" { return }
        let std = (volume as NSString).standardizingPath
        guard std == volume, volume.hasPrefix("/Volumes/"), !volume.dropFirst(9).isEmpty,
              !volume.dropFirst(9).contains("/") else {
            throw AdminError.rejected(L("Volumen no permitido: \(volume)"))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: volume, isDirectory: &isDir), isDir.boolValue else {
            throw AdminError.rejected(L("El volumen no está montado: \(volume)"))
        }
    }

    // MARK: Línea de comandos

    /// Programa y argumentos (rutas absolutas). Solo se llama tras `validate()`.
    public var argv: [String] {
        switch self {
        case .daemonDisable(let l): ["/bin/launchctl", "disable", "system/\(l)"]
        case .daemonStop(let l): ["/bin/launchctl", "bootout", "system/\(l)"]
        case .daemonEnable(let l): ["/bin/launchctl", "enable", "system/\(l)"]
        case .daemonStart(let p): ["/bin/launchctl", "bootstrap", "system", p]
        case .pmset(let s, let k, let v): ["/usr/bin/pmset", s.rawValue, k, String(v)]
        case .spotlightIndexing(let v, let on): ["/usr/bin/mdutil", "-i", on ? "on" : "off", v]
        case .spotlightRebuild(let v): ["/usr/bin/mdutil", "-E", v]
        }
    }

    /// Fallos que no son errores: detener algo que no estaba en marcha, cargar algo ya cargado.
    var toleratedStatuses: Set<Int32> {
        switch self {
        case .daemonStop: [3, 36, 113]      // no estaba cargado
        case .daemonStart: [5, 37]          // ya estaba cargado
        default: []
        }
    }
}

public enum AdminError: LocalizedError, Equatable {
    case rejected(String)
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .rejected(let why): L("MacOSUtil no ejecuta esto: \(why)")
        case .cancelled: L("Cancelado: no se cambió nada.")
        case .failed(let why): why
        }
    }
}
