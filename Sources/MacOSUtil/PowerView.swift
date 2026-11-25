import SwiftUI
import Privileged

/// Ajustes de energía (`pmset`). Los cambios se acumulan y se aplican juntos con una sola petición de contraseña.
@MainActor
@Observable
final class PowerModel {
    typealias Source = Power.Source

    let store = PowerStore()
    private(set) var values: [Source: [String: Int]] = [:]
    /// "<fuente>:<ajuste>" → valor deseado
    private(set) var pending: [String: Int] = [:]
    private(set) var isApplying = false
    /// Fuerza a SwiftUI a releer `store` tras cada cambio.
    private(set) var storeVersion = 0
    var banner: AppModel.Banner?

    /// Batería primero (en portátiles), después corriente.
    var sources: [Source] { [.battery, .charger].filter { values[$0] != nil } }

    func settings(for s: Source) -> [PowerSetting] {
        Power.settings.filter { values[s]?[$0.key] != nil }
    }

    func refresh() {
        Task.detached {
            let v = Power.read()
            await MainActor.run { self.values = v; self.storeVersion += 1 }
        }
    }

    private static func key(_ s: Source, _ k: String) -> String { "\(s.rawValue):\(k)" }

    func current(_ s: Source, _ k: String) -> Int? { values[s]?[k] }

    func value(_ s: Source, _ k: String) -> Int { pending[Self.key(s, k)] ?? current(s, k) ?? 0 }

    func set(_ s: Source, _ k: String, _ v: Int) {
        if v == current(s, k) { pending[Self.key(s, k)] = nil } else { pending[Self.key(s, k)] = v }
    }

    func isPending(_ s: Source, _ k: String) -> Bool { pending[Self.key(s, k)] != nil }

    func isManaged(_ s: Source, _ k: String) -> Bool {
        _ = storeVersion
        guard let o = store.original(s, k) else { return false }
        return o != current(s, k)
    }

    var managedCount: Int { _ = storeVersion; return store.count }

    func discard() { pending = [:] }

    func apply() {
        guard !pending.isEmpty, !isApplying else { return }
        let changes: [(Source, String, Int, Int?)] = pending.sorted { $0.key < $1.key }.compactMap { k, v in
            let parts = k.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let s = Source(rawValue: parts[0]) else { return nil }
            return (s, parts[1], v, current(s, parts[1]))
        }
        let commands = changes.map { AdminCommand.pmset(source: $0.0, setting: $0.1, value: $0.2) }
        run(commands, reason: commands.count == 1 ? L("MacOSUtil quiere cambiar 1 ajuste de energía.") : L("MacOSUtil quiere cambiar \(commands.count) ajustes de energía.")) { outcomes in
            for (c, o) in zip(changes, outcomes) where o.ok {
                if let old = c.3 { try? self.store.remember(c.0, c.1, value: old) }
            }
            self.pending = [:]
        }
    }

    func restoreAll() {
        let commands = store.restoreCommands()
        guard !commands.isEmpty else { return }
        run(commands, reason: L("MacOSUtil quiere devolver los ajustes de energía a sus valores originales.")) { outcomes in
            for (c, o) in zip(commands, outcomes) where o.ok {
                if case .pmset(let s, let k, _) = c { try? self.store.forget(s, k) }
            }
            self.pending = [:]
        }
    }

    private func run(_ commands: [AdminCommand], reason: String, onDone: @escaping @MainActor ([AdminRunner.Outcome]) -> Void) {
        isApplying = true
        Task.detached {
            let result: Result<[AdminRunner.Outcome], Error> = Result { try AdminRunner.run(commands, reason: reason) }
            let fresh = Power.read()
            await MainActor.run {
                self.isApplying = false
                switch result {
                case .success(let outcomes):
                    onDone(outcomes)
                    let bad = outcomes.filter { !$0.ok }
                    if !bad.isEmpty {
                        self.banner = .init(text: bad.map { "• \($0.command.argv.dropFirst().joined(separator: " ")): \($0.output)" }
                            .joined(separator: "\n"), isError: true)
                    }
                case .failure(AdminError.cancelled):
                    break
                case .failure(let error):
                    self.banner = .init(text: error.localizedDescription, isError: true)
                }
                self.values = fresh
                self.storeVersion += 1
            }
        }
    }
}

struct PowerView: View {
    @Environment(AppModel.self) private var root
    @State private var confirmRestore = false

    var body: some View {
        @Bindable var model = root.power
        Form {
            Section {
                Text("Cuándo duerme el Mac y qué hace mientras duerme. Cambiarlos pide tu contraseña de administrador una vez por cada vez que pulsas «Aplicar».")
                    .font(.uiCallout).foregroundStyle(.secondary)
                if model.managedCount > 0 {
                    HStack {
                        Text(model.managedCount == 1 ? L("MacOSUtil cambió 1 ajuste.") : L("MacOSUtil cambió \(model.managedCount) ajustes."))
                        Spacer()
                        Button("Restaurar originales") { confirmRestore = true }.disabled(model.isApplying)
                    }
                }
            }
            if model.sources.isEmpty {
                Section { Text("No se pudieron leer los ajustes de energía (pmset).").foregroundStyle(.secondary) }
            }
            ForEach(model.sources, id: \.self) { src in
                Section(model.sources.count > 1 ? (src == .battery ? L("Con batería") : L("Conectado a la corriente")) : L("Energía")) {
                    ForEach(model.settings(for: src)) { setting in
                        PowerRow(source: src, setting: setting)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Energía")
        .onAppear { model.refresh() }
        .safeAreaInset(edge: .bottom) {
            if !model.pending.isEmpty || model.isApplying {
                HStack {
                    if model.isApplying {
                        ProgressView().controlSize(.small)
                        Text("Aplicando…")
                    } else {
                        Text(model.pending.count == 1 ? L("1 cambio sin aplicar") : L("\(model.pending.count) cambios sin aplicar"))
                    }
                    Spacer()
                    Button("Descartar") { model.discard() }.disabled(model.isApplying)
                    Button("Aplicar") { model.apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isApplying)
                        .help("macOS pedirá tu contraseña de administrador")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
            }
        }
        .confirmationDialog("¿Restaurar los ajustes de energía?", isPresented: $confirmRestore) {
            Button("Restaurar \(model.managedCount)") { model.restoreAll() }
        } message: {
            Text("Vuelven a los valores que tenían antes de cambiarlos con MacOSUtil. macOS pedirá tu contraseña.")
        }
    }
}

private struct PowerRow: View {
    @Environment(AppModel.self) private var root
    let source: Power.Source
    let setting: PowerSetting

    var body: some View {
        let model = root.power
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(setting.title)
                    if model.isPending(source, setting.key) { Tag(text: L("Sin aplicar"), color: .blue) }
                    else if model.isManaged(source, setting.key) { Tag(text: L("Cambiado por MacOSUtil"), color: .green) }
                }
                Text(setting.description).font(.uiCaption).foregroundStyle(.secondary)
                if let caveat = setting.caveat {
                    Text(caveat).font(.uiCaption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            control(model)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func control(_ model: PowerModel) -> some View {
        switch setting.kind {
        case .toggle:
            Toggle("", isOn: Binding(get: { model.value(source, setting.key) != 0 },
                                     set: { model.set(source, setting.key, $0 ? 1 : 0) }))
                .toggleStyle(.switch).labelsHidden().disabled(model.isApplying)
        case .minutes(let options):
            let current = model.value(source, setting.key)
            let all = options.contains(current) ? options : (options + [current]).sorted()
            Picker("", selection: Binding(get: { current }, set: { model.set(source, setting.key, $0) })) {
                ForEach(all, id: \.self) { m in
                    Text(m == 0 ? L("Nunca") : (m < 60 || m % 60 != 0 ? "\(m) min" : "\(m / 60) h")).tag(m)
                }
            }
            .labelsHidden().frame(width: 110).disabled(model.isApplying)
        }
    }
}

// MARK: - Spotlight (en «Espacio en disco»)

@MainActor
@Observable
final class SpotlightModel {
    private(set) var volumes: [Spotlight.Volume] = []
    private(set) var busy: Set<String> = []
    var banner: AppModel.Banner?

    func refresh() {
        Task.detached {
            let v = Spotlight.volumes()
            await MainActor.run { self.volumes = v }
        }
    }

    func setIndexing(_ v: Spotlight.Volume, _ on: Bool) {
        run(v, .spotlightIndexing(volume: v.path, enabled: on),
            reason: on ? L("MacOSUtil quiere activar la indexación de Spotlight en «\(v.name)».") : L("MacOSUtil quiere desactivar la indexación de Spotlight en «\(v.name)»."))
    }

    func rebuild(_ v: Spotlight.Volume) {
        run(v, .spotlightRebuild(volume: v.path), reason: L("MacOSUtil quiere reconstruir el índice de Spotlight de «\(v.name)».")) {
            self.banner = .init(text: L("Spotlight está reconstruyendo el índice de «\(v.name)». Puede tardar un rato y usar CPU mientras tanto."), isError: false)
        }
    }

    private func run(_ v: Spotlight.Volume, _ command: AdminCommand, reason: String, onOK: (@MainActor () -> Void)? = nil) {
        guard !busy.contains(v.id) else { return }
        busy.insert(v.id)
        Task.detached {
            let result: Result<[AdminRunner.Outcome], Error> = Result { try AdminRunner.run([command], reason: reason) }
            let fresh = Spotlight.volumes()
            await MainActor.run {
                self.busy.remove(v.id)
                self.volumes = fresh
                switch result {
                case .success(let o) where o.allSatisfy(\.ok): onOK?()
                case .success(let o): self.banner = .init(text: o.map(\.output).joined(separator: "\n"), isError: true)
                case .failure(AdminError.cancelled): break
                case .failure(let e): self.banner = .init(text: e.localizedDescription, isError: true)
                }
            }
        }
    }
}

struct SpotlightSection: View {
    @Bindable var model: SpotlightModel
    @State private var confirmOff: Spotlight.Volume?

    var body: some View {
        Section {
            ForEach(model.volumes) { v in
                HStack {
                    Image(systemName: v.path == "/" ? "internaldrive" : "externaldrive").foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(v.name)
                        Text(v.detail).font(.uiCaption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy.contains(v.id) {
                        ProgressView().controlSize(.small)
                    } else if let on = v.indexing {
                        if on { Button("Reconstruir índice") { model.rebuild(v) }.controlSize(.small) }
                        Toggle("", isOn: Binding(get: { on }, set: { new in
                            if new { model.setIndexing(v, true) } else { confirmOff = v }
                        }))
                        .toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        } header: {
            Text("Indexación de Spotlight")
        } footer: {
            Text("Desactivarla en discos de copias o de archivo ahorra CPU y escrituras. En el disco de arranque, Spotlight, Mail y Ajustes dejan de encontrar cosas. Cada cambio pide tu contraseña.").footerStyle()
        }
        .onAppear { model.refresh() }
        .confirmationDialog("¿Desactivar la indexación de «\(confirmOff?.name ?? "")»?",
                            isPresented: Binding(get: { confirmOff != nil }, set: { if !$0 { confirmOff = nil } }),
                            presenting: confirmOff) { v in
            Button("Desactivar", role: .destructive) { model.setIndexing(v, false) }
        } message: { v in
            Text(v.path == "/"
                 ? L("Es el disco de arranque: la búsqueda de Spotlight, de Mail y de muchas apps dejará de funcionar bien.")
                 : L("Spotlight dejará de buscar en este disco. Puedes volver a activarla cuando quieras."))
        }
    }
}
