import Foundation

/// Un servicio de terceros que launchd arranca solo.
public struct StartupItem: Identifiable, Hashable, Sendable {
    public enum Scope: String, Codable, Sendable, CaseIterable {
        /// ~/Library/LaunchAgents: solo tu usuario. Se puede desactivar sin contraseña.
        case userAgent
        /// /Library/LaunchAgents: se carga en la sesión de cada usuario. Se puede desactivar para tu usuario sin contraseña.
        case globalAgent
        /// Registrado por una app desde dentro de su bundle (SMAppService). Se gestiona en Ajustes › Ítems de inicio.
        case appManaged
        /// /Library/LaunchDaemons y servicios de sistema: corren como root. Cambiarlos pide la contraseña de administrador.
        case daemon

        public var title: String {
            switch self {
            case .userAgent: "Tus agentes"
            case .globalAgent: "Agentes para todos los usuarios"
            case .appManaged: "Registrados por apps"
            case .daemon: "Servicios del sistema (root)"
            }
        }

        public var subtitle: String {
            switch self {
            case .userAgent: "~/Library/LaunchAgents. Se arrancan al iniciar tu sesión."
            case .globalAgent: "/Library/LaunchAgents. Desactivarlos aquí solo afecta a tu usuario."
            case .appManaged: "La propia app los registra; se activan o desactivan en Ajustes › Ítems de inicio."
            case .daemon: "/Library/LaunchDaemons. Corren como root desde el arranque; desactivarlos o reactivarlos pide tu contraseña de administrador."
            }
        }

        /// Dominio de launchd donde vive el servicio.
        var domain: String {
            switch self {
            case .userAgent, .globalAgent, .appManaged: "gui/\(getuid())"
            case .daemon: "system"
            }
        }

        /// Se pueden desactivar desde MacOSUtil (si además tienen plist propio). Los daemons piden contraseña.
        public var canToggle: Bool { self != .appManaged }

        /// Cambiarlo pide la contraseña de administrador.
        public var needsAdmin: Bool { self == .daemon }
    }

    public var id: String { "\(scope.rawValue):\(label)" }
    public let label: String
    public let scope: Scope
    /// Ruta del .plist (no hay para los registrados por apps).
    public let plistPath: String?
    /// Ejecutable que lanza.
    public let program: String?
    /// La app a la que pertenece, si se pudo averiguar.
    public let owner: Owner?
    /// Cuándo se ejecuta: «al iniciar sesión», «siempre activo», «cada 1 h»…
    public let schedule: [String]
    /// Proceso en marcha ahora.
    public let pid: Int32?
    /// Cargado en launchd (puede estar cargado sin proceso, esperando su momento).
    public let loaded: Bool
    /// Desactivado en launchd (`launchctl disable`) o con `Disabled = true` en el plist.
    public let disabled: Bool
    /// Memoria del proceso en marcha (RSS), en bytes.
    public var memory: Int64?

    public struct Owner: Hashable, Sendable {
        public let name: String
        /// Ruta de la .app, si existe.
        public let appPath: String?
    }

    /// El ejecutable ya no existe: es un resto de una app desinstalada.
    public var isOrphan: Bool {
        guard let program else { return false }
        return !FileManager.default.fileExists(atPath: program)
    }

    public var isRunning: Bool { pid != nil }

    /// Se puede desactivar desde MacOSUtil: agente o daemon con plist propio (los registrados por apps, no).
    public var canToggle: Bool { scope.canToggle && plistPath != nil }

    /// No se encontró una app instalada a la que pertenezca (el nombre sale solo del identificador).
    /// Suele indicar que la app se borró y su agente se quedó.
    public var ownerAppMissing: Bool { owner?.appPath == nil }

    public var displayName: String { owner?.name ?? label }
}

public enum StartupError: LocalizedError {
    case notAllowed(String)
    case launchctl(String)

    public var errorDescription: String? {
        switch self {
        case .notAllowed(let why): why
        case .launchctl(let out): "launchctl: \(out)"
        }
    }
}
