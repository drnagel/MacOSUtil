import SwiftUI
import AppCatalog
import TweakEngine

@MainActor
@Observable
final class AppsModel {
    private(set) var catalog: AppCatalogFile?
    private(set) var loadError: String?
    private(set) var info: [String: CaskInfo] = [:]
    private(set) var statuses: [String: AppStatus] = [:]
    private(set) var isChecking = false
    private(set) var brewInstalled = Homebrew.isInstalled

    /// Apps marcadas para instalar.
    var selected: Set<String> = []

    // Trabajo en curso (instalar, actualizar, desinstalar)
    private(set) var isRunning = false
    private(set) var currentTask: String?
    private(set) var log: [String] = []
    var showLog = false
    var banner: AppModel.Banner?

    init() { load() }

    func load() {
        do {
            guard let dir = Catalog.locate() else { throw AppCatalogError.notFound }
            catalog = try AppCatalogFile.load(from: dir)
            loadError = nil
        } catch {
            catalog = nil
            loadError = error.localizedDescription
        }
    }

    // MARK: Estado

    func status(_ a: AppEntry) -> AppStatus { statuses[a.id] ?? .unknown }

    func needsAdmin(_ a: AppEntry) -> Bool { a.cask.flatMap { info[$0]?.needsAdmin } ?? false }

    func latestVersion(_ a: AppEntry) -> String? { a.cask.flatMap { info[$0]?.version } }

    var installedCount: Int { statuses.values.filter(\.isInstalled).count }

    var outdated: [AppEntry] {
        (catalog?.allApps ?? []).filter { if case .brew(_, true) = status($0) { true } else { false } }
    }

    func canSelect(_ a: AppEntry) -> Bool {
        a.cask != nil && status(a) == .notInstalled && brewInstalled && !isRunning
    }

    func toggle(_ a: AppEntry) {
        if selected.contains(a.id) { selected.remove(a.id) } else if canSelect(a) { selected.insert(a.id) }
    }

    /// Consulta Homebrew (una sola llamada para todo el catálogo) y lo que hay en /Applications.
    func refresh() {
        Task { await refreshNow() }
    }

    /// Igual que `refresh()` pero se puede esperar (exportar necesita el estado al día).
    func refreshNow() async {
        guard let catalog, !isChecking else { return }
        brewInstalled = Homebrew.isInstalled
        isChecking = true
        let tokens = catalog.allApps.compactMap(\.cask)
        let info = brewInstalled ? await Homebrew.info(tokens) : [:]
        self.info = info
        var s: [String: AppStatus] = [:]
        for a in catalog.allApps {
            if a.cask != nil && !brewInstalled {
                // Sin Homebrew solo se puede saber si la app está en /Applications.
                s[a.id] = .notInstalled
            } else {
                s[a.id] = Homebrew.status(of: a, info: info)
            }
        }
        statuses = s
        selected = selected.filter { id in s[id] == .notInstalled }
        isChecking = false
    }

    // MARK: Acciones

    func installSelected() {
        guard let catalog, !isRunning else { return }
        let apps = catalog.allApps.filter { selected.contains($0.id) && $0.cask != nil }
        let direct = apps.filter { !needsAdmin($0) }
        let admin = apps.filter { needsAdmin($0) }
        if !admin.isEmpty {
            Homebrew.openInTerminal(admin.compactMap(\.cask).map { ["install", "--cask", $0] },
                                    title: "MacOSUtil: instalando \(admin.map(\.name).joined(separator: ", ")) (pide contraseña)")
        }
        selected = []
        guard !direct.isEmpty else {
            if !admin.isEmpty { banner = .init(text: adminNote(admin), isError: false) }
            return
        }
        runJobs(direct.map { a in ("Instalando \(a.name)", { await Homebrew.install(a.cask!, onLine: $0) }) },
                note: admin.isEmpty ? nil : adminNote(admin))
    }

    func upgrade(_ apps: [AppEntry]) {
        let list = apps.filter { $0.cask != nil }
        let admin = list.filter { needsAdmin($0) }
        if !admin.isEmpty {
            Homebrew.openInTerminal(admin.compactMap(\.cask).map { ["upgrade", "--cask", $0] },
                                    title: "MacOSUtil: actualizando \(admin.map(\.name).joined(separator: ", "))")
        }
        let direct = list.filter { !needsAdmin($0) }
        guard !direct.isEmpty else { return }
        runJobs(direct.map { a in ("Actualizando \(a.name)", { await Homebrew.upgrade(a.cask!, onLine: $0) }) }, note: nil)
    }

    func uninstall(_ a: AppEntry) {
        guard let token = a.cask else { return }
        if needsAdmin(a) {
            Homebrew.openInTerminal([["uninstall", "--cask", token]], title: "MacOSUtil: desinstalando \(a.name)")
            return
        }
        runJobs([("Desinstalando \(a.name)", { await Homebrew.uninstall(token, onLine: $0) })], note: nil)
    }

    func openAppStore(_ a: AppEntry) {
        if let url = a.appStoreURL { NSWorkspace.shared.open(url) }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func adminNote(_ apps: [AppEntry]) -> String {
        "\(apps.map(\.name).joined(separator: ", ")) se instala en Terminal porque pide tu contraseña de administrador. "
            + "Cuando termine, pulsa «Volver a comprobar»."
    }

    private typealias Job = (title: String, run: (@escaping @Sendable (String) -> Void) async -> Homebrew.RunResult)

    /// Ejecuta trabajos de brew uno detrás de otro, con la salida en vivo en `log`, y muestra el resultado.
    private func runJobs(_ jobs: [Job], note: String?) {
        guard !isRunning else { return }
        Task {
            let results = await executeJobs(jobs)
            let failed = zip(jobs, results).filter { !$1 }.map(\.0.title)
            let done = results.filter { $0 }.count
            var text = done == 1 ? "1 tarea completada." : "\(done) tareas completadas."
            if !failed.isEmpty { text += "\nCon error: \(failed.joined(separator: ", ")). Mira el registro para ver el motivo." }
            if let note { text += "\n\n" + note }
            banner = .init(text: text, isError: !failed.isEmpty)
            refresh()
        }
    }

    /// Núcleo de `runJobs`: devuelve, por cada trabajo, si terminó bien.
    private func executeJobs(_ jobs: [Job]) async -> [Bool] {
        isRunning = true
        log = []
        var results: [Bool] = []
        for job in jobs {
            currentTask = job.title
            append("==> \(job.title)")
            let result = await job.run { line in Task { @MainActor in self.append(line) } }
            results.append(result.ok)
            if !result.ok {
                // brew explica el error en sus últimas líneas
                let tail = result.output.split(separator: "\n").suffix(3).joined(separator: " ")
                append("✗ \(tail)")
            }
        }
        currentTask = nil
        isRunning = false
        return results
    }

    /// Resultado de instalar un lote desde el asistente.
    struct InstallOutcome {
        var installed: [String] = []
        var failed: [String] = []
        /// Se abrieron en Terminal porque piden contraseña.
        var inTerminal: [String] = []
    }

    /// Instala un lote y espera a que termine (lo usa el asistente). Las que piden contraseña van a Terminal.
    func install(_ apps: [AppEntry]) async -> InstallOutcome {
        var outcome = InstallOutcome()
        let list = apps.filter { $0.cask != nil && !status($0).isInstalled }
        let admin = list.filter { needsAdmin($0) }
        let direct = list.filter { !needsAdmin($0) }
        if !admin.isEmpty {
            Homebrew.openInTerminal(admin.compactMap(\.cask).map { ["install", "--cask", $0] },
                                    title: "MacOSUtil: instalando \(admin.map(\.name).joined(separator: ", ")) (pide contraseña)")
            outcome.inTerminal = admin.map(\.name)
        }
        guard !direct.isEmpty, !isRunning else { return outcome }
        let results = await executeJobs(direct.map { a in ("Instalando \(a.name)", { await Homebrew.install(a.cask!, onLine: $0) }) })
        for (a, ok) in zip(direct, results) { if ok { outcome.installed.append(a.name) } else { outcome.failed.append(a.name) } }
        refresh()
        return outcome
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}
