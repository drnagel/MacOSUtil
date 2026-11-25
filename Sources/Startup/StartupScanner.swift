import Foundation

/// Lista los servicios de terceros que launchd arranca solos. Solo lee: no necesita contraseña.
public enum StartupScanner {
    static var directories: [(String, StartupItem.Scope)] {
        [(NSHomeDirectory() + "/Library/LaunchAgents", .userAgent),
         ("/Library/LaunchAgents", .globalAgent),
         ("/Library/LaunchDaemons", .daemon)]
    }

    public static func scan() -> [StartupItem] {
        let gui = Launchctl.domainState("gui/\(getuid())")
        let system = Launchctl.domainState("system")
        let apps = InstalledApps.scan()
        var items: [StartupItem] = []
        var seen: Set<String> = []

        // 1. Servicios con plist en las carpetas de LaunchAgents/LaunchDaemons
        for (dir, scope) in directories {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for f in files.sorted() where f.hasSuffix(".plist") {
                let path = dir + "/" + f
                guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
                let label = plist["Label"] as? String ?? String(f.dropLast(6))
                guard !isApple(label) else { continue }
                let state = scope == .daemon ? system : gui
                let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
                let loaded = state.services.keys.contains(label)
                let disabled = state.disabled[label] ?? (plist["Disabled"] as? Bool ?? false)
                items.append(StartupItem(
                    label: label, scope: scope, plistPath: path, program: program,
                    owner: owner(label: label, program: program, plist: plist, apps: apps),
                    schedule: schedule(plist, daemon: scope == .daemon), pid: state.services[label] ?? nil, loaded: loaded,
                    disabled: disabled, memory: nil))
                seen.insert("\(scope == .daemon ? "system" : "gui"):\(label)")
            }
        }

        // 2. Servicios que las apps registran desde su bundle (SMAppService): están en launchd pero no en esas carpetas.
        for (domainName, state, scope) in [("gui/\(getuid())", gui, StartupItem.Scope.appManaged), ("system", system, .daemon)] {
            let key = scope == .daemon ? "system" : "gui"
            for (label, pid) in state.services.sorted(by: { $0.key < $1.key }) {
                guard !seen.contains("\(key):\(label)"), !isApple(label), !isTransient(label) else { continue }
                let info = Launchctl.serviceInfo(domain: domainName, label: label)
                guard let program = info["program"], !isSystemPath(program) else { continue }
                items.append(StartupItem(
                    label: label, scope: scope, plistPath: nil, program: program,
                    owner: owner(label: label, program: program, plist: [:], apps: apps),
                    schedule: [], pid: pid, loaded: true, disabled: state.disabled[label] ?? false, memory: nil))
            }
        }

        // 3. Memoria de los que están en marcha (una sola llamada a ps)
        let mem = memory(of: items.compactMap(\.pid))
        return items.map { var i = $0; i.memory = i.pid.flatMap { mem[$0] }; return i }
    }

    // MARK: Filtros

    static func isApple(_ label: String) -> Bool {
        label.hasPrefix("com.apple.") || label == "com.apple"
    }

    /// Entradas que no son servicios de arranque: apps abiertas, extensiones de red, etc.
    static func isTransient(_ label: String) -> Bool {
        label.hasPrefix("application.") || label.hasPrefix("NetworkExtension.") || label.contains(".xpc.") || label.hasPrefix("[")
    }

    /// Ejecutables del propio macOS con etiqueta que no empieza por com.apple (cron, cupsd, ssh-agent…).
    static func isSystemPath(_ p: String) -> Bool {
        ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains { p.hasPrefix($0) }
    }

    // MARK: Cuándo se ejecuta

    static func schedule(_ plist: [String: Any], daemon: Bool) -> [String] {
        var s: [String] = []
        if plist["RunAtLoad"] as? Bool == true { s.append(daemon ? L("Al arrancar el Mac") : L("Al iniciar sesión")) }
        if let k = plist["KeepAlive"] {
            if (k as? Bool) == true || k is [String: Any] { s.append(L("Siempre activo")) }
        }
        if let i = plist["StartInterval"] as? Int { s.append(L("Cada \(duration(i))")) }
        if plist["StartCalendarInterval"] != nil { s.append(L("Programado")) }
        if plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil { s.append(L("Al cambiar archivos")) }
        if plist["MachServices"] != nil && s.isEmpty { s.append(L("Bajo demanda")) }
        return s
    }

    static func duration(_ seconds: Int) -> String {
        if seconds % 86400 == 0 { return "\(seconds / 86400) d" }
        if seconds % 3600 == 0 { return "\(seconds / 3600) h" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }

    // MARK: A qué app pertenece

    static func owner(label: String, program: String?, plist: [String: Any], apps: InstalledApps) -> StartupItem.Owner? {
        // a) El plist lo declara
        if let ids = plist["AssociatedBundleIdentifiers"] as? [String] ?? (plist["AssociatedBundleIdentifiers"] as? String).map({ [$0] }) {
            for id in ids { if let a = apps.byBundleID[id.lowercased()] { return .init(name: a.name, appPath: a.path) } }
        }
        // b) El ejecutable está dentro de una app instalada
        if let program, let a = apps.containing(program) { return .init(name: a.name, appPath: a.path) }
        // c) Comparte el prefijo del identificador con una app instalada (com.valvesoftware.* → Steam)
        if let a = apps.bestPrefixMatch(label) { return .init(name: a.name, appPath: a.path) }
        // d) El ejecutable es una .app aunque no esté en /Applications
        if let program, let r = program.range(of: ".app/") {
            let name = ((String(program[..<r.lowerBound])) as NSString).lastPathComponent
            return .init(name: name, appPath: nil)
        }
        // e) El fabricante, por el identificador (com.waves.wls → Waves)
        let parts = label.split(separator: ".")
        if parts.count >= 2, ["com", "org", "net", "io", "de", "jp", "co", "us"].contains(String(parts[0])) {
            let vendor = String(parts[1]).lowercased()
            return .init(name: knownVendors[vendor] ?? vendor.prefix(1).uppercased() + vendor.dropFirst(), appPath: nil)
        }
        return nil
    }

    /// Nombres legibles de fabricantes cuyo identificador no se parece al nombre comercial.
    static let knownVendors: [String: String] = [
        "valvesoftware": "Steam (Valve)", "adobe": "Adobe", "microsoft": "Microsoft", "google": "Google",
        "zoom": "Zoom", "dropbox": "Dropbox", "logitech": "Logitech", "logi": "Logitech", "waves": "Waves",
        "teamviewer": "TeamViewer", "docker": "Docker", "oracle": "Oracle", "vmware": "VMware",
        "parallels": "Parallels", "spotify": "Spotify", "epicgames": "Epic Games", "cloudflare": "Cloudflare",
        "pqrs": "Karabiner-Elements", "objective-see": "Objective-See", "eset": "ESET", "malwarebytes": "Malwarebytes",
    ]

    // MARK: Memoria

    static func memory(of pids: [Int32]) -> [Int32: Int64] {
        guard !pids.isEmpty else { return [:] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "pid=,rss=", "-p", pids.map(String.init).joined(separator: ",")]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var result: [Int32: Int64] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ")
            if f.count == 2, let pid = Int32(f[0]), let kb = Int64(f[1]) { result[pid] = kb * 1024 }
        }
        return result
    }
}

/// Apps instaladas (/Applications, /Applications/Utilities, ~/Applications) indexadas por bundle id.
struct InstalledApps {
    struct App { let name: String; let path: String; let bundleID: String }
    var byBundleID: [String: App] = [:]

    static func scan() -> InstalledApps {
        var r = InstalledApps()
        let dirs = ["/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".app") {
                let path = dir + "/" + f
                guard let b = Bundle(path: path), let id = b.bundleIdentifier, !id.hasPrefix("com.apple.") else { continue }
                let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? String(f.dropLast(4))
                r.byBundleID[id.lowercased()] = App(name: name, path: path, bundleID: id.lowercased())
            }
        }
        return r
    }

    func containing(_ program: String) -> App? {
        byBundleID.values.first { program.hasPrefix($0.path + "/") }
    }

    /// La app cuyo bundle id comparte más componentes iniciales con la etiqueta (mínimo «com.fabricante»).
    /// También acepta un fabricante que empiece igual (com.waves.* → com.wavesaudio.central), y en ese caso
    /// desempata por componentes compartidos («central»).
    func bestPrefixMatch(_ label: String) -> App? {
        let l = label.lowercased().split(separator: ".").map(String.init)
        guard l.count >= 2 else { return nil }
        var best: (App, Double)?
        for app in byBundleID.values {
            let b = app.bundleID.split(separator: ".").map(String.init)
            guard b.count >= 2, l[0] == b[0] else { continue }
            var n = 0
            while n < min(l.count, b.count), l[n] == b[n] { n += 1 }
            var score = Double(n)
            if n < 2 {
                let (lv, bv) = (l[1], b[1])
                guard min(lv.count, bv.count) >= 4, lv.hasPrefix(bv) || bv.hasPrefix(lv) else { continue }
                score = 1.5 + 0.1 * Double(Set(l.dropFirst(2)).intersection(b.dropFirst(2)).count)
            }
            if score > (best?.1 ?? 0) { best = (app, score) }
        }
        return best?.0
    }
}
