import AppKit
import NotchCore
import Observation

/// The menu-bar item: pending requests, quick toggles, and the app's screens.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let windows: WindowController

    init(model: AppModel, windows: WindowController) {
        self.model = model
        self.windows = windows
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        updateButton()
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = model.pending
            _ = model.settings.quietMode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateButton()
                self?.observe()
            }
        }
    }

    private func updateButton() {
        let count = model.pending.count
        let symbol = model.settings.quietMode ? "eyes.inverse" : "eyes"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Notch Companion")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.title = count > 0 ? " \(count)" : ""
        item.button?.setAccessibilityLabel(count > 0 ? "Notch Companion, \(count) waiting" : "Notch Companion")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let pending = model.pending
        if pending.isEmpty {
            menu.addItem(disabled("No agents waiting"))
        } else {
            menu.addItem(disabled(pending.count == 1 ? "1 request waiting" : "\(pending.count) requests waiting"))
            for record in pending.prefix(8) {
                let title = "\(AlertCopy.title(for: record.event)) — \(record.event.project ?? record.event.agent.displayName)"
                let entry = NSMenuItem(title: title, action: #selector(openRecord(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = record.id
                entry.image = NSImage(systemSymbolName: record.event.type.symbol, accessibilityDescription: nil)
                menu.addItem(entry)
            }
            menu.addItem(action("Show in Notch", #selector(showPending), key: "n", modifiers: [.control, .option]))
            menu.addItem(action("Dismiss All", #selector(dismissAll)))
        }
        menu.addItem(.separator())
        let quiet = action("Quiet Mode", #selector(toggleQuiet))
        quiet.state = model.settings.quietMode ? .on : .off
        menu.addItem(quiet)
        menu.addItem(.separator())
        menu.addItem(action("Connect Tools…", #selector(showTools)))
        menu.addItem(action("Character Preview…", #selector(showCharacter)))
        menu.addItem(action("Notification History…", #selector(showHistory)))
        menu.addItem(action("Settings…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("Quit Notch Companion", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "",
                        modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    @objc private func openRecord(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let record = model.pending.first(where: { $0.id == id }) else { return }
        model.open(record)
    }

    @objc private func showPending() { model.showPendingList() }
    @objc private func dismissAll() { model.dismissAll() }
    @objc private func toggleQuiet() { model.settings.quietMode.toggle() }
    @objc private func showTools() { windows.show(.tools) }
    @objc private func showCharacter() { windows.show(.character) }
    @objc private func showHistory() { windows.show(.history) }
    @objc private func showSettings() { windows.show(.settings) }
    @objc private func quit() { NSApp.terminate(nil) }
}
