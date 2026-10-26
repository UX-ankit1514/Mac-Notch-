import Foundation

/// Claude Code lifecycle hooks → standard events.
///
/// Hooks are observational: `notch-hook` never writes to stdout, so Claude
/// Code sees no decision and its permission flow is unchanged.
public struct ClaudeCodeConnector: Connector {
    public let agent = AgentKind.claudeCode

    /// Tools whose "permission" is really the agent asking the user something.
    static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    public init() {}

    public var hookRegistrations: [HookRegistration] {
        [
            HookRegistration("PermissionRequest"),
            HookRegistration("Notification"),
            HookRegistration("PreToolUse", matcher: "AskUserQuestion|ExitPlanMode"),
            HookRegistration("PostToolUse"),
            HookRegistration("PostToolUseFailure"),
            HookRegistration("UserPromptSubmit"),
            HookRegistration("Stop"),
            HookRegistration("StopFailure"),
            HookRegistration("SessionStart"),
            HookRegistration("SessionEnd"),
        ]
    }

    public var capabilities: [Capability] {
        [
            Capability(type: .permission, support: .supported, source: "PermissionRequest, Notification"),
            Capability(type: .question, support: .supported, source: "AskUserQuestion, ExitPlanMode, elicitation"),
            Capability(type: .completed, support: .supported, source: "Stop"),
            Capability(type: .criticalError, support: .supported, source: "StopFailure"),
            Capability(type: .buildFailed, support: .partial, source: "PostToolUseFailure (Bash, classified locally)"),
            Capability(type: .testFailed, support: .partial, source: "PostToolUseFailure (Bash, classified locally)"),
            Capability(type: .stopped, support: .partial, source: "PostToolUseFailure (interrupt)"),
            Capability(type: .idle, support: .supported, source: "Notification (idle_prompt)"),
            Capability(type: .sessionStart, support: .supported, source: "SessionStart"),
            Capability(type: .sessionEnd, support: .supported, source: "SessionEnd"),
        ]
    }

    public func normalize(_ payload: JSONValue, context: HookContext) -> AgentEvent? {
        guard let hook = payload["hook_event_name"]?.string else { return nil }
        let tool = payload["tool_name"]?.string

        switch hook {
        case "PermissionRequest":
            let isQuestion = tool.map(Self.questionTools.contains) ?? false
            return makeEvent(isQuestion ? .question : .permission, payload: payload, context: context,
                             detail: isQuestion ? nil : tool)

        case "Notification":
            // Only the typed notification is authoritative; message text is never parsed.
            switch payload["notification_type"]?.string {
            case "permission_prompt": return makeEvent(.permission, payload: payload, context: context)
            case "elicitation_dialog": return makeEvent(.question, payload: payload, context: context)
            case "idle_prompt": return makeEvent(.idle, payload: payload, context: context)
            default: return nil
            }

        case "PreToolUse":
            guard let tool, Self.questionTools.contains(tool) else { return nil }
            return makeEvent(.question, payload: payload, context: context)

        case "PostToolUse", "UserPromptSubmit":
            return makeEvent(.activity, payload: payload, context: context, detail: tool)

        case "PostToolUseFailure":
            if payload["is_interrupt"]?.bool == true {
                return makeEvent(.stopped, payload: payload, context: context, detail: tool)
            }
            if tool == "Bash", let command = payload["tool_input"]?["command"]?.string,
               let kind = CommandClassifier.classify(command) {
                // Only the category leaves this function, never the command.
                return makeEvent(kind == .build ? .buildFailed : .testFailed,
                                 payload: payload, context: context, confidence: 0.85)
            }
            return makeEvent(.activity, payload: payload, context: context, detail: tool)

        case "Stop":
            return makeEvent(.completed, payload: payload, context: context)

        case "StopFailure":
            let kind = payload["error_type"]?.string ?? payload["error"]?.string
            return makeEvent(.criticalError, payload: payload, context: context,
                             detail: kind.flatMap(Self.errorLabel))

        case "SessionStart":
            return makeEvent(.sessionStart, payload: payload, context: context,
                             detail: payload["source"]?.string)

        case "SessionEnd":
            return makeEvent(.sessionEnd, payload: payload, context: context,
                             detail: payload["reason"]?.string)

        default:
            return nil
        }
    }

    /// Known error categories only. Free-form error text can contain keys or
    /// paths, so anything not on this list is dropped rather than forwarded.
    static let knownErrorTypes: Set<String> = [
        "rate_limit", "authentication_failed", "billing_error", "invalid_request",
        "server_error", "overloaded", "max_output_tokens", "network_error", "timeout", "unknown",
    ]

    static func errorLabel(_ raw: String) -> String? {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return knownErrorTypes.contains(label) ? label : nil
    }
}

/// Codex hooks → standard events. Codex exposes fewer lifecycle hooks than
/// Claude Code; anything it doesn't expose is declared unavailable.
public struct CodexConnector: Connector {
    public let agent = AgentKind.codex

    public init() {}

    public var hookRegistrations: [HookRegistration] {
        [
            HookRegistration("PermissionRequest"),
            HookRegistration("PostToolUse"),
            HookRegistration("UserPromptSubmit"),
            HookRegistration("Stop"),
            HookRegistration("SessionStart"),
            HookRegistration("SessionEnd"),
            HookRegistration("Interrupt"),
        ]
    }

    public var capabilities: [Capability] {
        [
            Capability(type: .permission, support: .supported, source: "PermissionRequest"),
            Capability(type: .question, support: .unavailable, source: "No hook for user questions"),
            Capability(type: .completed, support: .supported, source: "Stop"),
            Capability(type: .criticalError, support: .unavailable, source: "No failure hook"),
            Capability(type: .buildFailed, support: .partial, source: "PostToolUse exit code (classified locally)"),
            Capability(type: .testFailed, support: .partial, source: "PostToolUse exit code (classified locally)"),
            Capability(type: .stopped, support: .partial, source: "Interrupt hook (declared by Codex; not verified in tests)"),
            Capability(type: .idle, support: .unavailable, source: "No idle hook"),
            Capability(type: .sessionStart, support: .supported, source: "SessionStart"),
            Capability(type: .sessionEnd, support: .partial, source: "SessionEnd (declared by Codex; not verified in tests)"),
        ]
    }

    public func normalize(_ payload: JSONValue, context: HookContext) -> AgentEvent? {
        guard let hook = payload["hook_event_name"]?.string else { return nil }
        let tool = payload["tool_name"]?.string

        switch hook {
        case "PermissionRequest":
            return makeEvent(.permission, payload: payload, context: context, detail: tool)

        case "PostToolUse":
            if let failure = Self.commandFailure(payload) {
                return makeEvent(failure == .build ? .buildFailed : .testFailed,
                                 payload: payload, context: context, confidence: 0.8)
            }
            return makeEvent(.activity, payload: payload, context: context, detail: tool)

        case "UserPromptSubmit":
            return makeEvent(.activity, payload: payload, context: context)

        case "Stop":
            return makeEvent(.completed, payload: payload, context: context)

        case "SessionStart":
            return makeEvent(.sessionStart, payload: payload, context: context,
                             detail: payload["source"]?.string)

        case "SessionEnd":
            return makeEvent(.sessionEnd, payload: payload, context: context)

        case "Interrupt":
            return makeEvent(.stopped, payload: payload, context: context)

        default:
            return nil
        }
    }

    /// A shell tool that exited non-zero while running a build or test command.
    static func commandFailure(_ payload: JSONValue) -> CommandClassifier.Kind? {
        let response = payload["tool_response"]
        let exitCode = response?["exit_code"]?.int ?? response?["exitCode"]?.int
            ?? response?["metadata"]?["exit_code"]?.int
        guard let exitCode, exitCode != 0 else { return nil }
        let input = payload["tool_input"]
        let command: String? = input?["command"]?.string
            ?? input?["command"]?.array?.compactMap(\.string).joined(separator: " ")
            ?? input?["cmd"]?.string
        return command.flatMap(CommandClassifier.classify)
    }
}
