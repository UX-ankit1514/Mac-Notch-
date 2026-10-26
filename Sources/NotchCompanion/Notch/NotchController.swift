import AppKit
import NotchCore
import Observation
import SwiftUI

/// What the notch view renders. Owned by NotchController.
@Observable
final class NotchState {
    var geometry: NotchGeometry
    var mode: NotchMode = .hidden
    var alert: NotchAlert?
    var pending: [NotificationRecord] = []
    var hovering = false
    var navigationHint: String?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    var size: CGSize { NotchLayout.size(for: mode, geometry: geometry, rows: pending.count) }

    /// Where the live character sits inside the shape (shape-local points).
    var characterFrame: CGRect {
        let f = NotchLayout.flare, top = geometry.contentTop, s = size
        switch mode {
        case .hidden, .character:
            return CGRect(x: f, y: top, width: s.width, height: NotchLayout.contentHeight)
        case .detail:
            return CGRect(x: f, y: top, width: NotchLayout.characterSlot, height: NotchLayout.contentHeight)
        case .compact:
            return geometry.hasNotch
                ? CGRect(x: f + 24, y: 0, width: NotchLayout.compactWing - 28, height: s.height)
                : CGRect(x: f + 4, y: 0, width: 60, height: s.height)
        case .list:
            return CGRect(x: f, y: top, width: 112, height: NotchLayout.listHeader)
        }
    }

    /// In the detail layout the canvas sits so the storyboard's empty left
    /// margin falls off the edge: the wave (leftmost gesture) stays visible and
    /// the finger-gun (rightmost) stops short of the text.
    var canvasCenter: CGFloat {
        guard mode == .detail else { return 0.5 }
        let canvasWidth = NotchLayout.contentHeight * NotchLayout.canvasAspect
        return (canvasWidth / 2 - 28) / NotchLayout.characterSlot
    }
}

/// Places the notch on the right display, maps alerts to notch states,
/// drives the character, and handles hover, click and pass-through.
@MainActor
final class NotchController {
    let model: AppModel
    let panel = NotchPanel()
    let character = CharacterController()
    let state: NotchState
    private var monitors: [Any] = []
    private var promoteTask: Task<Void, Never>?
    private var shownAlertID: UUID?
    private var lastReminderTick = 0

    init(model: AppModel) {
        self.model = model
        let screen = NotchGeometry.preferredScreen()
        state = NotchState(geometry: screen.map(NotchGeometry.measure) ?? NotchGeometry(
            screenFrame: .zero, notchSize: .zero, menuBarHeight: 24, centerX: 0))
    }

    func start() {
        let root = NotchRootView(state: state, model: model, controller: self)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        placePanel()
        panel.orderFrontRegardless()

        character.director.onHidden = { [weak self] in self?.collapse() }
        applySettings()
        observe()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placePanel() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placePanel() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderFrontRegardless() }
        }
        installMouseMonitors()
    }

    /// Recomputes geometry for the active display (display changes, wake).
    func placePanel() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        state.geometry = NotchGeometry.measure(screen)
        let g = state.geometry
        let height = g.topOffset + g.contentTop + NotchLayout.panelExtraHeight
        let frame = CGRect(x: g.centerX - NotchLayout.panelWidth / 2, y: g.screenFrame.maxY - height,
                           width: NotchLayout.panelWidth, height: height)
        panel.setFrame(frame, display: true)
    }

    func applySettings() {
        character.apply(intensity: model.settings.motionIntensity.scale, reduceMotion: model.reduceMotion)
    }

    // MARK: Observation

    private func observe() {
        withObservationTracking {
            _ = model.currentAlert
            _ = model.showingList
            _ = model.pending
            _ = model.reminderTick
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
        update()
    }

    private func update() {
        state.pending = model.pending
        if model.reminderTick != lastReminderTick {
            lastReminderTick = model.reminderTick
            if state.mode != .hidden { character.director.remind() }
        }

        if model.showingList, !model.pending.isEmpty {
            let emotion = model.pending.count > 1 ? EmotionEngine.multipleRequests : model.pending[0].emotion
            setMode(.list)
            character.director.show(emotion)
            return
        }

        guard let alert = model.currentAlert else {
            state.alert = nil
            shownAlertID = nil
            promoteTask?.cancel()
            if character.director.machine.isVisible {
                character.director.hide()        // collapses when the exit finishes
            } else {
                collapse()
            }
            return
        }

        let isNew = alert.record.id != shownAlertID
        state.alert = alert
        shownAlertID = alert.record.id
        state.navigationHint = model.navigation.hint(for: alert.record.event.host)
        character.director.show(alert.emotion)

        switch alert.style {
        case .compact:
            setMode(.compact)
        case .full:
            if state.mode == .hidden || state.mode == .compact || state.mode == .list {
                // Reveal the character first, then make room for the message.
                setMode(.character)
                schedulePromotion()
            } else if isNew && state.mode == .character {
                schedulePromotion()
            }
        }
    }

    private func schedulePromotion() {
        promoteTask?.cancel()
        promoteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled, let self, self.state.mode == .character, self.state.alert != nil else { return }
            self.setMode(.detail)
        }
    }

    private func setMode(_ mode: NotchMode) {
        guard state.mode != mode else { return }
        let animation: Animation = mode == .hidden
            ? .timingCurve(0.23, 1, 0.32, 1, duration: 0.25)        // exit: strong ease-out
            : .spring(duration: 0.32, bounce: 0.15)                  // expand: restrained overshoot
        withAnimation(model.reduceMotion ? .easeOut(duration: 0.2) : animation) {
            state.mode = mode
        }
        updateMousePassThrough()
    }

    private func collapse() {
        guard model.currentAlert == nil, !(model.showingList && !model.pending.isEmpty) else { return }
        setMode(.hidden)
        state.hovering = false
    }

    // MARK: Input

    /// Rect of the visible shape in screen coordinates.
    private var shapeScreenRect: CGRect? {
        guard state.mode != .hidden else { return nil }
        let g = state.geometry, s = state.size
        let width = s.width + 2 * NotchLayout.flare
        return CGRect(x: g.centerX - width / 2, y: g.screenFrame.maxY - g.topOffset - s.height,
                      width: width, height: s.height)
    }

    private func installMouseMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassThrough() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Accept the mouse only over the visible shape; everything else passes through.
    func updateMousePassThrough() {
        let inside = shapeScreenRect?.contains(NSEvent.mouseLocation) ?? false
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if !inside && state.hovering { hover(false) }
    }

    func hover(_ inside: Bool) {
        guard state.hovering != inside else { return }
        withAnimation(.easeOut(duration: 0.2)) { state.hovering = inside }
        character.director.pointer(inside: inside)
        if inside, state.mode == .character { setMode(.detail) }
    }

    /// Pupils follow the pointer while hovering.
    func track(_ location: CGPoint) {
        let frame = state.characterFrame
        let x = (location.x - frame.midX) / max(frame.width / 2, 1)
        let y = (location.y - frame.midY) / max(frame.height / 2, 1)
        character.director.track(CGPoint(x: x, y: y))
    }

    func activate() {
        character.director.press()
        if state.mode == .compact { setMode(.detail) }
        guard let record = state.alert?.record else { return }
        model.open(record)
    }

    func open(_ record: NotificationRecord) {
        character.director.press()
        model.open(record)
    }

    func dismissCurrent() {
        guard let id = state.alert?.record.id else { return }
        model.dismiss(id)
    }

    func toggleList() {
        if model.showingList {
            model.showingList = false
            model.refresh()
        } else {
            model.showPendingList()
        }
    }
}
