import Foundation

/// Texto traducible. La clave es el texto en español (como está en el código) y la traducción al inglés
/// está en `Localization/en.json`; `Scripts/build.sh` genera las tablas de cada idioma.
func L(_ text: String.LocalizationValue) -> String { String(localized: text) }
