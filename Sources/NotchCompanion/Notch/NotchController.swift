import AppKit
import NotchCore
import Observation
import SwiftUI

/// What the notch view renders. Owned by NotchController.
///
/// Everything is laid out in the panel's fixed coordinates (x = 0 at the
/// panel's left edge, y = 0 at the top of the silhouette), so only the
/// silhouette changes size and content never drifts while it animates.
@Observable
final class NotchState {
    var geometry: NotchGeometry
    var mode: NotchMode = .hidden
    /// The layout the character is placed for. It stays put while the notch
    /// collapses (the shape closes over it) and jumps to the next layout,
    /// unanimated, while the notch is still shut.
    var characterMode: NotchMode = .character
    /// Whether the silhouette is drawn at all. Under a hardware notch it is
    /// switched on while collapsed (black on black: invisible) so opening is
    /// pure growth, never a fade; it's off at rest so screenshots stay clean.
    var revealed = false
    var alert: NotchAlert?
    var pending: [NotificationRecord] = []
    var hovering = false
    var navigationHint: String?
    /// Why the last click couldn't return anywhere ("Terminal is closed").
    var navigationProblem: String?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    var size: CGSize { size(for: mode) }
    var flare: CGFloat { NotchLayout.flare(for: mode, geometry: geometry) }

    var shape: NotchShape {
        NotchShape(size: size, flare: flare, bottomRadius: NotchLayout.bottomRadius(for: mode, geometry: geometry),
                   pill: !geometry.hasNotch)
    }

    func size(for mode: NotchMode) -> CGSize {
        NotchLayout.size(for: mode, geometry: geometry, rows: pending.count)
    }

    /// Left edge of the body (inside the flares) for a layout, in panel points.
    func bodyMinX(for mode: NotchMode) -> CGFloat {
        NotchLayout.panelWidth / 2 - size(for: mode).width / 2
    }

    /// Where the live character sits (panel points).
    var characterFrame: CGRect {
        let mode = characterMode, x = bodyMinX(for: mode), top = geometry.contentTop
        switch mode {
        case .hidden, .character:
            return CGRect(x: x, y: top, width: size(for: .character).width, height: NotchLayout.contentHeight)
        case .detail:
            return CGRect(x: x, y: top, width: NotchLayout.characterSlot, height: NotchLayout.contentHeight)
        case .compact:
            let height = size(for: .compact).height
            return geometry.hasNotch
                ? CGRect(x: x + 24, y: 0, width: NotchLayout.compactWing - 28, height: height)
                : CGRect(x: x + 4, y: 0, width: 60, height: height)
        case .list:
            return CGRect(x: x, y: top, width: 112, height: NotchLayout.listHeader)
        }
    }

    /// In the detail layout the canvas sits so the storyboard's empty left
    /// margin falls off the edge: the wave (leftmost gesture) stays visible and
    /// the finger-gun (rightmost) stops short of the text.
    var canvasCenter: CGFloat {
        guard characterMode == .detail else { return 0.5 }
        let canvasWidth = NotchLayout.contentHeight * NotchLayout.canvasAspect
        return (canvasWidth / 2 - 28) / NotchLayout.characterSlot
    }
}

/// One spring family for every change of the silhouette, so opening,
/// re-layout and closing feel like the same physical object (PRD §8.5:
/// expansion 250–350 ms, exit 200–300 ms, restrained overshoot).
enum NotchMotion {
    /// Grows out of the hardware notch with a slight, settling overshoot.
    static let open = Animation.spring(duration: 0.36, bounce: 0.2)
    /// Between open layouts (character → message, list, compact → detail).
    static let morph = Animation.spring(duration: 0.4, bounce: 0.14)
    /// Tucks back into the notch: critically damped, no overshoot.
    static let close = Animation.spring(duration: 0.3, bounce: 0)
    /// Copy and list rows changing in place.
    static let content = Animation.smooth(duration: 0.28)
    /// Reduce Motion: no growth or overshoot, a short cross-fade instead.
    static let reduced = Animation.easeOut(duration: 0.2)
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
    /// A compact alert the user clicked open; it stays open until it changes.
    private var expandedAlertID: UUID?
    private var lastReminderTick = 0

    init(model: AppModel) {
        self.model = model
        let screen = NotchGeometry.preferredScreen()
        state = NotchState(geometry: screen.map(NotchGeometry.measure) ?? NotchGeometry(
            screenFrame: .zero, notchSize: .zero, menuBarHeight: 24, centerX: 0))
    }

    func start() {
        character.view.rig.prewarm()
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

    /// Re-arms tracking, then applies the current model once per change.
    private func observe() {
        withObservationTracking {
            _ = model.currentAlert
            _ = model.showingList
            _ = model.waiting
            _ = model.reminderTick
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        update()
    }

    private func update() {
        if state.pending != model.waiting {
            withAnimation(contentAnimation) { state.pending = model.waiting }
        }
        if model.reminderTick != lastReminderTick {
            lastReminderTick = model.reminderTick
            if state.mode != .hidden { character.director.remind() }
        }

        if model.showingList, let first = model.waiting.first {
            let emotion = model.waiting.count > 1 ? EmotionEngine.multipleRequests : first.emotion
            setMode(.list)
            character.director.show(emotion)
            return
        }

        guard let alert = model.currentAlert else {
            // The copy fades first; the character retreats; the notch closes
            // over the tail of the retreat (MotionDirector.onHidden).
            withAnimation(contentAnimation) { state.alert = nil }
            shownAlertID = nil
            expandedAlertID = nil
            promoteTask?.cancel()
            if character.director.machine.isVisible {
                character.director.hide()
            } else {
                collapse()
            }
            return
        }

        let isNew = alert.record.id != shownAlertID
        withAnimation(contentAnimation) {
            if state.alert != alert { state.alert = alert }
            if isNew {
                state.navigationHint = model.navigation.hint(for: alert.record.event.host)
                state.navigationProblem = nil
            }
        }
        shownAlertID = alert.record.id
        if isNew { expandedAlertID = nil }
        character.director.show(alert.emotion)

        switch alert.style {
        case .compact:
            if alert.record.id != expandedAlertID { setMode(.compact) }
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

    private var contentAnimation: Animation { model.reduceMotion ? NotchMotion.reduced : NotchMotion.content }

    /// Opening grows the silhouette out of the hardware notch; closing tucks
    /// it back in. Under a notch the silhouette is opaque the whole way, so it
    /// reads as the notch itself changing shape. Springs retarget from the
    /// on-screen state, so a new alert mid-close simply reopens.
    private func setMode(_ mode: NotchMode) {
        guard state.mode != mode else { return }
        let opening = state.mode == .hidden, closing = mode == .hidden
        // Grow out of the notch only where there is one, and not under Reduce Motion.
        let grows = state.geometry.hasNotch && !model.reduceMotion

        if opening {
            // While still shut, put the character where it will be, so it just
            // rises in place instead of sliding across as the shape opens.
            withTransaction(Transaction(animation: nil)) {
                state.characterMode = mode
                if grows { state.revealed = true }
            }
        }

        let animation: Animation
        if model.reduceMotion {
            animation = NotchMotion.reduced
        } else if opening {
            animation = NotchMotion.open
        } else if closing {
            animation = NotchMotion.close
        } else {
            animation = NotchMotion.morph
        }

        if closing {
            withAnimation(animation, completionCriteria: .removed) {
                state.mode = .hidden
                if !grows { state.revealed = false }
            } completion: { [weak self] in
                // Fully tucked in: stop drawing it, unless something reopened it.
                guard let self, self.state.mode == .hidden else { return }
                self.state.revealed = false
            }
        } else {
            withAnimation(animation) {
                state.mode = mode
                state.characterMode = mode
                if !grows { state.revealed = true }
            }
        }
        updateMousePassThrough()
    }

    private func collapse() {
        guard model.currentAlert == nil, !(model.showingList && !model.waiting.isEmpty) else { return }
        setMode(.hidden)
        state.hovering = false
    }

    // MARK: Input

    /// Rect of the visible shape in screen coordinates.
    private var shapeScreenRect: CGRect? {
        guard state.mode != .hidden else { return nil }
        let g = state.geometry, s = state.size
        let width = s.width + 2 * state.flare
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
        guard let record = state.alert?.record else {
            character.director.press()
            return
        }
        if state.mode == .compact {
            expandedAlertID = record.id
            setMode(.detail)
        }
        open(record)
    }

    func open(_ record: NotificationRecord) {
        character.director.press()
        model.open(record) { [weak self] result in
            // Say why nothing came forward, where the click happened.
            guard let self, result.level == .unavailable, self.state.alert?.record.id == record.id else { return }
            withAnimation(self.contentAnimation) { self.state.navigationProblem = result.message }
        }
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
