import Foundation

/// A coding agent we have a connector for.
public enum AgentKind: String, Codable, Sendable, CaseIterable, Hashable {
    case claudeCode = "claude-code"
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// The standard event vocabulary every connector normalises into.
public enum EventType: String, Codable, Sendable, CaseIterable, Hashable {
    case permission           // tool approval is blocking the agent
    case question             // the agent asked a question / wants confirmation
    case manualIntervention   // the agent is blocked on the user for another reason
    case completed            // the agent finished its turn
    case buildFailed
    case testFailed
    case criticalError        // API/auth/runtime failure that ended the turn
    case stopped              // the task was interrupted or cancelled
    case idle                 // the agent has been waiting on the user for a while
    case sessionStart
    case sessionEnd
    case activity             // the user responded or the agent resumed work

    /// Events that block the agent until the user acts. These stay pending
    /// until a later event shows the request was handled.
    public var needsAttention: Bool {
        switch self {
        case .permission, .question, .manualIntervention: true
        default: false
        }
    }

    /// Events the notch presents at all. Session bookkeeping and activity never alert.
    public var isPresentable: Bool {
        switch self {
        case .sessionStart, .sessionEnd, .activity: false
        default: true
        }
    }

    public var defaultPriority: Priority {
        switch self {
        case .criticalError: .critical
        case .permission, .question, .manualIntervention: .high
        case .completed, .buildFailed, .testFailed, .stopped: .normal
        case .idle, .sessionStart, .sessionEnd, .activity: .low
        }
    }

    /// The user-facing category these events are filtered by in Settings.
    public var category: EventCategory {
        switch self {
        case .permission, .manualIntervention: .permissions
        case .question: .questions
        case .completed: .completions
        case .buildFailed, .testFailed, .criticalError: .failures
        case .stopped: .stops
        case .idle, .sessionStart, .sessionEnd, .activity: .idle
        }
    }
}

public enum EventCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case permissions, questions, completions, failures, stops, idle

    public var displayName: String {
        switch self {
        case .permissions: "Permission requests"
        case .questions: "Questions & confirmations"
        case .completions: "Task completed"
        case .failures: "Errors & failures"
        case .stops: "Task stopped"
        case .idle: "Idle reminders"
        }
    }
}

public enum Priority: Int, Codable, Sendable, Comparable, CaseIterable, Hashable {
    case low = 0, normal, high, critical

    public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .critical: "Critical"
        }
    }
}

public enum EventStatus: String, Codable, Sendable, Hashable {
    case pending, resolved, expired
}

/// Where the agent is running, as far as the hook could tell.
public struct HostInfo: Codable, Sendable, Hashable {
    public var bundleID: String?
    public var name: String?
    public var pid: Int32?
    /// Controlling terminal of the agent, e.g. "/dev/ttys003".
    public var tty: String?

    public init(bundleID: String? = nil, name: String? = nil, pid: Int32? = nil, tty: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
        self.tty = tty
    }

    public var isKnown: Bool { bundleID != nil || pid != nil }
}

/// One normalised event. Carries only metadata: never prompts, code, or command text.
public struct AgentEvent: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var type: EventType
    public var agent: AgentKind
    public var sessionID: String
    public var host: HostInfo
    /// Human-readable project identity (the git root's folder name).
    public var project: String?
    /// Working directory, used only to navigate back to an editor window.
    public var cwd: String?
    public var agentPID: Int32?
    public var timestamp: Date
    public var priority: Priority
    public var status: EventStatus
    public var connectorVersion: String
    /// 0…1. Authoritative hook events are 1; inferred classifications are lower.
    public var confidence: Double
    /// A short, non-sensitive qualifier, e.g. the tool name "Bash".
    public var detail: String?

    public init(
        id: UUID = UUID(), type: EventType, agent: AgentKind, sessionID: String,
        host: HostInfo = HostInfo(), project: String? = nil, cwd: String? = nil,
        agentPID: Int32? = nil, timestamp: Date = Date(), priority: Priority? = nil,
        status: EventStatus = .pending, connectorVersion: String = "1",
        confidence: Double = 1, detail: String? = nil
    ) {
        self.id = id
        self.type = type
        self.agent = agent
        self.sessionID = sessionID
        self.host = host
        self.project = project
        self.cwd = cwd
        self.agentPID = agentPID
        self.timestamp = timestamp
        self.priority = priority ?? type.defaultPriority
        self.status = status
        self.connectorVersion = connectorVersion
        self.confidence = confidence
        self.detail = detail
    }

    /// Equivalent reports of one outstanding request share this key, so a
    /// PermissionRequest hook and the matching permission Notification merge.
    public var dedupeKey: String {
        let kind = type.needsAttention ? "attention" : type.rawValue
        return "\(agent.rawValue)|\(sessionID)|\(kind)"
    }

    /// The session's identity across agents.
    public var sessionKey: String { "\(agent.rawValue)|\(sessionID)" }
}

/// What travels over the local socket from `notch-hook` to the app.
public struct EventEnvelope: Codable, Sendable {
    public static let currentVersion = 1

    public var v: Int
    public var token: String
    public var event: AgentEvent

    public init(token: String, event: AgentEvent) {
        self.v = Self.currentVersion
        self.token = token
        self.event = event
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
