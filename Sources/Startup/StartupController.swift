import Foundation

/// Desactiva y reactiva agentes de launchd en tu sesión (dominio gui/<uid>), sin contraseña.
///
/// Desactivar = `launchctl disable` (no vuelve a arrancar, ni tras reiniciar) + `launchctl bootout` (se detiene ya).
/// Reactivar = `launchctl enable` + `launchctl bootstrap` con su plist (arranca otra vez).
/// El plist nunca se borra ni se modifica, así que todo es reversible.
public final class StartupController: @unchecked Sendable {
    public struct Record: Codable, Sendable {
        public let label: String
        public let scope: StartupItem.Scope
        public let plistPath: String
        public let disabledAt: Date
    }

    private struct File: Codable { var version = 1; var disabled: [String: Record] = [:] }

    public let url: URL
    private var file: File
    private let lock = NSLock()

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacOSUtil/startup.json")
    }

    public init(url: URL = StartupController.defaultURL) {
        self.url = url
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        file = (try? Data(contentsOf: url)).flatMap { try? dec.decode(File.self, from: $0) } ?? File()
    }

    /// Servicios que desactivó MacOSUtil (para «Reactivar todo»).
    public var records: [Record] { lock.withLock { file.disabled.values.sorted { $0.label < $1.label } } }

    public func isManaged(_ item: StartupItem) -> Bool { lock.withLock { file.disabled[item.label] != nil } }

    // MARK: Acciones

    public func disable(_ item: StartupItem) throws {
        guard item.scope.canToggle, let plist = item.plistPath else {
            throw StartupError.notAllowed("«\(item.displayName)» no se puede desactivar desde aquí: \(item.scope.subtitle)")
        }
        let target = "\(item.scope.domain)/\(item.label)"
        let r = Launchctl.run(["disable", target])
        guard r.ok else { throw StartupError.launchctl(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        // Si no estaba cargado, bootout falla; no importa: ya no arrancará.
        Launchctl.run(["bootout", target])
        try save { $0.disabled[item.label] = Record(label: item.label, scope: item.scope, plistPath: plist, disabledAt: Date()) }
    }

    public func enable(_ item: StartupItem) throws {
        guard item.scope.canToggle, let plist = item.plistPath else {
            throw StartupError.notAllowed("«\(item.displayName)» no se puede activar desde aquí.")
        }
        try enable(label: item.label, scope: item.scope, plistPath: plist)
    }

    /// Reactiva todo lo que desactivó MacOSUtil. Devuelve los errores por etiqueta.
    public func enableAll() -> [(label: String, error: String)] {
        var errors: [(String, String)] = []
        for r in records {
            do { try enable(label: r.label, scope: r.scope, plistPath: r.plistPath) }
            catch { errors.append((r.label, error.localizedDescription)) }
        }
        return errors
    }

    func enable(label: String, scope: StartupItem.Scope, plistPath: String) throws {
        let target = "\(scope.domain)/\(label)"
        let r = Launchctl.run(["enable", target])
        guard r.ok else { throw StartupError.launchctl(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if FileManager.default.fileExists(atPath: plistPath) {
            let b = Launchctl.run(["bootstrap", scope.domain, plistPath])
            // 5 / 37 = ya estaba cargado: no es un error.
            if !b.ok && ![5, 37].contains(b.status) && !b.output.contains("already") {
                throw StartupError.launchctl(b.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        try save { $0.disabled[label] = nil }
    }

    private func save(_ change: (inout File) -> Void) throws {
        try lock.withLock {
            change(&file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(file).write(to: url, options: .atomic)
        }
    }
}

// MARK: - Pruebas

extension StartupController {
    /// Prueba el ciclo completo con un agente temporal que no está en ~/Library/LaunchAgents
    /// (así macOS no muestra el aviso de «ítem en segundo plano añadido»). Devuelve (mensaje, ok).
    public static func selfTestCycle(storeURL: URL) -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        let label = "local.macosutil.selftest.agent"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macosutil-agent-\(UUID().uuidString)")
        let plist = dir.appendingPathComponent("\(label).plist")
        let domain = "gui/\(getuid())"
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            Launchctl.run(["bootout", "\(domain)/\(label)"])
            Launchctl.run(["enable", "\(domain)/\(label)"])
            try? FileManager.default.removeItem(at: dir)
        }
        let dict: NSDictionary = ["Label": label, "ProgramArguments": ["/bin/sleep", "600"], "RunAtLoad": true]
        guard dict.write(to: plist, atomically: true) else { return [("no se pudo escribir el plist de prueba", false)] }

        func state() -> (running: Bool, disabled: Bool) {
            let s = Launchctl.domainState(domain)
            return ((s.services[label] ?? nil) != nil, s.disabled[label] ?? false)
        }
        func item() -> StartupItem {
            let s = state()
            return StartupItem(label: label, scope: .userAgent, plistPath: plist.path, program: "/bin/sleep",
                               owner: nil, schedule: [], pid: nil, loaded: s.running, disabled: s.disabled, memory: nil)
        }

        Launchctl.run(["bootstrap", domain, plist.path])
        Thread.sleep(forTimeInterval: 0.3)
        results.append(("agente de prueba en marcha", state().running))

        let c = StartupController(url: storeURL)
        do {
            try c.disable(item())
            Thread.sleep(forTimeInterval: 0.3)
            let s = state()
            results.append(("desactivar: detenido y marcado como desactivado", !s.running && s.disabled))
            results.append(("registrado en startup.json", c.isManaged(item())))

            let errors = c.enableAll()
            Thread.sleep(forTimeInterval: 0.3)
            let s2 = state()
            results.append(("reactivar todo: vuelve a estar en marcha", errors.isEmpty && s2.running && !s2.disabled))
            results.append(("registro eliminado", c.records.isEmpty))
        } catch {
            results.append(("error: \(error.localizedDescription)", false))
        }

        let daemon = StartupItem(label: "x", scope: .daemon, plistPath: "/x", program: nil, owner: nil, schedule: [],
                                 pid: nil, loaded: false, disabled: false, memory: nil)
        var refused = false
        do { try c.disable(daemon) } catch StartupError.notAllowed { refused = true } catch {}
        results.append(("rechaza desactivar un daemon sin el helper", refused))
        return results
    }
}
