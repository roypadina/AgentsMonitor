import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import AgentsMonitorKit

// MARK: - About tab

enum AboutInfo {
    static let kofi = URL(string: "https://ko-fi.com/roypadina")!
    static let github = URL(string: "https://github.com/roypadina/AgentsMonitor")!
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    private static var window: NSWindow?

    /// Custom window (the standard panel's fixed-height credits box clipped the text).
    /// Shown through AccessoryWindows: an accessory (LSUIElement) app needs the Dock/menu-bar switch.
    @MainActor static func showWindow() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            w.title = "About Agents Monitor"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        if let window { AccessoryWindows.shared.show(window) }
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 2) {
                Text("Agents Monitor").font(.title.bold())
                Text("Version \(AboutInfo.version) (\(AboutInfo.build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                Text("Made by Roy Padina").font(.headline)
                Text("I'm a software engineer from Israel who builds small, focused Mac tools to fix the little annoyances in my own day — then shares them free and open source.")
                Text("If this app saves you time, a coffee on Ko-fi keeps the next one coming. ☕")
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Link(destination: AboutInfo.kofi) {
                    Text("Support on Ko-fi ☕").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Link(destination: AboutInfo.github) {
                    Text("GitHub").frame(minWidth: 70)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Link("Report an issue", destination: AboutInfo.github.appendingPathComponent("issues"))
                .font(.callout)

            Divider()

            VStack(spacing: 8) {
                Text("Have an idea, or want to help build it?").font(.headline)
                Text("Feature requests and pull requests are welcome. Ko-fi supporters go to the front of the queue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Link(destination: URL(string: "https://github.com/roypadina/AgentsMonitor/issues/new?template=feature_request.yml")!) {
                        Text("Request a feature").frame(minWidth: 120)
                    }
                    .buttonStyle(.bordered)

                    Link(destination: URL(string: "https://github.com/roypadina/AgentsMonitor/blob/main/CONTRIBUTING.md")!) {
                        Text("Contribute").frame(minWidth: 90)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text("© Roy Padina · MIT")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 380)
    }
}

/// Settings tab stays compact and defers to the About window.
struct AboutTab: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
            Text("Agents Monitor").font(.title2.bold())
            Text("Version \(AboutInfo.version)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("About Agents Monitor…") { AboutInfo.showWindow() }
                Button("Welcome Guide…") { WelcomeWindow.show() }
                Link("Support on Ko-fi ☕", destination: AboutInfo.kofi)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Accounts tab

@MainActor
struct AccountsTab: View {
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
                Menu {
                    Button("Claude Code Account…") { addClaudeAccount() }
                    Button("Codex Account…") { addCodexAccount() }
                    Button("Remote Claude Account…") { showAddRemote = true }
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .fixedSize()
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
                    ProviderBadge(provider: account.provider)
                    Text(isLocal(account) ? "Local" : "Remote")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("Rename") { beginRename(account) }
                        .controlSize(.mini)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove \(account.name)", systemImage: "trash", role: .destructive) { remove(account) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Remove account")
            }
            HStack(spacing: 12) {
                Toggle("Desktop", isOn: binding(for: account, \.desktopAlerts))
                    .toggleStyle(.checkbox)
                Toggle("ntfy", isOn: binding(for: account, \.ntfyEnabled))
                    .toggleStyle(.checkbox)
                Toggle("Menu bar", isOn: binding(for: account, \.showInMenuBar))
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

    /// Config dirs are dot-directories (`~/.claude`, `~/.claude-personal`, `~/.codex`): without
    /// `showsHiddenFiles` the panel hides them and there is nothing to select.
    private func pickConfigDir() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = "Add"
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func add(_ account: Account) {
        store.accounts.append(account)
        store.states[account.id] = .idle
        store.save()
        Task { await store.refresh() }
    }

    private func addCodexAccount() {
        guard let url = pickConfigDir() else { return }
        let path = url.path
        guard let email = codexAccountName(configDir: path) else {
            let alert = NSAlert()
            alert.messageText = "No Codex login found there"
            alert.informativeText = "That folder has no readable auth.json with a ChatGPT token — pick the directory Codex uses as CODEX_HOME, and run `codex login` in it first. An api-key-only login has no usage to report."
            alert.runModal()
            return
        }
        add(Account(name: email, kind: .local(configDirPath: path), provider: .codex))
    }

    /// nil when the directory has no usable Codex login.
    private func codexAccountName(configDir: String) -> String? {
        guard let account = AppStore.codexAccount(configDir: configDir) else { return nil }
        return account.name
    }

    private func addClaudeAccount() {
        guard let url = pickConfigDir() else { return }
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
        add(Account(name: name, kind: .local(configDirPath: path)))
    }
}

// MARK: - Alerts tab

@MainActor
struct AlertsTab: View {
    private let store = AppStore.shared
    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var ntfyToken = ""
    @State private var ntfyFallbackURL = ""

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
                SecureField("Access token (optional)", text: $ntfyToken)
                    .onSubmit(saveNtfySecrets)
                SecureField("Fallback topic URL (optional)", text: $ntfyFallbackURL)
                    .onSubmit(saveNtfySecrets)
                Text("Token and fallback URL are stored in the macOS Keychain. The token is sent only to the server above. The fallback URL (for example a public ntfy.sh topic) is used when the server does not answer or returns an error.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Text("Authorization: \(authStatusText)")
                    .foregroundStyle(authStatus == .denied ? .red : .secondary)
                Button("Send Test Alert") { sendTestAlert() }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshAuthStatus()
            ntfyToken = Ntfy.secret(.token) ?? ""
            ntfyFallbackURL = Ntfy.secret(.fallbackURL) ?? ""
        }
        .onDisappear(perform: saveNtfySecrets)
        // The Settings window is released on close and closing fires no onDisappear: save then too (SET-4).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if (note.object as? NSWindow)?.contentViewController is SettingsTabs { saveNtfySecrets() }
        }
    }

    private func saveNtfySecrets() {
        Ntfy.setSecret(.token, ntfyToken)
        Ntfy.setSecret(.fallbackURL, ntfyFallbackURL)
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

    // Qualified: AgentsMonitorKit also exports a `Settings` type; SwiftUI has its own Settings scene.
    private func bindingString(_ keyPath: WritableKeyPath<AgentsMonitorKit.Settings, String>) -> Binding<String> {
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
        saveNtfySecrets()
        let alert = AgentsMonitorKit.Alert(
            accountId: UUID(), accountName: "Test", key: "test",
            title: "Agents Monitor test alert",
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
struct GeneralTab: View {
    private let store = AppStore.shared

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

            LaunchAtLoginToggle()

            Section("Accounts") {
                Picker("Provider badge", selection: badgeBinding) {
                    ForEach(ProviderBadgeStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                Toggle("Color-code by provider", isOn: bindingBool(\.providerColors))
                    .disabled(store.settings.providerBadge == .hidden)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        ForEach(Provider.allCases, id: \.self) { provider in
                            ProviderBadge(provider: provider,
                                          style: store.settings.providerBadge == .hidden ? .iconAndName : store.settings.providerBadge,
                                          colored: store.settings.providerColors)
                        }
                    }
                    Text("Shown next to every account name, here and in the popover. The color also runs down the edge of each card. Limit bars and the usage dot stay severity-colored — rename an account from the Accounts tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Menu bar") {
                Toggle("Show percent", isOn: bindingBool(\.showPercentInMenuBar))
                Picker("Value", selection: metricBinding) {
                    ForEach(MenuBarMetric.allCases, id: \.self) { metric in
                        Text(metric.label).tag(metric)
                    }
                }
                .disabled(!store.settings.showPercentInMenuBar)
                Toggle("Also show per-model window", isOn: bindingBool(\.menuBarShowModelScoped))
                    .disabled(store.settings.menuBarMetric == .modelScoped)
                Toggle("Also show extra usage spent", isOn: bindingBool(\.menuBarShowSpend))
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Usage dot", isOn: bindingBool(\.menuBarBlockedDot))
                    HStack(spacing: 5) {
                        ForEach([0, 25, 50, 75, 100], id: \.self) { percent in
                            HStack(spacing: 2) {
                                Image(nsImage: UsageDot.composite(percents: [percent], diameter: 9))
                                Text("\(percent)%")
                            }
                        }
                    }
                    .font(.caption2)
                    Text("Green through red by session/weekly usage — per-model windows are excluded, since a maxed-out model still leaves the others usable. Turn off \"Show percent\" for a dots-only menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.menuBarText.isEmpty ? "Preview: (hidden)" : "Preview: \(store.menuBarText)")
                    Text("Choose which accounts appear with the Menu bar checkbox in the Accounts tab.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Toggle("Toast notifications", isOn: bindingBool(\.toastEnabled))
            Toggle("Sound", isOn: bindingBool(\.soundEnabled))
        }
        .formStyle(.grouped)
    }

    private var badgeBinding: Binding<ProviderBadgeStyle> {
        Binding(
            get: { store.settings.providerBadge },
            set: { store.settings.providerBadge = $0; store.save() }
        )
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

    private var metricBinding: Binding<MenuBarMetric> {
        Binding(
            get: { store.settings.menuBarMetric },
            set: { store.settings.menuBarMetric = $0; store.save() }
        )
    }

    private func bindingBool(_ keyPath: WritableKeyPath<AgentsMonitorKit.Settings, Bool>) -> Binding<Bool> {
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
                .textSelection(.enabled)
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
    case register         // was on, registration lost — register again
    case reRegisterMoved  // bundle moved (or registration lost) — re-register
}

/// Wraps the "open at login" login-item registration. Self-heals: re-registers
/// automatically when the app bundle moves or the registration is lost. Never turns
/// it on by itself — LaunchAtLoginToggle (Welcome, Settings > General) is the opt-in.
enum LoginItem {

    private static let pathKey = "registeredBundlePath"

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Pure decision (unit-tested in LanGuard's original). A `nil` stored path while already
    /// enabled means "first time we're recording it" -> no re-register. A `nil` stored path
    /// while not registered means the user never turned it on, or turned it off -> leave it off.
    static func decide(status: SMAppService.Status, storedPath: String?, currentPath: String) -> LoginRegisterDecision {
        switch status {
        case .notRegistered:
            return storedPath != nil ? .register : .none
        case .notFound:
            return storedPath != nil ? .reRegisterMoved : .none
        case .enabled, .requiresApproval:
            return (storedPath == currentPath || storedPath == nil) ? .none : .reRegisterMoved
        @unknown default:
            return .none
        }
    }

    /// Ensure an item the user turned on is registered for the CURRENT bundle path. Called on
    /// every launch — re-registers if the app moved or the registration was lost; does nothing
    /// for an item that is off.
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
                NSLog("AgentsMonitor: login item register failed: \(error)")
            }
            return decision
        }
    }

    /// From the Open at Login toggle.
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
            NSLog("AgentsMonitor: login item \(enabled ? "register" : "unregister") failed: \(error)")
            return false
        }
    }
}
