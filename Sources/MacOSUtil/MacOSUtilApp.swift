import SwiftUI
import AppKit

@main
struct MacOSUtilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app: AppModel
    @State private var monitor = MonitorModel.shared
    /// Widget de la barra de menús (CPU, memoria y disco). Activado por defecto.
    @AppStorage("showMenuBarWidget") private var showWidget = true
    @AppStorage("menuBarLabel") private var labelMode: MenuBarLabelMode = .cpuAndMemory

    init() {
        // Modo diagnóstico sin interfaz: `MacOSUtil --selftest`
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }
        // Herramienta del catálogo: `MacOSUtil --catalog validate|keygen|bundle|verify`
        if let i = CommandLine.arguments.firstIndex(of: "--catalog") {
            exit(CatalogTool.run(Array(CommandLine.arguments[(i + 1)...])))
        }
        _app = State(initialValue: AppModel.shared)
    }

    var body: some Scene {
        Window("MacOSUtil", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Configuración") {
                Button("Asistente de configuración…") { app.openWizard() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Exportar configuración…") { app.exportSetup() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Importar configuración…") { app.importSetup() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Reaplicar última configuración") { app.reapplyLast() }
            }
            CommandMenu("Ajustes") {
                Button("Volver a comprobar") { app.refresh(); app.apps.refresh(); app.startup.refresh(); app.power.refresh(); app.health.refresh() }.keyboardShortcut("r", modifiers: .command)
                Button("Recargar catálogo") { app.load(); app.apps.load(); app.apps.refresh() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Buscar actualizaciones del catálogo…") { app.checkCatalogUpdate() }
                Divider()
                Button("Abrir DiskTree") { DiskTreeLink.open() }.disabled(DiskTreeLink.appURL == nil)
                Divider()
                Toggle("Mostrar el widget en la barra de menús", isOn: $showWidget)
            }
        }

        MenuBarExtra(isInserted: $showWidget) {
            MenuBarPanel(monitor: monitor, mode: $labelMode, isShown: $showWidget)
                .environment(app)
        } label: {
            MenuBarLabel(monitor: monitor, mode: labelMode)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in MonitorModel.shared.start() }
    }

    /// Con el widget en la barra de menús, cerrar la ventana no cierra la app: se vuelve a abrir desde el widget.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "showMenuBarWidget") as? Bool ?? true)
    }
}
