import Foundation
import TweakEngine
import AppCatalog

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
        check(true, "\(catalog.categories.count) categorías, \(catalog.allTweaks.count) ajustes (\(dir.path))")

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
