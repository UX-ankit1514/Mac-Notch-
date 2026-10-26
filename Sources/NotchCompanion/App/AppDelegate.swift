import AppKit
import NotchCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private(set) var notch: NotchController!
    private var menuBar: MenuBarController!
    private var windows: WindowController!
    private let hotKey = HotKey()

    func applicationDidFinishLaunching(_ notification: Notification) {
        CharacterAssets.shared.preload()
        model.start()

        notch = NotchController(model: model)
        notch.start()
        windows = WindowController(model: model)
        menuBar = MenuBarController(model: model, windows: windows)

        model.settingsChanged = { [weak self] in self?.settingsChanged() }
        settingsChanged()

        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--show"), i + 1 < args.count, let screen = Screen(rawValue: args[i + 1]) {
            windows.show(screen)
        } else if let i = args.firstIndex(of: "--demo"), i + 1 < args.count {
            runDemo(args[i + 1])
        } else if !model.settings.hasCompletedOnboarding {
            windows.show(.welcome)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.show(.tools)
        return true
    }

    private func settingsChanged() {
        notch.applySettings()
        if model.settings.hotkeyEnabled {
            hotKey.register { [weak self] in self?.notch.toggleList() }
        } else {
            hotKey.unregister()
        }
    }

    /// `--demo <emotion|all>`: plays emotions in the notch for visual checks.
    private func runDemo(_ name: String) {
        let types: [EventType] = [.permission, .question, .idle, .testFailed, .criticalError,
                                  .completed, .buildFailed, .stopped]
        let wanted: [EventType]
        if name == "all" {
            wanted = types
        } else if name == "list" {
            model.simulate(.permission, agent: .claudeCode, project: "Portfolio Website")
            model.simulate(.question, agent: .codex, project: "Dashboard Redesign")
            model.showPendingList()
            return
        } else if let emotion = Emotion(rawValue: name) {
            if emotion == .envy {
                model.simulate(.permission, agent: .claudeCode, project: "Portfolio Website")
                model.simulate(.permission, agent: .codex, project: "Dashboard Redesign")
                return
            }
            wanted = types.filter { EmotionEngine.emotion(for: $0) == emotion }
        } else {
            wanted = []
        }
        Task { @MainActor in
            for type in wanted {
                model.simulate(type)
                try? await Task.sleep(for: .seconds(wanted.count > 1 ? 4.5 : 0))
                if wanted.count > 1 { model.dismissAll() }
            }
        }
    }
}
