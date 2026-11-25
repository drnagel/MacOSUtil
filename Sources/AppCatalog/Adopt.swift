import Foundation

/// Pasar a Homebrew una app del catálogo que se instaló a mano, para poder actualizarla desde MacOSUtil.
///
/// - Misma versión que el cask → `brew install --cask --adopt`: Homebrew se queda con tu copia tal cual
///   (solo la acepta si es idéntica a la que instalaría).
/// - Versión distinta → `brew install --cask --force`: descarga la última y sustituye la app.
///   Los ajustes y datos de ~/Library no se tocan.
/// - Si la app está en ~/Applications, se pasa `--appdir` para que no cambie de sitio.
public enum Adopt {
    public enum Mode: Equatable, Sendable {
        /// La versión coincide: se adopta tu copia sin descargar otra.
        case adopt
        /// La versión no coincide: se sustituye por la de Homebrew.
        case replace
    }

    public struct Plan: Equatable, Sendable {
        public let token: String
        public let mode: Mode
        /// Versión de tu copia (CFBundleShortVersionString), si se pudo leer.
        public let localVersion: String?
        /// Versión que instalaría Homebrew.
        public let caskVersion: String
        /// Carpeta donde está tu copia, si no es /Applications.
        public let appDir: String?
        /// El cask instala un .pkg: hay que hacerlo en Terminal (pide contraseña).
        public let needsTerminal: Bool

        /// Argumentos de brew.
        public var arguments: [String] {
            var args = ["install", "--cask", mode == .adopt ? "--adopt" : "--force"]
            if let appDir { args.append("--appdir=\(appDir)") }
            args.append(token)
            return args
        }
    }

    /// Plan para una app instalada a mano en `path`. nil si no se puede (sin cask o token no válido).
    public static func plan(token: String, path: String, info: CaskInfo) -> Plan? {
        guard Homebrew.isValidToken(token) else { return nil }
        let local = localVersion(atPath: path)
        let mode: Mode = (local != nil && sameVersion(local!, info.version)) ? .adopt : .replace
        let dir = (path as NSString).deletingLastPathComponent
        let appDir = dir == "/Applications" ? nil : dir
        return Plan(token: token, mode: mode, localVersion: local, caskVersion: displayVersion(info.version),
                    appDir: appDir, needsTerminal: info.needsAdmin)
    }

    public static func localVersion(atPath path: String) -> String? {
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: plist) else { return nil }
        return (d["CFBundleShortVersionString"] as? String) ?? (d["CFBundleVersion"] as? String)
    }

    /// Los casks escriben a veces «1.2.3,456» (versión y build): se compara la parte antes de la coma.
    public static func displayVersion(_ caskVersion: String) -> String {
        String(caskVersion.split(separator: ",").first ?? Substring(caskVersion))
    }

    public static func sameVersion(_ local: String, _ cask: String) -> Bool {
        local.trimmingCharacters(in: .whitespaces) == displayVersion(cask).trimmingCharacters(in: .whitespaces)
    }
}

extension Homebrew {
    public static func adopt(_ plan: Adopt.Plan, onLine: (@Sendable (String) -> Void)? = nil) async -> RunResult {
        guard isValidToken(plan.token) else { return RunResult(status: -1, output: L("Token no válido")) }
        return await run(plan.arguments, onLine: onLine)
    }
}
