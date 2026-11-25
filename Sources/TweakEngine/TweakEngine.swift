import Foundation

/// Estado actual de un ajuste en este Mac.
public enum TweakStatus: Equatable, Sendable {
    case on
    case off
    /// Algunas acciones coinciden y otras no (p. ej. se cambió una parte a mano).
    case partial
    case unavailable(String)

    public var isOn: Bool { self == .on }
}

/// Resultado de aplicar o revertir un lote de ajustes.
public struct BatchResult: Sendable {
    public var changed: [String] = []
    public var failed: [(id: String, error: String)] = []
    public var restarted: [String] = []
    public var needsLogout = false

    public init() {}
}

/// Aplica, comprueba y revierte ajustes del catálogo. Guarda los valores originales en `StateStore`.
public final class TweakEngine: @unchecked Sendable {
    public let store: StateStore

    public init(store: StateStore = StateStore()) {
        self.store = store
    }

    // MARK: Comprobar

    public func status(_ t: Tweak) -> TweakStatus {
        if !t.isCompatible { return .unavailable(L("No probado en esta versión de macOS")) }
        if t.admin { return .unavailable(L("Necesita permisos de administrador")) }
        var matches = 0
        for case .defaults(let a) in t.actions {
            if case .value(let v) = Preferences.read(a), v.matches(a.value) { matches += 1 }
        }
        return matches == t.actions.count ? .on : (matches == 0 ? .off : .partial)
    }

    /// Valor actual de cada acción, para mostrar «ahora: X → quedará: Y».
    public func currentValues(_ t: Tweak) -> [(action: DefaultsAction, stored: Preferences.Stored)] {
        t.actions.map { if case .defaults(let a) = $0 { (a, Preferences.read(a)) } else { fatalError() } }
    }

    /// `true` si MacOSUtil lo cambió y tiene el original guardado.
    public func isManaged(_ t: Tweak) -> Bool { store.record(for: t.id) != nil }

    // MARK: Aplicar

    /// Escribe los valores del ajuste. No reinicia procesos: eso lo hace `run(_:)` una vez por lote.
    public func apply(_ t: Tweak) throws {
        guard t.isCompatible else { throw TweakError.incompatible(t.title) }
        guard !t.admin else { throw TweakError.needsAdmin(t.title) }
        var originals: [StateStore.Original] = []
        for case .defaults(let a) in t.actions {
            let current = Preferences.read(a)
            if case .unsupported(let type) = current { throw TweakError.unsupportedValue(slot: a.slot, type: type) }
            originals.append(.init(domain: a.domain, key: a.key, currentHost: a.currentHost, stored: current))
        }
        // Primero se guarda el original; si la escritura falla a medias, se puede deshacer igual.
        try store.remember(t.id, originals: originals)
        for case .defaults(let a) in t.actions { try Preferences.write(a, a.value) }
    }

    // MARK: Revertir

    /// Devuelve las claves a su valor anterior a MacOSUtil. Si no hay registro (el ajuste ya estaba así antes
    /// de usar la app), borra las claves para volver al valor por defecto de macOS.
    public func revert(_ t: Tweak) throws {
        if let r = store.record(for: t.id) {
            try restore(r.originals)
        } else {
            for case .defaults(let a) in t.actions { try Preferences.write(a, nil) }
        }
        try store.forget(t.id)
    }

    /// Revierte un registro aunque el ajuste ya no esté en el catálogo.
    public func revert(id: String) throws {
        if let r = store.record(for: id) { try restore(r.originals) }
        try store.forget(id)
    }

    private func restore(_ originals: [StateStore.Original]) throws {
        for o in originals {
            if case .unsupported = o.stored { continue }   // nunca se llegó a sobrescribir
            // Solo importan dominio, clave y host; el valor que se escribe es el segundo argumento de write().
            let a = DefaultsAction(domain: o.domain, key: o.key, value: .bool(false), currentHost: o.currentHost)
            switch o.stored {
            case .absent: try Preferences.write(a, nil)
            case .value(let v): try Preferences.write(a, v)
            case .unsupported: break
            }
        }
    }

    // MARK: Lotes

    public enum Change: Sendable { case apply(Tweak), revert(Tweak) }

    /// Aplica un lote de cambios y reinicia una sola vez los procesos afectados (Finder, Dock…).
    public func run(_ changes: [Change], restartProcesses: Bool = true) -> BatchResult {
        var result = BatchResult()
        var toRestart: [String] = []
        for change in changes {
            let t: Tweak
            do {
                switch change {
                case .apply(let tw): t = tw; try apply(tw)
                case .revert(let tw): t = tw; try revert(tw)
                }
                result.changed.append(t.id)
                result.needsLogout = result.needsLogout || t.logout
                for p in t.restart where !toRestart.contains(p) { toRestart.append(p) }
            } catch {
                let id = switch change { case .apply(let tw), .revert(let tw): tw.id }
                result.failed.append((id, error.localizedDescription))
            }
        }
        if restartProcesses {
            for p in toRestart where Self.killall(p) { result.restarted.append(p) }
        }
        return result
    }

    /// Revierte todo lo que MacOSUtil cambió.
    public func revertAll(catalog: Catalog) -> BatchResult {
        var changes: [Change] = []
        var orphans: [String] = []
        for id in store.appliedIDs {
            if let t = catalog.tweak(id) { changes.append(.revert(t)) } else { orphans.append(id) }
        }
        var result = run(changes)
        for id in orphans {
            do { try revert(id: id); result.changed.append(id) }
            catch { result.failed.append((id, error.localizedDescription)) }
        }
        return result
    }

    @discardableResult
    static func killall(_ process: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = [process]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }
}
