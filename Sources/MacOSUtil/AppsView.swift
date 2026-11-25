import SwiftUI
import AppCatalog

struct AppsView: View {
    @Environment(AppModel.self) private var root
    @State private var confirmAdoptAll = false
    private var model: AppsModel { root.apps }

    var body: some View {
        @Bindable var model = model
        Form {
            if !model.brewInstalled {
                Section {
                    Label("Homebrew no está instalado", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Las apps se instalan con Homebrew. Descarga el instalador oficial (.pkg) desde GitHub, ábrelo y, cuando termine, pulsa «Volver a comprobar».")
                        .font(.uiCallout).foregroundStyle(.secondary)
                    HStack {
                        Button("Abrir la página del instalador") { NSWorkspace.shared.open(Homebrew.installerPage) }
                        Button("Volver a comprobar") { model.refresh() }
                    }
                }
            }
            if let error = model.loadError {
                Section { Text(error).foregroundStyle(.red) }
            }
            if !model.outdated.isEmpty {
                Section {
                    HStack {
                        Label("\(model.outdated.count) con actualización disponible", systemImage: "arrow.down.circle")
                        Spacer()
                        Button("Actualizar todas") { model.upgrade(model.outdated) }.disabled(model.isRunning)
                    }
                }
            }
            if !model.adoptable.isEmpty {
                Section {
                    HStack {
                        Label("\(model.adoptable.count) instaladas fuera de Homebrew", systemImage: "shippingbox")
                        Spacer()
                        Button("Pasar todas a Homebrew") { confirmAdoptAll = true }.disabled(model.isRunning)
                    }
                } footer: {
                    Text("Así se actualizan desde aquí con «Actualizar», como las demás. Tus ajustes y datos se conservan.").footerStyle()
                }
            }
            ForEach(model.catalog?.categories ?? []) { c in
                Section {
                    ForEach(c.apps) { AppRow(app: $0) }
                } header: {
                    Label(c.title, systemImage: c.icon)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Apps")
        .overlay(alignment: .top) {
            if model.isChecking && model.statuses.isEmpty {
                ProgressView("Consultando Homebrew…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 40)
            }
        }
        .safeAreaInset(edge: .bottom) { AppsBar() }
        .sheet(isPresented: $model.showLog) { LogSheet() }
        .onAppear { if model.statuses.isEmpty { model.refresh() } }
        .confirmationDialog("¿Pasar \(model.adoptable.count) apps a Homebrew?", isPresented: $confirmAdoptAll) {
            Button("Pasar \(model.adoptable.count) a Homebrew") { model.adopt(model.adoptable) }
        } message: {
            Text(AdoptText.summary(model.adoptable, model: model))
        }
    }
}

/// Textos de confirmación para pasar apps a Homebrew.
@MainActor
enum AdoptText {
    static func line(_ a: AppEntry, _ plan: Adopt.Plan, open: Bool) -> String {
        var t: String
        switch plan.mode {
        case .adopt:
            t = L("\(a.name): tu copia (\(plan.localVersion ?? "?")) es la misma que la de Homebrew; se adopta sin descargar nada.")
        case .replace:
            t = L("\(a.name): se descarga la \(plan.caskVersion) y sustituye a tu copia (\(plan.localVersion ?? L("versión desconocida"))).")
        }
        if plan.needsTerminal { t += " " + L("Se hace en Terminal porque pide tu contraseña.") }
        if open { t += " " + L("Está abierta: ciérrala antes.") }
        return t
    }

    static func summary(_ apps: [AppEntry], model: AppsModel) -> String {
        let lines = apps.compactMap { a in model.adoptPlan(a).map { "• " + line(a, $0, open: model.isOpen(a)) } }
        return lines.joined(separator: "\n") + "\n\n" + L("Tus ajustes y datos de ~/Library se conservan.")
    }
}

struct AppRow: View {
    @Environment(AppModel.self) private var root
    let app: AppEntry
    @State private var confirmUninstall = false
    @State private var confirmAdopt = false

    var body: some View {
        let model = root.apps
        let status = model.status(app)
        HStack(alignment: .top, spacing: 10) {
            if app.cask != nil {
                Toggle("", isOn: Binding(get: { model.selected.contains(app.id) }, set: { _ in model.toggle(app) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!model.canSelect(app) && !model.selected.contains(app.id))
                    .opacity(status.isInstalled ? 0.3 : 1)
            } else {
                Image(systemName: "bag").foregroundStyle(.secondary).frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name)
                    StatusTag(status: status)
                    if model.needsAdmin(app) { Tag(text: L("Pide contraseña"), color: .secondary) }
                    if let v = model.requiredMacOS(app) { Tag(text: L("Requiere macOS \(v) o posterior"), color: .red) }
                    if app.appStore != nil { Tag(text: "App Store", color: .blue) }
                }
                Text(app.description).font(.uiCallout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            actions(status)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(app) }
        .confirmationDialog("¿Pasar \(app.name) a Homebrew?", isPresented: $confirmAdopt) {
            Button(model.adoptPlan(app)?.mode == .adopt ? L("Adoptar") : L("Sustituir por la de Homebrew")) { model.adopt([app]) }
        } message: {
            if let plan = model.adoptPlan(app) {
                Text(AdoptText.line(app, plan, open: model.isOpen(app)) + " " + L("Tus ajustes y datos de ~/Library se conservan."))
            }
        }
        .confirmationDialog("¿Desinstalar \(app.name)?", isPresented: $confirmUninstall) {
            Button("Desinstalar", role: .destructive) { model.uninstall(app) }
        } message: {
            Text("Homebrew borra la app de /Applications. Sus preferencias y datos se conservan.")
        }
    }

    @ViewBuilder
    private func actions(_ status: AppStatus) -> some View {
        let model = root.apps
        HStack(spacing: 6) {
            switch status {
            case .brew(_, let outdated):
                if outdated {
                    Button("Actualizar") { model.upgrade([app]) }.disabled(model.isRunning)
                }
                Button("Desinstalar") { confirmUninstall = true }.disabled(model.isRunning)
            case .manual(let path):
                Button("Mostrar") { model.reveal(path) }
                if model.adoptPlan(app) != nil {
                    Button("Pasar a Homebrew") { confirmAdopt = true }.disabled(model.isRunning)
                }
            case .notInstalled where app.appStore != nil:
                Button("Ver en App Store") { model.openAppStore(app) }
            default:
                EmptyView()
            }
        }
        .controlSize(.small)
    }
}

struct StatusTag: View {
    let status: AppStatus

    var body: some View {
        switch status {
        case .brew(let v, let outdated):
            Tag(text: outdated ? L("Actualización disponible") : L("Instalada · \(v)"), color: outdated ? .orange : .green)
        case .manual:
            Tag(text: L("Instalada fuera de Homebrew"), color: .teal)
        case .unavailable:
            Tag(text: L("No disponible en Homebrew"), color: .red)
        case .notInstalled, .unknown:
            EmptyView()
        }
    }
}

/// Barra inferior: apps marcadas, botón Instalar y progreso.
struct AppsBar: View {
    @Environment(AppModel.self) private var root

    var body: some View {
        let model = root.apps
        if model.isRunning || !model.selected.isEmpty {
            HStack(spacing: 12) {
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.currentTask ?? L("Trabajando…"))
                        Text(model.log.last ?? "").font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    Text(model.selected.count == 1 ? L("1 app seleccionada") : L("\(model.selected.count) apps seleccionadas"))
                }
                Spacer()
                Button("Registro") { model.showLog = true }.disabled(model.log.isEmpty)
                if !model.isRunning {
                    Button("Quitar selección") { model.selected = [] }
                    Button("Instalar") { model.installSelected() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)
        }
    }
}

struct LogSheet: View {
    @Environment(AppModel.self) private var root
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Registro de Homebrew").font(.uiHeadline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(root.apps.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.uiMono).textSelection(.enabled).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: root.apps.log.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
            .padding(8)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            HStack { Spacer(); Button("Cerrar") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(width: 640, height: 420)
    }
}
