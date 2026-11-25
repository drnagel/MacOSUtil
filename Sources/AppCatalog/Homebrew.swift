import Foundation
import AppKit

/// Acceso a Homebrew. Siempre se llama al binario por ruta absoluta (las apps gráficas no heredan el PATH del shell).
public enum Homebrew {
    public static let installerPage = URL(string: "https://github.com/Homebrew/brew/releases/latest")!

    public static var path: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var isInstalled: Bool { path != nil }

    /// Los tokens se pasan como argumentos (nunca por un shell), pero igualmente se restringen a este formato.
    public static func isValidToken(_ t: String) -> Bool {
        t.range(of: #"^[a-z0-9][a-z0-9@._+-]*$"#, options: .regularExpression) != nil
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        env["NONINTERACTIVE"] = "1"
        return env
    }

    // MARK: Ejecutar

    public struct RunResult: Sendable {
        public let status: Int32
        public let output: String
        public var ok: Bool { status == 0 }
    }

    /// Ejecuta `brew <args>` y va pasando cada línea de salida a `onLine`.
    public static func run(_ args: [String], onLine: (@Sendable (String) -> Void)? = nil) async -> RunResult {
        guard let brew = path else { return RunResult(status: -1, output: "Homebrew no está instalado.") }
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: brew)
            p.arguments = args
            p.environment = environment
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let buffer = LineBuffer(onLine: onLine)
            pipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if !data.isEmpty { buffer.append(data) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? pipe.fileHandleForReading.readToEnd() { buffer.append(rest) }
                buffer.flush()
                cont.resume(returning: RunResult(status: proc.terminationStatus, output: buffer.all))
            }
            do { try p.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: RunResult(status: -1, output: error.localizedDescription))
            }
        }
    }

    public static func install(_ token: String, onLine: (@Sendable (String) -> Void)? = nil) async -> RunResult {
        guard isValidToken(token) else { return RunResult(status: -1, output: "Token no válido") }
        return await run(["install", "--cask", token], onLine: onLine)
    }

    public static func upgrade(_ token: String, onLine: (@Sendable (String) -> Void)? = nil) async -> RunResult {
        guard isValidToken(token) else { return RunResult(status: -1, output: "Token no válido") }
        return await run(["upgrade", "--cask", token], onLine: onLine)
    }

    public static func uninstall(_ token: String, onLine: (@Sendable (String) -> Void)? = nil) async -> RunResult {
        guard isValidToken(token) else { return RunResult(status: -1, output: "Token no válido") }
        return await run(["uninstall", "--cask", token], onLine: onLine)
    }

    // MARK: Consultar

    /// Información de varios casks en una sola llamada. Si alguno no existe, `brew info` falla entero,
    /// así que se reintenta de uno en uno. Los que no existen no aparecen en el resultado.
    public static func info(_ tokens: [String]) async -> [String: CaskInfo] {
        let valid = tokens.filter(isValidToken)
        guard !valid.isEmpty else { return [:] }
        let all = await run(["info", "--json=v2", "--cask"] + valid)
        if all.ok, let parsed = parseInfo(all.output) { return parsed }
        var result: [String: CaskInfo] = [:]
        for t in valid {
            let one = await run(["info", "--json=v2", "--cask", t])
            if one.ok, let parsed = parseInfo(one.output) { result.merge(parsed) { a, _ in a } }
        }
        return result
    }

    static func parseInfo(_ output: String) -> [String: CaskInfo]? {
        // La salida JSON empieza en la primera «{»; antes puede haber avisos de brew.
        guard let start = output.firstIndex(of: "{"),
              let data = String(output[start...]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return nil }
        var result: [String: CaskInfo] = [:]
        for c in casks {
            guard let token = c["token"] as? String else { continue }
            let artifacts = c["artifacts"] as? [[String: Any]] ?? []
            var appPaths: [String] = []
            var needsAdmin = false
            for a in artifacts {
                if a["pkg"] != nil || a["installer"] != nil { needsAdmin = true }
                guard let apps = a["app"] as? [Any] else { continue }
                if let target = a["target"] as? String {
                    appPaths.append((target as NSString).expandingTildeInPath)
                    continue
                }
                for item in apps {
                    if let name = item as? String { appPaths.append("/Applications/" + (name as NSString).lastPathComponent) }
                    if let dict = item as? [String: Any], let target = dict["target"] as? String {
                        appPaths.append(target.hasPrefix("/") ? target : "/Applications/" + target)
                    }
                }
            }
            result[token] = CaskInfo(token: token,
                                     version: c["version"] as? String ?? "?",
                                     installed: c["installed"] as? String,
                                     outdated: c["outdated"] as? Bool ?? false,
                                     appPaths: appPaths,
                                     needsAdmin: needsAdmin)
        }
        return result
    }

    /// Estado de una entrada del catálogo a partir de la info de Homebrew y de lo que hay en disco.
    public static func status(of entry: AppEntry, info: [String: CaskInfo]) -> AppStatus {
        switch entry.source {
        case .cask(let token):
            guard let i = info[token] else { return .unavailable }
            if let v = i.installed { return .brew(version: v, outdated: i.outdated) }
            if let p = findApp(entry, known: i.appPaths) { return .manual(path: p) }
            return .notInstalled
        case .appStore:
            return findApp(entry, known: []).map { .manual(path: $0) } ?? .notInstalled
        case nil:
            return .unavailable
        }
    }

    /// Busca la .app en /Applications y ~/Applications: primero las rutas que declara el cask y luego
    /// por nombre (`appName` o «<name>.app»), que cubre los casks que instalan un .pkg sin declarar la app.
    static func findApp(_ entry: AppEntry, known: [String]) -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory() + "/Applications/"
        var names = known.map { ($0 as NSString).lastPathComponent }
        names.append(entry.appName ?? entry.name + ".app")
        var candidates = known
        for n in names { candidates += ["/Applications/" + n, home + n] }
        return candidates.first(where: fm.fileExists(atPath:))
    }

    // MARK: Terminal

    /// Los casks que instalan un .pkg piden la contraseña de administrador, y eso solo se puede escribir
    /// en una terminal. Genera un script `.command` y lo abre en Terminal.
    @discardableResult
    public static func openInTerminal(_ commands: [[String]], title: String) -> Bool {
        guard let brew = path else { return false }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacOSUtil", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("brew-\(UUID().uuidString.prefix(8)).command")
        var lines = ["#!/bin/zsh", "clear", "echo '\(title.replacingOccurrences(of: "'", with: ""))'", "echo"]
        for args in commands {
            // Todos los argumentos son tokens validados o flags fijos: no hay nada que escapar.
            guard args.allSatisfy({ isValidToken($0) || $0.hasPrefix("--") || ["install", "upgrade", "uninstall"].contains($0) })
            else { return false }
            lines.append("\(brew) \(args.joined(separator: " "))")
        }
        lines += ["echo", "echo 'Terminado. Vuelve a MacOSUtil y pulsa «Volver a comprobar».'", "read -k1 '?Pulsa una tecla para cerrar…'",
                  "rm -f \"$0\""]
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// Acumula la salida y la entrega por líneas completas.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private var collected = Data()
    private let lock = NSLock()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        collected.append(data)
        pending.append(data)
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...nl)
            emit(line)
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { emit(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
    }

    var all: String { lock.withLock { String(decoding: collected, as: UTF8.self) } }

    private func emit(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { onLine?(trimmed) }
    }
}
