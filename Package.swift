// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacOSUtil",
    platforms: [.macOS(.v15)],
    targets: [
        // Motor de ajustes: catálogo declarativo + aplicar / comprobar / revertir. Sin UI.
        .target(
            name: "TweakEngine",
            path: "Sources/TweakEngine"
        ),
        // Catálogo de apps + Homebrew: detectar, instalar, actualizar y desinstalar.
        .target(
            name: "AppCatalog",
            path: "Sources/AppCatalog"
        ),
        // Operaciones de administrador (lista cerrada, contraseña por lote), energía (pmset) y Spotlight (mdutil).
        .target(
            name: "Privileged",
            path: "Sources/Privileged"
        ),
        // Servicios que arrancan solos (launchd): listar, desactivar y reactivar.
        .target(
            name: "Startup",
            dependencies: ["Privileged"],
            path: "Sources/Startup"
        ),
        // Perfiles del asistente y archivos de configuración exportados. Solo ids: no depende de los otros módulos.
        .target(
            name: "Profiles",
            path: "Sources/Profiles"
        ),
        .executableTarget(
            name: "MacOSUtil",
            dependencies: ["TweakEngine", "AppCatalog", "Startup", "Profiles", "Privileged"],
            path: "Sources/MacOSUtil"
        )
    ],
    swiftLanguageModes: [.v5]
)
