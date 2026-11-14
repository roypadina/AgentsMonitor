import AppKit
import AgentsMonitorKit

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
        @discardableResult func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            m.addItem(i)
            return i
        }
        if SupportPrompt.shared.showing {  // the receipt card is mouse-only; same three answers here
            m.addItem(.sectionHeader(title: "Support Agents Monitor"))
            for (tag, title) in ["Tip a Coffee on Ko-fi ☕", "Ask Me in 2 Weeks", "Don't Ask Again"].enumerated() {
                item(title, #selector(answerSupport(_:))).tag = tag  // index into supportAnswers
            }
            m.addItem(.separator())
        }
        item(Updates.menuTitle, #selector(update))
        m.addItem(.separator())
        item("Settings…", #selector(settings), key: ",")
        item("About Agents Monitor", #selector(about))
        item("Support on Ko-fi ☕", #selector(kofi)).keyEquivalentModifierMask = []  // no modifier, so ⌥ swaps in the alternate below
        let preview = item("Show Support Prompt Now", #selector(previewSupport))  // hold ⌥; never recorded
        preview.keyEquivalentModifierMask = .option
        preview.isAlternate = true
        m.addItem(.separator())
        item("Quit Agents Monitor", #selector(quit), key: "q")
        return m
    }

    @objc private func update() { Updates.check() }
    @objc private func settings() { SettingsWindow.shared.show() }
    @objc private func about() { AboutInfo.showWindow() }
    @objc private func kofi() { SupportPrompt.shared.openKofi() }
    @objc private func previewSupport() { SupportPrompt.shared.present(record: false) }
    private static let supportAnswers: [SupportPromptState.Answer] = [.support, .snooze, .never]
    @objc private func answerSupport(_ sender: NSMenuItem) { SupportPrompt.shared.answerFromMenu(Self.supportAnswers[sender.tag]) }
    @objc private func quit() { NSApp.terminate(nil) }
}
