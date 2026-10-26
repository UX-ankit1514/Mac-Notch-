import AppKit

/// A borderless, non-activating overlay above the menu bar. It never takes
/// keyboard focus and lets clicks through everywhere except the live notch.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        setAccessibilityRole(.popover)
        setAccessibilityLabel("Notch Companion")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
