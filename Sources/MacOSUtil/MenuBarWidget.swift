import SwiftUI
import Health

/// Lecturas periódicas para el widget de la barra de menús (cada 2 s; cuesta lo mismo que nada).
@MainActor
@Observable
final class MonitorModel {
    private let sampler = SystemSampler()
    private(set) var snapshot: SystemSnapshot?
    /// Últimos 60 valores (2 minutos) para las gráficas pequeñas.
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    @ObservationIgnored private var timer: Timer?

    static let historyLength = 60

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in MonitorModel.shared.tick() }
        }
    }

    static let shared = MonitorModel()

    private func tick() {
        let s = sampler.sample()
        snapshot = s
        if let cpu = s.cpu { cpuHistory = Array((cpuHistory + [cpu]).suffix(Self.historyLength)) }
        memoryHistory = Array((memoryHistory + [s.memoryFraction]).suffix(Self.historyLength))
    }
}

/// Qué se ve en la barra de menús.
enum MenuBarLabelMode: String, CaseIterable, Identifiable {
    case cpuAndMemory, cpu, memory, icon
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuAndMemory: L("CPU y memoria")
        case .cpu: L("CPU")
        case .memory: L("Memoria")
        case .icon: L("Solo el icono")
        }
    }
}

enum WidgetFormat {
    static func percent(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded())) %" } ?? "–" }
    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .memory) }
    static func disk(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    static func pressureTitle(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: L("normal")
        case .warning: L("elevada")
        case .critical: L("crítica")
        }
    }

    static func pressureColor(_ p: MemoryPressure) -> Color {
        switch p {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    static func uptime(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f.string(from: t) ?? ""
    }
}

/// Texto de la barra de menús.
struct MenuBarLabel: View {
    let monitor: MonitorModel
    let mode: MenuBarLabelMode

    var body: some View {
        let s = monitor.snapshot
        let symbol = (s?.pressure ?? .normal) > .normal ? "gauge.with.dots.needle.100percent" : "gauge.with.dots.needle.33percent"
        switch mode {
        case .icon:
            Image(systemName: symbol)
        case .cpu:
            Text("CPU \(WidgetFormat.percent(s?.cpu))").monospacedDigit()
        case .memory:
            Text(verbatim: "\(L("MEM")) \(WidgetFormat.percent(s?.memoryFraction))").monospacedDigit()
        case .cpuAndMemory:
            Text(verbatim: "CPU \(WidgetFormat.percent(s?.cpu)) · \(L("MEM")) \(WidgetFormat.percent(s?.memoryFraction))").monospacedDigit()
        }
    }
}

/// Panel que se abre al pulsar el widget.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    let monitor: MonitorModel
    @Binding var mode: MenuBarLabelMode
    @Binding var isShown: Bool

    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(Color.accentColor)
                Text("MacOSUtil").font(.headline)
                Spacer()
                if let s { Text("Encendido: \(WidgetFormat.uptime(s.uptime))").font(.caption).foregroundStyle(.secondary) }
            }

            MetricRow(title: L("CPU"), value: WidgetFormat.percent(s?.cpu), detail: L("Uso de todos los núcleos"),
                      history: monitor.cpuHistory, color: .blue)

            MetricRow(title: L("Memoria"),
                      value: s.map { "\(WidgetFormat.bytes($0.memoryUsed)) / \(WidgetFormat.bytes($0.memoryTotal))" } ?? "–",
                      detail: s.map { L("Presión \(WidgetFormat.pressureTitle($0.pressure)) · swap \(WidgetFormat.bytes($0.swapUsed))") } ?? "",
                      detailColor: s.map { $0.pressure > .normal ? WidgetFormat.pressureColor($0.pressure) : .secondary } ?? .secondary,
                      history: monitor.memoryHistory, color: s.map { WidgetFormat.pressureColor($0.pressure) } ?? .green)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Disco de arranque").font(.subheadline)
                    Spacer()
                    Text(s.map { L("\(WidgetFormat.disk($0.diskFree)) libres") } ?? "–").font(.subheadline).monospacedDigit()
                }
                ProgressView(value: s?.diskUsedFraction ?? 0)
                    .tint((s?.diskUsedFraction ?? 0) > 0.9 ? .red : .accentColor)
                if let s { Text("de \(WidgetFormat.disk(s.diskTotal))").font(.caption).foregroundStyle(.secondary) }
            }

            Divider()

            HStack {
                Button("Abrir MacOSUtil") { show(nil) }
                Button("Estado del Mac") { show(.health) }
                Button("Arranque") { show(.startup) }
            }
            .controlSize(.small)

            HStack {
                Picker("En la barra:", selection: $mode) {
                    ForEach(MenuBarLabelMode.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Spacer()
                Button("Ocultar widget") { isShown = false }.controlSize(.small)
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func show(_ section: SidebarItem?) {
        if let section { app.selection = section }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MetricRow: View {
    let title: String
    let value: String
    let detail: String
    var detailColor: Color = .secondary
    let history: [Double]
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.subheadline)
                    Spacer()
                    Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                Text(detail).font(.caption).foregroundStyle(detailColor)
            }
            Sparkline(values: history, color: color).frame(width: 90, height: 30)
        }
    }
}

/// Gráfica mínima de los últimos valores (0…1).
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let n = MonitorModel.historyLength
            let step = geo.size.width / CGFloat(max(n - 1, 1))
            let offset = CGFloat(n - values.count) * step
            let points = values.enumerated().map { i, v in
                CGPoint(x: offset + CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(min(max(v, 0), 1))))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.4))
                if points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.25))
                    Path { p in
                        p.move(to: points[0])
                        points.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(color, lineWidth: 1.5)
                }
            }
        }
    }
}
