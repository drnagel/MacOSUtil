import Foundation
import Privileged
import TweakEngine
import AppCatalog
import Startup
import Profiles

/// `MacOSUtil --selftest`: valida el catálogo, muestra el estado de cada ajuste en este Mac y prueba
/// aplicar → comprobar → revertir sobre un dominio de prueba (no toca ninguna preferencia real).
enum SelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ msg: String) {
            print(cond ? "  ✓ \(msg)" : "  ✗ \(msg)")
            if !cond { ok = false }
        }

        let v = ProcessInfo.processInfo.operatingSystemVersion
        print("macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")

        // 1. Catálogo
        print("== Catálogo")
        guard let dir = Catalog.locate() else { print("  ✗ no se encontró Catalog/"); return false }
        let catalog: Catalog
        do { catalog = try Catalog.load(from: dir) } catch {
            print("  ✗ \(error.localizedDescription)"); return false
        }
        let linkCount = catalog.categories.reduce(0) { $0 + $1.links.count }
        check(true, "\(catalog.categories.count) categorías, \(catalog.allTweaks.count) ajustes, \(linkCount) enlaces a Ajustes (\(dir.path))")
        // Un enlace que no sea de Ajustes del Sistema debe rechazarse.
        let bad = #"{"id":"x","title":"x","icon":"x","order":1,"links":[{"id":"x.a","title":"a","description":"","url":"https://example.com"}]}"#
        if let cat = try? JSONDecoder().decode(TweakCategory.self, from: Data(bad.utf8)) {
            let problems = Catalog(categories: [cat], source: dir).validate()
            check(problems.contains { $0.contains("solo se permiten") }, "rechaza enlaces que no son de Ajustes del Sistema")
        } else {
            check(false, "no se pudo decodificar la categoría de prueba")
        }

        // 2. Estado actual (solo lectura)
        print("== Estado en este Mac (solo lectura)")
        let engine = TweakEngine()
        for c in catalog.categories {
            print("  [\(c.title)]")
            for t in c.tweaks {
                let mark = switch engine.status(t) {
                case .on: "●"
                case .off: "○"
                case .partial: "◐"
                case .unavailable: "–"
                }
                print("    \(mark) \(t.id)")
            }
        }

        // 3. Ciclo completo en un dominio de prueba con un state.json temporal
        print("== Motor (dominio de prueba)")
        let domain = "local.macosutil.selftest"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("macosutil-selftest-\(UUID().uuidString).json")
        let testEngine = TweakEngine(store: StateStore(url: tmp))
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pre = DefaultsAction(domain: domain, key: "Existing", value: .string("original"))
        let actions: [DefaultsAction] = [
            DefaultsAction(domain: domain, key: "Flag", value: .bool(true)),
            DefaultsAction(domain: domain, key: "Count", value: .int(7)),
            DefaultsAction(domain: domain, key: "Speed", value: .double(0.25)),
            DefaultsAction(domain: domain, key: "Existing", value: .string("cambiado")),
            DefaultsAction(domain: domain, key: "PerHost", value: .bool(true), currentHost: true),
        ]
        let tweak = Tweak(id: "selftest.cycle", title: "Prueba", description: "", actions: actions.map { .defaults($0) })
        let cleanup = { for a in actions { try? Preferences.write(a, nil) } }
        cleanup()
        defer { cleanup() }

        do {
            try Preferences.write(pre, .string("original"))
            check(testEngine.status(tweak) == .off, "estado inicial: desactivado")

            try testEngine.apply(tweak)
            check(testEngine.status(tweak) == .on, "tras aplicar: activado")
            check(testEngine.isManaged(tweak), "originales guardados en state.json")
            check(Preferences.read(actions[2]) == .value(.double(0.25)), "float escrito como decimal")
            check(Preferences.read(actions[4]) == .value(.bool(true)), "clave -currentHost escrita")

            // Aplicar otra vez no debe pisar el original guardado.
            try testEngine.apply(tweak)
            try testEngine.revert(tweak)
            check(testEngine.status(tweak) == .off, "tras revertir: desactivado")
            check(Preferences.read(pre) == .value(.string("original")), "clave existente restaurada a su valor original")
            check(Preferences.read(actions[0]) == .absent, "clave nueva borrada al revertir")
            check(!testEngine.isManaged(tweak), "registro eliminado de state.json")

            // Lote + parcial
            try Preferences.write(actions[0], .bool(true))
            check(testEngine.status(tweak) == .partial, "detecta estado parcial")
            let r = testEngine.run([.apply(tweak)], restartProcesses: false)
            check(r.failed.isEmpty && r.changed == [tweak.id], "lote aplicado sin errores")
            let all = testEngine.revertAll(catalog: catalog)   // el ajuste no está en el catálogo: se revierte por registro
            check(all.failed.isEmpty && testEngine.store.appliedIDs.isEmpty, "restaurar todo (ajuste fuera del catálogo)")
            check(Preferences.read(actions[0]) == .value(.bool(true)), "restaura el valor previo al lote")

            // Valores de tipo no soportado no se sobrescriben.
            CFPreferencesSetValue("Existing" as CFString, ["a", "b"] as CFArray, domain as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            var refused = false
            do { try testEngine.apply(tweak) } catch TweakError.unsupportedValue { refused = true }
            check(refused, "rechaza sobrescribir un valor de tipo no soportado (array)")
        } catch {
            check(false, "error inesperado: \(error.localizedDescription)")
        }

        // 4. Catálogo de apps contra Homebrew (solo consulta, no instala nada)
        print("== Apps")
        do {
            let apps = try AppCatalogFile.load(from: dir)
            check(true, "\(apps.categories.count) categorías, \(apps.allApps.count) apps")
            if Homebrew.isInstalled {
                let tokens = apps.allApps.compactMap(\.cask)
                let t0 = Date()
                let info = blocking { await Homebrew.info(tokens) }
                let missing = tokens.filter { info[$0] == nil }
                check(missing.isEmpty, "\(tokens.count - missing.count)/\(tokens.count) casks existen en Homebrew (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s)"
                      + (missing.isEmpty ? "" : " · faltan: \(missing.joined(separator: ", "))"))
                for a in apps.allApps {
                    let st = Homebrew.status(of: a, info: info)
                    let mark = switch st {
                    case .brew(let v, let outdated): "brew \(v)\(outdated ? " (desactualizada)" : "")"
                    case .manual: "instalada fuera de brew"
                    case .notInstalled: "—"
                    case .unavailable: "NO DISPONIBLE"
                    case .unknown: "?"
                    }
                    let admin = a.cask.flatMap { info[$0]?.needsAdmin } == true ? " [pide contraseña]" : ""
                    print("    \(a.name): \(mark)\(admin)")
                }
            } else {
                print("  – Homebrew no está instalado: no se comprueban los casks")
            }
        } catch {
            check(false, error.localizedDescription)
        }

        // 4b. Perfiles y archivo de configuración
        print("== Perfiles")
        do {
            let profiles = try ProfileCatalog.load(from: dir)
            let appIDs = Set(((try? AppCatalogFile.load(from: dir))?.allApps ?? []).map(\.id))
            let tweakIDs = Set(catalog.allTweaks.map(\.id))
            let problems = ProfileCatalog.validate(profiles, tweakIDs: tweakIDs, appIDs: appIDs)
            check(problems.isEmpty, "\(profiles.count) perfiles válidos" + (problems.isEmpty ? "" : ": " + problems.joined(separator: "; ")))
            for p in profiles { print("    \(p.title): \(p.tweaks.count) ajustes, \(p.apps.count) apps") }
            let bad = Profile(id: "x", title: "x", description: "", icon: "x", order: 0, tweaks: ["no.existe"], apps: ["tampoco"])
            check(ProfileCatalog.validate([bad], tweakIDs: tweakIDs, appIDs: appIDs).count == 2, "detecta ajustes y apps inexistentes en un perfil")

            let setup = SetupFile(macOS: SetupFile.currentMacOS, profile: "developer", tweaks: ["dock.autohide", "finder.show-extensions"], apps: ["rectangle"])
            let back = try SetupFile.decode(setup.encoded())
            check(back.tweaks == setup.tweaks && back.apps == setup.apps && back.profile == "developer", "exportar → importar conserva ajustes y apps")
            let text = String(decoding: try setup.encoded(), as: UTF8.self)
            check(!text.contains(NSUserName()) && !text.contains(Host.current().localizedName ?? "\u{0}"), "el archivo no contiene usuario ni nombre del equipo")
            var rejected = false
            do { _ = try SetupFile.decode(Data(#"{"format":"otra-cosa","version":1}"#.utf8)) } catch { rejected = true }
            check(rejected, "rechaza archivos que no son de MacOSUtil")
            let withUnknown = SetupFile(macOS: "99", profile: nil, tweaks: ["dock.autohide", "futuro.ajuste"], apps: ["app-futura"])
            let u = withUnknown.unknown(tweakIDs: tweakIDs, appIDs: appIDs)
            check(u.tweaks == ["futuro.ajuste"] && u.apps == ["app-futura"], "señala ids desconocidos al importar")
            let tmpLast = FileManager.default.temporaryDirectory.appendingPathComponent("macosutil-last-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: tmpLast) }
            try LastSetup.save(setup, to: tmpLast)
            check(LastSetup.load(from: tmpLast) == setup, "guarda y recupera la última configuración")
        } catch {
            check(false, "perfiles: \(error.localizedDescription)")
        }

        // 5. Servicios de arranque: listado (solo lectura) y ciclo desactivar/reactivar con un agente temporal
        print("== Arranque")
        let t1 = Date()
        let items = StartupScanner.scan()
        check(true, "\(items.count) servicios de terceros (\(String(format: "%.1f", Date().timeIntervalSince(t1))) s)")
        for scope in StartupItem.Scope.allCases {
            let group = items.filter { $0.scope == scope }
            guard !group.isEmpty else { continue }
            print("  [\(scope.title)]")
            for i in group {
                var flags: [String] = []
                if let pid = i.pid { flags.append("pid \(pid)") } else if i.loaded { flags.append("cargado") }
                if let m = i.memory { flags.append(ByteCountFormatter.string(fromByteCount: m, countStyle: .memory)) }
                if i.disabled { flags.append("DESACTIVADO") }
                if i.isOrphan { flags.append("RESTO") }
                flags += i.schedule
                print("    \(i.displayName) · \(i.label) · \(flags.joined(separator: ", "))")
            }
        }
        let tmpStore = FileManager.default.temporaryDirectory.appendingPathComponent("macosutil-startup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpStore) }
        for (msg, good) in StartupController.selfTestCycle(storeURL: tmpStore) { check(good, msg) }

        print("== Privilegios (sin pedir contraseña)")
        func rejects(_ c: AdminCommand) -> Bool { (try? c.validate()) == nil }
        func accepts(_ c: AdminCommand) -> Bool { (try? c.validate()) != nil }
        check(rejects(.daemonDisable(label: "com.apple.mdworker")), "rechaza servicios de Apple")
        check(rejects(.daemonDisable(label: "a b; rm -rf /")) && rejects(.daemonStop(label: "../x")), "rechaza etiquetas con espacios o rutas")
        check(rejects(.daemonStart(plistPath: "/tmp/x.plist")) && rejects(.daemonStart(plistPath: "/Library/LaunchDaemons/../x.plist"))
              && rejects(.daemonStart(plistPath: "/Library/LaunchDaemons/a/x.plist")), "rechaza plists fuera de /Library/LaunchDaemons")
        check(rejects(.pmset(source: .all, setting: "hibernatemode", value: 0)) && rejects(.pmset(source: .all, setting: "sleep", value: 9999)),
              "rechaza ajustes de energía no permitidos o fuera de rango")
        check(rejects(.spotlightIndexing(volume: "/etc", enabled: false)) && rejects(.spotlightIndexing(volume: "/Volumes/../etc", enabled: false))
              && rejects(.spotlightRebuild(volume: "/Volumes/a/b")), "rechaza rutas que no son volúmenes")
        check(accepts(.pmset(source: .charger, setting: "powernap", value: 0)) && accepts(.daemonDisable(label: "com.example.helper"))
              && accepts(.spotlightIndexing(volume: "/", enabled: true)), "acepta comandos válidos")
        check(AdminRunner.shellQuote("it's") == "'it'\\''s'", "comillas simples escapadas en el shell")
        check(AdminRunner.appleString("a\"b\\c") == "\"a\\\"b\\\\c\"", "comillas y barras escapadas en AppleScript")
        let cmds: [AdminCommand] = [.pmset(source: .charger, setting: "powernap", value: 0), .daemonStop(label: "x.y")]
        let script = AdminRunner.shellScript(cmds)
        check(script.contains("'/usr/bin/pmset' '-c' 'powernap' '0'") && script.hasSuffix("exit 0"), "script del lote")
        let parsed = AdminRunner.parse("@@BEGIN 0\r@@END 0 0\r@@BEGIN 1\rBoot-out failed: 3: No such process\r@@END 1 3", commands: cmds)
        check(parsed.count == 2 && parsed[0].ok && parsed[1].ok && parsed[1].output.contains("No such process"),
              "lee el resultado de cada comando (detener algo parado no es error)")
        let sample = "Battery Power:\n lowpowermode 1\n sleep 1\nAC Power:\n Sleep On Power Button 1\n powernap 1\n sleep 0\n"
        let pv = Power.parse(sample)
        check(pv[.battery]?["lowpowermode"] == 1 && pv[.charger]?["powernap"] == 1 && pv[.charger]?["Sleep On Power Button"] == 1,
              "lee pmset -g custom (batería y corriente)")
        let tmpPower = FileManager.default.temporaryDirectory.appendingPathComponent("macosutil-power-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpPower) }
        let ps = PowerStore(url: tmpPower)
        try? ps.remember(.charger, "powernap", value: 1)
        try? ps.remember(.charger, "powernap", value: 0)
        check(PowerStore(url: tmpPower).original(.charger, "powernap") == 1
              && ps.restoreCommands() == [.pmset(source: .charger, setting: "powernap", value: 1)], "power.json guarda solo el valor original")
        check(Spotlight.parseStatus("/:\n\tIndexing enabled. \n").indexing == true
              && Spotlight.parseStatus("/Volumes/X:\n\tIndexing disabled.\n").indexing == false, "lee mdutil -s")
        let live = Power.read()
        check(!live.isEmpty, "pmset en este Mac: \(live.keys.map { $0 == .battery ? "batería" : "corriente" }.sorted().joined(separator: ", "))")
        let vols = Spotlight.volumes()
        check(vols.contains { $0.path == "/" }, "volúmenes: \(vols.map { "\($0.name) (\($0.indexing.map { $0 ? "indexa" : "no indexa" } ?? "?"))" }.joined(separator: ", "))")

        print("== DiskTree")
        check(DiskTreeLink.Destination.tab("cleanup").url?.absoluteString == "disktree://open?tab=cleanup", "enlace a pestaña")
        check(DiskTreeLink.Destination.folder("/Users/a b/Library/Caches").url?.absoluteString
              == "disktree://folder?path=/Users/a%20b/Library/Caches", "enlace a carpeta con espacios")
        check(DiskTreeLink.Destination.scan.url?.absoluteString == "disktree://scan", "enlace para analizar")
        if let app = DiskTreeLink.appURL {
            print("  DiskTree: \((app.path as NSString).abbreviatingWithTildeInPath) · enlaces: \(DiskTreeLink.supportsLinks(app) ? "sí" : "no")")
        } else {
            print("  DiskTree no está instalada (se omite)")
        }

        print(ok ? "OK" : "FALLÓ")
        return ok
    }

    /// Espera una tarea async desde el selftest (que corre en el hilo principal, sin interfaz).
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        let sem = DispatchSemaphore(value: 0)
        Task.detached { box.value = await work(); sem.signal() }
        sem.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }
}
