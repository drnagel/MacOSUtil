import SwiftUI
import TweakEngine
import AppCatalog
import Profiles
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case category(String)
    case health
    case apps
    case startup
    case power
    case disk
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let engine = TweakEngine()
    let apps = AppsModel()
    let startup = StartupModel()
    let power = PowerModel()
    let health = HealthModel()
    private(set) var catalog: Catalog?
    private(set) var loadError: String?
    private(set) var statuses: [String: TweakStatus] = [:]
    /// Cambios marcados que todavía no se aplicaron: id → estado deseado (activado o no).
    private(set) var pending: [String: Bool] = [:]
    private(set) var isApplying = false
    var selection: SidebarItem?
    var banner: Banner?
    /// Perfiles del asistente (`Catalog/profiles`).
    private(set) var profiles: [Profile] = []
    private(set) var profileError: String?
    /// Asistente abierto (nil = cerrado).
    var wizard: WizardModel?

    struct Banner: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    init() {
        load()
    }

    func load() {
        do {
            guard let dir = Catalog.locate() else { throw CatalogError.notFound }
            catalog = try Catalog.load(from: dir)
            loadError = nil
            if selection == nil, let first = catalog?.categories.first { selection = .category(first.id) }
            loadProfiles(from: dir)
        } catch {
            catalog = nil
            loadError = error.localizedDescription
        }
        refresh()
    }

    private func loadProfiles(from dir: URL) {
        do {
            let p = try ProfileCatalog.load(from: dir)
            let problems = ProfileCatalog.validate(p, tweakIDs: tweakIDs, appIDs: appIDs)
            if !problems.isEmpty { throw ProfileError.invalid(problems.joined(separator: "\n")) }
            profiles = p
            profileError = nil
        } catch {
            profiles = []
            profileError = error.localizedDescription
        }
    }

    var tweakIDs: Set<String> { Set(catalog?.allTweaks.map(\.id) ?? []) }
    var appIDs: Set<String> {
        let dir = Catalog.locate()
        let file = dir.flatMap { try? AppCatalogFile.load(from: $0) }
        return Set(apps.catalog?.allApps.map(\.id) ?? file?.allApps.map(\.id) ?? [])
    }

    func refresh() {
        guard let catalog else { statuses = [:]; return }
        var s: [String: TweakStatus] = [:]
        for t in catalog.allTweaks { s[t.id] = engine.status(t) }
        statuses = s
    }

    // MARK: Estado por ajuste

    func status(_ t: Tweak) -> TweakStatus { statuses[t.id] ?? .off }

    /// Lo que muestra el interruptor: el cambio pendiente si lo hay, si no el estado real.
    func isOn(_ t: Tweak) -> Bool { pending[t.id] ?? status(t).isOn }

    func set(_ t: Tweak, on: Bool) {
        if on == status(t).isOn { pending[t.id] = nil } else { pending[t.id] = on }
    }

    func onCount(_ c: TweakCategory) -> Int { c.tweaks.filter { status($0).isOn }.count }

    var pendingRequiresLogout: Bool {
        pending.keys.contains { catalog?.tweak($0)?.logout == true }
    }

    var managedCount: Int { engine.store.appliedIDs.count }

    // MARK: Acciones

    func discardPending() { pending = [:] }

    func applyPending() {
        guard let catalog, !pending.isEmpty, !isApplying else { return }
        let changes: [TweakEngine.Change] = pending.compactMap { id, on in
            guard let t = catalog.tweak(id) else { return nil }
            return on ? .apply(t) : .revert(t)
        }
        runBatch { engine in engine.run(changes) }
    }

    func revertAll() {
        guard let catalog, !isApplying else { return }
        runBatch { engine in engine.revertAll(catalog: catalog) }
    }

    /// Activa los ajustes indicados que no estén ya activados, y espera a que termine (lo usa el asistente).
    func applyTweaks(_ ids: [String]) async -> BatchResult {
        guard let catalog else { return BatchResult() }
        let changes: [TweakEngine.Change] = ids.compactMap { catalog.tweak($0) }
            .filter { !status($0).isOn && !isUnavailable($0) }
            .map { .apply($0) }
        guard !changes.isEmpty else { return BatchResult() }
        isApplying = true
        let engine = self.engine
        let result = await Task.detached { engine.run(changes) }.value
        isApplying = false
        refresh()
        return result
    }

    func isUnavailable(_ t: Tweak) -> Bool {
        if case .unavailable = status(t) { return true }
        return false
    }

    private func runBatch(_ work: @escaping @Sendable (TweakEngine) -> BatchResult) {
        isApplying = true
        let engine = self.engine
        Task.detached {
            let result = work(engine)
            await MainActor.run {
                self.isApplying = false
                self.pending = [:]
                self.refresh()
                self.banner = Self.describe(result)
            }
        }
    }

    // MARK: Asistente, exportar, importar y reaplicar

    func openWizard(seed: SetupFile? = nil) {
        wizard = WizardModel(root: self, seed: seed)
    }

    /// Lo que está activado y lo instalado ahora mismo, como archivo de configuración.
    func currentSetup() async -> SetupFile {
        refresh()
        await apps.refreshNow()
        let on = (catalog?.allTweaks ?? []).filter { status($0).isOn }.map(\.id)
        let installed = (apps.catalog?.allApps ?? []).filter { apps.status($0).isInstalled }.map(\.id)
        return SetupFile(macOS: SetupFile.currentMacOS, profile: nil, tweaks: on, apps: installed)
    }

    func exportSetup() {
        Task {
            let setup = await currentSetup()
            let panel = NSSavePanel()
            panel.title = "Exportar configuración"
            panel.message = "Se guardan los ajustes activados y las apps instaladas del catálogo. No incluye datos personales."
            panel.nameFieldStringValue = "Mi Mac.\(SetupFile.fileExtension)"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try setup.encoded().write(to: url, options: .atomic)
                banner = Banner(text: "Configuración exportada: \(setup.tweaks.count) ajustes y \(setup.apps.count) apps.\n\(url.lastPathComponent)",
                                isError: false)
            } catch {
                banner = Banner(text: error.localizedDescription, isError: true)
            }
        }
    }

    func importSetup() {
        let panel = NSOpenPanel()
        panel.title = "Importar configuración"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var setup = try SetupFile.decode(Data(contentsOf: url))
            let unknown = setup.unknown(tweakIDs: tweakIDs, appIDs: appIDs)
            setup.tweaks.removeAll { unknown.tweaks.contains($0) }
            setup.apps.removeAll { unknown.apps.contains($0) }
            openWizard(seed: setup)
            if !unknown.tweaks.isEmpty || !unknown.apps.isEmpty {
                wizard?.notice = "Se ignoran \(unknown.tweaks.count + unknown.apps.count) elementos que esta versión de MacOSUtil no conoce: "
                    + (unknown.tweaks + unknown.apps).joined(separator: ", ")
            }
        } catch {
            banner = Banner(text: error.localizedDescription, isError: true)
        }
    }

    var lastSetup: SetupFile? { LastSetup.load() }

    /// Vuelve a activar los ajustes de la última configuración aplicada (p. ej. tras actualizar macOS).
    func reapplyLast() {
        guard let last = LastSetup.load() else {
            banner = Banner(text: "Todavía no has aplicado ninguna configuración con el asistente.", isError: false)
            return
        }
        Task {
            let result = await applyTweaks(last.tweaks)
            await apps.refreshNow()
            let missing = (apps.catalog?.allApps ?? []).filter { last.apps.contains($0.id) && !apps.status($0).isInstalled }
            var b = result.changed.isEmpty && result.failed.isEmpty
                ? Banner(text: "Todo sigue como en la última configuración: no había nada que reaplicar.", isError: false)
                : Self.describe(result)
            if !missing.isEmpty {
                b = Banner(text: b.text + "\n\nFaltan \(missing.count) apps de esa configuración: \(missing.map(\.name).joined(separator: ", ")). "
                           + "Puedes instalarlas desde Apps.", isError: b.isError)
            }
            banner = b
        }
    }

    static func describe(_ r: BatchResult) -> Banner {
        if !r.failed.isEmpty {
            let lines = r.failed.map { "• \($0.error)" }.joined(separator: "\n")
            return Banner(text: "\(r.changed.count) cambios aplicados, \(r.failed.count) con error:\n\(lines)", isError: true)
        }
        var text = r.changed.count == 1 ? "1 cambio aplicado." : "\(r.changed.count) cambios aplicados."
        if !r.restarted.isEmpty { text += " Reiniciado: \(r.restarted.joined(separator: ", "))." }
        if r.needsLogout { text += " Algunos cambios se notarán del todo al cerrar sesión o reabrir las apps." }
        return Banner(text: text, isError: false)
    }
}
