import AppKit
import NotchCore
import SwiftUI

/// Notification History (PRD FR-09, §15.4).
struct HistoryView: View {
    let model: AppModel
    @LocalState private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                ScreenHeader(title: "Notification History",
                             subtitle: "Kept on this Mac for \(model.settings.historyRetentionDays) days. Metadata only.")
                Spacer()
                Button("Clear History…") { confirmClear = true }
                    .disabled(model.history.isEmpty)
            }
            if model.history.isEmpty {
                ContentUnavailableView("No notifications yet", systemImage: "tray",
                                       description: Text("Events from connected agents will appear here."))
            } else {
                List(model.history) { record in
                    HistoryRow(record: record, model: model)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            if let message = model.lastNavigation {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .confirmationDialog("Clear all notification history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("Pending requests stay in the notch until their agents move on.")
        }
    }
}

private struct HistoryRow: View {
    let record: NotificationRecord
    let model: AppModel

    var body: some View {
        let event = record.event
        HStack(spacing: 12) {
            Image(systemName: event.type.symbol)
                .foregroundStyle(event.type.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(AlertCopy.title(for: event)).font(.body.weight(.medium))
                Text(AlertCopy.subtitle(for: event)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(statusText)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            Text(record.lastSeen.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            Button("Return") { model.open(record) }
                .disabled(!canReturn)
                .help(canReturn ? (model.navigation.hint(for: event.host) ?? "") : "Source app isn't running")
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if record.muted { return "Muted" }
        switch record.status {
        case .pending: return record.dismissed ? "Pending · dismissed" : "Pending"
        case .resolved: return record.event.type.needsAttention ? "Resolved" : "Shown"
        case .expired: return "Expired"
        }
    }

    private var canReturn: Bool {
        guard let id = record.event.host.bundleID, id != AppPaths.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }
}

/// Settings (PRD FR-10, §15.5).
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        Form {
            Section("General") {
                LoginItemToggle()
                Toggle("Show pending requests with ⌃⌥N", isOn: $model.settings.hotkeyEnabled)
            }

            Section("Notifications") {
                ForEach(EventCategory.allCases, id: \.self) { category in
                    Toggle(category.displayName, isOn: Binding(
                        get: { model.settings.enabledCategories.contains(category) },
                        set: { on in
                            if on { model.settings.enabledCategories.insert(category) }
                            else { model.settings.enabledCategories.remove(category) }
                        }))
                }
                ForEach(AgentKind.allCases, id: \.self) { agent in
                    Toggle("Alerts from \(agent.displayName)", isOn: Binding(
                        get: { model.settings.enabledAgents.contains(agent) },
                        set: { on in
                            if on { model.settings.enabledAgents.insert(agent) }
                            else { model.settings.enabledAgents.remove(agent) }
                        }))
                }
                Toggle("Sound", isOn: $model.settings.soundEnabled)
                Picker("Remind me about unanswered requests", selection: $model.settings.reminderMinutes) {
                    Text("Never").tag(0)
                    Text("Every 2 minutes").tag(2)
                    Text("Every 5 minutes").tag(5)
                    Text("Every 15 minutes").tag(15)
                }
            }

            Section("Quiet") {
                Toggle("Quiet mode (no sound, compact alerts)", isOn: $model.settings.quietMode)
                Toggle("Quiet hours", isOn: $model.settings.quietHoursEnabled)
                if model.settings.quietHoursEnabled {
                    MinutePicker(title: "From", minutes: $model.settings.quietHoursStart)
                    MinutePicker(title: "Until", minutes: $model.settings.quietHoursEnd)
                }
                Toggle("Respect macOS Focus", isOn: $model.settings.respectFocus)
                HStack {
                    Text("Focus status: \(model.focus.availability)").font(.caption).foregroundStyle(.secondary)
                    if model.focus.availability == "Not requested" {
                        Button("Allow") { model.focus.request() }.controlSize(.small)
                    }
                }
            }

            Section("Motion") {
                Picker("Character motion", selection: $model.settings.motionIntensity) {
                    ForEach(MotionIntensity.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Reduce motion", isOn: $model.settings.reduceMotion)
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    Text("Reduce Motion is on in System Settings, so the character uses cross-fades only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("History & privacy") {
                Picker("Keep history for", selection: $model.settings.historyRetentionDays) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                Text("Stored locally: agent, project folder name, event type, tool name, host app, time and status. Never prompts, code, command text or credentials. Nothing is sent off this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Help & diagnostics") {
                LabeledContent("Version", value: "\(NotchVersion.app) (connector \(NotchVersion.connector))")
                LabeledContent("Data folder") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.support]) }
                }
                LabeledContent("Events received", value: "\(model.diagnostics.received)")
                if let p95 = model.diagnostics.p95Latency {
                    LabeledContent("Alert latency (p95)", value: String(format: "%.0f ms", p95 * 1000))
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct MinutePicker: View {
    let title: String
    @Binding var minutes: Int

    var body: some View {
        DatePicker(title, selection: Binding(
            get: { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date() },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
    }
}
