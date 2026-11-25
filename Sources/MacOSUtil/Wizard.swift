import SwiftUI
import TweakEngine
import AppCatalog
import Profiles

/// Estado del asistente de configuración: perfil → ajustes → apps → resumen → aplicar.
@MainActor
@Observable
final class WizardModel: Identifiable {
    enum Step: Int, CaseIterable {
        case profile, tweaks, apps, summary, applying, done

        var title: String {
            switch self {
            case .profile: "Perfil"
            case .tweaks: "Ajustes"
            case .apps: "Apps"
            case .summary: "Resumen"
            case .applying, .done: "Aplicar"
            }
        }
    }

    let id = UUID()
    unowned let root: AppModel
    var step: Step = .profile
    /// Perfil elegido (nil si se parte de un archivo importado o desde cero).
    private(set) var profile: Profile?
    private(set) var importedFrom: SetupFile?
    var tweakSelection: Set<String> = []
    var appSelection: Set<String> = []
    /// Aviso que se muestra arriba (p. ej. elementos ignorados al importar).
    var notice: String?

    private(set) var tweakResult: BatchResult?
    private(set) var appOutcome: AppsModel.InstallOutcome?

    init(root: AppModel, seed: SetupFile?) {
        self.root = root
        if let seed {
            importedFrom = seed
            tweakSelection = Set(seed.tweaks)
            appSelection = Set(seed.apps)
            step = .tweaks
        }
        root.refresh()
        if root.apps.statuses.isEmpty { root.apps.refresh() }
    }

    var sourceTitle: String {
        if let profile { return profile.title }
        if importedFrom != nil { return "Configuración importada" }
        return "Personalizado"
    }

    func choose(_ p: Profile?) {
        profile = p
        importedFrom = nil
        tweakSelection = Set(p?.tweaks ?? [])
        appSelection = Set(p?.apps ?? [])
        step = .tweaks
    }

    // MARK: Lo que se va a hacer

    var tweaksToApply: [Tweak] {
        (root.catalog?.allTweaks ?? []).filter { tweakSelection.contains($0.id) && !root.status($0).isOn && !root.isUnavailable($0) }
    }

    var tweaksAlreadyOn: Int {
        (root.catalog?.allTweaks ?? []).filter { tweakSelection.contains($0.id) && root.status($0).isOn }.count
    }

    var appsToInstall: [AppEntry] {
        (root.apps.catalog?.allApps ?? []).filter { appSelection.contains($0.id) && isInstallable($0) }
    }

    var appsAlreadyInstalled: Int {
        (root.apps.catalog?.allApps ?? []).filter { appSelection.contains($0.id) && root.apps.status($0).isInstalled }.count
    }

    func isInstallable(_ a: AppEntry) -> Bool {
        a.cask != nil && root.apps.brewInstalled && root.apps.status(a) == .notInstalled
    }

    var restarts: [String] {
        var r: [String] = []
        for t in tweaksToApply { for p in t.restart where !r.contains(p) { r.append(p) } }
        return r
    }

    var needsLogout: Bool { tweaksToApply.contains(where: \.logout) }

    var appsNeedingPassword: [AppEntry] { appsToInstall.filter { root.apps.needsAdmin($0) } }

    var hasWork: Bool { !tweaksToApply.isEmpty || !appsToInstall.isEmpty }

    // MARK: Navegación

    func next() {
        guard let i = Step.allCases.firstIndex(of: step), step < .summary else { return }
        step = Step.allCases[i + 1]
    }

    func back() {
        switch step {
        case .tweaks: step = importedFrom == nil ? .profile : .tweaks
        case .apps: step = .tweaks
        case .summary: step = .apps
        default: break
        }
    }

    // MARK: Aplicar

    func apply() {
        guard step == .summary else { return }
        step = .applying
        let tweaks = Array(tweakSelection)
        let apps = appsToInstall
        Task {
            tweakResult = await root.applyTweaks(tweaks)
            appOutcome = await root.apps.install(apps)
            // Se guarda lo elegido (no solo lo que faltaba) para poder reaplicarlo entero.
            try? LastSetup.save(SetupFile(macOS: SetupFile.currentMacOS, profile: profile?.id,
                                          tweaks: tweaks, apps: Array(appSelection)))
            step = .done
        }
    }
}

extension WizardModel.Step: Comparable {
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - Vista

struct WizardView: View {
    @Bindable var model: WizardModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.step {
                case .profile: ProfileStep(model: model)
                case .tweaks: TweakStep(model: model)
                case .apps: AppStep(model: model)
                case .summary: SummaryStep(model: model)
                case .applying: ApplyingStep(model: model)
                case .done: DoneStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 780, height: 600)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "wand.and.stars").font(.uiTitle2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Asistente de configuración").font(.uiHeadline)
                Text(model.step == .profile ? "Elige un punto de partida" : model.sourceTitle)
                    .font(.uiCallout).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach([WizardModel.Step.profile, .tweaks, .apps, .summary, .applying], id: \.self) { s in
                    let current = model.step == s || (s == .applying && model.step == .done)
                    let passed = model.step > s
                    Text(s.title)
                        .font(.uiCaption.weight(current ? .semibold : .regular))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(current ? Color.accentColor.opacity(0.2) : .clear, in: Capsule())
                        .foregroundStyle(current ? Color.accentColor : (passed ? .primary : .secondary))
                }
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if model.step == .profile || model.step == .tweaks || model.step == .apps || model.step == .summary {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Spacer()
            switch model.step {
            case .profile:
                Button("Empezar desde cero") { model.choose(nil) }
            case .tweaks, .apps:
                if !(model.step == .tweaks && model.importedFrom != nil) {
                    Button("Atrás") { model.back() }
                }
                Button("Siguiente") { model.next() }.keyboardShortcut(.defaultAction)
            case .summary:
                Button("Atrás") { model.back() }
                Button("Aplicar") { model.apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasWork)
            case .applying:
                ProgressView().controlSize(.small)
            case .done:
                Button("Cerrar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

private struct ProfileStep: View {
    let model: WizardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cada perfil marca un conjunto de ajustes y apps. En los siguientes pasos puedes quitar o añadir lo que quieras; nada se aplica hasta el resumen.")
                    .font(.uiCallout).foregroundStyle(.secondary)
                if let error = model.root.profileError {
                    Text(error).foregroundStyle(.red).font(.uiCallout)
                }
                // Grid (no LazyVGrid) para que las dos tarjetas de cada fila tengan la misma altura.
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(Array(stride(from: 0, to: model.root.profiles.count, by: 2)), id: \.self) { i in
                        GridRow {
                            card(model.root.profiles[i])
                            if i + 1 < model.root.profiles.count { card(model.root.profiles[i + 1]) }
                            else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func card(_ p: Profile) -> some View {
        Button { model.choose(p) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: p.icon).font(.uiTitle3).foregroundStyle(Color.accentColor).frame(width: 26)
                    Text(p.title).font(.uiHeadline)
                    Spacer()
                    Text("\(p.tweaks.count) ajustes · \(p.apps.count) apps").font(.uiCaption).foregroundStyle(.tertiary)
                }
                Text(p.description).font(.uiCallout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

private struct TweakStep: View {
    @Bindable var model: WizardModel

    var body: some View {
        Form {
            if let notice = model.notice {
                Section { Label(notice, systemImage: "info.circle").font(.uiCallout) }
            }
            Section {
                Text("Marca lo que quieras activar. Lo que ya está activado en este Mac aparece marcado y no se toca. El asistente solo activa: para desactivar algo, usa la sección de ajustes.")
                    .font(.uiCallout).foregroundStyle(.secondary)
            }
            ForEach(model.root.catalog?.categories ?? []) { c in
                if !c.tweaks.isEmpty {
                    Section(c.title) {
                        ForEach(c.tweaks) { t in
                            let already = model.root.status(t).isOn
                            let unavailable = model.root.isUnavailable(t)
                            Toggle(isOn: Binding(
                                get: { already || model.tweakSelection.contains(t.id) },
                                set: { on in if on { model.tweakSelection.insert(t.id) } else { model.tweakSelection.remove(t.id) } })) {
                                HStack(spacing: 6) {
                                    Text(t.title)
                                    if already { Tag(text: "Ya activado", color: .green) }
                                    if t.risk > .low { Tag(text: "Riesgo \(t.risk.title.lowercased())", color: .orange) }
                                    if t.logout { Tag(text: "Cerrar sesión", color: .secondary) }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(already || unavailable)
                            .help(t.description)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppStep: View {
    @Bindable var model: WizardModel

    var body: some View {
        let apps = model.root.apps
        Form {
            if !apps.brewInstalled {
                Section {
                    Label("Homebrew no está instalado: no se puede instalar ninguna app desde aquí. Instálalo desde la sección Apps y vuelve al asistente.",
                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } else if apps.isChecking && apps.statuses.isEmpty {
                Section { HStack { ProgressView().controlSize(.small); Text("Consultando Homebrew…") } }
            }
            ForEach(apps.catalog?.categories ?? []) { c in
                Section(c.title) {
                    ForEach(c.apps) { a in
                        let installed = apps.status(a).isInstalled
                        let selectable = model.isInstallable(a)
                        Toggle(isOn: Binding(
                            get: { installed || model.appSelection.contains(a.id) },
                            set: { on in if on { model.appSelection.insert(a.id) } else { model.appSelection.remove(a.id) } })) {
                            HStack(spacing: 6) {
                                Text(a.name)
                                if installed { Tag(text: "Ya instalada", color: .green) }
                                if a.appStore != nil { Tag(text: "Solo App Store", color: .blue) }
                                if apps.needsAdmin(a) { Tag(text: "Pide contraseña", color: .secondary) }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!selectable)
                        .help(a.description)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SummaryStep: View {
    let model: WizardModel

    var body: some View {
        Form {
            Section("Ajustes") {
                if model.tweaksToApply.isEmpty {
                    Text("No hay ajustes nuevos que activar.").foregroundStyle(.secondary)
                } else {
                    Text("Se activarán \(model.tweaksToApply.count):").font(.uiCallout)
                    Text(model.tweaksToApply.map(\.title).joined(separator: " · ")).font(.uiCallout).foregroundStyle(.secondary)
                }
                if model.tweaksAlreadyOn > 0 {
                    Text("\(model.tweaksAlreadyOn) ya estaban activados.").font(.uiCaption).foregroundStyle(.secondary)
                }
                if !model.restarts.isEmpty {
                    Label("Se reiniciarán \(model.restarts.joined(separator: ", ")) (un parpadeo de un segundo).", systemImage: "arrow.clockwise")
                        .font(.uiCallout)
                }
                if model.needsLogout {
                    Label("Algunos cambios se notarán del todo al cerrar sesión o reabrir las apps.", systemImage: "person.crop.circle.badge.clock")
                        .font(.uiCallout)
                }
            }
            Section("Apps") {
                if model.appsToInstall.isEmpty {
                    Text("No hay apps nuevas que instalar.").foregroundStyle(.secondary)
                } else {
                    Text("Se instalarán \(model.appsToInstall.count) con Homebrew:").font(.uiCallout)
                    Text(model.appsToInstall.map(\.name).joined(separator: " · ")).font(.uiCallout).foregroundStyle(.secondary)
                }
                if model.appsAlreadyInstalled > 0 {
                    Text("\(model.appsAlreadyInstalled) ya estaban instaladas.").font(.uiCaption).foregroundStyle(.secondary)
                }
                if !model.appsNeedingPassword.isEmpty {
                    Label("\(model.appsNeedingPassword.map(\.name).joined(separator: ", ")) se instala en Terminal porque pide tu contraseña.",
                          systemImage: "lock").font(.uiCallout)
                }
            }
            Section {
                Text("Todo lo que se active se puede deshacer con «Restaurar todo». La configuración elegida se guarda para poder reaplicarla después de una actualización de macOS.")
                    .font(.uiCaption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ApplyingStep: View {
    let model: WizardModel

    var body: some View {
        let apps = model.root.apps
        VStack(spacing: 14) {
            ProgressView()
            if model.tweakResult == nil {
                Text("Aplicando ajustes…")
            } else {
                Text(apps.currentTask ?? "Preparando apps…")
                Text(apps.log.last ?? "").font(.uiMono).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 600)
            }
        }
        .padding(40)
    }
}

private struct DoneStep: View {
    let model: WizardModel

    var body: some View {
        let tr = model.tweakResult ?? BatchResult()
        let ao = model.appOutcome ?? AppsModel.InstallOutcome()
        let hadErrors = !tr.failed.isEmpty || !ao.failed.isEmpty
        Form {
            Section {
                Label(hadErrors ? "Terminado con algunos problemas" : "Configuración aplicada",
                      systemImage: hadErrors ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.uiTitle3).foregroundStyle(hadErrors ? .orange : .green)
            }
            Section("Ajustes") {
                Text(tr.changed.count == 1 ? "1 ajuste activado." : "\(tr.changed.count) ajustes activados.")
                ForEach(tr.failed, id: \.id) { f in Text("✗ \(f.error)").foregroundStyle(.red).font(.uiCallout) }
                if !tr.restarted.isEmpty { Text("Reiniciado: \(tr.restarted.joined(separator: ", ")).").font(.uiCallout).foregroundStyle(.secondary) }
                if tr.needsLogout { Text("Cierra sesión cuando puedas para que todos los cambios se apliquen del todo.").font(.uiCallout) }
            }
            Section("Apps") {
                Text(ao.installed.isEmpty ? "No se instaló ninguna app." : "Instaladas: \(ao.installed.joined(separator: ", ")).")
                if !ao.failed.isEmpty {
                    Text("Con error: \(ao.failed.joined(separator: ", ")). Mira el registro en la sección Apps.").foregroundStyle(.red).font(.uiCallout)
                }
                if !ao.inTerminal.isEmpty {
                    Text("En Terminal (pide contraseña): \(ao.inTerminal.joined(separator: ", ")). Cuando termine, pulsa «Volver a comprobar».")
                        .font(.uiCallout)
                }
            }
        }
        .formStyle(.grouped)
    }
}
