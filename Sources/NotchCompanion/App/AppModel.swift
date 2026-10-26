import AppKit
import NotchCore
import Observation
import os

let log = Logger(subsystem: AppPaths.bundleID, category: "app")

/// Bounded diagnostics with no secrets: counts and latencies only.
struct Diagnostics {
    var received = 0
    var rejected: [String: Int] = [:]
    var rateLimited = 0
    var latencies: [Double] = []

    mutating func record(latency: Double) {
        latencies.append(latency)
        if latencies.count > 500 { latencies.removeFirst(latencies.count - 500) }
    }

    var p95Latency: Double? {
        guard !latencies.isEmpty else { return nil }
        let sorted = latencies.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }
}

/// The app's single source of truth. Receives events, applies the
/// notification rules, persists history, and publishes what the notch shows.
@Observable
final class AppModel {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            settingsChanged?()
        }
    }

    private(set) var manager = NotificationManager()
    private(set) var currentAlert: NotchAlert?
    private(set) var pending: [NotificationRecord] = []
    private(set) var history: [NotificationRecord] = []
    private(set) var diagnostics = Diagnostics()
    private(set) var lastNavigation: String?
    /// The notch's pending-request list is expanded.
    var showingList = false
    /// Bumped when an unresolved request should get a gentle reminder.
    private(set) var reminderTick = 0
    private(set) var serverError: String?

    let paths = AppPaths.default
    let navigation = NavigationController()
    let integrations: IntegrationManager
    let focus = FocusObserver()
    var settingsChanged: (() -> Void)?

    @ObservationIgnored private var store: HistoryStore?
    @ObservationIgnored private var server: LocalSocketServer?
    @ObservationIgnored private var validator: PayloadValidator?
    @ObservationIgnored private var limiter = RateLimiter()
    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var housekeeping: Timer?
    @ObservationIgnored private var lastPrune = Date.distantPast

    init() {
        settings = AppSettings.load()
        integrations = IntegrationManager(paths: AppPaths.default)
    }

    // MARK: Lifecycle

    func start() {
        do {
            try paths.prepare()
            let token = try paths.loadOrCreateToken()
            validator = PayloadValidator(token: token)
        } catch {
            serverError = "Couldn't prepare \(paths.support.path): \(error.localizedDescription)"
            log.error("prepare failed: \(error.localizedDescription, privacy: .public)")
        }

        do {
            store = try HistoryStore(url: paths.historyDatabase)
        } catch {
            log.error("history unavailable: \(String(describing: error), privacy: .public)")
        }
        restorePending()
        startServer()
        drainSpool()
        integrations.installHelperIfNeeded()
        integrations.refresh(store: store)

        housekeeping = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    private func startServer() {
        let server = LocalSocketServer(path: paths.socket.path) { [weak self] data in
            Task { @MainActor in self?.receive(data, spooled: false) }
        }
        do {
            try server.start()
            self.server = server
            serverError = nil
        } catch LocalSocketError.alreadyRunning {
            serverError = "Another copy of Notch Companion is already running."
        } catch {
            serverError = "Event receiver couldn't start (\(error))."
        }
    }

    private func drainSpool() {
        for data in Spool(directory: paths.spoolDirectory).drain() { receive(data, spooled: true) }
    }

    private func restorePending() {
        guard let store else { return }
        let restored = store.pending(newerThan: Date().addingTimeInterval(-manager.pendingLifetime))
        manager.restore(restored)
        let expired = manager.expire()
        store.upsert(expired)
        refresh()
        history = store.recent()
    }

    /// After sleep: reconcile requests whose agent died, restart the receiver if needed.
    private func didWake() {
        if let server, !LocalSocketClient.isListening(at: server.path) {
            server.stop()
            self.server = nil
            startServer()
        }
        drainSpool()
        tick()
    }

    private func tick() {
        let expired = manager.expire()
        if !expired.isEmpty { store?.upsert(expired) }
        if let record = manager.reminderDue(interval: Double(settings.reminderMinutes) * 60),
           !(settings.quietMode || settings.isQuietHours()) {
            log.info("reminder for \(record.event.type.rawValue, privacy: .public)")
            reminderTick += 1
        }
        if Date().timeIntervalSince(lastPrune) > 3600 {
            store?.prune(olderThan: Date().addingTimeInterval(-Double(settings.historyRetentionDays) * 86400))
            lastPrune = Date()
        }
        refresh()
    }

    // MARK: Receiving

    func receive(_ data: Data, spooled: Bool) {
        guard let validator else { return }
        guard limiter.allow() else {
            diagnostics.rateLimited += 1
            return
        }
        switch validator.validate(data) {
        case let .failure(reason):
            diagnostics.rejected[String(describing: reason), default: 0] += 1
            log.notice("rejected event: \(String(describing: reason), privacy: .public)")
        case let .success(event):
            diagnostics.received += 1
            let latency = Date().timeIntervalSince(event.timestamp)
            if !spooled { diagnostics.record(latency: latency) }
            log.info("event \(event.type.rawValue, privacy: .public) latency_ms=\(Int(latency * 1000), privacy: .public) spooled=\(spooled, privacy: .public)")
            ingest(event)
        }
    }

    func ingest(_ event: AgentEvent) {
        let result = manager.ingest(event, policy: policy())
        store?.upsert(result.changed)
        if event.connectorVersion != NotchVersion.simulated {
            integrations.noteEvent(from: event.agent, at: event.timestamp)
        }
        if result.playSound { playSound(for: event.priority) }
        if result.disposition == .presented { announce(event) }
        if pending.count < 2 { showingList = false }
        refresh()
    }

    private func policy() -> NotificationPolicy {
        var p = NotificationPolicy()
        p.enabledAgents = settings.enabledAgents
        p.enabledCategories = settings.enabledCategories
        p.quiet = settings.quietMode || settings.isQuietHours()
        p.focusActive = settings.respectFocus && focus.isFocused
        p.soundEnabled = settings.soundEnabled
        p.frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return p
    }

    /// Republishes what the notch should show and schedules the next change.
    func refresh() {
        let now = Date()
        currentAlert = manager.currentAlert(now: now)
        pending = manager.allPending
        if pending.count < 2 && showingList && pending.isEmpty { showingList = false }
        history = store?.recent() ?? history

        deadlineTimer?.invalidate()
        if let deadline = manager.nextDeadline(now: now) {
            deadlineTimer = Timer.scheduledTimer(withTimeInterval: max(0.05, deadline.timeIntervalSince(now)), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    // MARK: User actions

    func dismiss(_ id: UUID) {
        manager.dismiss(id)
        if let record = manager.records[id] { store?.upsert([record]) }
        refresh()
    }

    func dismissAll() {
        manager.dismissAll()
        showingList = false
        refresh()
    }

    func showPendingList() {
        manager.undismissAll()
        showingList = !manager.allPending.isEmpty
        refresh()
    }

    /// Returns to the source. Never marks the request resolved: only the agent can.
    func open(_ record: NotificationRecord) {
        Task {
            let result = await navigation.open(record.event)
            lastNavigation = result.message
        }
    }

    func clearHistory() {
        store?.clear()
        history = []
    }

    /// A simulated event straight into the pipeline (Character Preview).
    func simulate(_ type: EventType, agent: AgentKind = .claudeCode, project: String? = "Notch Companion") {
        let event = AgentEvent(type: type, agent: agent, sessionID: "preview-\(type.rawValue)",
                               host: HostInfo(bundleID: AppPaths.bundleID, name: "Preview"),
                               project: project, connectorVersion: NotchVersion.simulated,
                               detail: type == .permission ? "Bash" : nil)
        ingest(event)
    }

    // MARK: Output

    private func playSound(for priority: Priority) {
        let name: NSSound.Name = switch priority {
        case .critical: "Basso"
        case .high: "Tink"
        default: "Pop"
        }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = 0.45
        sound.play()
    }

    /// Status text independent of the character, for VoiceOver.
    private func announce(_ event: AgentEvent) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: AlertCopy.spoken(for: event),
            .priority: event.priority >= .high ? NSAccessibilityPriorityLevel.high.rawValue : NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    var reduceMotion: Bool {
        settings.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func lastEvent(for agent: AgentKind) -> Date? { store?.lastEvent(for: agent) }
}
