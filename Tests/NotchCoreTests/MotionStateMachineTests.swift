import Testing
@testable import NotchCore

@Suite struct MotionStateMachineTests {
    @Test func `full lifecycle: enter, react, wait, hover, exit`() {
        var m = MotionStateMachine()
        #expect(m.handle(.show(.anxiety)) == [.playEntry(.anxiety)])
        #expect(m.phase == .entering)
        #expect(m.handle(.entered) == [.playReaction(.anxiety)])
        #expect(m.handle(.reactionFinished) == [.startIdle])
        #expect(m.phase == .waiting)
        #expect(m.handle(.pointerEntered) == [.stopIdle, .hoverOn])
        #expect(m.phase == .interacting)
        #expect(m.handle(.pointerExited) == [.hoverOff, .startIdle])
        #expect(m.handle(.hide) == [.stopIdle, .playExit])
        #expect(m.handle(.exited) == [])
        #expect(m.phase == .hidden)
    }

    @Test func `a new emotion transitions the one character instead of spawning another`() {
        var m = MotionStateMachine()
        _ = m.handle(.show(.joy))
        _ = m.handle(.entered)
        _ = m.handle(.reactionFinished)
        #expect(m.handle(.show(.fear)) == [.stopIdle, .crossfade(to: .fear), .playReaction(.fear)])
        #expect(m.emotion == .fear)
        #expect(m.handle(.show(.fear)) == [])
    }

    @Test func `showing during the exit re-enters`() {
        var m = MotionStateMachine()
        _ = m.handle(.show(.joy))
        _ = m.handle(.hide)
        #expect(m.phase == .exiting)
        #expect(m.handle(.show(.anxiety)) == [.playEntry(.anxiety)])
    }

    @Test func `hovering during the reaction lands in interacting`() {
        var m = MotionStateMachine()
        _ = m.handle(.show(.envy))
        _ = m.handle(.entered)
        #expect(m.handle(.pointerEntered) == [])
        #expect(m.handle(.reactionFinished) == [.hoverOn])
        #expect(m.phase == .interacting)
    }

    @Test func `reminders replay gently from waiting only`() {
        var m = MotionStateMachine()
        #expect(m.handle(.remind) == [])
        _ = m.handle(.show(.anxiety))
        _ = m.handle(.entered)
        _ = m.handle(.reactionFinished)
        #expect(m.handle(.remind) == [.stopIdle, .playReminder(.anxiety)])
        #expect(m.handle(.reactionFinished) == [.startIdle])
    }

    @Test func `nothing animates while hidden`() {
        var m = MotionStateMachine()
        #expect(m.handle(.hide) == [])
        #expect(m.handle(.pointerEntered) == [])
        #expect(m.handle(.reactionFinished) == [])
        #expect(!m.isVisible)
    }
}
