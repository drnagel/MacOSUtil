import SwiftUI
import Health

@MainActor
@Observable
final class HealthModel {
    private(set) var checks: [HealthCheck] = []
    private(set) var isChecking = false
    private(set) var checkedAt: Date?

    /// Avisos y problemas (para el contador de la barra lateral).
    var issueCount: Int { checks.filter { $0.status >= .warning }.count }

    func checks(in group: HealthCheck.Group) -> [HealthCheck] {
        checks.filter { $0.group == group }
    }

    func refresh() {
        guard !isChecking else { return }
        isChecking = true
        Task.detached {
            let found = HealthScanner.run()
            await MainActor.run {
                self.checks = found
                self.checkedAt = Date()
                self.isChecking = false
            }
        }
    }
}

struct HealthView: View {
    @Environment(AppModel.self) private var root

    var body: some View {
        let model = root.health
        Form {
            Section {
                HStack(spacing: 14) {
                    summaryIcon(model)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summaryTitle(model)).font(.uiTitle3.weight(.semibold))
                        Text(summaryDetail(model)).font(.uiCaption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isChecking { ProgressView().controlSize(.small) }
                }
                .padding(.vertical, 4)
            }
            ForEach(HealthCheck.Group.allCases, id: \.self) { group in
                let items = model.checks(in: group)
                if !items.isEmpty {
                    Section(group.title) {
                        ForEach(items) { HealthRow(check: $0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Estado del Mac")
        .onAppear { if model.checks.isEmpty { model.refresh() } }
    }

    @ViewBuilder
    private func summaryIcon(_ m: HealthModel) -> some View {
        let worst = m.checks.map(\.status).max() ?? .good
        Image(systemName: worst >= .warning ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
            .font(.system(size: 30))
            .foregroundStyle(worst == .bad ? Color.red : (worst == .warning ? Color.orange : Color.green))
    }

    private func summaryTitle(_ m: HealthModel) -> String {
        if m.checks.isEmpty { return "Comprobando…" }
        let bad = m.checks.filter { $0.status == .bad }.count
        let warn = m.checks.filter { $0.status == .warning }.count
        if bad == 0 && warn == 0 { return "Todo en orden" }
        var parts: [String] = []
        if bad > 0 { parts.append("\(bad) \(bad == 1 ? "problema" : "problemas")") }
        if warn > 0 { parts.append("\(warn) \(warn == 1 ? "aviso" : "avisos")") }
        return parts.joined(separator: " y ")
    }

    private func summaryDetail(_ m: HealthModel) -> String {
        guard let at = m.checkedAt else { return "Seguridad, actualizaciones, copias de seguridad, discos y sistema." }
        return "Comprobado a las \(at.formatted(date: .omitted, time: .shortened)). Solo se lee: aquí no se cambia nada. Pulsa ⌘R para volver a comprobar."
    }
}

private struct HealthRow: View {
    let check: HealthCheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.uiTitle3).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title)
                Text(check.detail).font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let s = check.settingsURL, let url = URL(string: s), check.status >= .warning {
                Button("Abrir Ajustes") { NSWorkspace.shared.open(url) }.controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch check.status {
        case .good: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .bad: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch check.status {
        case .good: .green
        case .info: .secondary
        case .warning: .orange
        case .bad: .red
        }
    }
}
