import Foundation

/// Una comprobación del estado del Mac. Todas se leen sin contraseña ni Acceso total al disco.
public struct HealthCheck: Identifiable, Sendable, Equatable {
    public enum Group: String, CaseIterable, Sendable {
        case security, updates, backup, disks, system

        public var title: String {
            switch self {
            case .security: "Seguridad"
            case .updates: "Actualizaciones"
            case .backup: "Copias de seguridad"
            case .disks: "Discos"
            case .system: "Sistema"
            }
        }
    }

    public enum Status: Int, Comparable, Sendable {
        case good, info, warning, bad
        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    public let id: String
    public let group: Group
    public let title: String
    public let status: Status
    public let detail: String
    /// Panel de Ajustes del Sistema donde se arregla (solo `x-apple.systempreferences:`).
    public let settingsURL: String?

    public init(id: String, group: Group, title: String, status: Status, detail: String, settingsURL: String? = nil) {
        self.id = id; self.group = group; self.title = title; self.status = status; self.detail = detail
        self.settingsURL = settingsURL.flatMap { $0.hasPrefix("x-apple.systempreferences:") ? $0 : nil }
    }
}

public enum HealthScanner {
    static let securityPane = "x-apple.systempreferences:com.apple.preference.security"
    static let updatePane = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
    static let timeMachinePane = "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"
    static let firewallPane = "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall"

    /// Hace todas las comprobaciones en paralelo (cada comando tiene un límite de tiempo).
    public static func run(now: Date = Date()) -> [HealthCheck] {
        let jobs: [@Sendable () -> [HealthCheck]] = [
            { [sip()] }, { [fileVault()] }, { [gatekeeper()] }, { [firewall()] },
            { updates(now: now) }, { timeMachine(now: now) },
            { disks() }, { [freeSpace()] }, { [memory()] }, { [uptime(now: now)] }, { battery() },
        ]
        let box = Box(count: jobs.count)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in box.set(i, jobs[i]()) }
        return box.all.flatMap { $0 }
    }

    // MARK: Seguridad

    static func sip() -> HealthCheck {
        let out = Cmd.run("/usr/bin/csrutil", ["status"])
        return parseSIP(out)
    }

    public static func parseSIP(_ out: String?) -> HealthCheck {
        let t = out?.lowercased() ?? ""
        if t.contains("status: enabled") {
            return .init(id: "sip", group: .security, title: "Protección de la integridad del sistema (SIP)", status: .good,
                         detail: "Activada: nadie puede modificar los archivos de macOS, ni siquiera con contraseña de administrador.")
        }
        if t.contains("disabled") {
            return .init(id: "sip", group: .security, title: "Protección de la integridad del sistema (SIP)", status: .bad,
                         detail: "Desactivada. Solo se vuelve a activar desde el modo de recuperación (csrutil enable).")
        }
        return .init(id: "sip", group: .security, title: "Protección de la integridad del sistema (SIP)", status: .info,
                     detail: "No se pudo leer su estado.")
    }

    static func fileVault() -> HealthCheck { parseFileVault(Cmd.run("/usr/bin/fdesetup", ["status"])) }

    public static func parseFileVault(_ out: String?) -> HealthCheck {
        let t = out ?? ""
        let url = securityPane + "?FileVault"
        if t.contains("FileVault is On") {
            return .init(id: "filevault", group: .security, title: "FileVault (cifrado del disco)", status: .good,
                         detail: "Activado: si pierdes o te roban el Mac, nadie puede leer el disco sin tu contraseña.", settingsURL: url)
        }
        if t.contains("Encryption in progress") || t.contains("Decryption in progress") {
            return .init(id: "filevault", group: .security, title: "FileVault (cifrado del disco)", status: .info,
                         detail: "Cambiando el cifrado ahora mismo.", settingsURL: url)
        }
        if t.contains("FileVault is Off") {
            return .init(id: "filevault", group: .security, title: "FileVault (cifrado del disco)", status: .warning,
                         detail: "Desactivado: si te roban el Mac, pueden leer todos tus archivos conectando el disco a otro equipo. Activarlo no ralentiza un Mac con chip de Apple.",
                         settingsURL: url)
        }
        return .init(id: "filevault", group: .security, title: "FileVault (cifrado del disco)", status: .info,
                     detail: "No se pudo leer su estado.", settingsURL: url)
    }

    static func gatekeeper() -> HealthCheck {
        let t = Cmd.run("/usr/sbin/spctl", ["--status"]) ?? ""
        if t.contains("assessments enabled") {
            return .init(id: "gatekeeper", group: .security, title: "Gatekeeper", status: .good,
                         detail: "Activado: macOS comprueba la firma de las apps antes de abrirlas.")
        }
        if t.contains("assessments disabled") {
            return .init(id: "gatekeeper", group: .security, title: "Gatekeeper", status: .bad,
                         detail: "Desactivado: cualquier app se abre sin comprobar quién la firmó. Se reactiva con «sudo spctl --master-enable».",
                         settingsURL: securityPane + "?General")
        }
        return .init(id: "gatekeeper", group: .security, title: "Gatekeeper", status: .info, detail: "No se pudo leer su estado.")
    }

    static func firewall() -> HealthCheck {
        let t = Cmd.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]) ?? ""
        if t.contains("State = 1") || t.contains("State = 2") || t.lowercased().contains("is enabled") {
            return .init(id: "firewall", group: .security, title: "Firewall", status: .good,
                         detail: "Activado: bloquea las conexiones entrantes que no hayas permitido.", settingsURL: firewallPane)
        }
        if t.contains("State = 0") || t.lowercased().contains("is disabled") {
            return .init(id: "firewall", group: .security, title: "Firewall", status: .warning,
                         detail: "Desactivado. En casa detrás de un router importa poco; en redes públicas (cafeterías, hoteles) conviene activarlo.",
                         settingsURL: firewallPane)
        }
        return .init(id: "firewall", group: .security, title: "Firewall", status: .info, detail: "No se pudo leer su estado.", settingsURL: firewallPane)
    }

    // MARK: Actualizaciones

    static let softwareUpdatePlist = "/Library/Preferences/com.apple.SoftwareUpdate.plist"

    static func updates(now: Date) -> [HealthCheck] {
        parseUpdates(readPrefs(softwareUpdatePlist), now: now)
    }

    public static func parseUpdates(_ prefs: [String: Any], now: Date) -> [HealthCheck] {
        var checks: [HealthCheck] = []
        let pending = (prefs["RecommendedUpdates"] as? [[String: Any]] ?? []).compactMap {
            ($0["Display Name"] as? String)?.replacingOccurrences(of: "\u{00a0}", with: " ")
        }
        let last = prefs["LastSuccessfulDate"] as? Date
        let checked = last.map { " Última comprobación: \(Fmt.relative($0, now: now))." } ?? ""
        if pending.isEmpty {
            checks.append(.init(id: "updates", group: .updates, title: "Actualizaciones pendientes", status: .good,
                                detail: "No hay ninguna." + checked, settingsURL: updatePane))
        } else {
            let macOS = pending.contains { $0.hasPrefix("macOS") }
            checks.append(.init(id: "updates", group: .updates, title: "Actualizaciones pendientes",
                                status: macOS ? .warning : .info,
                                detail: pending.joined(separator: " · ") + "." + checked, settingsURL: updatePane))
        }
        let critical = prefs["CriticalUpdateInstall"] as? Bool ?? true
        let autoCheck = prefs["AutomaticCheckEnabled"] as? Bool ?? true
        if !autoCheck || !critical {
            var off: [String] = []
            if !autoCheck { off.append("buscar actualizaciones") }
            if !critical { off.append("instalar las respuestas de seguridad") }
            checks.append(.init(id: "autoupdate", group: .updates, title: "Actualizaciones automáticas", status: .warning,
                                detail: "Desactivado: \(off.joined(separator: " y ")). Los parches de seguridad tardarán en llegar.",
                                settingsURL: updatePane))
        } else {
            let auto = prefs["AutomaticallyInstallMacOSUpdates"] as? Bool ?? false
            checks.append(.init(id: "autoupdate", group: .updates, title: "Actualizaciones automáticas", status: .good,
                                detail: "Las respuestas de seguridad se instalan solas." + (auto ? " macOS también se actualiza solo." : " Las actualizaciones de macOS las instalas tú."),
                                settingsURL: updatePane))
        }
        return checks
    }

    /// Lee un plist de /Library/Preferences. Las preferencias de Time Machine están protegidas por la privacidad de
    /// macOS y no se pueden abrir directamente sin Acceso total al disco; `defaults export` sí las devuelve.
    static func readPrefs(_ path: String) -> [String: Any] {
        if let d = NSDictionary(contentsOfFile: path) as? [String: Any], !d.isEmpty { return d }
        guard let xml = Cmd.run("/usr/bin/defaults", ["export", String(path.dropLast(6)), "-"]),
              let data = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return plist
    }

    // MARK: Time Machine

    static let timeMachinePlist = "/Library/Preferences/com.apple.TimeMachine.plist"

    static func timeMachine(now: Date) -> [HealthCheck] {
        [parseTimeMachine(readPrefs(timeMachinePlist), now: now)]
    }

    public static func parseTimeMachine(_ prefs: [String: Any], now: Date) -> HealthCheck {
        let title = "Time Machine"
        let dests = prefs["Destinations"] as? [[String: Any]] ?? []
        guard !dests.isEmpty else {
            return .init(id: "timemachine", group: .backup, title: title, status: .warning,
                         detail: "No hay ningún disco de copias configurado: si el disco falla, se pierde todo.", settingsURL: timeMachinePane)
        }
        let dates = dests.flatMap { $0["SnapshotDates"] as? [Date] ?? [] }
        let names = dests.compactMap { $0["LastKnownVolumeName"] as? String }
        let auto = (prefs["AutoBackup"] as? Bool) ?? ((prefs["AutoBackup"] as? Int).map { $0 != 0 } ?? false)
        let where_ = names.isEmpty ? "" : " en «\(names.joined(separator: "», «"))»"
        guard let lastDate = dates.max() else {
            return .init(id: "timemachine", group: .backup, title: title, status: .warning,
                         detail: "Configurado\(where_), pero todavía no hay ninguna copia completa.", settingsURL: timeMachinePane)
        }
        let days = now.timeIntervalSince(lastDate) / 86_400
        var detail = "Última copia\(where_): \(Fmt.relative(lastDate, now: now))."
        var status: HealthCheck.Status = days > 30 ? .bad : (days > 7 ? .warning : .good)
        if !auto {
            detail += " Las copias automáticas están desactivadas: solo se hacen cuando las pides."
            status = max(status, .warning)
        }
        return .init(id: "timemachine", group: .backup, title: title, status: status, detail: detail, settingsURL: timeMachinePane)
    }

    // MARK: Discos

    static func disks() -> [HealthCheck] {
        guard let list = Cmd.run("/usr/sbin/diskutil", ["list", "physical"], timeout: 8) else {
            return [.init(id: "smart", group: .disks, title: "Estado de los discos", status: .info, detail: "diskutil no respondió.")]
        }
        let ids = list.components(separatedBy: .newlines).compactMap { line -> String? in
            guard line.hasPrefix("/dev/disk") else { return nil }
            return line.split(separator: " ").first.map { String($0.dropFirst(5)) }
        }
        return ids.map { id in parseDiskInfo(id: id, Cmd.run("/usr/sbin/diskutil", ["info", id], timeout: 6)) }
    }

    public static func parseDiskInfo(id: String, _ out: String?) -> HealthCheck {
        guard let out else {
            return .init(id: "smart-\(id)", group: .disks, title: id, status: .warning, detail: "El disco no responde.")
        }
        var fields: [String: String] = [:]
        for line in out.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let name = fields["Device / Media Name"] ?? id
        let isInternal = (fields["Device Location"] ?? "").lowercased() == "internal" || fields["Internal"] == "Yes"
        let size = fields["Disk Size"].flatMap { $0.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } } ?? ""
        let kind = [isInternal ? "Interno" : "Externo", fields["Protocol"], size.isEmpty ? nil : size].compactMap { $0 }.joined(separator: " · ")
        let smart = fields["SMART Status"] ?? ""
        let title = "\(name)"
        switch smart {
        case "Verified":
            return .init(id: "smart-\(id)", group: .disks, title: title, status: .good, detail: "\(kind). SMART: sin errores.")
        case "Failing":
            return .init(id: "smart-\(id)", group: .disks, title: title, status: .bad,
                         detail: "\(kind). SMART indica que el disco está fallando: copia tus datos cuanto antes y sustitúyelo.")
        case "Not Supported":
            return .init(id: "smart-\(id)", group: .disks, title: title, status: .info,
                         detail: "\(kind). macOS no puede leer su estado SMART (habitual en discos por USB).")
        default:
            return .init(id: "smart-\(id)", group: .disks, title: title, status: .info,
                         detail: "\(kind). SMART: \(smart.isEmpty ? "desconocido" : smart).")
        }
    }

    static func freeSpace() -> HealthCheck {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
        let total = Int64(v?.volumeTotalCapacity ?? 0)
        let free = v?.volumeAvailableCapacityForImportantUsage ?? 0
        return evaluateFreeSpace(free: free, total: total)
    }

    public static func evaluateFreeSpace(free: Int64, total: Int64) -> HealthCheck {
        let title = "Espacio libre en el disco de arranque"
        guard total > 0 else { return .init(id: "space", group: .disks, title: title, status: .info, detail: "No se pudo leer.") }
        let pct = Double(free) / Double(total)
        let text = "\(Fmt.bytes(free)) libres de \(Fmt.bytes(total)) (\(Int((pct * 100).rounded())) %)."
        if pct < 0.10 {
            return .init(id: "space", group: .disks, title: title, status: .bad,
                         detail: text + " Con tan poco espacio macOS se ralentiza y las actualizaciones pueden fallar.")
        }
        if pct < 0.20 {
            return .init(id: "space", group: .disks, title: title, status: .warning, detail: text + " Conviene liberar algo de espacio.")
        }
        return .init(id: "space", group: .disks, title: title, status: .good, detail: text)
    }

    // MARK: Sistema

    static func memory() -> HealthCheck {
        let freePct = Cmd.run("/usr/bin/memory_pressure", ["-Q"]).flatMap { out -> Int? in
            guard let line = out.components(separatedBy: .newlines).first(where: { $0.contains("free percentage") }),
                  let n = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "") else { return nil }
            return Int(n)
        }
        var swap: Int64 = 0
        var xsu = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsu, &size, nil, 0) == 0 { swap = Int64(xsu.xsu_used) }
        return evaluateMemory(freePercent: freePct, swapUsed: swap, total: Int64(ProcessInfo.processInfo.physicalMemory))
    }

    public static func evaluateMemory(freePercent: Int?, swapUsed: Int64, total: Int64) -> HealthCheck {
        let title = "Memoria"
        var parts = ["\(Fmt.bytes(total)) en total"]
        if let f = freePercent { parts.append("\(f) % libre") }
        parts.append("swap en uso: \(Fmt.bytes(swapUsed))")
        let base = parts.joined(separator: " · ") + "."
        if let f = freePercent, f < 10 {
            return .init(id: "memory", group: .system, title: title, status: .warning,
                         detail: base + " La memoria va justa: mira en Arranque qué servicios de fondo puedes parar.")
        }
        if swapUsed > total / 2 {
            return .init(id: "memory", group: .system, title: title, status: .warning,
                         detail: base + " Usa mucho swap: el Mac escribe en disco lo que no le cabe en memoria.")
        }
        return .init(id: "memory", group: .system, title: title, status: .good, detail: base)
    }

    static func uptime(now: Date) -> HealthCheck {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else {
            return .init(id: "uptime", group: .system, title: "Último reinicio", status: .info, detail: "No se pudo leer.")
        }
        return evaluateUptime(boot: Date(timeIntervalSince1970: TimeInterval(tv.tv_sec)), now: now)
    }

    public static func evaluateUptime(boot: Date, now: Date) -> HealthCheck {
        let days = now.timeIntervalSince(boot) / 86_400
        let text = "Encendido desde \(Fmt.relative(boot, now: now))."
        if days > 30 {
            return .init(id: "uptime", group: .system, title: "Último reinicio", status: .info,
                         detail: text + " Reiniciar de vez en cuando aplica actualizaciones pendientes y libera memoria.")
        }
        return .init(id: "uptime", group: .system, title: "Último reinicio", status: .good, detail: text)
    }

    /// Solo en portátiles (si `pmset -g batt` muestra una batería interna).
    static func battery() -> [HealthCheck] {
        guard let batt = Cmd.run("/usr/bin/pmset", ["-g", "batt"]), batt.contains("InternalBattery") else { return [] }
        let profile = Cmd.run("/usr/sbin/system_profiler", ["SPPowerDataType"], timeout: 10) ?? ""
        return [parseBattery(profile)]
    }

    public static func parseBattery(_ profile: String) -> HealthCheck {
        var fields: [String: String] = [:]
        for line in profile.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let k = parts[0].trimmingCharacters(in: .whitespaces)
            if fields[k] == nil { fields[k] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        let cycles = fields["Cycle Count"].map { "\($0) ciclos" }
        let capacity = fields["Maximum Capacity"].map { "capacidad máxima \($0)" }
        let condition = fields["Condition"] ?? ""
        let info = [cycles, capacity].compactMap { $0 }.joined(separator: " · ")
        let pane = "x-apple.systempreferences:com.apple.Battery-Settings.extension"
        switch condition {
        case "Normal", "":
            return .init(id: "battery", group: .system, title: "Batería", status: .good,
                         detail: (info.isEmpty ? "Estado normal" : info.prefix(1).uppercased() + info.dropFirst()) + ".", settingsURL: pane)
        default:
            return .init(id: "battery", group: .system, title: "Batería", status: .warning,
                         detail: "Estado: \(condition)" + (info.isEmpty ? "" : " · \(info)") + ". Conviene revisarla en un servicio técnico.", settingsURL: pane)
        }
    }
}

// MARK: - Utilidades

private final class Box: @unchecked Sendable {
    private var values: [[HealthCheck]]
    private let lock = NSLock()
    init(count: Int) { values = Array(repeating: [], count: count) }
    func set(_ i: Int, _ v: [HealthCheck]) { lock.withLock { values[i] = v } }
    var all: [[HealthCheck]] { lock.withLock { values } }
}

enum Cmd {
    /// Ejecuta un comando y devuelve su salida (stdout + stderr), o nil si falla al lanzarse o tarda demasiado.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        // Se lee mientras corre para que una salida grande no bloquee el proceso.
        let data = pipe.fileHandleForReading.readDataToEndOfFileWithTimeout(timeout)
        if done.wait(timeout: .now() + (data == nil ? 0 : 1)) == .timedOut {
            p.terminate()
            return nil
        }
        return data.map { String(decoding: $0, as: UTF8.self) }
    }
}

extension FileHandle {
    /// Lee hasta el final o hasta `timeout`; nil si se agotó el tiempo.
    func readDataToEndOfFileWithTimeout(_ timeout: TimeInterval) -> Data? {
        let box = DataBox()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.data = self.readDataToEndOfFile()
            sem.signal()
        }
        return sem.wait(timeout: .now() + timeout) == .timedOut ? nil : box.data
    }
}

private final class DataBox: @unchecked Sendable { var data: Data? }

public enum Fmt {
    public static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    /// «hoy», «ayer», «hace 3 días», «hace 2 meses».
    public static func relative(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "hoy"
        case 1: return "ayer"
        case 2..<30: return "hace \(days) días"
        case 30..<60: return "hace 1 mes"
        case 60..<365: return "hace \(days / 30) meses"
        default: return "hace más de un año"
        }
    }
}
