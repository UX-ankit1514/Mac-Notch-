import Foundation

/// The character's presentation phases (PRD §14.2).
public enum MotionPhase: String, Sendable, Equatable {
    case hidden, entering, reacting, waiting, interacting, exiting
}

public enum MotionInput: Sendable, Equatable {
    case show(Emotion)
    case remind
    case entered
    case reactionFinished
    case pointerEntered
    case pointerExited
    case hide
    case exited
}

/// What the renderer should do. The renderer reports completion back as
/// `.entered`, `.reactionFinished` and `.exited`.
public enum MotionCommand: Sendable, Equatable {
    case playEntry(Emotion)
    case playReaction(Emotion)
    case playReminder(Emotion)
    case crossfade(to: Emotion)
    case startIdle
    case stopIdle
    case hoverOn
    case hoverOff
    case playExit
}

/// Motion is driven only by explicit state changes, never by free-running
/// random animation. One character, so a new emotion transitions the
/// existing one instead of spawning another.
public struct MotionStateMachine: Sendable {
    public private(set) var phase: MotionPhase = .hidden
    public private(set) var emotion: Emotion = .neutral
    public private(set) var hovering = false

    public init() {}

    public var isVisible: Bool { phase != .hidden }

    public mutating func handle(_ input: MotionInput) -> [MotionCommand] {
        switch (phase, input) {
        case let (.hidden, .show(e)), let (.exiting, .show(e)):
            phase = .entering
            emotion = e
            return [.playEntry(e)]

        case let (.entering, .show(e)), let (.reacting, .show(e)),
             let (.waiting, .show(e)), let (.interacting, .show(e)):
            guard e != emotion else { return [] }
            emotion = e
            var commands: [MotionCommand] = []
            if phase == .waiting || phase == .interacting { commands.append(.stopIdle) }
            commands.append(.crossfade(to: e))
            // Mid-entry, the reaction follows `.entered` with the new emotion.
            if phase != .entering {
                phase = .reacting
                commands.append(.playReaction(e))
            }
            return commands

        case (.entering, .entered):
            phase = .reacting
            return [.playReaction(emotion)]

        case (.reacting, .reactionFinished):
            phase = hovering ? .interacting : .waiting
            return hovering ? [.hoverOn] : [.startIdle]

        case (.waiting, .remind), (.interacting, .remind):
            var commands: [MotionCommand] = phase == .waiting ? [.stopIdle] : []
            phase = .reacting
            commands.append(.playReminder(emotion))
            return commands

        case (.waiting, .pointerEntered):
            hovering = true
            phase = .interacting
            return [.stopIdle, .hoverOn]

        case (.entering, .pointerEntered), (.reacting, .pointerEntered):
            hovering = true
            return []

        case (.interacting, .pointerExited):
            hovering = false
            phase = .waiting
            return [.hoverOff, .startIdle]

        case (_, .pointerExited):
            hovering = false
            return []

        case (.entering, .hide), (.reacting, .hide):
            phase = .exiting
            return [.playExit]

        case (.waiting, .hide), (.interacting, .hide):
            phase = .exiting
            hovering = false
            return [.stopIdle, .playExit]

        case (.exiting, .exited):
            phase = .hidden
            emotion = .neutral
            return []

        default:
            return []
        }
    }
}
