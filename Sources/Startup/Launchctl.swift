import Foundation

/// Llamadas a /bin/launchctl. Las lecturas (`print`) funcionan sin contraseña en los dominios gui y system.
enum Launchctl {
    struct Result {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    @discardableResult
    static func run(_ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(status: -1, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// Estado de un dominio (`launchctl print gui/<uid>` o `system`): servicios con PID y lista de desactivados.
    struct DomainState {
        /// label → PID (nil si está cargado pero sin proceso)
        var services: [String: Int32?] = [:]
        /// label → true si está desactivado
        var disabled: [String: Bool] = [:]
    }

    static func domainState(_ domain: String) -> DomainState {
        parseDomain(run(["print", domain]).output)
    }

    static func parseDomain(_ text: String) -> DomainState {
        var state = DomainState()
        var block: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("= {") {
                block = String(line.dropLast(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line == "}" { block = nil; continue }
            switch block {
            case "services":
                // «     919      - \tlabel»  →  pid, último estado, label
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 3 else { continue }
                let pid = Int32(parts[0]).flatMap { $0 > 0 ? $0 : nil }
                state.services[parts[2...].joined(separator: " ")] = pid
            case "disabled services":
                // «"label" => disabled»
                guard let arrow = line.range(of: " => ") else { continue }
                let label = line[..<arrow.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                state.disabled[label] = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces) == "disabled"
            default:
                continue
            }
        }
        return state
    }

    /// Campos de un servicio concreto (`launchctl print <dominio>/<label>`): program, path…
    static func serviceInfo(domain: String, label: String) -> [String: String] {
        let r = run(["print", "\(domain)/\(label)"])
        guard r.ok else { return [:] }
        var info: [String: String] = [:]
        for raw in r.output.split(separator: "\n") {
            // Solo el primer nivel de sangría (una tabulación): los bloques anidados repiten claves como «state».
            guard raw.hasPrefix("\t"), !raw.hasPrefix("\t\t"), let eq = raw.range(of: " = ") else { continue }
            let key = raw[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = raw[eq.upperBound...].trimmingCharacters(in: .whitespaces)
            if info[key] == nil, !value.hasSuffix("{") { info[key] = value }
        }
        return info
    }
}
