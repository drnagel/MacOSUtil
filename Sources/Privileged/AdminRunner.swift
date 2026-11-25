import Foundation

/// Ejecuta un lote de `AdminCommand` como administrador pidiendo la contraseña **una sola vez** (diálogo de macOS).
/// No queda nada instalado ni corriendo como root: cuando termina el lote, se acabaron los permisos.
///
/// Por dentro usa `osascript … with administrator privileges`, con cada argumento entre comillas simples
/// (nunca se interpolan textos sin escapar) y solo tras validar cada comando.
public enum AdminRunner {
    public struct Outcome: Sendable, Equatable {
        public let command: AdminCommand
        public let status: Int32
        public let output: String
        public let ok: Bool
    }

    /// Valida todo el lote, pide la contraseña y ejecuta los comandos en orden. Si uno falla, sigue con el resto
    /// y devuelve el resultado de cada uno. Lanza `.cancelled` si se cancela el diálogo.
    public static func run(_ commands: [AdminCommand], reason: String) throws -> [Outcome] {
        guard !commands.isEmpty else { return [] }
        for c in commands { try c.validate() }
        let script = shellScript(commands)
        let apple = "do shell script \(appleString(script)) with prompt \(appleString(reason)) with administrator privileges"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", apple]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw AdminError.failed(error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        let errText = String(decoding: errData, as: UTF8.self)
        if p.terminationStatus != 0 {
            if errText.contains("-128") || errText.localizedCaseInsensitiveContains("cancel") { throw AdminError.cancelled }
            throw AdminError.failed("No se pudieron obtener permisos de administrador: \(errText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return parse(String(decoding: data, as: UTF8.self), commands: commands)
    }

    // MARK: Construcción del script (público para el selftest)

    /// Script de shell del lote. Cada comando va entre marcadores para separar su salida y su código.
    public static func shellScript(_ commands: [AdminCommand]) -> String {
        var lines: [String] = []
        for (i, c) in commands.enumerated() {
            let cmd = c.argv.map(shellQuote).joined(separator: " ")
            lines.append("echo '@@BEGIN \(i)'; \(cmd) 2>&1; echo \"@@END \(i) $?\"")
        }
        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }

    /// `'texto'` con las comillas simples escapadas como `'\''`.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Literal de AppleScript: escapa `\` y `"`.
    public static func appleString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Separa la salida de cada comando. `do shell script` convierte los saltos de línea en `\r`.
    public static func parse(_ text: String, commands: [AdminCommand]) -> [Outcome] {
        let lines = text.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var outputs: [Int: [String]] = [:]
        var statuses: [Int: Int32] = [:]
        var current: Int?
        for line in lines {
            if line.hasPrefix("@@BEGIN "), let i = Int(line.dropFirst(8)) {
                current = i; outputs[i] = []
            } else if line.hasPrefix("@@END ") {
                let parts = line.dropFirst(6).split(separator: " ")
                if parts.count == 2, let i = Int(parts[0]), let s = Int32(parts[1]) { statuses[i] = s }
                current = nil
            } else if let c = current {
                outputs[c, default: []].append(line)
            }
        }
        return commands.enumerated().map { i, c in
            let status = statuses[i] ?? -1
            let output = (outputs[i] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let tolerated = c.toleratedStatuses.contains(status)
                || (status != 0 && output.localizedCaseInsensitiveContains("already") && { if case .daemonStart = c { true } else { false } }())
            return Outcome(command: c, status: status, output: output, ok: status == 0 || tolerated)
        }
    }
}
