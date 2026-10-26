import NotchCore
import SwiftUI

/// First-run setup (PRD Journey 1): introduce, choose tools, connect with
/// consent, test the notch, basic settings, done. No code required.
struct OnboardingView: View {
    let model: AppModel
    let finish: () -> Void
    @LocalState private var step = 0
    @LocalState private var selected: Set<AgentKind> = Set(AgentKind.allCases)
    @LocalState private var preview = CharacterController()

    private let steps = ["Welcome", "Choose tools", "Connect", "Test", "Basics"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            .accessibilityLabel("Step \(step + 1) of \(steps.count): \(steps[step])")

            Group {
                switch step {
                case 0: welcome
                case 1: chooseTools
                case 2: connect
                case 3: test
                default: basics
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Spacer()
                if step < steps.count - 1 {
                    Button(step == 0 ? "Get Started" : "Continue") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == 1 && selected.isEmpty)
                } else {
                    Button("Done") {
                        model.settings.hasCompletedOnboarding = true
                        finish()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .onAppear {
            preview.apply(intensity: model.settings.motionIntensity.scale, reduceMotion: model.reduceMotion)
            preview.director.show(.joy)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            NotchCard(height: 150) { CharacterView(controller: preview) }
            Text("Never leave an AI coding agent waiting without knowing it.")
                .font(.title2.weight(.semibold))
            Text("When Claude Code or Codex needs your permission, asks a question, fails, or finishes, the notch opens and this little companion tells you. Click it to jump back to the right app.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chooseTools: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenHeader(title: "Which agents do you use?",
                         subtitle: "Notch Companion checks whether each one is installed on this Mac.")
            ForEach(AgentKind.allCases, id: \.self) { agent in
                let status = model.integrations.status(agent)
                Toggle(isOn: Binding(get: { selected.contains(agent) },
                                     set: { if $0 { selected.insert(agent) } else { selected.remove(agent) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.displayName).font(.headline)
                        Text(status.isInstalled ? "Installed\(status.version.map { " · v\($0)" } ?? "") · \(status.state)"
                                                : "Not installed on this Mac")
                            .font(.callout)
                            .foregroundStyle(status.isInstalled ? Color.secondary : Color.orange)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!status.isInstalled)
            }
            Text("Other agents can't be detected reliably yet, so they aren't offered rather than pretending to work.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenHeader(title: "Connect notification hooks",
                         subtitle: "Here's exactly what changes before you agree.")
            VStack(alignment: .leading, spacing: 6) {
                Label("Adds hook entries to ~/.claude/settings.json and ~/.codex/hooks.json.", systemImage: "doc.badge.plus")
                Label("Keeps every existing setting and hook, and saves a timestamped backup first.", systemImage: "externaldrive.badge.checkmark")
                Label("Hooks only report events. They never approve, deny or run anything.", systemImage: "hand.raised.slash")
                Label("Only metadata leaves the hook: event type, tool name, project folder name. Never prompts, code or commands.", systemImage: "lock")
            }
            .font(.callout)
            ForEach(AgentKind.allCases.filter(selected.contains), id: \.self) { agent in
                AgentConnectRow(model: model, agent: agent, showsTest: false)
            }
        }
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenHeader(title: "Try it",
                         subtitle: "This sends a simulated permission request through the real hook helper.")
            HStack {
                ForEach(AgentKind.allCases.filter(selected.contains), id: \.self) { agent in
                    Button("Test \(agent.displayName)") { model.integrations.test(agent) }
                }
            }
            ForEach(AgentKind.allCases.filter(selected.contains), id: \.self) { agent in
                if let message = model.integrations.status(agent).message {
                    Text("\(agent.displayName): \(message)").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Look at the top of your screen: the notch should open and the character should look anxious, with \"needs permission\" next to it. Click it to come back here, or hover and press × to dismiss.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var basics: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            ScreenHeader(title: "A few basics", subtitle: "You can change these any time in Settings.")
            Form {
                Toggle("Play a sound for new alerts", isOn: $model.settings.soundEnabled)
                Picker("Character motion", selection: $model.settings.motionIntensity) {
                    ForEach(MotionIntensity.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Open at login", isOn: Binding(get: { LoginItem.isEnabled },
                                                      set: { try? LoginItem.set($0) }))
                Text("Login item: \(LoginItem.statusText)").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
    }
}

/// Status line and actions for one connector, shared by onboarding and Tools.
struct AgentConnectRow: View {
    let model: AppModel
    let agent: AgentKind
    var showsTest = true

    var body: some View {
        let status = model.integrations.status(agent)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: agent.symbol).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.displayName).font(.headline)
                    Text(statusLine(status)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if status.isInstalled {
                    if status.hooksInstalled {
                        if showsTest { Button("Test") { model.integrations.test(agent) } }
                        Button("Repair") { model.integrations.connect(agent) }
                        Button("Remove") { model.integrations.remove(agent) }
                    } else {
                        Button(status.hooksStale ? "Repair" : "Connect") { model.integrations.connect(agent) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            if let message = status.message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private func statusLine(_ s: AgentStatus) -> String {
        var parts = [s.state]
        if let version = s.version { parts.append("v\(version)") }
        if let last = s.lastEvent {
            parts.append("last event \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}
