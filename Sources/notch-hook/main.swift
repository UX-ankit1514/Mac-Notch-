// notch-hook — the command agent hooks run.
//
// Reads the hook payload from stdin, normalises it locally, and forwards
// only metadata to Notch Companion over a private Unix socket. It never
// writes to stdout (so the agent never sees a decision) and always exits 0
// (so a missing or crashed companion can't block the agent).
import Darwin
import Foundation
import NotchCore

let paths = AppPaths.default

func log(_ message: String) {
    FileHandle.standardError.write(Data("notch-hook: \(message)\n".utf8))
}

/// Live delivery, or spool + wake the app. Returns how it went.
@discardableResult
func deliver(_ event: AgentEvent) -> String {
    guard let token = paths.readToken() else { return "app not set up (no token)" }
    guard let data = try? EventEnvelope.encoder().encode(EventEnvelope(token: token, event: event)) else {
        return "encode failed"
    }
    if LocalSocketClient.send(data, to: paths.socket.path) { return "delivered" }
    do {
        try Spool(directory: paths.spoolDirectory).write(data)
    } catch {
        return "spool failed"
    }
    launchAppIfNeeded()
    return "spooled"
}

/// Wakes the app (in the background) at most once every 15 seconds.
func launchAppIfNeeded() {
    let marker = paths.launchMarker
    if let date = (try? FileManager.default.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date,
       Date().timeIntervalSince(date) < 15 { return }
    FileManager.default.createFile(atPath: marker.path, contents: nil, attributes: [.posixPermissions: 0o600])
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = ["/usr/bin/open", "-g", "-b", AppPaths.bundleID].map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    posix_spawn(&pid, "/usr/bin/open", nil, nil, argv, environ)
}

func runHook(_ agent: AgentKind) {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard !input.isEmpty, input.count < 8 * 1024 * 1024,
          let payload = try? JSONValue.parse(input) else { return }
    let names = agent == .claudeCode ? ["claude"] : ["codex"]
    let detected = HostDetector.detect(agentNames: names)
    let context = HookContext(host: detected.host, agentPID: detected.agentPID)
    guard let event = Connectors.connector(for: agent).normalize(payload, context: context) else { return }
    deliver(event)
}

/// `notch-hook simulate <type> [--agent claude-code|codex] [--project NAME] [--session ID] [--detail TEXT]`
/// Sends a test event through the real delivery path (used by onboarding and tests).
func simulate(_ args: [String]) {
    guard let typeName = args.first, let type = EventType(rawValue: typeName) else {
        log("simulate: unknown type. One of: \(EventType.allCases.map(\.rawValue).joined(separator: ", "))")
        return
    }
    var options: [String: String] = [:]
    var i = 1
    while i + 1 < args.count, args[i].hasPrefix("--") {
        options[String(args[i].dropFirst(2))] = args[i + 1]
        i += 2
    }
    let agent = options["agent"].flatMap(AgentKind.init(rawValue:)) ?? .claudeCode
    let detected = HostDetector.detect(agentNames: [])
    let cwd = FileManager.default.currentDirectoryPath
    let event = AgentEvent(
        type: type, agent: agent,
        sessionID: Sanitize.sessionID(options["session"] ?? "test-\(agent.rawValue)"),
        host: detected.host,
        // Same limits as real events, so a long name is trimmed, not rejected.
        project: (options["project"] ?? ProjectName.resolve(cwd: cwd)).map { Sanitize.short($0, limit: 120) },
        cwd: cwd,
        connectorVersion: NotchVersion.simulated,
        detail: options["detail"].map { Sanitize.short($0, limit: 64) })
    log("simulate \(type.rawValue): \(deliver(event))")
}

/// `notch-hook install|uninstall|status <claude-code|codex> [--helper PATH]`
/// The same merge-safe installer the app's Connect button uses, for CLI setup.
func manageHooks(_ command: String, _ args: [String]) {
    guard let name = args.first, let agent = AgentKind(rawValue: name) else {
        log("\(command): agent must be claude-code or codex")
        return
    }
    let helper = args.firstIndex(of: "--helper").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        ?? paths.installedHook.path
    let installer = agent == .claudeCode ? HookInstaller.claudeCode(helperPath: helper) : HookInstaller.codex(helperPath: helper)
    do {
        switch command {
        case "install":
            let (plan, backup) = try installer.install()
            log("install \(agent.rawValue): added \(plan.added), updated \(plan.updated), unchanged \(plan.unchanged.count)"
                + (backup.map { "; backup \($0.path)" } ?? ""))
        case "uninstall":
            let (plan, backup) = try installer.uninstall()
            log("uninstall \(agent.rawValue): removed \(plan.removed)" + (backup.map { "; backup \($0.path)" } ?? ""))
        default:
            log("\(agent.rawValue): \(installer.isInstalled() ? "connected" : installer.hasAnyEntries() ? "needs repair" : "not connected") (\(installer.configURL.path))")
        }
    } catch {
        log("\(command) failed: \(error)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "claude-code", "claude":
    runHook(.claudeCode)
case "codex":
    runHook(.codex)
case "simulate":
    simulate(Array(arguments.dropFirst()))
case let command? where ["install", "uninstall", "status"].contains(command):
    manageHooks(command, Array(arguments.dropFirst()))
case "--version":
    log("\(NotchVersion.app) (connector \(NotchVersion.connector))")
default:
    log("""
        usage: notch-hook <claude-code|codex>        (reads a hook payload on stdin)
               notch-hook simulate <type> [--agent A] [--project P] [--session S] [--detail D]
               notch-hook install|uninstall|status <claude-code|codex> [--helper PATH]
        """)
}
exit(0)
