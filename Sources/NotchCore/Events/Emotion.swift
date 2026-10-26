import Foundation

/// The character's nine emotional states (PRD §8.3) plus a neutral fallback.
/// These are presentation rules, not claims about what an agent feels.
public enum Emotion: String, Codable, Sendable, CaseIterable, Hashable {
    case anxiety, envy, embarrassment, ennui, disgust, fear, joy, anger, sadness
    case neutral

    public static let nine: [Emotion] = [
        .anxiety, .envy, .embarrassment, .ennui, .disgust, .fear, .joy, .anger, .sadness,
    ]

    public var displayName: String { rawValue.capitalized }

    /// What the state means in the product, for the Character Preview screen.
    public var meaning: String {
        switch self {
        case .anxiety: "Permission or input required"
        case .envy: "Several agents need you"
        case .embarrassment: "Clarification or confirmation"
        case .ennui: "Idle or waiting"
        case .disgust: "Tests failed"
        case .fear: "Critical error"
        case .joy: "Task completed"
        case .anger: "Build or command failed"
        case .sadness: "Task stopped"
        case .neutral: "Neutral"
        }
    }
}

/// Maps standardised events to the character's presentation.
public enum EmotionEngine {
    public static func emotion(for type: EventType) -> Emotion {
        switch type {
        case .permission, .manualIntervention: .anxiety
        case .question: .embarrassment
        case .idle: .ennui
        case .testFailed: .disgust
        case .criticalError: .fear
        case .completed: .joy
        case .buildFailed: .anger
        case .stopped: .sadness
        case .sessionStart, .sessionEnd, .activity: .neutral
        }
    }

    /// Several sessions waiting at once is shown as Envy: the character
    /// side-eyes between them. It never implies a failure.
    public static let multipleRequests: Emotion = .envy
}

/// Short notch copy derived only from reliable event metadata.
public enum AlertCopy {
    public static func title(for event: AgentEvent) -> String {
        let agent = event.agent.displayName
        switch event.type {
        case .permission:
            if let tool = event.detail, !tool.isEmpty { return "\(agent) needs permission for \(tool)" }
            return "\(agent) needs permission"
        case .question: return "\(agent) needs your input"
        case .manualIntervention: return "\(agent) needs you"
        case .completed: return "Task completed"
        case .buildFailed: return "Build failed"
        case .testFailed: return "Tests failed"
        case .criticalError: return "\(agent) hit an error"
        case .stopped: return "Task stopped"
        case .idle: return "\(agent) is waiting"
        case .sessionStart: return "\(agent) session started"
        case .sessionEnd: return "\(agent) session ended"
        case .activity: return "\(agent) is working"
        }
    }

    /// "Project: Portfolio Website · Terminal". Falls back to the agent name,
    /// never an invented project.
    public static func subtitle(for event: AgentEvent) -> String {
        var parts: [String] = []
        if let project = event.project, !project.isEmpty {
            parts.append("Project: \(project)")
        } else {
            parts.append(event.agent.displayName)
        }
        if let host = event.host.name, !host.isEmpty { parts.append(host) }
        return parts.joined(separator: " · ")
    }

    /// A single sentence for VoiceOver that does not depend on the emotion.
    public static func spoken(for event: AgentEvent) -> String {
        "\(title(for: event)). \(subtitle(for: event))."
    }

    public static func multipleTitle(count: Int) -> String {
        "\(count) agents need your attention"
    }
}
