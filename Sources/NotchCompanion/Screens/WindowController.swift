import AppKit
import NotchCore
import SwiftUI

enum Screen: String, CaseIterable, Identifiable, Hashable {
    case welcome, tools, character, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .tools: "Connect Your Tools"
        case .character: "Character Preview"
        case .history: "Notification History"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .tools: "point.3.connected.trianglepath.dotted"
        case .character: "face.smiling"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

@Observable
final class Navigation {
    var screen: Screen = .welcome
}

/// The one app window. The app stays a menu-bar accessory; the window comes
/// forward when asked and the app returns to the background when it closes.
final class WindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let navigation = Navigation()
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show(_ screen: Screen) {
        navigation.screen = screen
        if window == nil {
            let host = NSHostingController(rootView: MainView(model: model, navigation: navigation,
                                                              close: { [weak self] in self?.window?.close() }))
            host.sizingOptions = []          // the window keeps its size; content scrolls
            let window = NSWindow(contentViewController: host)
            window.title = "Notch Companion"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.setContentSize(NSSize(width: 820, height: 580))
            window.minSize = NSSize(width: 720, height: 500)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        model.integrations.refresh()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MainView: View {
    let model: AppModel
    @Bindable var navigation: Navigation
    let close: () -> Void

    var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $navigation.screen) { screen in
                Label(screen.title, systemImage: screen.symbol).tag(screen)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            Group {
                switch navigation.screen {
                case .welcome: OnboardingView(model: model, finish: close)
                case .tools: ToolsView(model: model)
                case .character: CharacterPreviewView(model: model)
                case .history: HistoryView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            // minHeight 0: a screen can never force the split view taller than the window. If one did,
            // the sidebar and content would be centred far off screen and the window would look blank.
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// A black, notch-shaped card holding a character: the way it looks in the
/// notch, in light and dark appearance alike.
struct NotchCard<Content: View>: View {
    var height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 22,
                                              bottomTrailingRadius: 22, topTrailingRadius: 6, style: .continuous))
    }
}

/// A character showing one emotion's key pose without animating (thumbnails).
struct StillCharacter: NSViewRepresentable {
    let emotion: Emotion

    func makeNSView(context: Context) -> CharacterNSView {
        let view = CharacterNSView()
        view.rig.show(Pose.key(for: emotion), fade: 0)
        return view
    }

    func updateNSView(_ view: CharacterNSView, context: Context) {
        view.rig.show(Pose.key(for: emotion), fade: 0.15)
    }
}

/// "Open at login" that shows what macOS actually did: registration can
/// need approval in System Settings, or fail for an app outside Applications.
struct LoginItemToggle: View {
    @LocalState private var enabled = LoginItem.isEnabled
    @LocalState private var status = LoginItem.statusText
    @LocalState private var error: String?

    var body: some View {
        Toggle("Open at login", isOn: Binding(get: { enabled }, set: set))
            .onAppear(perform: reload)
        Text(error ?? "Status: \(status)").font(.caption).foregroundStyle(.secondary)
    }

    private func set(_ on: Bool) {
        do {
            try LoginItem.set(on)
            error = nil
        } catch {
            self.error = "Couldn't change it: \(error.localizedDescription)"
        }
        reload()
    }

    private func reload() {
        enabled = LoginItem.isEnabled
        status = LoginItem.statusText
    }
}

struct ScreenHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary)
        }
        .padding(.bottom, 6)
    }
}

/// SwiftUI's `@State` resolves to a macro whose plugin ships only with Xcode;
/// naming the property wrapper directly builds with the Command Line Tools too.
typealias LocalState<Value> = SwiftUI.State<Value>
