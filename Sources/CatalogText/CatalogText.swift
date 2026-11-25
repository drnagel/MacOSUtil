import Foundation

/// Textos del catálogo en varios idiomas: `"title": { "en": "…", "es": "…" }`.
/// Al leer el catálogo se elige el idioma de la app (el del Mac si está traducido; si no, inglés).
/// También se acepta un texto simple (`"title": "…"`) para catálogos antiguos.
public enum CatalogLanguage {
    /// Idiomas que debe tener cada texto del catálogo. El primero es el de reserva.
    public static let required = ["en", "es"]

    /// Idioma en el que se muestra la app ("en" o "es").
    public static var current: String {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        return required.contains(lang) ? lang : "en"
    }

    /// Elige el texto del idioma actual, luego inglés, luego cualquiera.
    public static func pick(_ values: [String: String]) -> String {
        values[current] ?? values["en"] ?? values.values.sorted().first ?? ""
    }
}

extension KeyedDecodingContainer {
    public func decodeLocalized(forKey key: Key) throws -> String {
        if let s = try? decode(String.self, forKey: key) { return s }
        let values = try decode([String: String].self, forKey: key)
        guard !values.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Texto sin traducciones")
        }
        return CatalogLanguage.pick(values)
    }
}
