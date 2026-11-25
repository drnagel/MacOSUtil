import Foundation

/// Lectura y escritura de preferencias con CFPreferences (lo mismo que hace `defaults`, sin lanzar procesos).
/// Solo dominios del usuario actual; los dominios de sistema (/Library/Preferences) necesitan el helper (Fase 2).
public enum Preferences {
    /// Lo que hay guardado en una clave.
    public enum Stored: Codable, Hashable, Sendable {
        case absent
        case value(PrefValue)
        /// Array, diccionario, fecha o datos: no se sabe restaurar, así que no se toca.
        case unsupported(String)
    }

    public static func read(_ a: DefaultsAction) -> Stored {
        guard let raw = CFPreferencesCopyValue(a.key as CFString, appID(a.domain),
                                               kCFPreferencesCurrentUser, host(a)) else { return .absent }
        if CFGetTypeID(raw) == CFBooleanGetTypeID() {
            return .value(.bool(CFBooleanGetValue((raw as! CFBoolean))))
        }
        if CFGetTypeID(raw) == CFNumberGetTypeID() {
            let n = raw as! NSNumber
            return .value(CFNumberIsFloatType((raw as! CFNumber)) ? .double(n.doubleValue) : .int(n.intValue))
        }
        if let s = raw as? String { return .value(.string(s)) }
        return .unsupported(String(describing: CFCopyTypeIDDescription(CFGetTypeID(raw)) ?? "desconocido" as CFString))
    }

    /// Escribe (o borra con `nil`) y sincroniza para que cfprefsd lo persista.
    public static func write(_ a: DefaultsAction, _ value: PrefValue?) throws {
        let cf: CFPropertyList? = switch value {
        case .bool(let b): b as CFBoolean
        case .int(let i): NSNumber(value: i)
        case .double(let d): NSNumber(value: d)
        case .string(let s): s as CFString
        case nil: nil
        }
        CFPreferencesSetValue(a.key as CFString, cf, appID(a.domain), kCFPreferencesCurrentUser, host(a))
        guard CFPreferencesSynchronize(appID(a.domain), kCFPreferencesCurrentUser, host(a)) else {
            throw TweakError.writeFailed(a.command)
        }
    }

    static func appID(_ domain: String) -> CFString {
        domain == "NSGlobalDomain" || domain == "-g" ? kCFPreferencesAnyApplication : domain as CFString
    }

    static func host(_ a: DefaultsAction) -> CFString {
        a.currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
    }
}

public enum TweakError: LocalizedError, Equatable {
    case writeFailed(String)
    case unsupportedValue(slot: String, type: String)
    case incompatible(String)
    case needsAdmin(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let cmd): "No se pudo guardar la preferencia (\(cmd))."
        case .unsupportedValue(let slot, let type):
            "\(slot) contiene un valor de tipo \(type); no se modifica para no perderlo."
        case .incompatible(let t): "«\(t)» no está probado en esta versión de macOS."
        case .needsAdmin(let t): "«\(t)» necesita permisos de administrador (llega en la Fase 2)."
        }
    }
}
