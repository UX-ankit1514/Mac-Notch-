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
        let size = state.size
        let flare = g.hasNotch ? NotchLayout.flare : 0
        let shape = NotchShape(flare: flare, bottomRadius: state.mode == .compact ? 12 : NotchLayout.bottomRadius,
                               pill: !g.hasNotch)
        let hidden = state.mode == .hidden
        let cf = state.characterFrame

        ZStack(alignment: .topLeading) {
            Color.black
            CharacterView(controller: controller.character, canvasCenter: state.canvasCenter)
                .frame(width: cf.width, height: cf.height)
                .offset(x: cf.minX, y: cf.minY)
            content(flare: flare)
        }
        .frame(width: size.width + 2 * flare, height: size.height, alignment: .topLeading)
        .clipShape(shape)
        .contentShape(shape)
        .shadow(color: .black.opacity(hidden ? 0 : 0.32), radius: 14, y: 6)
        .opacity(hidden ? 0 : 1)
        .scaleEffect(hidden && !g.hasNotch ? 0.96 : 1, anchor: .top)
        .animation(.easeOut(duration: hidden ? 0.15 : 0.08).delay(hidden ? 0.18 : 0), value: hidden)
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

    private var accessibilityText: String {
        if state.mode == .list { return AlertCopy.multipleTitle(count: state.pending.count) }
        guard let event = state.alert?.record.event else { return "Notch Companion" }
        return AlertCopy.spoken(for: event)
    }

    @ViewBuilder
    private func content(flare: CGFloat) -> some View {
        switch state.mode {
        case .detail:
            if let alert = state.alert { detail(alert, flare: flare) }
        case .compact:
            if let alert = state.alert { compact(alert, flare: flare) }
        case .list:
            list(flare: flare)
        case .hidden, .character:
            EmptyView()
        }
    }

    // MARK: Detail: character left, message right

    private func detail(_ alert: NotchAlert, flare: CGFloat) -> some View {
        let event = alert.record.event
        let x = flare + NotchLayout.characterSlot - 4
        let width = state.size.width - NotchLayout.characterSlot - 14
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
                if state.hovering, let hint = state.navigationHint {
                    Text(hint + " ›")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
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
        .transition(.opacity.combined(with: .offset(y: 4)).animation(.easeOut(duration: 0.2).delay(0.08)))
        .id(alert.record.id)
    }

    // MARK: Compact: tiny character left, status right

    private func compact(_ alert: NotchAlert, flare: CGFloat) -> some View {
        let g = state.geometry
        let event = alert.record.event
        let wingStart = g.hasNotch ? flare + NotchLayout.compactWing + g.notchSize.width : flare + 68
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
        .frame(width: g.hasNotch ? NotchLayout.compactWing - 8 : 150, height: state.size.height,
               alignment: g.hasNotch ? .center : .leading)
        .offset(x: wingStart + 2, y: 0)
        .transition(.opacity)
    }

    // MARK: List: every pending request, newest first

    private func list(flare: CGFloat) -> some View {
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
            }
        }
        .frame(width: state.size.width, alignment: .topLeading)
        .offset(x: flare, y: top)
        .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.06)))
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
