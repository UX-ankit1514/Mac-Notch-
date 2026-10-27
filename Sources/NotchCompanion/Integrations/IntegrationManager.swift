import AppKit
import NotchCore
import Observation

/// Connector status for the Connect Your Tools screen (PRD FR-02).
struct AgentStatus: Equatable {
    var agent: AgentKind
    var binaryPath: String?
    var version: String?
    var hooksInstalled = false
    var hooksStale = false
    var lastEvent: Date?
    var message: String?

    var isInstalled: Bool { binaryPath != nil }

    var state: String {
        if !isInstalled { return "Not installed" }
        if hooksStale { return "Needs repair" }
        if !hooksInstalled { return "Not connected" }
        return lastEvent == nil ? "Connected — waiting for first event" : "Connected"
    }
}

/// Detects agents, installs the hook helper, and connects/removes hooks.
@Observable
final class IntegrationManager {
    private(set) var statuses: [AgentKind: AgentStatus] = [:]
    /// True until the first search for agent binaries finishes.
    private(set) var detecting = true
    let paths: AppPaths

    init(paths: AppPaths) {
        self.paths = paths
        for agent in AgentKind.allCases { statuses[agent] = AgentStatus(agent: agent) }
    }

    func status(_ agent: AgentKind) -> AgentStatus { statuses[agent] ?? AgentStatus(agent: agent) }

    // MARK: Helper

    /// The helper shipped in the app (or next to the dev binary).
    var bundledHelper: URL? {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/notch-hook"),
            URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                .deletingLastPathComponent().appendingPathComponent("notch-hook"),
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Copies the helper to a stable path hooks can reference, so moving the
    /// app doesn't break agent configuration. Updates it when the app updates.
    @discardableResult
    func installHelperIfNeeded() -> Bool {
        guard let source = bundledHelper else { return false }
        let target = paths.installedHook
        let fm = FileManager.default
        if let a = fm.contents(atPath: source.path), let b = fm.contents(atPath: target.path), a == b { return true }
        do {
            try paths.prepare()
            let temp = target.deletingLastPathComponent().appendingPathComponent(".notch-hook.tmp")
            try? fm.removeItem(at: temp)
            try fm.copyItem(at: source, to: temp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: target)
            }
            return true
        } catch {
            log.error("helper install failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func installer(for agent: AgentKind) -> HookInstaller {
        switch agent {
        case .claudeCode: .claudeCode(helperPath: paths.installedHook.path)
        case .codex: .codex(helperPath: paths.installedHook.path)
        }
    }

    // MARK: Status

    func refresh(store: HistoryStore? = nil) {
        for agent in AgentKind.allCases {
            var status = statuses[agent] ?? AgentStatus(agent: agent)
            let installer = installer(for: agent)
            status.hooksInstalled = installer.isInstalled()
            status.hooksStale = !status.hooksInstalled && installer.hasAnyEntries()
            if let last = store?.lastEvent(for: agent) { status.lastEvent = last }
            statuses[agent] = status
        }
        Task { await detectBinaries() }
    }

    func noteEvent(from agent: AgentKind, at date: Date) {
        statuses[agent]?.lastEvent = date
    }

    private func detectBinaries() async {
        for agent in AgentKind.allCases {
            let found = await Self.locate(agent)
            statuses[agent]?.binaryPath = found?.path
            statuses[agent]?.version = found?.version
        }
        detecting = false
    }

    // MARK: Actions

    /// Installs hooks after the user has seen what will change. Existing
    /// configuration is preserved and backed up first.
    func connect(_ agent: AgentKind) {
        guard installHelperIfNeeded() else {
            statuses[agent]?.message = "The hook helper is missing from the app bundle. Rebuild the app."
            return
        }
        do {
            let (plan, backup) = try installer(for: agent).install()
            var message = plan.isNoOp ? "Already connected." : "Connected: \(plan.added.count + plan.updated.count) hooks added."
            if let backup { message += " Backup: \(backup.lastPathComponent)" }
            if agent == .codex && !plan.isNoOp { message += " Codex will ask you to trust the new hooks the next time it starts." }
            statuses[agent]?.message = message
        } catch {
            statuses[agent]?.message = "Couldn't connect: \(error)"
        }
        refresh()
    }

    func remove(_ agent: AgentKind) {
        do {
            let (plan, backup) = try installer(for: agent).uninstall()
            var message = plan.isNoOp ? "Nothing to remove." : "Removed \(plan.removed.count) hooks."
            if let backup { message += " Backup: \(backup.lastPathComponent)" }
            statuses[agent]?.message = message
        } catch {
            statuses[agent]?.message = "Couldn't remove: \(error)"
        }
        refresh()
    }

    /// Sends a test event through the real helper and socket, end to end.
    func test(_ agent: AgentKind) {
        guard installHelperIfNeeded() else { return }
        let process = Process()
        process.executableURL = paths.installedHook
        process.arguments = ["simulate", EventType.permission.rawValue, "--agent", agent.rawValue,
                             "--project", "Connection test", "--session", "test-\(agent.rawValue)", "--detail", "Test"]
        let pipe = Pipe()
        process.standardError = pipe
        process.terminationHandler = { [weak self] _ in
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in
                self?.statuses[agent]?.message = output.contains("delivered")
                    ? "Test notification delivered through the hook helper."
                    : "Test failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
        do { try process.run() } catch { statuses[agent]?.message = "Test failed: \(error.localizedDescription)" }
    }

    // MARK: Detection

    struct Located: Sendable { var path: String; var version: String? }

    @concurrent
    static func locate(_ agent: AgentKind) async -> Located? {
        let name = agent == .claudeCode ? "claude" : "codex"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
        ]
        if agent == .claudeCode { candidates.insert("\(home)/.claude/local/claude", at: 1) }
        var path = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        if path == nil, let found = run("/bin/zsh", ["-lc", "command -v \(name)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), found.hasPrefix("/") {
            path = found
        }
        guard let path else { return nil }
        let output = run(path, ["--version"]) ?? ""
        let version = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression).map { String(output[$0]) }
        return Located(path: path, version: version)
    }

    /// Runs a short command, giving up after `timeout` seconds.
    nonisolated static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
