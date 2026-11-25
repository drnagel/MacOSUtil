// Dibuja el icono de MacOSUtil (tres deslizadores de ajustes sobre fondo oscuro) en un PNG de 1024 px.
// Mismo fondo y paleta que DiskTree, para que se vean como una familia.
// Uso: swift Scripts/make_icon.swift <salida.png>
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Fondo tipo "squircle" (igual que DiskTree)
let inset: CGFloat = 100
let bgRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)
NSGradient(starting: color(0x1B1B1F), ending: color(0x050506))!.draw(in: bg, angle: -90)
color(0xFFFFFF, 0.08).setStroke(); bg.lineWidth = 4; bg.stroke()

// Tres deslizadores: (color, posición del mando de 0 a 1), de arriba abajo.
let sliders: [(UInt32, UInt32, CGFloat)] = [
    (0x2FA8F5, 0x7FCBFA, 0.70),
    (0xB65CF2, 0xD39BF7, 0.32),
    (0x1CCFA5, 0x6FE3C6, 0.56),
]
let trackX = bgRect.minX + 150
let trackW = bgRect.width - 300
let trackH: CGFloat = 56
let knobR: CGFloat = 74
let spacing: CGFloat = 210
let midY = bgRect.midY

for (i, s) in sliders.enumerated() {
    let y = midY + spacing * CGFloat(1 - i)
    let (base, light, pos) = s
    let knobX = trackX + trackW * pos

    // Pista apagada
    let track = NSBezierPath(roundedRect: NSRect(x: trackX, y: y - trackH / 2, width: trackW, height: trackH),
                             xRadius: trackH / 2, yRadius: trackH / 2)
    color(0xFFFFFF, 0.10).setFill(); track.fill()

    // Tramo activo (hasta el mando), con degradado
    let active = NSBezierPath(roundedRect: NSRect(x: trackX, y: y - trackH / 2, width: knobX - trackX, height: trackH),
                              xRadius: trackH / 2, yRadius: trackH / 2)
    NSGradient(starting: color(base, 0.85), ending: color(light))!.draw(in: active, angle: 0)

    // Mando: sombra, círculo blanco y punto del color de la pista
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.55)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let knob = NSBezierPath(ovalIn: NSRect(x: knobX - knobR, y: y - knobR, width: knobR * 2, height: knobR * 2))
    NSGradient(starting: color(0xFFFFFF), ending: color(0xD9D9DE))!.draw(in: knob, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let dotR: CGFloat = 26
    color(base).setFill()
    NSBezierPath(ovalIn: NSRect(x: knobX - dotR, y: y - dotR, width: dotR * 2, height: dotR * 2)).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
