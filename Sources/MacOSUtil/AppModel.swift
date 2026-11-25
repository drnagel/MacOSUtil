import SwiftUI
import TweakEngine

enum SidebarItem: Hashable {
    case category(String)
    case apps
    case disk
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let engine = TweakEngine()
    let apps = AppsModel()
    private(set) var catalog: Catalog?
    private(set) var loadError: String?
    private(set) var statuses: [String: TweakStatus] = [:]
    /// Cambios marcados que todavía no se aplicaron: id → estado deseado (activado o no).
    private(set) var pending: [String: Bool] = [:]
    private(set) var isApplying = false
    var selection: SidebarItem?
    var banner: Banner?

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
        } catch {
            catalog = nil
            loadError = error.localizedDescription
        }
        refresh()
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

    private static func describe(_ r: BatchResult) -> Banner {
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
