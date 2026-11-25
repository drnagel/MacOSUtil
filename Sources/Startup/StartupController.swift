import Foundation
import Privileged

/// Desactiva y reactiva servicios de launchd de terceros.
/// - Agentes (dominio gui/<uid>): sin contraseña.
/// - Daemons de /Library/LaunchDaemons (dominio system): con `AdminRunner`, que pide la contraseña una vez por lote.
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
        guard item.canToggle, let plist = item.plistPath else {
            throw StartupError.notAllowed("«\(item.displayName)» no se puede desactivar desde aquí: \(item.scope.subtitle)")
        }
        if item.scope.needsAdmin {
            try Self.checkDaemon(plist)
            let outcomes = try AdminRunner.run([.daemonDisable(label: item.label), .daemonStop(label: item.label)],
                                               reason: "MacOSUtil quiere desactivar el servicio «\(item.displayName)».")
            try Self.check(outcomes)
        } else {
            let target = "\(item.scope.domain)/\(item.label)"
            let r = Launchctl.run(["disable", target])
            guard r.ok else { throw StartupError.launchctl(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
            // Si no estaba cargado, bootout falla; no importa: ya no arrancará.
            Launchctl.run(["bootout", target])
        }
        try save { $0.disabled[item.label] = Record(label: item.label, scope: item.scope, plistPath: plist, disabledAt: Date()) }
    }

    public func enable(_ item: StartupItem) throws {
        guard item.canToggle, let plist = item.plistPath else {
            throw StartupError.notAllowed("«\(item.displayName)» no se puede activar desde aquí.")
        }
        if item.scope.needsAdmin {
            try Self.checkDaemon(plist)
            let outcomes = try AdminRunner.run(Self.enableCommands(label: item.label, plistPath: plist),
                                               reason: "MacOSUtil quiere reactivar el servicio «\(item.displayName)».")
            try Self.check(outcomes)
            try save { $0.disabled[item.label] = nil }
        } else {
            try enable(label: item.label, scope: item.scope, plistPath: plist)
        }
    }

    /// Antes de pedir la contraseña: solo daemons con su plist en /Library/LaunchDaemons.
    static func checkDaemon(_ plistPath: String) throws {
        guard AdminCommand.isDaemonPlistPath(plistPath) else {
            throw AdminError.rejected("el plist no está en /Library/LaunchDaemons: \(plistPath)")
        }
    }

    static func enableCommands(label: String, plistPath: String) -> [AdminCommand] {
        var cmds: [AdminCommand] = [.daemonEnable(label: label)]
        if FileManager.default.fileExists(atPath: plistPath) { cmds.append(.daemonStart(plistPath: plistPath)) }
        return cmds
    }

    static func check(_ outcomes: [AdminRunner.Outcome]) throws {
        if let bad = outcomes.first(where: { !$0.ok }) {
            throw StartupError.launchctl(bad.output.isEmpty ? "launchctl terminó con código \(bad.status)" : bad.output)
        }
    }

    /// Reactiva todo lo que desactivó MacOSUtil. Devuelve los errores por etiqueta.
    /// Los daemons van en un solo lote: una sola petición de contraseña.
    public func enableAll() -> [(label: String, error: String)] {
        var errors: [(String, String)] = []
        let all = records
        for r in all where !r.scope.needsAdmin {
            do { try enable(label: r.label, scope: r.scope, plistPath: r.plistPath) }
            catch { errors.append((r.label, error.localizedDescription)) }
        }
        var daemons: [Record] = []
        for d in all where d.scope.needsAdmin {
            do { try Self.checkDaemon(d.plistPath); daemons.append(d) } catch { errors.append((d.label, error.localizedDescription)) }
        }
        guard !daemons.isEmpty else { return errors }
        var batch: [(label: String, commands: [AdminCommand])] = []
        for d in daemons { batch.append((d.label, Self.enableCommands(label: d.label, plistPath: d.plistPath))) }
        do {
            let outcomes = try AdminRunner.run(batch.flatMap(\.commands),
                                               reason: "MacOSUtil quiere reactivar \(daemons.count) \(daemons.count == 1 ? "servicio" : "servicios") del sistema.")
            var i = 0
            for b in batch {
                let mine = Array(outcomes[i..<(i + b.commands.count)])
                i += b.commands.count
                do { try Self.check(mine); try save { $0.disabled[b.label] = nil } }
                catch { errors.append((b.label, error.localizedDescription)) }
            }
        } catch {
            for d in daemons { errors.append((d.label, error.localizedDescription)) }
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

        // Daemons: se comprueba solo que se rechaza lo que no se debe tocar (sin pedir contraseña).
        let appManaged = StartupItem(label: "x.y", scope: .daemon, plistPath: nil, program: nil, owner: nil, schedule: [],
                                     pid: nil, loaded: false, disabled: false, memory: nil)
        var refused = false
        do { try c.disable(appManaged) } catch StartupError.notAllowed { refused = true } catch {}
        results.append(("rechaza desactivar un daemon registrado por una app (sin plist)", refused))
        let outside = StartupItem(label: "x.y", scope: .daemon, plistPath: "/tmp/x.y.plist", program: nil, owner: nil, schedule: [],
                                  pid: nil, loaded: false, disabled: false, memory: nil)
        var rejected = false
        do { try c.enable(outside) } catch AdminError.rejected { rejected = true } catch {}
        results.append(("rechaza un daemon con plist fuera de /Library/LaunchDaemons", rejected))
        return results
    }
}
