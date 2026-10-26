import Foundation

/// Everything a connector needs besides the raw hook payload. Gathered by
/// `notch-hook` from the process tree, so connectors stay pure and testable.
public struct HookContext: Sendable {
    public var host: HostInfo
    public var agentPID: Int32?
    public var now: Date
    public var connectorVersion: String
    public var projectName: @Sendable (String) -> String?

    public init(
        host: HostInfo = HostInfo(), agentPID: Int32? = nil, now: Date = Date(),
        connectorVersion: String = NotchVersion.connector,
        projectName: @escaping @Sendable (String) -> String? = ProjectName.resolve
    ) {
        self.host = host
        self.agentPID = agentPID
        self.now = now
        self.connectorVersion = connectorVersion
        self.projectName = projectName
    }
}

public enum NotchVersion {
    public static let app = "1.0.0"
    public static let connector = "1"
    /// Marks previews and connection tests, which aren't real agent events.
    public static let simulated = "sim"
}

/// How well a connector covers one standard event.
public enum Support: String, Sendable, Hashable {
    case supported
    case partial        // detected in some cases, or inferred locally
    case unavailable    // the agent exposes no reliable signal

    public var label: String {
        switch self {
        case .supported: "Supported"
        case .partial: "Partial"
        case .unavailable: "Unavailable"
        }
    }
}

public struct Capability: Sendable, Hashable, Identifiable {
    public var type: EventType
    public var support: Support
    public var source: String

    public var id: EventType { type }
}

/// A connector turns one agent's hook payloads into standard events.
/// Adding an agent means adding a connector; nothing in the character or
/// notification layers changes.
public protocol Connector: Sendable {
    var agent: AgentKind { get }
    /// Hook events to register, with an optional tool matcher.
    var hookRegistrations: [HookRegistration] { get }
    var capabilities: [Capability] { get }
    func normalize(_ payload: JSONValue, context: HookContext) -> AgentEvent?
}

public struct HookRegistration: Sendable, Hashable {
    public var event: String
    public var matcher: String?

    public init(_ event: String, matcher: String? = nil) {
        self.event = event
        self.matcher = matcher
    }
}

public enum Connectors {
    public static let all: [any Connector] = [ClaudeCodeConnector(), CodexConnector()]

    public static func connector(for agent: AgentKind) -> any Connector {
        switch agent {
        case .claudeCode: ClaudeCodeConnector()
        case .codex: CodexConnector()
        }
    }
}

// MARK: - Shared helpers

extension Connector {
    func makeEvent(
        _ type: EventType, payload: JSONValue, context: HookContext,
        detail: String? = nil, confidence: Double = 1
    ) -> AgentEvent {
        let cwd = payload["cwd"]?.string
        return AgentEvent(
            type: type,
            agent: agent,
            sessionID: Sanitize.sessionID(payload["session_id"]?.string),
            host: context.host,
            project: cwd.flatMap(context.projectName),
            cwd: cwd,
            agentPID: context.agentPID,
            timestamp: context.now,
            connectorVersion: context.connectorVersion,
            confidence: confidence,
            detail: detail.map { Sanitize.short($0, limit: 64) })
    }
}

public enum Sanitize {
    /// Session IDs are UUID-like; anything else is reduced to a safe charset.
    public static func sessionID(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "unknown" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        let cleaned = String(raw.unicodeScalars.filter { allowed.contains($0) })
        return cleaned.isEmpty ? "unknown" : String(cleaned.prefix(128))
    }

    public static func short(_ raw: String, limit: Int) -> String {
        var cleaned = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where !isUnsafe(scalar) { cleaned.append(scalar) }
        return String(String(cleaned).prefix(limit))
    }

    /// Control characters and invisible direction/format overrides that
    /// could disguise text. An explicit scalar check: the
    /// `CharacterSet.controlCharacters.contains` method-reference form
    /// rejected plain ASCII in -O builds.
    public static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F,          // C0/C1 controls
             0x200B...0x200F, 0x202A...0x202E,  // zero-width, bidi embedding/override
             0x2066...0x2069, 0xFEFF:           // bidi isolates, BOM
            true
        default:
            false
        }
    }
}
