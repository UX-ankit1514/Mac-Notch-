import Foundation

/// One notification as the user sees it: possibly several merged hook reports.
public struct NotificationRecord: Sendable, Identifiable, Hashable {
    public var id: UUID
    public var event: AgentEvent
    public var firstSeen: Date
    public var lastSeen: Date
    public var status: EventStatus
    /// Hidden from the notch but still pending and listed (PRD §10.5 Dismiss).
    public var dismissed: Bool
    /// Filtered by settings (agent or category off): kept in history only.
    public var muted: Bool
    public var resolvedAt: Date?
    public var lastReminder: Date?
    /// How it was first presented (compact when the user was already in the source app).
    public var style: AlertStyle = .full

    public init(event: AgentEvent, muted: Bool = false) {
        self.id = event.id
        self.event = event
        self.firstSeen = event.timestamp
        self.lastSeen = event.timestamp
        self.status = event.type.needsAttention ? .pending : .resolved
        self.dismissed = false
        self.muted = muted
        self.resolvedAt = event.type.needsAttention ? nil : event.timestamp
        self.lastReminder = nil
    }

    public var emotion: Emotion { EmotionEngine.emotion(for: event.type) }
    public var isActionable: Bool { status == .pending && event.type.needsAttention }
}

/// Inputs from settings and the system that shape presentation.
public struct NotificationPolicy: Sendable, Equatable {
    public var enabledAgents: Set<AgentKind> = Set(AgentKind.allCases)
    public var enabledCategories: Set<EventCategory> = Set(EventCategory.allCases)
    public var quiet = false
    public var focusActive = false
    public var soundEnabled = true
    /// Bundle ID of the app in front when the event arrived.
    public var frontmostBundleID: String?

    public init() {}
}

public enum AlertStyle: String, Sendable, Equatable {
    /// Expanded notch, character, message.
    case full
    /// Small wings beside the notch: used when the user is already in the
    /// source app, in quiet mode and during Focus.
    case compact
}

public struct NotchAlert: Sendable, Equatable {
    public var record: NotificationRecord
    public var emotion: Emotion
    public var style: AlertStyle
    public var pendingCount: Int
    /// Present until this time (transient alerts); nil = until resolved/dismissed.
    public var until: Date?
}

public struct IngestResult: Sendable, Equatable {
    public enum Disposition: Sendable, Equatable {
        case presented          // a new alert should appear
        case merged             // folded into an existing request: no new alert, no sound
        case recordedOnly       // history only (filtered, or outranked by a pending request)
        case duplicate          // dropped
        case bookkeeping        // session/activity events
    }

    public var disposition: Disposition
    /// Records to write to history (new or changed).
    public var changed: [NotificationRecord] = []
    public var resolvedIDs: [UUID] = []
    public var playSound = false
    public var style: AlertStyle = .full
}

/// Prioritises, deduplicates, queues and expires notifications. A value type
/// with no I/O, so every rule is unit-tested; the app owns one instance.
public struct NotificationManager: Sendable {
    public var transientDuration: TimeInterval = 5
    public var lowPriorityDuration: TimeInterval = 3.5
    public var pendingLifetime: TimeInterval = 12 * 3600
    public var duplicateWindow: TimeInterval = 5

    public private(set) var records: [UUID: NotificationRecord] = [:]
    public private(set) var sessions: [String: SessionState] = [:]
    /// The transient (non-blocking) alert currently on screen, if any.
    public private(set) var transient: (id: UUID, until: Date, style: AlertStyle)?
    private var seenEventIDs: [UUID] = []
    private var lastTransientByKey: [String: Date] = [:]

    public init() {}

    // MARK: Ingest

    public mutating func ingest(_ event: AgentEvent, policy: NotificationPolicy, now: Date = Date()) -> IngestResult {
        guard !seenEventIDs.contains(event.id) else { return IngestResult(disposition: .duplicate) }
        remember(event.id)
        trackSession(event)

        var result = IngestResult(disposition: .bookkeeping)
        result.resolvedIDs = resolve(after: event)
        result.changed = result.resolvedIDs.compactMap { records[$0] }

        guard event.type.isPresentable else { return result }

        let muted = !policy.enabledAgents.contains(event.agent)
            || !policy.enabledCategories.contains(event.type.category)

        // Same outstanding request reported twice (PermissionRequest + Notification).
        if event.type.needsAttention, let existing = pendingRecord(dedupeKey: event.dedupeKey) {
            var merged = existing
            merged.lastSeen = event.timestamp
            if merged.event.detail == nil { merged.event.detail = event.detail }
            if merged.event.type != .permission, event.type == .permission { merged.event.type = .permission }
            records[merged.id] = merged
            result.disposition = .merged
            result.changed.append(merged)
            return result
        }

        // The same transient outcome twice in quick succession (e.g. Stop re-fired).
        if !event.type.needsAttention {
            if let last = lastTransientByKey[event.dedupeKey], now.timeIntervalSince(last) < duplicateWindow {
                return IngestResult(disposition: .duplicate, changed: result.changed,
                                    resolvedIDs: result.resolvedIDs)
            }
            lastTransientByKey[event.dedupeKey] = now
        }

        let record = NotificationRecord(event: event, muted: muted)
        records[record.id] = record
        result.changed.append(record)

        if muted {
            result.disposition = .recordedOnly
            return result
        }

        let style = style(for: event, policy: policy)
        records[record.id]?.style = style
        let focusSuppressed = policy.focusActive && event.priority < .high
        // A blocked agent outranks routine news; only critical errors interrupt it.
        let outranked = !event.type.needsAttention && event.priority < .critical
            && topPending() != nil

        if focusSuppressed || outranked {
            result.disposition = .recordedOnly
            return result
        }

        if !event.type.needsAttention {
            let duration = event.priority == .low ? lowPriorityDuration : transientDuration
            transient = (record.id, now.addingTimeInterval(duration), style)
        }
        result.disposition = .presented
        result.style = style
        result.playSound = policy.soundEnabled && !policy.quiet && style == .full
            && event.priority >= .normal
        return result
    }

    func style(for event: AgentEvent, policy: NotificationPolicy) -> AlertStyle {
        if policy.quiet || policy.focusActive || event.priority == .low { return .compact }
        if let front = policy.frontmostBundleID, front == event.host.bundleID { return .compact }
        return .full
    }

    // MARK: Resolution

    /// Marks pending requests handled when a later event in the same session
    /// shows the agent moved on. Clicking the alert never resolves anything.
    mutating func resolve(after event: AgentEvent) -> [UUID] {
        let candidates = records.values.filter {
            $0.isActionable && $0.event.sessionKey == event.sessionKey && $0.firstSeen <= event.timestamp
        }
        guard !candidates.isEmpty else { return [] }

        let resolvesAll: Bool
        switch event.type {
        case .completed, .stopped, .criticalError, .sessionEnd, .sessionStart, .idle:
            resolvesAll = true
        case .activity:
            // A prompt submission means the user is back. A finished tool only
            // resolves the request for that tool: parallel tools must not
            // clear a different tool's pending approval.
            resolvesAll = event.detail == nil
        default:
            resolvesAll = false
        }

        var resolved: [UUID] = []
        for var record in candidates {
            let matches: Bool
            if resolvesAll {
                matches = true
            } else if event.type == .activity, let tool = event.detail {
                matches = record.event.detail == nil || record.event.detail == tool
                    || (record.event.type == .question && ClaudeCodeConnector.questionTools.contains(tool))
            } else {
                matches = false
            }
            guard matches else { continue }
            record.status = .resolved
            record.resolvedAt = event.timestamp
            records[record.id] = record
            resolved.append(record.id)
        }
        return resolved
    }

    // MARK: Presentation

    /// Undismissed, unmuted pending requests, most important first.
    public var pending: [NotificationRecord] {
        records.values
            .filter { $0.isActionable && !$0.dismissed && !$0.muted }
            .sorted {
                ($0.event.priority, $0.lastSeen) > ($1.event.priority, $1.lastSeen)
            }
    }

    /// Every pending request including dismissed ones (the menu and the list).
    public var allPending: [NotificationRecord] {
        records.values.filter { $0.isActionable && !$0.muted }.sorted { $0.lastSeen > $1.lastSeen }
    }

    func topPending() -> NotificationRecord? { pending.first }

    func pendingRecord(dedupeKey: String) -> NotificationRecord? {
        records.values.first { $0.isActionable && $0.event.dedupeKey == dedupeKey }
    }

    /// What the notch should show right now, or nil to collapse.
    public func currentAlert(now: Date = Date()) -> NotchAlert? {
        let pendingNow = pending
        if let t = transient, t.until > now, let record = records[t.id] {
            if record.event.priority >= .critical || pendingNow.isEmpty {
                return NotchAlert(record: record, emotion: record.emotion, style: t.style,
                             pendingCount: pendingNow.count, until: t.until)
            }
        }
        guard let top = pendingNow.first else { return nil }
        let sessionsWaiting = Set(pendingNow.map(\.event.sessionKey)).count
        let emotion = sessionsWaiting >= 2 ? EmotionEngine.multipleRequests : top.emotion
        // Several waiting always gets the full notch; a single request keeps
        // the style it arrived with.
        let style: AlertStyle = sessionsWaiting >= 2 ? .full : top.style
        return NotchAlert(record: top, emotion: emotion, style: style,
                     pendingCount: pendingNow.count, until: nil)
    }

    /// Next time the presentation changes on its own (a transient ends).
    public func nextDeadline(now: Date = Date()) -> Date? {
        guard let t = transient, t.until > now else { return nil }
        return t.until
    }

    // MARK: User actions

    public mutating func dismiss(_ id: UUID) {
        if transient?.id == id { transient = nil }
        records[id]?.dismissed = true
    }

    public mutating func dismissAll() {
        transient = nil
        for id in records.keys where records[id]?.isActionable == true { records[id]?.dismissed = true }
    }

    /// Brings dismissed requests back (the "show pending" action).
    public mutating func undismissAll() {
        for id in records.keys where records[id]?.isActionable == true { records[id]?.dismissed = false }
    }

    // MARK: Housekeeping

    /// Expires requests that are too old or whose agent process has exited.
    public mutating func expire(now: Date = Date(), isAlive: (Int32) -> Bool = HostDetector.isAlive) -> [NotificationRecord] {
        var changed: [NotificationRecord] = []
        for var record in records.values where record.isActionable {
            let tooOld = now.timeIntervalSince(record.lastSeen) > pendingLifetime
            let agentGone = record.event.agentPID.map { !isAlive($0) } ?? false
            guard tooOld || agentGone else { continue }
            record.status = .expired
            record.resolvedAt = now
            records[record.id] = record
            changed.append(record)
        }
        if let t = transient, t.until <= now { transient = nil }
        // Keep memory bounded: resolved/expired records live on in history.
        let settled = records.values.filter { !$0.isActionable && now.timeIntervalSince($0.lastSeen) > 600 }
        for record in settled where record.id != transient?.id { records[record.id] = nil }
        return changed
    }

    /// A pending request due a gentle reminder, if any; marks it reminded.
    public mutating func reminderDue(now: Date = Date(), interval: TimeInterval) -> NotificationRecord? {
        guard interval > 0, var top = topPending() else { return nil }
        let since = top.lastReminder ?? top.lastSeen
        guard now.timeIntervalSince(since) >= interval else { return nil }
        top.lastReminder = now
        records[top.id] = top
        return top
    }

    /// Reloads requests still pending from a previous run.
    public mutating func restore(_ restored: [NotificationRecord]) {
        for record in restored where records[record.id] == nil {
            records[record.id] = record
            remember(record.id)
            trackSession(record.event)
        }
    }

    // MARK: Sessions

    public struct SessionState: Sendable, Hashable {
        public var agent: AgentKind
        public var sessionID: String
        public var project: String?
        public var host: HostInfo
        public var lastEvent: Date
        public var ended: Bool
    }

    public var activeSessions: [SessionState] {
        sessions.values.filter { !$0.ended }.sorted { $0.lastEvent > $1.lastEvent }
    }

    mutating func trackSession(_ event: AgentEvent) {
        var state = sessions[event.sessionKey] ?? SessionState(
            agent: event.agent, sessionID: event.sessionID, project: event.project,
            host: event.host, lastEvent: event.timestamp, ended: false)
        state.lastEvent = max(state.lastEvent, event.timestamp)
        state.project = event.project ?? state.project
        if event.host.isKnown { state.host = event.host }
        state.ended = event.type == .sessionEnd
        sessions[event.sessionKey] = state
    }

    private mutating func remember(_ id: UUID) {
        seenEventIDs.append(id)
        if seenEventIDs.count > 512 { seenEventIDs.removeFirst(seenEventIDs.count - 512) }
    }
}
