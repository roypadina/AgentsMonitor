import ServiceManagement
import SwiftUI

/// First-launch welcome (MBX-18): why the app exists, where the icon is, how to get back in without
/// the icon (MBX-8) and the login item (MBX-17). Shown once from AppDelegate; "Welcome Guide…" in
/// Settings > About reopens it.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView(
                // Settings first, so closing Welcome doesn't flip the Dock icon off and on.
                onOpenSettings: { SettingsWindow.shared.show(); window?.close() },
                onDone: { window?.close() })))
            w.title = "Welcome"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            // Release the window on close, as the Settings window does.
            Task { @MainActor in
                for await _ in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification, object: w) { break }
                window = nil
            }
        }
        if let window { AccessoryWindows.shared.show(window) }
    }
}

struct WelcomeView: View {
    let onOpenSettings: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Agents Monitor").font(.title2.bold())
                    Text("Claude Code and Codex stop mid-task when a session or weekly limit runs out. Agents Monitor shows how much of each limit your accounts have used and warns you before that happens.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            row("menubar.rectangle", "Agents Monitor lives in the menu bar.",
                "The dots and numbers show each account's usage. Click them for limit bars, reset times and graphs, and for Settings.")
            row("bell.badge", "It warns you before a limit runs out.",
                "At 80% and again at 95% (change both in Settings > Alerts): a notification, an on-screen toast with sound, or an ntfy push to your phone.")
            row("person.2", "Your accounts are found for you.",
                "Claude Code and Codex logins on this Mac are added automatically and read only to ask each provider for your usage. Add more in Settings > Accounts.")
            row("questionmark.circle", "Icon missing?",
                "Open Agents Monitor again from Applications to get Settings, or check System Settings > Menu Bar.")
            LaunchAtLoginToggle()
            SupportBox()
            HStack {
                Button("Open Settings", action: onOpenSettings)
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SupportBox: View {
    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free and open source").font(.headline)
                    Text("If Agents Monitor saves you time, a coffee on Ko-fi keeps the next one coming.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Link("Support on Ko-fi ☕", destination: AboutInfo.kofi).buttonStyle(.bordered)
            }
            .padding(4)
        }
    }
}

/// Settings > General and the welcome window (MBX-17): the only opt-in, status re-read on activation.
/// Goes through `LoginItem` so `registeredBundlePath` stays in step with the launch-time self-heal.
struct LaunchAtLoginToggle: View {
    @State private var status = LoginItem.status

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at Login", isOn: Binding(
                get: { status == .enabled },
                set: { on in
                    LoginItem.setEnabled(on)
                    status = LoginItem.status
                }))
            if status == .requiresApproval {
                Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            } else if status == .notFound {
                Text("Move Agents Monitor to Applications to open it at login.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = LoginItem.status  // the user may change it in System Settings
        }
    }
}
