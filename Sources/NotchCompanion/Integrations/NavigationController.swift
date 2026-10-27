import AppKit
import NotchCore

/// Returns the user to the source of an event (PRD FR-07), using the best
/// level the host verifiably supports, and saying which level it used.
@MainActor
final class NavigationController {
    enum Level: String {
        case exactSession = "Exact tab"
        case app = "App"
        case unavailable = "Unavailable"
    }

    struct Result {
        var level: Level
        var message: String
    }

    /// Hosts where focusing the exact tab by tty has been verified.
    static let sessionHosts: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]

    func level(for host: HostInfo) -> Level {
        guard let bundleID = host.bundleID, bundleID != AppPaths.bundleID else { return .unavailable }
        if Self.sessionHosts.contains(bundleID), host.tty != nil { return .exactSession }
        return .app
    }

    /// Short hint for the notch ("Opens Terminal tab").
    func hint(for host: HostInfo) -> String? {
        let name = host.name ?? host.bundleID.flatMap(HostDetector.knownName(for:)) ?? "source app"
        switch level(for: host) {
        case .exactSession: return "Click to open the \(name) tab"
        case .app: return "Click to open \(name)"
        case .unavailable: return nil
        }
    }

    /// Messages are short: the notch shows them on one line.
    func open(_ event: AgentEvent) async -> Result {
        let host = event.host
        guard let bundleID = host.bundleID else {
            return Result(level: .unavailable, message: "Source app unknown")
        }
        if bundleID == AppPaths.bundleID {
            // Previews and connection tests come from this app's own window.
            NSApp.activate()
            return Result(level: .app, message: "Opened Notch Companion")
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else {
            // Never open an unrelated or relaunched session.
            return Result(level: .unavailable, message: "\(host.name ?? bundleID) is closed")
        }

        if level(for: host) == .exactSession, let tty = host.tty,
           await Self.focusTab(bundleID: bundleID, tty: tty) {
            return Result(level: .exactSession, message: "Opened the \(host.name ?? "terminal") tab")
        }
        await activate(bundleID: bundleID)
        return Result(level: .app, message: "Opened \(host.name ?? bundleID)")
    }

    /// Activation through LaunchServices works from a background app, where
    /// NSRunningApplication.activate can be declined by the system.
    private func activate(bundleID: String) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Selects the tab whose tty matches, via AppleScript (asks once for
    /// Automation permission). Runs out of process, off the main thread.
    @concurrent
    static func focusTab(bundleID: String, tty: String) async -> Bool {
        guard tty.hasPrefix("/dev/tty"), tty.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" }) else { return false }
        let script: String
        switch bundleID {
        case "com.apple.Terminal":
            script = """
            tell application id "com.apple.Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected tab of w to t
                    set index of w to 1
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            return "missing"
            """
        case "com.googlecode.iterm2":
            script = """
            tell application id "com.googlecode.iterm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      select w
                      tell t to select
                      tell s to select
                      activate
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return "missing"
            """
        default:
            return false
        }
        // The first run waits on macOS's Automation prompt; give the user time to answer it.
        let output = IntegrationManager.run("/usr/bin/osascript", ["-e", script], timeout: 60)
        return output?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }
}
