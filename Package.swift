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
        .executableTarget(
            name: "MacOSUtil",
            dependencies: ["TweakEngine"],
            path: "Sources/MacOSUtil"
        )
    ],
    swiftLanguageModes: [.v5]
)
