import SwiftUI
import AppKit

@main
struct MacOSUtilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app: AppModel

    init() {
        // Modo diagnóstico sin interfaz: `MacOSUtil --selftest`
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
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
                Divider()
                Button("Abrir DiskTree") { DiskTreeLink.open() }.disabled(DiskTreeLink.appURL == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
