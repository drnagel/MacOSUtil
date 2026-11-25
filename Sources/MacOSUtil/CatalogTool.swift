import Foundation
import CryptoKit
import CatalogUpdate

/// Herramienta del catálogo, sin interfaz: `MacOSUtil --catalog <orden>`.
///
///   validate [Catalog]                  Valida el catálogo (lo usa la acción de GitHub en cada pull request).
///   keygen [archivo]                    Crea la clave de firma (por defecto ~/.config/macosutil/catalog-signing.key).
///   bundle [Catalog] [dist] [--key k]   Valida, empaqueta y firma → dist/catalog.json y dist/catalog.json.sig.
///   verify [dist]                       Comprueba la firma de dist/ con la clave pública de la app y su contenido.
///
/// Los mensajes son para quien mantiene el catálogo, así que no se traducen.
enum CatalogTool {
    static var defaultKey: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/macosutil/catalog-signing.key")
    }

    static func run(_ args: [String]) -> Int32 {
        let cmd = args.first ?? "help"
        var rest = Array(args.dropFirst())
        var keyPath = defaultKey
        if let i = rest.firstIndex(of: "--key"), rest.indices.contains(i + 1) {
            keyPath = URL(fileURLWithPath: (rest[i + 1] as NSString).expandingTildeInPath)
            rest.removeSubrange(i...(i + 1))
        }
        func path(_ i: Int, _ fallback: String) -> URL { URL(fileURLWithPath: rest.indices.contains(i) ? rest[i] : fallback) }

        switch cmd {
        case "validate":
            let dir = path(0, "Catalog")
            let problems = CatalogBundle.validate(dir: dir)
            if problems.isEmpty { print("✓ Catalog is valid (\(dir.path))"); return 0 }
            print("✗ \(problems.count) problem(s):\n  " + problems.joined(separator: "\n  "))
            return 1

        case "keygen":
            let file = rest.first.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultKey
            guard !FileManager.default.fileExists(atPath: file.path) else {
                print("✗ \(file.path) already exists. Delete it first if you really want a new key."); return 1
            }
            let key = Curve25519.Signing.PrivateKey()
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try key.rawRepresentation.base64EncodedString().write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { print("✗ \(error.localizedDescription)"); return 1 }
            print("✓ Private key saved to \(file.path) (never commit it)")
            print("Public key (paste into CatalogBundle.publicKey):\n\(key.publicKey.rawRepresentation.base64EncodedString())")
            return 0

        case "bundle":
            let dir = path(0, "Catalog"), out = path(1, "dist")
            let problems = CatalogBundle.validate(dir: dir)
            guard problems.isEmpty else { print("✗ Invalid catalog:\n  " + problems.joined(separator: "\n  ")); return 1 }
            guard let keyText = try? String(contentsOf: keyPath, encoding: .utf8),
                  let raw = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
                print("✗ Couldn't read the signing key at \(keyPath.path)"); return 1
            }
            do {
                let data = try CatalogBundle.make(from: dir).encoded()
                let sig = try CatalogBundle.sign(data, privateKey: key)
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try data.write(to: out.appendingPathComponent("catalog.json"))
                try (sig + "\n").write(to: out.appendingPathComponent("catalog.json.sig"), atomically: true, encoding: .utf8)
                let bundle = try CatalogBundle.verify(data, signature: sig, publicKey: key.publicKey.rawRepresentation.base64EncodedString())
                print("✓ dist/catalog.json v\(bundle.version) · \(bundle.files.count) files · signed")
                if key.publicKey.rawRepresentation.base64EncodedString() != CatalogBundle.publicKey {
                    print("⚠︎ This key doesn't match CatalogBundle.publicKey: the app will reject this catalog.")
                    return 1
                }
                return 0
            } catch { print("✗ \(error.localizedDescription)"); return 1 }

        case "verify":
            let out = path(0, "dist")
            do {
                let data = try Data(contentsOf: out.appendingPathComponent("catalog.json"))
                let sig = try String(contentsOf: out.appendingPathComponent("catalog.json.sig"), encoding: .utf8)
                let bundle = try CatalogBundle.verify(data, signature: sig)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("macosutil-verify-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: tmp) }
                try bundle.write(to: tmp)
                let problems = CatalogBundle.validate(dir: tmp)
                guard problems.isEmpty else { print("✗ Signed, but invalid:\n  " + problems.joined(separator: "\n  ")); return 1 }
                print("✓ Valid signature · catalog v\(bundle.version) · \(bundle.files.count) files")
                return 0
            } catch { print("✗ \(error.localizedDescription)"); return 1 }

        default:
            print("""
            usage: MacOSUtil --catalog <command>
              validate [Catalog]                 validate the catalog folder
              keygen [file]                      create the signing key (default ~/.config/macosutil/catalog-signing.key)
              bundle [Catalog] [dist] [--key k]  validate, bundle and sign into dist/
              verify [dist]                      check dist/ against the app's public key
            """)
            return cmd == "help" ? 0 : 2
        }
    }
}
