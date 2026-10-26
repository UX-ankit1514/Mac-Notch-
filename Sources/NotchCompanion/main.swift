import AppKit

// Notch Companion runs as a menu-bar app (LSUIElement) with no Dock icon.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
