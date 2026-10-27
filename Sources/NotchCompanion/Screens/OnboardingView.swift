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
                case 0: scrolling(welcome)
                case 1: scrolling(chooseTools)
                case 2: scrolling(connect)
                case 3: scrolling(test)
                default: basics     // its grouped Form scrolls by itself
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Spacer()
                if step < steps.count - 1 {
                    // Never a dead end: with no agent chosen, connecting just waits for later.
                    Button(step == 0 ? "Get Started" : "Continue") { step += 1 }
                        .keyboardShortcut(.defaultAction)
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

    /// Step content scrolls between the fixed progress bar and buttons, like every other screen.
    /// Unscrolled, its wrapping text reported a minimum height measured at a sliver of width;
    /// the split view grew thousands of points to fit it and the whole window showed blank.
    private func scrolling(_ content: some View) -> some View {
        ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
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

    /// Selected agents that are actually installed: the only ones that can be connected or tested.
    private var chosen: [AgentKind] {
        AgentKind.allCases.filter { selected.contains($0) && model.integrations.status($0).isInstalled }
    }

    private var chooseTools: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenHeader(title: "Which agents do you use?",
                         subtitle: "Notch Companion checks whether each one is installed on this Mac.")
            ForEach(AgentKind.allCases, id: \.self) { agent in
                let status = model.integrations.status(agent)
                let checking = !status.isInstalled && model.integrations.detecting
                Toggle(isOn: Binding(get: { status.isInstalled && selected.contains(agent) },
                                     set: { if $0 { selected.insert(agent) } else { selected.remove(agent) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.displayName).font(.headline)
                        Group {
                            if status.isInstalled {
                                Text("Installed\(status.version.map { " · v\($0)" } ?? "") · \(status.state)")
                            } else if checking {
                                Text("Checking…")
                            } else {
                                Text("Not installed on this Mac").foregroundStyle(.orange)
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
            if chosen.isEmpty {
                noAgentsChosen
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Adds hook entries to \(chosen.map(Self.configFile).formatted(.list(type: .and))).",
                          systemImage: "doc.badge.plus")
                    Label("Keeps every existing setting and hook, and saves a timestamped backup first.", systemImage: "externaldrive.badge.checkmark")
                    Label("Hooks only report events. They never approve, deny or run anything.", systemImage: "hand.raised.slash")
                    Label("Only metadata leaves the hook: event type, tool name, project folder name. Never prompts, code or commands.", systemImage: "lock")
                }
                .font(.callout)
                ForEach(chosen, id: \.self) { agent in
                    AgentConnectRow(model: model, agent: agent, showsTest: false)
                }
            }
        }
    }

    private static func configFile(_ agent: AgentKind) -> String {
        switch agent {
        case .claudeCode: "~/.claude/settings.json"
        case .codex: "~/.codex/hooks.json"
        }
    }

    private var noAgentsChosen: some View {
        Text("No installed agent is selected. You can connect one any time from Connect Your Tools in the menu bar.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenHeader(title: "Try it",
                         subtitle: "This sends a simulated permission request through the real hook helper.")
            if chosen.isEmpty { noAgentsChosen }
            HStack {
                ForEach(chosen, id: \.self) { agent in
                    Button("Test \(agent.displayName)") { model.integrations.test(agent) }
                }
            }
            ForEach(chosen, id: \.self) { agent in
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
                LoginItemToggle()
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
