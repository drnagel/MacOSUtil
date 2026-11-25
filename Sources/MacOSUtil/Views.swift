import SwiftUI
import TweakEngine

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmRevertAll = false

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            Group {
                if let error = app.loadError {
                    ContentUnavailableView("No se pudo cargar el catálogo", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    switch app.selection {
                    case .category(let id):
                        if let c = app.catalog?.categories.first(where: { $0.id == id }) { CategoryView(category: c) }
                    case .apps:
                        AppsView()
                    case .disk:
                        DiskView()
                    case nil:
                        ContentUnavailableView("Elige una sección", systemImage: "sidebar.left")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { PendingBar() }
        }
        .toolbar {
            ToolbarItem {
                Button { app.refresh(); app.apps.refresh() } label: { Label("Volver a comprobar", systemImage: "arrow.clockwise") }
                    .help("Vuelve a leer el estado actual de cada ajuste (⌘R)")
            }
            ToolbarItem {
                Button { confirmRevertAll = true } label: {
                    Label("Restaurar todo", systemImage: "arrow.uturn.backward")
                }
                .disabled(app.managedCount == 0 || app.isApplying)
                .help("Deja todo como estaba antes de usar MacOSUtil")
            }
        }
        .confirmationDialog("¿Restaurar todos los ajustes?", isPresented: $confirmRevertAll) {
            Button("Restaurar \(app.managedCount) ajustes", role: .destructive) { app.revertAll() }
        } message: {
            Text("Cada ajuste que cambió MacOSUtil vuelve al valor que tenía antes.")
        }
        .alert(item: $app.banner) { b in
            Alert(title: Text(b.isError ? "Hubo problemas" : "Listo"), message: Text(b.text))
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            Section("Ajustes") {
                ForEach(app.catalog?.categories ?? []) { c in
                    Label(c.title, systemImage: c.icon)
                        .badge(Text("\(app.onCount(c))/\(c.tweaks.count)"))
                        .tag(SidebarItem.category(c.id))
                }
            }
            Section("Sistema") {
                Label("Apps", systemImage: "square.grid.2x2")
                    .badge(app.apps.installedCount)   // 0 (o aún sin consultar) no muestra contador
                    .tag(SidebarItem.apps)
                Label("Espacio en disco", systemImage: "internaldrive").tag(SidebarItem.disk)
            }
        }
    }
}

struct CategoryView: View {
    @Environment(AppModel.self) private var app
    let category: TweakCategory

    var body: some View {
        Form {
            if !category.tweaks.isEmpty {
                Section {
                    ForEach(category.tweaks) { TweakRow(tweak: $0) }
                } header: {
                    Text("\(app.onCount(category)) de \(category.tweaks.count) activados")
                }
            }
            if !category.links.isEmpty {
                Section {
                    ForEach(category.links) { SettingsLinkRow(link: $0) }
                } header: {
                    Text("Se cambian en Ajustes del Sistema")
                } footer: {
                    Text("macOS no deja cambiar estas opciones desde otras apps. El botón abre el panel exacto.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(category.title)
    }
}

struct SettingsLinkRow: View {
    let link: SettingsPaneLink

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(link.title)
                Text(link.description).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                if let url = link.settingsURL { NSWorkspace.shared.open(url) }
            } label: {
                Label("Abrir", systemImage: "arrow.up.forward.app")
            }
            .controlSize(.small)
            .disabled(link.settingsURL == nil)
        }
        .padding(.vertical, 3)
    }
}

struct TweakRow: View {
    @Environment(AppModel.self) private var app
    let tweak: Tweak
    @State private var showDetails = false

    var body: some View {
        let status = app.status(tweak)
        let pending = app.pending[tweak.id] != nil
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { app.isOn(tweak) }, set: { app.set(tweak, on: $0) })) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(tweak.title)
                        if pending { Tag(text: "Pendiente", color: .accentColor) }
                        if status == .partial { Tag(text: "Parcial", color: .orange) }
                        if tweak.risk > .low { Tag(text: "Riesgo \(tweak.risk.title.lowercased())", color: .orange) }
                        if tweak.logout { Tag(text: "Cerrar sesión", color: .secondary) }
                        if app.engine.isManaged(tweak) { Tag(text: "Cambiado por MacOSUtil", color: .green) }
                    }
                    Text(tweak.description).font(.callout).foregroundStyle(.secondary)
                    if case .unavailable(let why) = status {
                        Text(why).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .toggleStyle(.switch)
            .disabled(isUnavailable(status) || app.isApplying)

            Button {
                withAnimation(.snappy(duration: 0.15)) { showDetails.toggle() }
            } label: {
                Label("Qué cambia", systemImage: showDetails ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if showDetails {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(app.engine.currentValues(tweak).enumerated()), id: \.offset) { _, item in
                        Text(item.action.command)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Ahora: \(describe(item.stored))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !tweak.restart.isEmpty {
                        Text("Reinicia: \(tweak.restart.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(.vertical, 4)
    }

    private func isUnavailable(_ s: TweakStatus) -> Bool {
        if case .unavailable = s { return true }
        return false
    }

    private func describe(_ s: Preferences.Stored) -> String {
        switch s {
        case .absent: "sin definir (valor de fábrica)"
        case .value(let v): v.description
        case .unsupported(let type): "valor de tipo \(type)"
        }
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Barra inferior con los cambios marcados y el botón de aplicar.
struct PendingBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if !app.pending.isEmpty || app.isApplying {
            HStack(spacing: 12) {
                if app.isApplying {
                    ProgressView().controlSize(.small)
                    Text("Aplicando…")
                } else {
                    Image(systemName: "pencil.circle.fill").foregroundStyle(Color.accentColor)
                    Text(app.pending.count == 1 ? "1 cambio sin aplicar" : "\(app.pending.count) cambios sin aplicar")
                    if app.pendingRequiresLogout {
                        Text("· alguno requiere cerrar sesión").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Descartar") { app.discardPending() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(app.isApplying)
                Button("Aplicar") { app.applyPending() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(app.isApplying)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)
        }
    }
}

/// Espacio en disco: un resumen y el acceso a DiskTree, que es quien analiza y limpia.
struct DiskView: View {
    @State private var volume = VolumeInfo.current()
    @State private var diskTree = DiskTreeLink.appURL

    var body: some View {
        Form {
            Section("Disco de arranque") {
                LabeledContent("Disponible", value: VolumeInfo.format(volume.available))
                LabeledContent("Capacidad", value: VolumeInfo.format(volume.total))
                ProgressView(value: volume.usedFraction)
                    .tint(volume.usedFraction > 0.9 ? .red : .accentColor)
            }
            Section {
                if let url = diskTree {
                    LabeledContent("DiskTree") {
                        Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Button { DiskTreeLink.open() } label: {
                        Label("Abrir DiskTree", systemImage: "arrow.up.forward.app")
                    }
                } else {
                    Text("DiskTree no está instalada.")
                    Text("En ~/ClaudeCode/DiskTreeMac ejecuta Scripts/build.sh --install")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: {
                Text("Analizar y liberar espacio")
            } footer: {
                Text("DiskTree analiza qué ocupa espacio y limpia cachés, proyectos, apps y duplicados.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Espacio en disco")
        .onAppear {
            volume = .current()
            diskTree = DiskTreeLink.appURL
        }
    }
}
