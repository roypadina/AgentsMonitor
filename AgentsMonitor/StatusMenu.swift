import AppKit

/// Right-click / control-click menu on the menu-bar icon. SwiftUI's MenuBarExtra has no hook for it,
/// so a local event monitor catches the click on the status-bar window, swallows it and pops an NSMenu.
/// Left-click still opens the popover.
@MainActor final class StatusMenu: NSObject {
    static let shared = StatusMenu()
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  let window = event.window, let view = window.contentView,
                  String(describing: type(of: window)).contains("NSStatusBarWindow") else { return event }
            NSMenu.popUpContextMenu(self?.menu() ?? NSMenu(), with: event, for: view)
            return nil
        }
    }

    /// Built fresh on every click so the update item is current.
    func menu() -> NSMenu {
        let m = NSMenu()
        func item(_ title: String, _ action: Selector, key: String = "") {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            m.addItem(i)
        }
        item(Updates.menuTitle, #selector(update))
        m.addItem(.separator())
        item("Settings…", #selector(settings), key: ",")
        item("About Agents Monitor", #selector(about))
        item("Support on Ko-fi ☕", #selector(kofi))
        m.addItem(.separator())
        item("Quit Agents Monitor", #selector(quit), key: "q")
        return m
    }

    @objc private func update() { Updates.check() }
    @objc private func settings() { SettingsWindow.shared.show() }
    @objc private func about() { AboutInfo.showWindow() }
    @objc private func kofi() { NSWorkspace.shared.open(AboutInfo.kofi) }
    @objc private func quit() { NSApp.terminate(nil) }
}
