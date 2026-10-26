import AppKit
import Carbon.HIToolbox
import Intents
import Observation
import ServiceManagement

/// Launch at login through SMAppService (PRD FR-01).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "On"
        case .requiresApproval: "Waiting for approval in System Settings → General → Login Items"
        case .notRegistered: "Off"
        case .notFound: "Unavailable (move the app to Applications first)"
        @unknown default: "Unknown"
        }
    }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Reads the system Focus state when macOS grants it. Focus status needs the
/// Communication Notifications capability, which an ad-hoc signed build can't
/// carry, so this reports itself unavailable rather than guessing.
@Observable
final class FocusObserver {
    private(set) var isFocused = false
    private(set) var availability = "Checking…"

    init() {
        refresh()
    }

    func refresh() {
        let center = INFocusStatusCenter.default
        switch center.authorizationStatus {
        case .authorized:
            isFocused = center.focusStatus.isFocused ?? false
            availability = "Available"
        case .notDetermined:
            availability = "Not requested"
        default:
            isFocused = false
            availability = "Unavailable in this build — use Quiet Mode or Quiet Hours"
        }
    }

    func request() {
        INFocusStatusCenter.default.requestAuthorization { _ in
            Task { @MainActor in self.refresh() }
        }
    }
}

/// A global shortcut (⌃⌥N) that opens the pending list from the keyboard.
/// Carbon hot keys need no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var action: (@MainActor () -> Void)?

    func register(_ action: @escaping @MainActor () -> Void) {
        unregister()
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4E434F4D), id: 1)  // 'NCOM'
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }
}
