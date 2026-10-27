import NotchCore
import SwiftUI

extension EventType {
    var symbol: String {
        switch self {
        case .permission, .manualIntervention: "hand.raised.fill"
        case .question: "questionmark.bubble.fill"
        case .completed: "checkmark.circle.fill"
        case .buildFailed, .testFailed: "xmark.octagon.fill"
        case .criticalError: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle.fill"
        case .idle: "moon.zzz.fill"
        case .sessionStart, .sessionEnd, .activity: "circle"
        }
    }

    /// Name of the event kind, for settings and the capability matrix.
    var displayName: String {
        switch self {
        case .permission: "Permission request"
        case .question: "Question or confirmation"
        case .manualIntervention: "Needs intervention"
        case .completed: "Task completed"
        case .buildFailed: "Build failed"
        case .testFailed: "Tests failed"
        case .criticalError: "Critical error"
        case .stopped: "Task stopped"
        case .idle: "Idle / waiting"
        case .sessionStart: "Session started"
        case .sessionEnd: "Session ended"
        case .activity: "Activity"
        }
    }

    /// One-word status for the compact wing; never colour-only.
    var shortLabel: String {
        switch self {
        case .permission: "Permission"
        case .question: "Input"
        case .manualIntervention: "Needs you"
        case .completed: "Done"
        case .buildFailed: "Build failed"
        case .testFailed: "Tests failed"
        case .criticalError: "Error"
        case .stopped: "Stopped"
        case .idle: "Waiting"
        case .sessionStart, .sessionEnd, .activity: ""
        }
    }
}

extension EventType {
    /// Status colour by meaning (never the only signal: an icon and text go with it).
    var tint: Color {
        switch self {
        case .permission, .question, .manualIntervention: Color(red: 1, green: 0.72, blue: 0.27)
        case .completed: Color(red: 0.45, green: 0.86, blue: 0.55)
        case .buildFailed, .testFailed: Color(red: 1, green: 0.5, blue: 0.36)
        case .criticalError: Color(red: 1, green: 0.36, blue: 0.33)
        case .stopped, .idle, .sessionStart, .sessionEnd, .activity: Color(white: 0.72)
        }
    }
}

extension AgentKind {
    var symbol: String {
        switch self {
        case .claudeCode: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct NotchRootView: View {
    let state: NotchState
    let model: AppModel
    let controller: NotchController

    var body: some View {
        let g = state.geometry
        let shape = state.shape
        let open = state.mode != .hidden
        let cf = state.characterFrame

        // Fixed canvas the size of the panel; only the silhouette animates.
        // The character and copy keep their own coordinates and are revealed
        // by the growing shape, the way the Dynamic Island reveals content.
        ZStack(alignment: .topLeading) {
            AnimatedCharacterView(controller: controller.character, canvasCenter: state.canvasCenter)
                .frame(width: cf.width, height: cf.height)
                .offset(x: cf.minX, y: cf.minY)
            content
        }
        .frame(width: NotchLayout.panelWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.black)
        .clipShape(shape)
        // Depth from the path alone, not the rendered content; gone when
        // tucked into the notch.
        .background {
            shape.fill(.black)
                .shadow(color: .black.opacity(open ? 0.34 : 0), radius: 16, y: 8)
        }
        .contentShape(shape)
        .opacity(state.revealed ? 1 : 0)
        .scaleEffect(!g.hasNotch && !open ? 0.94 : 1, anchor: .top)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(location):
                controller.hover(true)
                controller.track(location)
            case .ended:
                controller.hover(false)
            }
        }
        .onTapGesture { if state.mode != .list { controller.activate() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open source") { controller.activate() }
        .accessibilityAction(named: "Dismiss") { controller.dismissCurrent() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, g.topOffset)
    }

    private var reduceMotion: Bool { model.reduceMotion }

    private var accessibilityText: String {
        if state.mode == .list { return AlertCopy.multipleTitle(count: state.pending.count) }
        guard let event = state.alert?.record.event else { return "Notch Companion" }
        return AlertCopy.spoken(for: event)
    }

    @ViewBuilder
    private var content: some View {
        switch state.mode {
        case .detail:
            if let alert = state.alert { detail(alert) }
        case .compact:
            if let alert = state.alert { compact(alert) }
        case .list:
            list
        case .hidden, .character:
            EmptyView()
        }
    }

    // MARK: Detail: character left, message right

    private func detail(_ alert: NotchAlert) -> some View {
        let event = alert.record.event
        let x = state.bodyMinX(for: .detail) + NotchLayout.characterSlot - 4
        let width = state.size(for: .detail).width - NotchLayout.characterSlot - 14
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: event.type.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(event.type.tint)
                    Text(event.agent.displayName.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(.white.opacity(0.5))
                }
                Text(AlertCopy.title(for: event))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(AlertCopy.subtitle(for: event))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                if let problem = state.navigationProblem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .transition(.opacity)
                } else if state.hovering, let hint = state.navigationHint {
                    Text(hint + " ›")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .frame(width: width, height: NotchLayout.contentHeight, alignment: .leading)

            HStack(spacing: 6) {
                if alert.pendingCount > 1 {
                    Button { controller.toggleList() } label: {
                        Text("\(alert.pendingCount) waiting")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.14)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(alert.pendingCount) requests waiting. Show list.")
                }
                if state.hovering {
                    Button { controller.dismissCurrent() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss — the request stays in the pending list")
                    .accessibilityLabel("Dismiss")
                    .transition(.opacity)
                }
            }
            .padding(.top, 8)
        }
        .frame(width: width, height: NotchLayout.contentHeight)
        .offset(x: x, y: state.geometry.contentTop)
        // Follows the character's glide left, once it has made room.
        .transition(.materialize(delay: 0.16, anchor: .leading, drift: 10, reduceMotion: reduceMotion))
        .id(alert.record.id)
    }

    // MARK: Compact: tiny character left, status right

    private func compact(_ alert: NotchAlert) -> some View {
        let g = state.geometry
        let event = alert.record.event
        let bodyMinX = state.bodyMinX(for: .compact)
        let wingStart = g.hasNotch ? bodyMinX + NotchLayout.compactWing + g.notchSize.width : bodyMinX + 68
        return HStack(spacing: 5) {
            Image(systemName: event.type.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(event.type.tint)
            Text(event.type.shortLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: g.hasNotch ? NotchLayout.compactWing - 8 : 150, height: state.size(for: .compact).height,
               alignment: g.hasNotch ? .center : .leading)
        .offset(x: wingStart + 2, y: 0)
        .transition(.materialize(delay: 0.08, anchor: g.hasNotch ? .center : .leading, reduceMotion: reduceMotion))
        .id(alert.record.id)
    }

    // MARK: List: every pending request, newest first

    private var list: some View {
        let top = state.geometry.contentTop
        let rows = Array(state.pending.prefix(NotchLayout.maxRows))
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(state.pending.count > 1 ? AlertCopy.multipleTitle(count: state.pending.count) : "1 request waiting")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Hide") { controller.toggleList() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.leading, 112)
            .padding(.trailing, 18)
            .frame(height: NotchLayout.listHeader)

            ForEach(rows) { record in
                PendingRow(record: record, hint: model.navigation.level(for: record.event.host).rawValue,
                           open: { controller.open(record) },
                           dismiss: { model.dismiss(record.id) })
                    .frame(height: NotchLayout.rowHeight)
                    .transition(.materialize(delay: 0, anchor: .top, reduceMotion: reduceMotion))
            }
        }
        .frame(width: state.size(for: .list).width, alignment: .topLeading)
        .offset(x: state.bodyMinX(for: .list), y: top)
        .transition(.materialize(delay: 0.08, anchor: .top, reduceMotion: reduceMotion))
    }
}

// MARK: - Content transitions

/// Copy settles in once the notch has made room, and leaves quickly, before
/// the shape closes, so text is never squeezed by the moving edge. Reduce
/// Motion keeps it to a plain cross-fade. (No blur: animating a blur costs
/// dropped frames while the silhouette is resizing.)
private struct Materialize: ViewModifier {
    var hidden: Bool
    var anchor: UnitPoint
    var scale: CGFloat
    var drift: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .scaleEffect(hidden ? scale : 1, anchor: anchor)
            .offset(x: hidden ? drift : 0)
    }
}

private extension AnyTransition {
    /// `drift`: how far right of its place the copy starts, so it follows motion leftward.
    static func materialize(delay: Double, anchor: UnitPoint, drift: CGFloat = 0, reduceMotion: Bool) -> AnyTransition {
        func effect(scale: CGFloat, drift: CGFloat) -> AnyTransition {
            reduceMotion ? .opacity : .modifier(active: Materialize(hidden: true, anchor: anchor, scale: scale, drift: drift),
                                                identity: Materialize(hidden: false, anchor: anchor, scale: 1, drift: 0))
        }
        let arrive: Animation = reduceMotion ? NotchMotion.reduced : .smooth(duration: 0.32).delay(delay)
        return .asymmetric(insertion: effect(scale: 0.96, drift: drift).animation(arrive),
                           removal: effect(scale: 0.98, drift: 0).animation(.easeOut(duration: 0.12)))
    }
}

private struct PendingRow: View {
    let record: NotificationRecord
    let hint: String
    let open: () -> Void
    let dismiss: () -> Void
    @LocalState private var hovered = false

    var body: some View {
        let event = record.event
        HStack(spacing: 10) {
            Image(systemName: event.type.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(event.type.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(AlertCopy.title(for: event))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(AlertCopy.subtitle(for: event))
                    Text("·")
                    Text(record.lastSeen, style: .relative)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            if hovered {
                Text(hint)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(hovered ? 0.08 : 0))
            .padding(.horizontal, 8))
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovered = inside } }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Dismiss", dismiss)
    }
}
