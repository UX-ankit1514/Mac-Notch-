import Foundation
import Testing
@testable import NotchCore

private func payload(_ text: String) throws -> JSONValue { try JSONValue.parse(text) }

private let context = HookContext(
    host: HostInfo(bundleID: "com.apple.Terminal", name: "Terminal", pid: 501, tty: "/dev/ttys003"),
    agentPID: 4242, now: Date(timeIntervalSince1970: 1_800_000_000),
    projectName: { _ in "Portfolio Website" })

@Suite struct ClaudeCodeConnectorTests {
    let connector = ClaudeCodeConnector()

    @Test func `permission request becomes a high-priority permission event`() throws {
        let p = try payload("""
            {"session_id":"abc-123","transcript_path":"/tmp/t.jsonl","cwd":"/Users/me/site",
             "hook_event_name":"PermissionRequest","tool_name":"Bash",
             "tool_input":{"command":"rm -rf build","description":"clean"}}
            """)
        let event = try #require(connector.normalize(p, context: context))
        #expect(event.type == .permission)
        #expect(event.priority == .high)
        #expect(event.detail == "Bash")
        #expect(event.sessionID == "abc-123")
        #expect(event.project == "Portfolio Website")
        #expect(event.host.bundleID == "com.apple.Terminal")
        #expect(event.agentPID == 4242)
        #expect(EmotionEngine.emotion(for: event.type) == .anxiety)
    }

    @Test func `AskUserQuestion permission is a question, not a permission`() throws {
        let p = try payload(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{}}"#)
        let event = try #require(connector.normalize(p, context: context))
        #expect(event.type == .question)
        #expect(EmotionEngine.emotion(for: event.type) == .embarrassment)
    }

    @Test(arguments: [
        ("permission_prompt", EventType.permission),
        ("idle_prompt", EventType.idle),
        ("elicitation_dialog", EventType.question),
    ])
    func `typed notifications map to events`(type: String, expected: EventType) throws {
        let p = try payload(#"{"session_id":"s","hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"\#(type)"}"#)
        #expect(connector.normalize(p, context: context)?.type == expected)
    }

    @Test func `untyped notifications are ignored rather than guessed from text`() throws {
        let p = try payload(#"{"session_id":"s","hook_event_name":"Notification","message":"Claude needs your permission"}"#)
        #expect(connector.normalize(p, context: context) == nil)
        let auth = try payload(#"{"session_id":"s","hook_event_name":"Notification","notification_type":"auth_success"}"#)
        #expect(connector.normalize(auth, context: context) == nil)
    }

    @Test func `stop is completion, stop failure is a critical error`() throws {
        let stop = try payload(#"{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false}"#)
        #expect(connector.normalize(stop, context: context)?.type == .completed)
        let failure = try payload(#"{"session_id":"s","hook_event_name":"StopFailure","error_type":"rate_limit"}"#)
        let event = try #require(connector.normalize(failure, context: context))
        #expect(event.type == .criticalError)
        #expect(event.priority == .critical)
        #expect(event.detail == "rate_limit")
    }

    @Test func `free-form error text is never carried as detail`() throws {
        let failure = try payload(#"{"session_id":"s","hook_event_name":"StopFailure","error":"API key sk-ant-123 rejected by server"}"#)
        #expect(connector.normalize(failure, context: context)?.detail == nil)
    }

    @Test func `failed build and test commands are classified locally`() throws {
        let build = try payload(#"{"session_id":"s","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"swift build -c release"},"error":"exit 1"}"#)
        #expect(connector.normalize(build, context: context)?.type == .buildFailed)
        let test = try payload(#"{"session_id":"s","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"npm test -- --watch=false"},"error":"exit 1"}"#)
        #expect(connector.normalize(test, context: context)?.type == .testFailed)
        let other = try payload(#"{"session_id":"s","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"grep foo bar.txt"},"error":"exit 1"}"#)
        #expect(connector.normalize(other, context: context)?.type == .activity)
    }

    @Test func `interrupted tool means the task was stopped`() throws {
        let p = try payload(#"{"session_id":"s","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"sleep 100"},"error":"Interrupted","is_interrupt":true}"#)
        #expect(connector.normalize(p, context: context)?.type == .stopped)
    }

    @Test func `prompt submission and tool completion are activity`() throws {
        let prompt = try payload(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","prompt":"my secret plan"}"#)
        let event = try #require(connector.normalize(prompt, context: context))
        #expect(event.type == .activity)
        #expect(event.detail == nil)
        let tool = try payload(#"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{},"tool_response":{}}"#)
        #expect(connector.normalize(tool, context: context)?.detail == "Edit")
    }

    @Test func `unknown hooks and missing names are ignored`() throws {
        #expect(connector.normalize(try payload(#"{"session_id":"s","hook_event_name":"PreCompact"}"#), context: context) == nil)
        #expect(connector.normalize(try payload(#"{"session_id":"s"}"#), context: context) == nil)
    }

    @Test func `hostile session ids are reduced to a safe charset`() throws {
        let p = try payload(#"{"session_id":"../../etc/passwd; rm -rf /","hook_event_name":"Stop"}"#)
        let event = try #require(connector.normalize(p, context: context))
        #expect(event.sessionID == "....etcpasswdrm-rf")
    }

    @Test func `normalised events never contain prompts, commands or tool input`() throws {
        let secrets = ["rm -rf build", "my secret plan", "sk-ant-123", "SUPER_SECRET"]
        let payloads = [
            #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build","env":"SUPER_SECRET"}}"#,
            #"{"session_id":"s","hook_event_name":"UserPromptSubmit","prompt":"my secret plan"}"#,
            #"{"session_id":"s","hook_event_name":"StopFailure","error":"sk-ant-123"}"#,
            #"{"session_id":"s","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"SUPER_SECRET=1 swift build"}}"#,
        ]
        for text in payloads {
            let event = try #require(connector.normalize(try payload(text), context: context))
            let json = String(decoding: try EventEnvelope.encoder().encode(EventEnvelope(token: "t", event: event)), as: UTF8.self)
            for secret in secrets { #expect(!json.contains(secret), "leaked \(secret)") }
        }
    }
}

@Suite struct CodexConnectorTests {
    let connector = CodexConnector()

    @Test func `permission, stop and session start`() throws {
        let perm = try payload(#"{"session_id":"c1","cwd":"/x","hook_event_name":"PermissionRequest","tool_name":"shell","tool_input":{"command":["ls"]}}"#)
        #expect(connector.normalize(perm, context: context)?.type == .permission)
        #expect(connector.normalize(perm, context: context)?.agent == .codex)
        let stop = try payload(#"{"session_id":"c1","hook_event_name":"Stop","last_assistant_message":"done"}"#)
        #expect(connector.normalize(stop, context: context)?.type == .completed)
        let start = try payload(#"{"session_id":"c1","hook_event_name":"SessionStart","source":"startup"}"#)
        #expect(connector.normalize(start, context: context)?.type == .sessionStart)
    }

    @Test func `non-zero exit from a test command is a test failure`() throws {
        let p = try payload(#"{"session_id":"c1","hook_event_name":"PostToolUse","tool_name":"shell","tool_input":{"command":["bash","-lc","cargo test"]},"tool_response":{"exit_code":101}}"#)
        #expect(connector.normalize(p, context: context)?.type == .testFailed)
        let ok = try payload(#"{"session_id":"c1","hook_event_name":"PostToolUse","tool_name":"shell","tool_input":{"command":"cargo test"},"tool_response":{"exit_code":0}}"#)
        #expect(connector.normalize(ok, context: context)?.type == .activity)
    }

    @Test func `unsupported capabilities are declared, not faked`() {
        let unavailable = connector.capabilities.filter { $0.support == .unavailable }.map(\.type)
        #expect(unavailable.contains(.idle))
        #expect(unavailable.contains(.question))
        let interrupt = try? JSONValue.parse(#"{"session_id":"c1","hook_event_name":"Interrupt"}"#)
        #expect(interrupt.flatMap { connector.normalize($0, context: context) }?.type == .stopped)
    }
}

@Suite struct CommandClassifierTests {
    @Test(arguments: [
        "swift build", "xcodebuild -scheme App build", "npm run build", "pnpm build", "cargo build --release",
        "go build ./...", "npx tsc --noEmit", "next build", "make", "cd app && make -j8", "./gradlew assembleDebug",
        "docker build -t x .", "cmake --build build",
    ])
    func `build commands`(command: String) {
        #expect(CommandClassifier.classify(command) == .build)
    }

    @Test(arguments: [
        "swift test", "xcodebuild test -scheme App", "npm test", "yarn test:unit", "pytest -q", "python -m pytest",
        "npx jest", "vitest run", "cargo test", "go test ./...", "bundle exec rspec", "make test", "./gradlew test",
        "bun test",
    ])
    func `test commands`(command: String) {
        #expect(CommandClassifier.classify(command) == .test)
    }

    @Test(arguments: ["ls -la", "git status", "grep -r foo .", "cat Makefile", "echo build", "npm install"])
    func `other commands`(command: String) {
        #expect(CommandClassifier.classify(command) == nil)
    }
}

@Suite struct HostDetectorTests {
    @Test func `outermost app bundle wins over helper apps`() {
        #expect(HostDetector.outermostAppBundle(in: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper")
                == "/Applications/Visual Studio Code.app")
        #expect(HostDetector.outermostAppBundle(in: "/bin/zsh") == nil)
    }

    @Test func `term program fallbacks`() {
        #expect(HostDetector.bundleID(forTermProgram: "Apple_Terminal") == "com.apple.Terminal")
        #expect(HostDetector.bundleID(forTermProgram: "WarpTerminal") == "dev.warp.Warp-Stable")
        #expect(HostDetector.bundleID(forTermProgram: "tmux") == nil)
    }

    @Test func `project name comes from the git root and is never invented`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notch-proj-\(UUID().uuidString)/Landing Page")
        let nested = root.appendingPathComponent("src/components")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        #expect(ProjectName.resolve(cwd: nested.path) == "Landing Page")
        #expect(ProjectName.resolve(cwd: FileManager.default.homeDirectoryForCurrentUser.path) == nil)
    }
}

/// Real payloads captured from Claude Code 2.1.310 (`claude -p` with these hooks
/// loaded via --settings), sanitised. Guards against hook-schema drift.
@Suite struct RealPayloadTests {
    @Test func `captured Claude Code session normalises end to end`() throws {
        let url = try #require(Bundle.module.url(forResource: "claude-code-2.1.310", withExtension: "jsonl", subdirectory: "Fixtures"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let connector = ClaudeCodeConnector()
        let ctx = HookContext(host: HostInfo(bundleID: "dev.warp.Warp-Stable", name: "Warp"), projectName: { _ in "project" })
        let types = try lines.map { try #require(connector.normalize(try JSONValue.parse(String($0)), context: ctx)).type }
        #expect(types == [.sessionStart, .activity, .permission, .completed, .sessionEnd])

        var manager = NotificationManager()
        let events = try lines.map { try #require(connector.normalize(try JSONValue.parse(String($0)), context: ctx)) }
        let now = events[0].timestamp
        _ = manager.ingest(events[0], policy: NotificationPolicy(), now: now)
        _ = manager.ingest(events[1], policy: NotificationPolicy(), now: now)
        let permission = manager.ingest(events[2], policy: NotificationPolicy(), now: now)
        #expect(permission.disposition == .presented)
        #expect(manager.pending.first?.event.detail == "Bash")
        // The turn ended (the permission was declined in -p mode): request resolved.
        let stop = manager.ingest(events[3], policy: NotificationPolicy(), now: now)
        #expect(stop.resolvedIDs.count == 1)
        #expect(manager.pending.isEmpty)
    }
}
