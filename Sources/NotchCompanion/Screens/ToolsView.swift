import NotchCore
import SwiftUI

/// Connect Your Tools (PRD FR-02, §15.2): per-agent status, actions, and an
/// honest capability matrix.
struct ToolsView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Connect Your Tools",
                             subtitle: "Notch Companion listens to official agent hooks. Nothing is read from your screen.")
                ForEach(AgentKind.allCases, id: \.self) { agent in
                    AgentConnectRow(model: model, agent: agent)
                }

                Text("What each agent can report").font(.headline).padding(.top, 6)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Event").bold()
                        ForEach(AgentKind.allCases, id: \.self) { Text($0.displayName).bold() }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Self.rows, id: \.self) { type in
                        GridRow {
                            Text(type.displayName)
                            ForEach(AgentKind.allCases, id: \.self) { agent in
                                let cap = Connectors.connector(for: agent).capabilities.first { $0.type == type }
                                Label(cap?.support.label ?? "Unavailable",
                                      systemImage: Self.symbol(cap?.support ?? .unavailable))
                                    .foregroundStyle(cap?.support == .supported ? Color.primary : Color.secondary)
                                    .help(cap?.source ?? "")
                            }
                        }
                    }
                }
                .font(.callout)

                Text("Event receiver").font(.headline).padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    if let error = model.serverError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        Label("Listening on a private local socket", systemImage: "checkmark.circle")
                    }
                    let d = model.diagnostics
                    Text("Events received: \(d.received) · rejected: \(d.rejected.values.reduce(0, +)) · rate-limited: \(d.rateLimited)")
                    if let p95 = d.p95Latency {
                        Text("Alert latency p95: \(String(format: "%.0f ms", p95 * 1000))")
                    }
                    Text("Hook helper: \(model.paths.installedHook.path)").textSelection(.enabled)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(28)
        }
    }

    static let rows: [EventType] = [.permission, .question, .completed, .criticalError, .buildFailed, .testFailed, .stopped, .idle]

    static func symbol(_ support: Support) -> String {
        switch support {
        case .supported: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .unavailable: "minus.circle"
        }
    }
}
