import Foundation
import Testing
@testable import NotchCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func event(
    _ type: EventType, session: String = "s1", agent: AgentKind = .claudeCode,
    at seconds: TimeInterval = 0, detail: String? = nil, host: String? = "com.apple.Terminal",
    agentPID: Int32? = nil
) -> AgentEvent {
    AgentEvent(type: type, agent: agent, sessionID: session,
               host: HostInfo(bundleID: host, name: "Terminal"), project: "Proj",
               agentPID: agentPID, timestamp: t0.addingTimeInterval(seconds), detail: detail)
}

@Suite struct NotificationManagerTests {
    let policy = NotificationPolicy()

    @Test func `permission presents with sound and stays pending`() {
        var m = NotificationManager()
        let r = m.ingest(event(.permission, detail: "Bash"), policy: policy, now: t0)
        #expect(r.disposition == .presented)
        #expect(r.playSound)
        #expect(m.pending.count == 1)
        let alert = m.currentAlert(now: t0.addingTimeInterval(600))
        #expect(alert?.emotion == .anxiety)
        #expect(alert?.until == nil)
    }

    @Test func `duplicate reports of one request merge without a second alert`() {
        var m = NotificationManager()
        let first = event(.permission, detail: "Bash")
        _ = m.ingest(first, policy: policy, now: t0)
        let again = m.ingest(event(.permission, at: 1), policy: policy, now: t0.addingTimeInterval(1))
        #expect(again.disposition == .merged)
        #expect(!again.playSound)
        #expect(m.pending.count == 1)
        #expect(m.pending.first?.event.detail == "Bash")
        // The exact same event delivered twice (spool + live) is dropped outright.
        let r1 = m.ingest(first, policy: policy, now: t0)
        #expect(r1.disposition == .duplicate)
    }

    @Test func `the tool finishing resolves its own request but not another tool's`() {
        var m = NotificationManager()
        _ = m.ingest(event(.permission, detail: "Bash"), policy: policy, now: t0)
        let other = m.ingest(event(.activity, at: 1, detail: "Read"), policy: policy, now: t0)
        #expect(other.resolvedIDs.isEmpty)
        #expect(m.pending.count == 1)
        let same = m.ingest(event(.activity, at: 2, detail: "Bash"), policy: policy, now: t0)
        #expect(same.resolvedIDs.count == 1)
        #expect(m.pending.isEmpty)
        #expect(m.currentAlert(now: t0.addingTimeInterval(3)) == nil)
    }

    @Test func `a new prompt or the turn ending resolves everything in that session only`() {
        var m = NotificationManager()
        _ = m.ingest(event(.permission, session: "a", detail: "Bash"), policy: policy, now: t0)
        _ = m.ingest(event(.question, session: "b"), policy: policy, now: t0)
        _ = m.ingest(event(.activity, session: "a", at: 5), policy: policy, now: t0)
        #expect(m.pending.map(\.event.sessionID) == ["b"])
        _ = m.ingest(event(.completed, session: "b", at: 6), policy: policy, now: t0.addingTimeInterval(6))
        #expect(m.pending.isEmpty)
    }

    @Test func `clicking or dismissing never resolves a request`() {
        var m = NotificationManager()
        _ = m.ingest(event(.permission), policy: policy, now: t0)
        let id = m.allPending[0].id
        m.dismiss(id)
        #expect(m.currentAlert(now: t0) == nil)
        #expect(m.allPending.count == 1)
        #expect(m.records[id]?.status == .pending)
        m.undismissAll()
        #expect(m.currentAlert(now: t0) != nil)
    }

    @Test func `completion is transient and never as urgent as a permission`() {
        var m = NotificationManager()
        let r = m.ingest(event(.completed), policy: policy, now: t0)
        #expect(r.disposition == .presented)
        let alert = m.currentAlert(now: t0.addingTimeInterval(1))
        #expect(alert?.emotion == .joy)
        #expect(alert?.until != nil)
        #expect(m.currentAlert(now: t0.addingTimeInterval(10)) == nil)
        #expect(m.pending.isEmpty)
    }

    @Test func `routine news does not take over from a waiting request`() {
        var m = NotificationManager()
        _ = m.ingest(event(.permission, session: "a"), policy: policy, now: t0)
        let r = m.ingest(event(.completed, session: "b", at: 1), policy: policy, now: t0.addingTimeInterval(1))
        #expect(r.disposition == .recordedOnly)
        #expect(m.currentAlert(now: t0.addingTimeInterval(2))?.record.event.sessionID == "a")
    }

    @Test func `a critical error interrupts, then the waiting request comes back`() {
        var m = NotificationManager()
        _ = m.ingest(event(.permission, session: "a"), policy: policy, now: t0)
        let r = m.ingest(event(.criticalError, session: "b", at: 1), policy: policy, now: t0.addingTimeInterval(1))
        #expect(r.disposition == .presented)
        #expect(m.currentAlert(now: t0.addingTimeInterval(2))?.emotion == .fear)
        #expect(m.currentAlert(now: t0.addingTimeInterval(30))?.record.event.sessionID == "a")
    }

    @Test func `highest priority request shows first and earlier requests are kept`() {
        var m = NotificationManager()
        _ = m.ingest(event(.question, session: "a"), policy: policy, now: t0)
        _ = m.ingest(event(.permission, session: "b", at: 1), policy: policy, now: t0)
        _ = m.ingest(event(.idle, session: "c", at: 2), policy: policy, now: t0)
        #expect(m.pending.count == 2)
        #expect(m.pending.first?.event.sessionID == "b")      // same priority: newest first
    }

    @Test func `two sessions waiting shows envy`() {
        var m = NotificationManager()
        _ = m.ingest(event(.permission, session: "a"), policy: policy, now: t0)
        _ = m.ingest(event(.permission, session: "b", agent: .codex, at: 1), policy: policy, now: t0)
        let alert = m.currentAlert(now: t0.addingTimeInterval(2))
        #expect(alert?.emotion == .envy)
        #expect(alert?.pendingCount == 2)
    }

    @Test func `already in the source app gives a compact, silent alert`() {
        var m = NotificationManager()
        var p = policy
        p.frontmostBundleID = "com.apple.Terminal"
        let r = m.ingest(event(.permission), policy: p, now: t0)
        #expect(r.style == .compact)
        #expect(!r.playSound)
        #expect(m.currentAlert(now: t0)?.style == .compact)
        // A second session waiting brings back the full notch.
        _ = m.ingest(event(.permission, session: "other"), policy: policy, now: t0)
        #expect(m.currentAlert(now: t0)?.style == .full)
    }

    @Test func `quiet mode and focus`() {
        var m = NotificationManager()
        var quiet = policy
        quiet.quiet = true
        let q = m.ingest(event(.permission, session: "q"), policy: quiet, now: t0)
        #expect(q.style == .compact && !q.playSound)

        var focus = policy
        focus.focusActive = true
        let r2 = m.ingest(event(.completed, session: "f"), policy: focus, now: t0)
        #expect(r2.disposition == .recordedOnly)
        let r3 = m.ingest(event(.permission, session: "g"), policy: focus, now: t0)
        #expect(r3.disposition == .presented)
    }

    @Test func `muted agents and categories are recorded but not presented`() {
        var m = NotificationManager()
        var p = policy
        p.enabledAgents = [.claudeCode]
        p.enabledCategories.remove(.completions)
        let r4 = m.ingest(event(.permission, agent: .codex), policy: p, now: t0)
        #expect(r4.disposition == .recordedOnly)
        let r5 = m.ingest(event(.completed, session: "x"), policy: p, now: t0)
        #expect(r5.disposition == .recordedOnly)
        #expect(m.pending.isEmpty)
    }

    @Test func `a repeated stop within the window is not shown twice`() {
        var m = NotificationManager()
        let r6 = m.ingest(event(.completed), policy: policy, now: t0)
        #expect(r6.disposition == .presented)
        let r7 = m.ingest(event(.completed, at: 1), policy: policy, now: t0.addingTimeInterval(1))
        #expect(r7.disposition == .duplicate)
    }

    @Test func `requests expire when old or when the agent process is gone`() {
        var m = NotificationManager()
        _ = m.ingest(event(.permission, session: "dead", agentPID: 999), policy: policy, now: t0)
        _ = m.ingest(event(.permission, session: "alive", agentPID: 1000), policy: policy, now: t0)
        let expired = m.expire(now: t0.addingTimeInterval(10), isAlive: { $0 == 1000 })
        #expect(expired.map(\.event.sessionID) == ["dead"])
        #expect(m.pending.map(\.event.sessionID) == ["alive"])
        let later = m.expire(now: t0.addingTimeInterval(13 * 3600), isAlive: { _ in true })
        #expect(later.map(\.event.sessionID) == ["alive"])
    }

    @Test func `gentle reminders respect the interval`() {
        var m = NotificationManager()
        _ = m.ingest(event(.permission), policy: policy, now: t0)
        let r8 = m.reminderDue(now: t0.addingTimeInterval(60), interval: 300)
        #expect(r8 == nil)
        let r9 = m.reminderDue(now: t0.addingTimeInterval(301), interval: 300)
        #expect(r9 != nil)
        let r10 = m.reminderDue(now: t0.addingTimeInterval(400), interval: 300)
        #expect(r10 == nil)
        let r11 = m.reminderDue(now: t0.addingTimeInterval(400), interval: 0)
        #expect(r11 == nil)
    }

    @Test func `alert copy uses the agent name when the project is unknown`() {
        var e = event(.permission, detail: "Bash")
        #expect(AlertCopy.title(for: e) == "Claude Code needs permission for Bash")
        #expect(AlertCopy.subtitle(for: e) == "Project: Proj · Terminal")
        e.project = nil
        e.host.name = nil
        #expect(AlertCopy.subtitle(for: e) == "Claude Code")
    }

    @Test func `every emotion is reachable`() {
        let reached = Set(EventType.allCases.map(EmotionEngine.emotion(for:)) + [EmotionEngine.multipleRequests])
        for emotion in Emotion.nine { #expect(reached.contains(emotion), "\(emotion)") }
    }
}
