import SwiftUI

/// Tamaños de texto del panel de la derecha y del asistente: algo más grandes que los de macOS
/// (cuerpo 13 → 15 pt) para que se lean mejor. Para cambiarlos, ajusta `scale`.
extension Font {
    static let scale: CGFloat = 1.15

    private static func sized(_ pt: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: (pt * scale).rounded(), weight: weight)
    }

    static let uiBody = sized(13)
    static let uiCallout = sized(12)
    static let uiCaption = sized(10.5)
    static let uiCaption2 = sized(10)
    static let uiHeadline = sized(13, .semibold)
    static let uiTitle3 = sized(15)
    static let uiTitle2 = sized(17)
    static let uiMono = Font.system(size: (10.5 * scale).rounded(), design: .monospaced)
}

extension View {
    /// Texto bajo una sección del formulario: pequeño, gris y alineado a la izquierda
    /// (si no, hereda el tamaño del cuerpo y parece un título).
    func footerStyle() -> some View {
        font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
