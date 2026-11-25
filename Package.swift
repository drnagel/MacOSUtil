// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacOSUtil",
    platforms: [.macOS(.v15)],
    targets: [
        // Textos del catálogo en varios idiomas ({ "en": …, "es": … }).
        .target(
            name: "CatalogText",
            path: "Sources/CatalogText"
        ),
        // Motor de ajustes: catálogo declarativo + aplicar / comprobar / revertir. Sin UI.
        .target(
            name: "TweakEngine",
            dependencies: ["CatalogText"],
            path: "Sources/TweakEngine"
        ),
        // Catálogo de apps + Homebrew: detectar, instalar, actualizar y desinstalar.
        .target(
            name: "AppCatalog",
            dependencies: ["CatalogText"],
            path: "Sources/AppCatalog"
        ),
        // Operaciones de administrador (lista cerrada, contraseña por lote), energía (pmset) y Spotlight (mdutil).
        .target(
            name: "Privileged",
            path: "Sources/Privileged"
        ),
        // Estado del Mac: seguridad, actualizaciones, copias, discos y sistema. Solo lectura, sin contraseña.
        .target(
            name: "Health",
            path: "Sources/Health"
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
            dependencies: ["CatalogText"],
            path: "Sources/Profiles"
        ),
        // Catálogo firmado: empaquetar, firmar, verificar e instalar actualizaciones desde GitHub.
        .target(
            name: "CatalogUpdate",
            dependencies: ["TweakEngine", "AppCatalog", "Profiles"],
            path: "Sources/CatalogUpdate"
        ),
        .executableTarget(
            name: "MacOSUtil",
            dependencies: ["TweakEngine", "AppCatalog", "Startup", "Profiles", "Privileged", "Health", "CatalogUpdate"],
            path: "Sources/MacOSUtil"
        )
    ],
    swiftLanguageModes: [.v5]
)
