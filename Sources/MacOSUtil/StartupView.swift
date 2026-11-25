import SwiftUI
import Startup

@MainActor
@Observable
final class StartupModel {
    let controller = StartupController()
    private(set) var items: [StartupItem] = []
    private(set) var isScanning = false
    private(set) var busy: Set<String> = []
    /// Fuerza a SwiftUI a releer `controller.records` tras cada cambio.
    private(set) var recordsVersion = 0
    var banner: AppModel.Banner?

    var running: [StartupItem] { items.filter(\.isRunning) }
    var runningMemory: Int64 { running.reduce(0) { $0 + ($1.memory ?? 0) } }
    var managedCount: Int { _ = recordsVersion; return controller.records.count }

    func items(in scope: StartupItem.Scope) -> [StartupItem] {
        items.filter { $0.scope == scope }.sorted { ($0.displayName, $0.label) < ($1.displayName, $1.label) }
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        Task.detached {
            let found = StartupScanner.scan()
            await MainActor.run {
                self.items = found
                self.isScanning = false
                self.recordsVersion += 1
            }
        }
    }

    func setEnabled(_ item: StartupItem, _ enabled: Bool) {
        guard !busy.contains(item.id) else { return }
        busy.insert(item.id)
        let controller = self.controller
        Task.detached {
            let errorText: String?
            do {
                if enabled { try controller.enable(item) } else { try controller.disable(item) }
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
            // launchd tarda un instante en arrancar o parar el proceso.
            try? await Task.sleep(for: .milliseconds(400))
            await MainActor.run {
                self.busy.remove(item.id)
                if let errorText { self.banner = .init(text: errorText, isError: true) }
                self.refresh()
            }
        }
    }

    func enableAll() {
        let controller = self.controller
        Task.detached {
            let errors = controller.enableAll()
            try? await Task.sleep(for: .milliseconds(400))
            await MainActor.run {
                if !errors.isEmpty {
                    self.banner = .init(text: errors.map { "• \($0.label): \($0.error)" }.joined(separator: "\n"), isError: true)
                } else {
                    self.banner = .init(text: "Se reactivó todo lo que había desactivado MacOSUtil.", isError: false)
                }
                self.refresh()
            }
        }
    }

    func isManaged(_ item: StartupItem) -> Bool { _ = recordsVersion; return controller.isManaged(item) }
}

struct StartupView: View {
    @Environment(AppModel.self) private var root
    @State private var confirmEnableAll = false

    private static let loginItemsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    var body: some View {
        @Bindable var model = root.startup
        Form {
            Section {
                HStack(spacing: 24) {
                    Stat(value: "\(model.items.count)", label: "servicios de terceros")
                    Stat(value: "\(model.running.count)", label: "en marcha ahora")
                    Stat(value: ByteCountFormatter.string(fromByteCount: model.runningMemory, countStyle: .memory),
                         label: "de memoria en uso")
                    Spacer()
                    if model.isScanning { ProgressView().controlSize(.small) }
                }
                if model.managedCount > 0 {
                    HStack {
                        Text("MacOSUtil desactivó \(model.managedCount) \(model.managedCount == 1 ? "servicio" : "servicios").")
                        Spacer()
                        Button("Reactivar todo") { confirmEnableAll = true }
                    }
                }
                HStack {
                    Text("Las apps que se abren al iniciar sesión se gestionan en Ajustes del Sistema.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Abrir Ítems de inicio") { NSWorkspace.shared.open(Self.loginItemsURL) }.controlSize(.small)
                }
            }

            ForEach(StartupItem.Scope.allCases, id: \.self) { scope in
                let group = model.items(in: scope)
                if !group.isEmpty {
                    Section {
                        ForEach(group) { StartupRow(item: $0) }
                    } header: {
                        Text(scope.title)
                    } footer: {
                        Text(scope.subtitle).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if model.items.isEmpty && !model.isScanning {
                Section { Text("No hay servicios de terceros que arranquen solos.").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Arranque")
        .onAppear { if model.items.isEmpty { model.refresh() } }
        .confirmationDialog("¿Reactivar todo?", isPresented: $confirmEnableAll) {
            Button("Reactivar \(model.managedCount)") { model.enableAll() }
        } message: {
            Text("Los servicios que desactivó MacOSUtil vuelven a arrancar ahora y al iniciar sesión.")
        }
        .alert(item: $model.banner) { b in
            Alert(title: Text(b.isError ? "Hubo problemas" : "Listo"), message: Text(b.text))
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct StartupRow: View {
    @Environment(AppModel.self) private var root
    let item: StartupItem
    @State private var confirmDisable = false

    var body: some View {
        let model = root.startup
        let busy = model.busy.contains(item.id)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                    if item.disabled {
                        Tag(text: "Desactivado", color: .orange)
                    } else if let pid = item.pid {
                        Tag(text: "En marcha" + (item.memory.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? ""),
                            color: .green)
                            .help("PID \(pid)")
                    } else {
                        Tag(text: item.loaded ? "En espera" : "No cargado", color: .secondary)
                    }
                    if item.isOrphan { Tag(text: "Resto: el programa ya no existe", color: .red) }
                    else if item.ownerAppMissing && item.scope != .daemon { Tag(text: "No se encontró su app", color: .yellow) }
                    if model.isManaged(item) { Tag(text: "Cambiado por MacOSUtil", color: .green) }
                }
                Text(item.label).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                if !item.schedule.isEmpty {
                    Text(item.schedule.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                if let program = item.program {
                    Text(program).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if let plist = item.plistPath {
                    Button("Mostrar") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plist)]) }
                        .controlSize(.small)
                }
                if busy {
                    ProgressView().controlSize(.small)
                } else if item.scope.canToggle {
                    Toggle("", isOn: Binding(
                        get: { !item.disabled },
                        set: { on in if on { model.setEnabled(item, true) } else { confirmDisable = true } }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help(item.disabled ? "Reactivar" : "Desactivar")
                }
            }
        }
        .padding(.vertical, 3)
        .confirmationDialog("¿Desactivar \(item.displayName)?", isPresented: $confirmDisable) {
            Button("Desactivar", role: .destructive) { model.setEnabled(item, false) }
        } message: {
            Text("Se detiene ahora y no vuelve a arrancar al iniciar sesión. El archivo no se borra: puedes reactivarlo cuando quieras."
                 + (item.isOrphan || item.ownerAppMissing ? "" : " La app a la que pertenece puede dejar de funcionar del todo."))
        }
    }
}
