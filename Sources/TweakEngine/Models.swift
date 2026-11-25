import Foundation

/// Un archivo del catálogo: una categoría con sus ajustes (`Catalog/tweaks/<categoria>.json`).
public struct TweakCategory: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// Nombre de SF Symbol para la barra lateral.
    public let icon: String
    public let order: Int
    public var tweaks: [Tweak]
    /// Opciones que macOS no deja cambiar por terminal: se abre el panel exacto de Ajustes del Sistema.
    public var links: [SettingsPaneLink]

    enum CodingKeys: String, CodingKey { case id, title, icon, order, tweaks, links }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        icon = try c.decode(String.self, forKey: .icon)
        order = try c.decode(Int.self, forKey: .order)
        tweaks = try c.decodeIfPresent([Tweak].self, forKey: .tweaks) ?? []
        links = try c.decodeIfPresent([SettingsPaneLink].self, forKey: .links) ?? []
    }
}

/// Enlace a un panel de Ajustes del Sistema (`x-apple.systempreferences:<panel>?<ancla>`).
public struct SettingsPaneLink: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let url: String

    public static let scheme = "x-apple.systempreferences"

    /// Solo se aceptan URLs de Ajustes del Sistema: el catálogo no puede abrir nada más.
    public var settingsURL: URL? {
        guard url.hasPrefix(Self.scheme + ":"), let u = URL(string: url) else { return nil }
        return u
    }
}

public enum Risk: String, Codable, Sendable, Comparable {
    case low, medium, high

    public var title: String {
        switch self {
        case .low: "Bajo"
        case .medium: "Medio"
        case .high: "Alto"
        }
    }

    private var rank: Int { switch self { case .low: 0; case .medium: 1; case .high: 2 } }
    public static func < (a: Risk, b: Risk) -> Bool { a.rank < b.rank }
}

/// Rango de versiones de macOS donde el ajuste se ha comprobado que funciona.
public struct MacOSRange: Codable, Hashable, Sendable {
    public let min: String?
    public let max: String?

    public func contains(_ v: OperatingSystemVersion) -> Bool {
        if let min, Self.compare(v, min) < 0 { return false }
        if let max, Self.compare(v, max) > 0 { return false }
        return true
    }

    /// Compara una versión con "15", "15.2" o "15.2.1". Si `bound` solo trae mayor, compara el mayor.
    static func compare(_ v: OperatingSystemVersion, _ bound: String) -> Int {
        let parts = bound.split(separator: ".").compactMap { Int($0) }
        let mine = [v.majorVersion, v.minorVersion, v.patchVersion]
        for (i, p) in parts.enumerated() where i < 3 {
            if mine[i] != p { return mine[i] < p ? -1 : 1 }
        }
        return 0
    }
}

/// Un ajuste del sistema. Está "activado" cuando todas sus acciones coinciden con el valor deseado.
public struct Tweak: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let risk: Risk
    /// Necesita privilegios de administrador (helper; Fase 2). En Fase 0 todos son `false`.
    public let admin: Bool
    public let macos: MacOSRange?
    public let actions: [TweakAction]
    /// Procesos a reiniciar (`killall`) tras aplicar o revertir: "Finder", "Dock", "SystemUIServer"…
    public let restart: [String]
    /// El cambio solo se nota del todo tras cerrar sesión o reabrir las apps.
    public let logout: Bool

    enum CodingKeys: String, CodingKey { case id, title, description, risk, admin, macos, actions, restart, logout }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decode(String.self, forKey: .description)
        risk = try c.decodeIfPresent(Risk.self, forKey: .risk) ?? .low
        admin = try c.decodeIfPresent(Bool.self, forKey: .admin) ?? false
        macos = try c.decodeIfPresent(MacOSRange.self, forKey: .macos)
        actions = try c.decode([TweakAction].self, forKey: .actions)
        restart = try c.decodeIfPresent([String].self, forKey: .restart) ?? []
        logout = try c.decodeIfPresent(Bool.self, forKey: .logout) ?? false
    }

    public init(id: String, title: String, description: String, risk: Risk = .low, admin: Bool = false,
                macos: MacOSRange? = nil, actions: [TweakAction], restart: [String] = [], logout: Bool = false) {
        self.id = id; self.title = title; self.description = description; self.risk = risk; self.admin = admin
        self.macos = macos; self.actions = actions; self.restart = restart; self.logout = logout
    }

    public var isCompatible: Bool { macos?.contains(ProcessInfo.processInfo.operatingSystemVersion) ?? true }
}

/// Acción atómica. Lista cerrada de tipos: el catálogo nunca ejecuta comandos arbitrarios.
/// Fase 0 implementa `defaults`; `pmset`, `launchctl`, `mdutil` y `open-settings-pane` llegan en fases siguientes.
public enum TweakAction: Codable, Hashable, Sendable {
    case defaults(DefaultsAction)

    enum CodingKeys: String, CodingKey { case type }

    public init(from d: Decoder) throws {
        let type = try d.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .type)
        switch type {
        case "defaults": self = .defaults(try DefaultsAction(from: d))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath,
                                                    debugDescription: "Tipo de acción no soportado: \(type)"))
        }
    }

    public func encode(to e: Encoder) throws {
        switch self {
        case .defaults(let a):
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode("defaults", forKey: .type)
            try a.encode(to: e)
        }
    }
}

/// Equivale a `defaults write <domain> <key> -<type> <value>` (o `defaults -currentHost write …`).
public struct DefaultsAction: Codable, Hashable, Sendable {
    /// Dominio de preferencias. "NSGlobalDomain" (o "-g") es el dominio global.
    public let domain: String
    public let key: String
    public let value: PrefValue
    /// `true` → `-currentHost` (preferencias por máquina, p. ej. algunas del trackpad).
    public let currentHost: Bool

    enum CodingKeys: String, CodingKey { case domain, key, valueType, value, currentHost }

    public init(domain: String, key: String, value: PrefValue, currentHost: Bool = false) {
        self.domain = domain; self.key = key; self.value = value; self.currentHost = currentHost
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        domain = try c.decode(String.self, forKey: .domain)
        key = try c.decode(String.self, forKey: .key)
        currentHost = try c.decodeIfPresent(Bool.self, forKey: .currentHost) ?? false
        let type = try c.decode(String.self, forKey: .valueType)
        switch type {
        case "bool": value = .bool(try c.decode(Bool.self, forKey: .value))
        case "int": value = .int(try c.decode(Int.self, forKey: .value))
        case "float": value = .double(try c.decode(Double.self, forKey: .value))
        case "string": value = .string(try c.decode(String.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(forKey: .valueType, in: c,
                                                   debugDescription: "valueType no soportado: \(type)")
        }
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(domain, forKey: .domain)
        try c.encode(key, forKey: .key)
        if currentHost { try c.encode(true, forKey: .currentHost) }
        switch value {
        case .bool(let v): try c.encode("bool", forKey: .valueType); try c.encode(v, forKey: .value)
        case .int(let v): try c.encode("int", forKey: .valueType); try c.encode(v, forKey: .value)
        case .double(let v): try c.encode("float", forKey: .valueType); try c.encode(v, forKey: .value)
        case .string(let v): try c.encode("string", forKey: .valueType); try c.encode(v, forKey: .value)
        }
    }

    /// Identifica la clave física (dominio + clave + host) para guardar el valor original.
    public var slot: String { "\(currentHost ? "currentHost:" : "")\(domain):\(key)" }

    /// Línea equivalente en terminal, para mostrar al usuario qué se hace.
    public var command: String {
        let host = currentHost ? " -currentHost" : ""
        let dom = domain == "NSGlobalDomain" ? "-g" : domain
        let (flag, v): (String, String) = switch value {
        case .bool(let b): ("-bool", b ? "true" : "false")
        case .int(let i): ("-int", String(i))
        case .double(let x): ("-float", String(x))
        case .string(let s): ("-string", "\"\(s)\"")
        }
        return "defaults\(host) write \(dom) \(key) \(flag) \(v)"
    }
}

/// Valor de una preferencia, con los tipos que el catálogo permite escribir.
public enum PrefValue: Codable, Hashable, Sendable, CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    /// Compara con tolerancia de tipos: un `bool` guardado como 0/1, o un entero frente a un decimal.
    public func matches(_ other: PrefValue) -> Bool {
        switch (self, other) {
        case let (.bool(a), .bool(b)): a == b
        case let (.bool(a), .int(b)), let (.int(b), .bool(a)): (a ? 1 : 0) == b
        case let (.int(a), .int(b)): a == b
        case let (.double(a), .double(b)): abs(a - b) < 0.0001
        case let (.int(a), .double(b)), let (.double(b), .int(a)): abs(Double(a) - b) < 0.0001
        case let (.string(a), .string(b)): a == b
        default: false
        }
    }

    public var description: String {
        switch self {
        case .bool(let b): b ? "true" : "false"
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .string(let s): "\"\(s)\""
        }
    }
}
