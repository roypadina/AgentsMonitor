import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import ClaudeMonitorKit

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsTab()
                .tabItem { Label("Accounts", systemImage: "person.2") }
            AlertsTab()
                .tabItem { Label("Alerts", systemImage: "bell") }
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460, height: 420)
    }
}

// MARK: - Accounts tab

@MainActor
private struct AccountsTab: View {
    private let store = AppStore.shared
    @State private var showAddRemote = false
    @State private var repasteAccount: Account?
    @State private var renameId: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List {
                ForEach(store.accounts) { account in
                    accountRow(account)
                }
            }
            .listStyle(.inset)

            HStack {
                Button("Add Local Account…") { addLocalAccount() }
                Button("Add Remote Account…") { showAddRemote = true }
                Spacer()
            }
        }
        .padding()
        .sheet(isPresented: $showAddRemote) {
            RemoteCredentialsSheet(mode: .add, credentialStore: credentialStore)
        }
        .sheet(item: $repasteAccount) { account in
            RemoteCredentialsSheet(
                mode: .repaste(accountId: account.id, accountName: account.name),
                credentialStore: credentialStore
            )
        }
    }

    @ViewBuilder
    private func accountRow(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if renameId == account.id {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename(account) }
                    Button("Save") { commitRename(account) }.controlSize(.small)
                } else {
                    Text(account.name)
                    Text(isLocal(account) ? "Local" : "Remote")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("Rename") { beginRename(account) }
                        .controlSize(.mini)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) { remove(account) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                Toggle("Desktop", isOn: binding(for: account, \.desktopAlerts))
                    .toggleStyle(.checkbox)
                Toggle("ntfy", isOn: binding(for: account, \.ntfyEnabled))
                    .toggleStyle(.checkbox)
                TextField("topic override", text: bindingOptional(for: account, \.ntfyTopicOverride))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                if case .remote = account.kind {
                    Button("Repaste…") { repasteAccount = account }.controlSize(.small)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func isLocal(_ account: Account) -> Bool {
        if case .local = account.kind { return true }
        return false
    }

    private func binding(for account: Account, _ keyPath: WritableKeyPath<Account, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.accounts.first(where: { $0.id == account.id })?[keyPath: keyPath] ?? false },
            set: { newValue in
                guard let idx = store.accounts.firstIndex(where: { $0.id == account.id }) else { return }
                store.accounts[idx][keyPath: keyPath] = newValue
                store.save()
            }
        )
    }

    private func bindingOptional(for account: Account, _ keyPath: WritableKeyPath<Account, String?>) -> Binding<String> {
        Binding(
            get: { store.accounts.first(where: { $0.id == account.id })?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let idx = store.accounts.firstIndex(where: { $0.id == account.id }) else { return }
                store.accounts[idx][keyPath: keyPath] = newValue.isEmpty ? nil : newValue
                store.save()
            }
        )
    }

    private func beginRename(_ account: Account) {
        renameId = account.id
        renameText = account.name
    }

    private func commitRename(_ account: Account) {
        if let idx = store.accounts.firstIndex(where: { $0.id == account.id }) {
            store.accounts[idx].name = renameText
            store.save()
        }
        renameId = nil
    }

    private func remove(_ account: Account) {
        store.accounts.removeAll { $0.id == account.id }
        store.states[account.id] = nil
        store.save()
    }

    private func addLocalAccount() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let path = url.path
        let service = KeychainService.serviceName(forConfigDir: path)
        guard KeychainService.discoverClaudeServices().contains(service) else {
            let alert = NSAlert()
            alert.messageText = "No Claude Code credentials found there"
            alert.informativeText = "That folder doesn't have a matching keychain entry — pick the directory Claude Code uses as CLAUDE_CONFIG_DIR."
            alert.runModal()
            return
        }

        let labels = KeychainService.discoverLabels()
        let name = labels[service]?.email ?? url.lastPathComponent
        let account = Account(name: name, kind: .local(configDirPath: path))
        store.accounts.append(account)
        store.states[account.id] = .idle
        store.save()
        Task { await store.refresh() }
    }
}

// MARK: - Alerts tab

@MainActor
private struct AlertsTab: View {
    private let store = AppStore.shared
    @State private var authStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section("Thresholds") {
                Stepper("Warning: \(store.settings.thresholds.warning)%", value: warningBinding, in: 1...99)
                Stepper("Critical: \(store.settings.thresholds.critical)%", value: criticalBinding, in: 1...100)
            }
            Section("Extra usage") {
                Toggle("Notify when extra usage starts", isOn: extraUsageBinding)
                Text("Alerts the moment paid usage starts being consumed, then stays quiet until spending pauses for 30 minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("ntfy") {
                TextField("Server", text: bindingString(\.ntfyServer))
                TextField("Default topic", text: bindingString(\.ntfyDefaultTopic))
            }
            Section("Notifications") {
                Text("Authorization: \(authStatusText)")
                    .foregroundStyle(authStatus == .denied ? .red : .secondary)
                Button("Send Test Alert") { sendTestAlert() }
            }
        }
        .padding()
        .onAppear { refreshAuthStatus() }
    }

    private var extraUsageBinding: Binding<Bool> {
        Binding(
            get: { store.settings.extraUsageAlerts },
            set: { store.settings.extraUsageAlerts = $0; store.save() }
        )
    }

    private var warningBinding: Binding<Int> {
        Binding(
            get: { store.settings.thresholds.warning },
            set: { newValue in
                store.settings.thresholds.warning = min(newValue, store.settings.thresholds.critical - 1)
                store.save()
            }
        )
    }

    private var criticalBinding: Binding<Int> {
        Binding(
            get: { store.settings.thresholds.critical },
            set: { newValue in
                store.settings.thresholds.critical = max(newValue, store.settings.thresholds.warning + 1)
                store.save()
            }
        )
    }

    // Qualified: ClaudeMonitorKit also exports a `Settings` type; SwiftUI has its own Settings scene.
    private func bindingString(_ keyPath: WritableKeyPath<ClaudeMonitorKit.Settings, String>) -> Binding<String> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.settings[keyPath: keyPath] = $0; store.save() }
        )
    }

    private var authStatusText: String {
        switch authStatus {
        case .authorized: return "Authorized"
        case .denied: return "Denied — enable in System Settings > Notifications"
        case .notDetermined: return "Not determined"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown"
        }
    }

    private func refreshAuthStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in authStatus = settings.authorizationStatus }
        }
    }

    private func sendTestAlert() {
        let alert = ClaudeMonitorKit.Alert(
            accountId: UUID(), accountName: "Test", key: "test",
            title: "Claude Monitor test alert",
            body: "This is a test — desktop, ntfy, and toast sinks are wired correctly.",
            level: .warning
        )
        var testAccount = Account(name: "Test", kind: .remote)
        testAccount.desktopAlerts = true
        testAccount.ntfyEnabled = !store.settings.ntfyDefaultTopic.isEmpty
        Notifier.deliver([alert], account: testAccount)
    }
}

// MARK: - General tab

@MainActor
private struct GeneralTab: View {
    private let store = AppStore.shared
    @State private var loginOn = LoginItem.isEnabled

    private static let pollOptions: [(String, Int)] = [
        ("30s", 30), ("1m", 60), ("3m", 180), ("5m", 300), ("10m", 600),
    ]

    var body: some View {
        Form {
            Picker("Poll interval", selection: pollBinding) {
                ForEach(Self.pollOptions, id: \.1) { label, seconds in
                    Text(label).tag(seconds)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Start at login", isOn: $loginOn)
                    .onChange(of: loginOn) { _, newValue in
                        LoginItem.setEnabled(newValue)
                        if newValue { LoginItem.promptForApprovalIfNeeded() }
                        loginOn = LoginItem.isEnabled
                    }
                Text("Login item: \(LoginItem.statusDescription)")
                    .font(.caption)
                    .foregroundStyle(LoginItem.status == .requiresApproval ? Color.orange : .secondary)
            }

            Toggle("Show percent in menu bar", isOn: bindingBool(\.showPercentInMenuBar))
            Toggle("Toast notifications", isOn: bindingBool(\.toastEnabled))
            Toggle("Sound", isOn: bindingBool(\.soundEnabled))
        }
        .padding()
        .onAppear { loginOn = LoginItem.isEnabled }
    }

    private var pollBinding: Binding<Int> {
        Binding(
            get: { store.settings.pollSeconds },
            set: { newValue in
                store.settings.pollSeconds = min(max(newValue, 30), 600)
                store.save()
                store.startPolling() // restart the sleep loop so the new interval takes effect now
            }
        )
    }

    private func bindingBool(_ keyPath: WritableKeyPath<ClaudeMonitorKit.Settings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.settings[keyPath: keyPath] = $0; store.save() }
        )
    }
}

// MARK: - Remote credentials sheet (Add Remote Account + repaste-on-expiry)

private let credentialStore = CredentialStore()

@MainActor
struct RemoteCredentialsSheet: View {
    enum Mode {
        case add
        case repaste(accountId: UUID, accountName: String)
    }

    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let credentialStore: CredentialStore
    @State private var pasted = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $pasted)
                .font(.system(.body, design: .monospaced))
                .frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pasted.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var title: String {
        switch mode {
        case .add: return "Add Remote Account"
        case .repaste(_, let name): return "Paste fresh credentials — \(name)"
        }
    }

    private var hint: String {
        "Paste the credentials JSON from the source machine.\n"
        + "macOS: security find-generic-password -s \"Claude Code-credentials\" -w\n"
        + "Linux: cat ~/.claude/.credentials.json"
    }

    private func save() {
        guard let data = pasted.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              oauth["accessToken"] is String else {
            errorMessage = "That doesn't look like Claude Code credentials JSON (missing claudeAiOauth.accessToken)."
            return
        }

        let accountId: UUID
        switch mode {
        case .add: accountId = UUID()
        case .repaste(let id, _): accountId = id
        }

        Task {
            do {
                try await credentialStore.storeRemoteCredentials(data, accountId: accountId)
                await applySaved(accountId: accountId)
            } catch {
                await MainActor.run { errorMessage = "Save failed: \(error)" }
            }
        }
    }

    @MainActor
    private func applySaved(accountId: UUID) async {
        let store = AppStore.shared
        if case .add = mode {
            let account = Account(id: accountId, name: "Remote Account", kind: .remote)
            store.accounts.append(account)
            store.states[account.id] = .idle
        }
        store.save()
        pasted = ""
        dismiss()
        await store.refresh()
    }
}

// MARK: - LoginItem (adapted from LanGuard-app's LanGuardFeature/LoginItem.swift, MIT-house style)

/// What registration action a launch needs, given current state.
enum LoginRegisterDecision: Equatable {
    case none             // already registered for this path — nothing to do
    case register         // not registered yet — register now
    case reRegisterMoved  // registration lost or bundle moved — re-register
}

/// Wraps the "start at login" login-item registration. Self-heals: re-registers
/// automatically when the app bundle moves or the registration is lost, and
/// prompts the user when macOS needs their approval.
enum LoginItem {

    private static let pathKey = "registeredBundlePath"

    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static var statusDescription: String {
        switch status {
        case .enabled:          return "Enabled"
        case .requiresApproval: return "Needs your approval in System Settings"
        case .notRegistered:    return "Not registered"
        case .notFound:         return "App not found — will re-register"
        @unknown default:       return "Unknown"
        }
    }

    /// Pure decision (unit-tested in LanGuard's original). A `nil` stored path while already
    /// enabled means "first time we're recording it" -> no re-register.
    static func decide(status: SMAppService.Status, storedPath: String?, currentPath: String) -> LoginRegisterDecision {
        switch status {
        case .notRegistered:
            return .register
        case .notFound:
            return .reRegisterMoved
        case .enabled, .requiresApproval:
            return (storedPath == currentPath || storedPath == nil) ? .none : .reRegisterMoved
        @unknown default:
            return .none
        }
    }

    /// Ensure the login item is registered for the CURRENT bundle path. Called on every
    /// launch — auto-registers on first run, re-registers if the app moved or the
    /// registration was lost.
    @discardableResult
    static func ensureRegistered() -> LoginRegisterDecision {
        let current = Bundle.main.bundlePath
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: pathKey)
        let decision = decide(status: status, storedPath: stored, currentPath: current)

        switch decision {
        case .none:
            if status == .enabled, stored != current {
                defaults.set(current, forKey: pathKey)
            }
            return .none

        case .register, .reRegisterMoved:
            if decision == .reRegisterMoved {
                try? SMAppService.mainApp.unregister()
            }
            do {
                try SMAppService.mainApp.register()
                defaults.set(current, forKey: pathKey)
            } catch {
                NSLog("ClaudeMonitor: login item register failed: \(error)")
            }
            return decision
        }
    }

    /// Manual toggle from Settings.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let defaults = UserDefaults.standard
        do {
            if enabled {
                try SMAppService.mainApp.register()
                defaults.set(Bundle.main.bundlePath, forKey: pathKey)
            } else {
                try SMAppService.mainApp.unregister()
                defaults.removeObject(forKey: pathKey)
            }
            return true
        } catch {
            NSLog("ClaudeMonitor: login item \(enabled ? "register" : "unregister") failed: \(error)")
            return false
        }
    }

    /// If macOS requires the user to approve the login item, prompt + open Settings.
    static func promptForApprovalIfNeeded() {
        guard status == .requiresApproval else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude Monitor needs approval to start at login"
        alert.informativeText = "macOS disabled Claude Monitor's login item. Open Login Items settings and switch it back on so it launches automatically."
        alert.addButton(withTitle: "Open Login Items Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
