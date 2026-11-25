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
        // Servicios que arrancan solos (launchd): listar, desactivar y reactivar.
        .target(
            name: "Startup",
            path: "Sources/Startup"
        ),
        .executableTarget(
            name: "MacOSUtil",
            dependencies: ["TweakEngine", "AppCatalog", "Startup"],
            path: "Sources/MacOSUtil"
        )
    ],
    swiftLanguageModes: [.v5]
)
