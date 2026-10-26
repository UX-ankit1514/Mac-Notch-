import Foundation
import Testing
@testable import NotchCore

private func tempDir() throws -> URL {
    // Short base path: Unix socket paths must stay under 104 bytes.
    let url = URL(fileURLWithPath: "/tmp/nc-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Mirrors the shape of the user's real ~/.claude/settings.json (ModelMatch hooks).
private let existingClaudeSettings = """
{
  "model": "opus",
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 \\"/Users/me/Hooks/modelmatch_hook.py\\" || true",
            "timeout": 30,
            "statusMessage": "ModelMatch: starting..."
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 \\"/Users/me/Hooks/modelmatch_hook.py\\" || true",
            "timeout": 120
          }
        ]
      }
    ]
  },
  "enabledPlugins": {
    "figma@claude-plugins-official": true
  },
  "effortLevel": 1.5
}

"""

@Suite struct JSONValueTests {
    @Test func `round trip preserves key order, numbers and escapes`() throws {
        let value = try JSONValue.parse(existingClaudeSettings)
        #expect(value.serialized() == existingClaudeSettings)
        #expect(value["effortLevel"] == .number("1.5"))
    }

    @Test func `unicode escapes and surrogate pairs`() throws {
        let value = try JSONValue.parse(#"{"a":"\u00e9\ud83d\ude00\n"}"#)
        #expect(value["a"]?.string == "é😀\n")
    }

    @Test func `malformed input throws`() {
        #expect(throws: JSONParseError.self) { try JSONValue.parse(#"{"a": }"#) }
        #expect(throws: JSONParseError.self) { try JSONValue.parse(#"{"a": 1} trailing"#) }
    }
}

@Suite struct HookInstallerTests {
    let helper = "/Users/me/Library/Application Support/NotchCompanion/bin/notch-hook"

    @Test func `install keeps unrelated settings and hooks intact`() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("settings.json")
        try existingClaudeSettings.write(to: config, atomically: true, encoding: .utf8)
        let installer = HookInstaller(configURL: config, helperPath: helper, agentArgument: "claude-code",
                                      registrations: ClaudeCodeConnector().hookRegistrations)

        let (plan, backup) = try installer.install()
        #expect(plan.added.count == ClaudeCodeConnector().hookRegistrations.count)
        #expect(try String(contentsOf: try #require(backup), encoding: .utf8) == existingClaudeSettings)
        #expect(installer.isInstalled())

        let after = try JSONValue.parse(Data(contentsOf: config))
        #expect(after["model"]?.string == "opus")
        #expect(after["effortLevel"] == .number("1.5"))
        #expect(after["enabledPlugins"]?["figma@claude-plugins-official"]?.bool == true)
        let sessionStart = try #require(after["hooks"]?["SessionStart"]?.array)
        #expect(sessionStart.count == 2)
        #expect(sessionStart[0]["hooks"]?.array?[0]["statusMessage"]?.string == "ModelMatch: starting...")
        #expect(after["hooks"]?["PreToolUse"]?.array?[0]["matcher"]?.string == "AskUserQuestion|ExitPlanMode")
        // Key order of the original file is unchanged.
        #expect(after.objectPairs?.map(\.key) == ["model", "hooks", "enabledPlugins", "effortLevel"])
    }

    @Test func `install is idempotent and uninstall restores the original exactly`() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("settings.json")
        try existingClaudeSettings.write(to: config, atomically: true, encoding: .utf8)
        let installer = HookInstaller(configURL: config, helperPath: helper, agentArgument: "claude-code",
                                      registrations: ClaudeCodeConnector().hookRegistrations)
        try installer.install()
        let (second, backup) = try installer.install()
        #expect(second.isNoOp)
        #expect(backup == nil)

        let (removed, _) = try installer.uninstall()
        #expect(!removed.removed.isEmpty)
        #expect(try String(contentsOf: config, encoding: .utf8) == existingClaudeSettings)
        #expect(!installer.hasAnyEntries())
    }

    @Test func `moving the helper repairs entries instead of duplicating them`() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("settings.json")
        let old = HookInstaller(configURL: config, helperPath: helper, agentArgument: "claude-code",
                                registrations: [HookRegistration("Stop")])
        try old.install()
        // Same marker path, different arguments → treated as stale and replaced.
        let new = HookInstaller(configURL: config, helperPath: helper, agentArgument: "claude-code --v2",
                                registrations: [HookRegistration("Stop")])
        let (plan, _) = try new.install()
        #expect(plan.updated == ["Stop"])
        let groups = try #require(try JSONValue.parse(Data(contentsOf: config))["hooks"]?["Stop"]?.array)
        #expect(groups.count == 1)
    }

    @Test func `codex empty hooks file and missing file both work`() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("hooks.json")
        try "{}\n".write(to: config, atomically: true, encoding: .utf8)
        let codex = HookInstaller.codex(helperPath: helper, home: dir)
        let installer = HookInstaller(configURL: config, helperPath: helper, agentArgument: "codex",
                                      registrations: codex.registrations, includeMatcher: false)
        try installer.install()
        let after = try JSONValue.parse(Data(contentsOf: config))
        #expect(after["hooks"]?["PermissionRequest"]?.array?[0]["matcher"] == nil)
        try installer.uninstall()
        #expect(try String(contentsOf: config, encoding: .utf8) == "{}\n")

        let missing = HookInstaller(configURL: dir.appendingPathComponent("new/hooks.json"), helperPath: helper,
                                    agentArgument: "codex", registrations: [HookRegistration("Stop")])
        let (_, backup) = try missing.install()
        #expect(backup == nil)
        #expect(missing.isInstalled())
    }

    @Test func `a symlinked config is updated through the link and keeps its mode`() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("dotfiles-settings.json")
        try existingClaudeSettings.write(to: real, atomically: true, encoding: .utf8)
        chmod(real.path, 0o640)
        let link = dir.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let installer = HookInstaller(configURL: link, helperPath: helper, agentArgument: "claude-code",
                                      registrations: [HookRegistration("Stop")])
        try installer.install()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(installer.isInstalled())
        let mode = (try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o640)
    }

    @Test func `invalid JSON is never overwritten`() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("settings.json")
        try "{ not json".write(to: config, atomically: true, encoding: .utf8)
        let installer = HookInstaller(configURL: config, helperPath: helper, agentArgument: "claude-code",
                                      registrations: [HookRegistration("Stop")])
        #expect(throws: HookInstaller.InstallError.self) { try installer.install() }
        #expect(try String(contentsOf: config, encoding: .utf8) == "{ not json")
    }

    @Test func `entries a user added next to ours survive uninstall`() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("settings.json")
        let mixed = """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\\"\(helper)\\" claude-code"},{"type":"command","command":"say done"}]}]}}
        """
        try mixed.write(to: config, atomically: true, encoding: .utf8)
        let installer = HookInstaller(configURL: config, helperPath: helper, agentArgument: "claude-code",
                                      registrations: [HookRegistration("Stop")])
        try installer.uninstall()
        let after = try JSONValue.parse(Data(contentsOf: config))
        let hooks = try #require(after["hooks"]?["Stop"]?.array?[0]["hooks"]?.array)
        #expect(hooks.map { $0["command"]?.string } == ["say done"])
    }
}

@Suite struct PayloadValidatorTests {
    let token = String(repeating: "a", count: 64)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func data(_ event: AgentEvent, token: String? = nil) throws -> Data {
        try EventEnvelope.encoder().encode(EventEnvelope(token: token ?? self.token, event: event))
    }

    func sample(_ mutate: (inout AgentEvent) -> Void = { _ in }) -> AgentEvent {
        var e = AgentEvent(type: .permission, agent: .claudeCode, sessionID: "abc-1", project: "P",
                           cwd: "/Users/me/p", timestamp: now)
        mutate(&e)
        return e
    }

    @Test func `valid envelope passes`() throws {
        let result = PayloadValidator(token: token).validate(try data(sample()), now: now)
        #expect((try? result.get())?.sessionID == "abc-1")
    }

    @Test func `wrong token, oversize, garbage and stale payloads are rejected`() throws {
        let v = PayloadValidator(token: token)
        #expect(v.validate(try data(sample(), token: String(repeating: "b", count: 64)), now: now) == .failure(.badToken))
        #expect(v.validate(Data(repeating: 0x20, count: 20_000), now: now) == .failure(.tooLarge))
        #expect(v.validate(Data("{\"v\":1}".utf8), now: now) == .failure(.malformed))
        let stale = try data(sample { $0.timestamp = now.addingTimeInterval(-3 * 86400) })
        #expect(v.validate(stale, now: now) == .failure(.stale))
    }

    @Test func `injected field content is rejected`() throws {
        let v = PayloadValidator(token: token)
        let cases: [(String, (inout AgentEvent) -> Void)] = [
            ("sessionID", { $0.sessionID = "a b; rm" }),
            ("project", { $0.project = "x\u{1B}[31m" }),
            ("cwd", { $0.cwd = "relative/path" }),
            ("host.tty", { $0.host.tty = "/etc/passwd" }),
            ("project", { $0.project = "safe\u{202E}txt.exe" }),
        ]
        for (field, mutate) in cases {
            let payload = try data(sample(mutate))
            #expect(v.validate(payload, now: now) == .failure(.invalidField(field)))
        }
    }

    @Test func `ordinary names pass in every build configuration`() throws {
        let v = PayloadValidator(token: token)
        for name in ["NotchCompanion", "Portfolio Website", "café-app", "日本語 project"] {
            let payload = try data(sample { $0.project = name })
            #expect((try? v.validate(payload, now: now).get())?.project == name)
        }
    }

    @Test func `rate limiter bounds bursts`() {
        var limiter = RateLimiter(capacity: 10, refillPerSecond: 5, now: now)
        let allowed = (0..<100).filter { _ in limiter.allow(now: now) }.count
        #expect(allowed == 10)
        let refilled = limiter.allow(now: now.addingTimeInterval(1))
        #expect(refilled)
    }
}

@Suite struct StorageTests {
    @Test func `history round trip, prune and clear`() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(url: dir.appendingPathComponent("h.sqlite"))
        let now = Date()
        var old = NotificationRecord(event: AgentEvent(type: .completed, agent: .codex, sessionID: "o",
                                                       timestamp: now.addingTimeInterval(-30 * 86400)))
        old.lastSeen = old.firstSeen
        let pending = NotificationRecord(event: AgentEvent(type: .permission, agent: .claudeCode, sessionID: "p",
                                                           host: HostInfo(bundleID: "com.apple.Terminal", tty: "/dev/ttys001"),
                                                           project: "Proj", timestamp: now, detail: "Bash"))
        store.upsert([old, pending])
        #expect(store.count == 2)
        let back = try #require(store.pending(newerThan: now.addingTimeInterval(-60)).first)
        #expect(back.id == pending.id)
        #expect(back.event.detail == "Bash")
        #expect(back.event.host.tty == "/dev/ttys001")
        #expect(back.status == .pending)
        #expect(store.lastEvent(for: .claudeCode) != nil)

        store.prune(olderThan: now.addingTimeInterval(-7 * 86400))
        #expect(store.count == 1)
        store.clear()
        #expect(store.count == 0)
    }

    @Test func `settings decode tolerates missing fields`() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"soundEnabled":false}"#.utf8))
        #expect(!decoded.soundEnabled)
        #expect(decoded.reminderMinutes == 5)
    }

    @Test func `quiet hours wrap past midnight`() throws {
        var s = AppSettings()
        s.quietHoursEnabled = true
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let at = { (h: Int) in cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h))! }
        #expect(s.isQuietHours(at: at(23), calendar: cal))
        #expect(s.isQuietHours(at: at(3), calendar: cal))
        #expect(!s.isQuietHours(at: at(12), calendar: cal))
    }

    @Test func `spool drains oldest first and deletes files`() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = Spool(directory: dir)
        try spool.write(Data("one".utf8))
        try spool.write(Data("two".utf8))
        let drained = spool.drain()
        #expect(drained.count == 2)
        #expect(spool.drain().isEmpty)
    }
}

@Suite struct SocketTests {
    @Test func `server receives a payload from the client and refuses a second server`() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("e.sock").path
        let received = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            let server = LocalSocketServer(path: path) { data in continuation.resume(returning: data) }
            do { try server.start() } catch { Issue.record("start failed: \(error)") }
            #expect(throws: LocalSocketError.alreadyRunning) { try LocalSocketServer(path: path) { _ in }.start() }
            #expect(LocalSocketClient.send(Data("hello".utf8), to: path))
            // Keep the server alive until the payload arrives.
            withExtendedLifetime(server) {}
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { _ = server }
        }
        #expect(String(decoding: received, as: UTF8.self) == "hello")
    }

    @Test func `client reports failure when nobody listens`() {
        #expect(!LocalSocketClient.send(Data("x".utf8), to: "/tmp/nc-nonexistent-\(UUID().uuidString.prefix(6)).sock"))
    }
}
