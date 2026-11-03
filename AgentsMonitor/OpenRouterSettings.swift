import SwiftUI
import AgentsMonitorKit

// MARK: - OpenRouter tab (design §4.3)

/// Management key, keys (rename, placement, order, remove), spend alert rules, delivery. Changes apply at once (SET-4).
@MainActor
struct OpenRouterTab: View {
    private let store = AppStore.shared
    @State private var managementKey = ""
    @State private var connecting = false
    @State private var connectError: String?
    @State private var confirmDisconnect = false
    @State private var removingKey: OpenRouterKeyConfig?
    @State private var renameId: String?
    @State private var renameText = ""
    @State private var sheet: Sheet?

    private enum Sheet: Identifiable {
        case addKey
        case rule(SpendRule, isNew: Bool)
        var id: String {
            switch self {
            case .addKey: return "add-key"
            case .rule(let rule, _): return rule.id.uuidString
            }
        }
    }

    var body: some View {
        Form {
            managementSection
            keysSection
            rulesSection
        }
        .formStyle(.grouped)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .addKey: AddOpenRouterKeySheet()
            case .rule(let rule, let isNew): SpendRuleSheet(rule: rule, isNew: isNew)
            }
        }
        // Rare and irreversible: the app cannot give a deleted secret back (UND-1).
        .confirmationDialog("Remove the management key?", isPresented: $confirmDisconnect) {
            Button("Remove") { store.disconnectManagementKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is deleted from the Keychain, and the keys it listed leave the app. Pasted keys stay.")
        }
        .confirmationDialog("Remove \(removingKey?.displayName ?? "key")?",
                            isPresented: Binding(get: { removingKey != nil }, set: { if !$0 { removingKey = nil } }),
                            presenting: removingKey) { key in
            Button("Remove") { store.removeKey(id: key.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The key is deleted from the Keychain. To monitor it again, paste it again.")
        }
    }

    // MARK: Management key

    private var managementSection: some View {
        Section {
            HStack {
                SecureField("Management key", text: $managementKey, prompt: Text("sk-or-v1-…"))
                    .onSubmit(connect)
                    .disabled(connecting)
                if connecting { SwiftUI.ProgressView().controlSize(.small) }
                Button("Connect", action: connect)
                    .disabled(connecting || managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let connectError { InlineError(text: connectError) }
            LabeledContent("Status") {
                HStack {
                    if let problem = managementProblem {
                        Image(systemName: "xmark.octagon").foregroundStyle(.red).accessibilityHidden(true)
                        Text(problem).lineLimit(2)
                    } else {
                        Text(status).monospacedDigit()
                    }
                    if store.settings.openRouter.managementKeyConfigured {
                        Button("Remove…") { confirmDisconnect = true }.controlSize(.small)
                    }
                }
            }
        } header: {
            Text("Management Key")
        } footer: {
            Text("Lists every key in your workspace and the credit balance. Create one on openrouter.ai under Keys → Management keys. Kept in the Keychain; sent only to openrouter.ai.")
                .formFooter()
        }
    }

    private var status: String {
        guard store.settings.openRouter.managementKeyConfigured else { return "Not connected" }
        let count = store.openRouterKeys.filter { $0.source == .managed }.count
        var parts = ["Connected", count == 1 ? "1 key" : "\(count) keys"]
        if let balance = store.openRouterSnapshot?.balance { parts.append("balance \(OpenRouter.formatUSD(balance.usd))") }
        if case .idle = store.openRouterState { parts.append("checking…") }
        return parts.joined(separator: " · ")
    }

    /// The management key's own failure from the last poll (expired, not a management key, offline).
    private var managementProblem: String? {
        guard store.settings.openRouter.managementKeyConfigured else { return nil }
        switch store.openRouterState {
        case .failed(let message): return message
        case .ok(let snapshot), .stale(let snapshot, _): return snapshot.managementError
        case .idle: return nil
        }
    }

    private func connect() {
        let key = managementKey
        guard !connecting, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        connecting = true
        connectError = nil
        Task {
            do {
                try await store.connectManagementKey(key)
                managementKey = ""
            } catch {
                connectError = error.localizedDescription
            }
            connecting = false
        }
    }

    // MARK: Keys

    private var keysSection: some View {
        Section {
            if store.openRouterKeys.isEmpty {
                Text("No keys yet. Connect a management key above, or add a key.")
                    .foregroundStyle(.secondary)
            } else {
                // Rows sit straight in the Form so the pane scrolls; a nested List never got scroll events.
                ForEach(store.openRouterKeys) { keyRow($0) }
                    .onMove { store.moveKeys(fromOffsets: $0, toOffset: $1) }
            }
            HStack {
                Button("Add Key…") { sheet = .addKey }
                Spacer()
                // Labels hidden + own Text: a labelled Picker in a Form row squeezes the button next to it.
                Text("Balance")
                    .foregroundStyle(store.settings.openRouter.managementKeyConfigured ? .primary : .secondary)
                Picker("Balance", selection: balancePlacement) {
                    ForEach(Placement.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(!store.settings.openRouter.managementKeyConfigured)
            }
        } header: {
            Text("Keys")
        } footer: {
            Text("Drag or right-click a key to reorder; this is the popover order. A key in the popover is also on the More page. Balance in Popover or More Page shows in the OpenRouter summary on both pages; Menu Bar and Popover adds the menu bar. The balance needs a management key.")
                .formFooter()
        }
    }

    private func keyRow(_ config: OpenRouterKeyConfig) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            if renameId == config.id {
                TextField("Name", text: $renameText, prompt: Text(config.lastName ?? config.lastLabel ?? "Name"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(config) }
                Button("Save") { commitRename(config) }
            } else {
                Button(config.displayName) {
                    renameId = config.id
                    renameText = config.nickname ?? ""
                }
                .buttonStyle(.plain)
                .lineLimit(1)
                .help("Rename \(config.displayName)")
                if let label = OpenRouterKeyRow.maskedLabel(config.lastLabel, displayName: config.displayName) {
                    Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(label)
                }
                Text(config.source == .managed ? "Managed" : "Pasted")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Picker("Placement for \(config.displayName)", selection: Binding(
                get: { store.openRouterKeys.first { $0.id == config.id }?.placement ?? config.placement },
                set: { store.setPlacement($0, forKey: config.id) })) {
                ForEach(Placement.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            if config.source == .pasted {
                Button("Remove \(config.displayName)", systemImage: "trash") { removingKey = config }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Remove key")
            }
        }
        .controlSize(.small)
        .contextMenu { moveMenu(config) }
    }

    /// Keyboard and VoiceOver path for reordering, and the fallback when drag is not available.
    @ViewBuilder
    private func moveMenu(_ config: OpenRouterKeyConfig) -> some View {
        if let i = store.openRouterKeys.firstIndex(where: { $0.id == config.id }) {
            let last = store.openRouterKeys.count - 1
            Button("Move to Top") { store.moveKeys(fromOffsets: IndexSet(integer: i), toOffset: 0) }.disabled(i == 0)
            Button("Move Up") { store.moveKeys(fromOffsets: IndexSet(integer: i), toOffset: i - 1) }.disabled(i == 0)
            Button("Move Down") { store.moveKeys(fromOffsets: IndexSet(integer: i), toOffset: i + 2) }.disabled(i == last)
        }
    }

    /// Empty clears the nickname (back to OpenRouter's name or the masked label).
    private func commitRename(_ config: OpenRouterKeyConfig) {
        store.setNickname(renameText, forKey: config.id)
        renameId = nil
    }

    private var balancePlacement: Binding<Placement> {
        Binding(get: { store.settings.openRouter.balancePlacement },
                set: { store.settings.openRouter.balancePlacement = $0; store.save() })
    }

    // MARK: Spend alerts

    private var rulesSection: some View {
        Section {
            if store.spendRules.isEmpty {
                Text("No rules yet.").foregroundStyle(.secondary)
            }
            ForEach(store.spendRules) { rule in
                HStack {
                    Toggle(isOn: Binding(
                        get: { store.spendRules.first { $0.id == rule.id }?.enabled ?? false },
                        set: { enabled in
                            guard let index = store.spendRules.firstIndex(where: { $0.id == rule.id }) else { return }
                            store.spendRules[index].enabled = enabled
                            store.save()
                        })) {
                        Text(rule.summary(names: keyName) + (rule.level == .critical ? " · critical" : ""))
                            .monospacedDigit()
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Button("Edit Rule", systemImage: "pencil") { sheet = .rule(rule, isNew: false) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("Edit rule")
                    Button("Delete Rule", systemImage: "trash") {
                        store.spendRules.removeAll { $0.id == rule.id }
                        store.save()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Delete rule")
                }
            }
            Button("Add Rule…") { sheet = .rule(SpendRule(), isNew: true) }
            // Delivery sits with the rules it delivers (mockup §4.3); one section less keeps the pane at 640.
            HStack(spacing: 12) {
                Text("Delivery")
                Spacer()
                Toggle("Desktop", isOn: deliveryBool(\.desktopAlerts)).toggleStyle(.checkbox)
                Toggle("ntfy", isOn: deliveryBool(\.ntfyEnabled)).toggleStyle(.checkbox)
                TextField("ntfy topic override", text: topicOverride, prompt: Text("topic override"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .disabled(!store.settings.openRouter.ntfyEnabled)
            }
        } header: {
            Text("Spend Alerts")
        } footer: {
            Text("Toast and sound follow Settings → General; ntfy uses the server in Settings → Alerts.")
                .formFooter()
        }
    }

    private func keyName(_ id: String) -> String {
        store.openRouterKeys.first { $0.id == id }?.displayName ?? "Removed key"
    }

    private func deliveryBool(_ keyPath: WritableKeyPath<OpenRouterSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings.openRouter[keyPath: keyPath] },
                set: { store.settings.openRouter[keyPath: keyPath] = $0; store.save() })
    }

    private var topicOverride: Binding<String> {
        Binding(get: { store.settings.openRouter.ntfyTopicOverride ?? "" },
                set: { store.settings.openRouter.ntfyTopicOverride = $0.isEmpty ? nil : $0; store.save() })
    }
}

/// Red symbol, plain words (FLW-17/23, CLR-5: only the symbol is tinted).
private struct InlineError: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "xmark.octagon").foregroundStyle(.red).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }
}

extension View {
    /// System Settings footer look (mac-design SET-6).
    func formFooter() -> some View {
        font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
    }
}

// MARK: - Add Key sheet (design §4.4)

@MainActor
struct AddOpenRouterKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var nickname = ""
    @State private var adding = false
    @State private var error: String?

    private var canAdd: Bool { !adding && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add OpenRouter Key").font(.headline)
            Form {
                SecureField("API key", text: $secret, prompt: Text("sk-or-v1-…"))
                TextField("Nickname", text: $nickname, prompt: Text("optional"))
            }
            .disabled(adding)
            Text("The key is checked once against openrouter.ai, then stored in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error { InlineError(text: error) }
            HStack {
                Spacer()
                if adding { SwiftUI.ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func add() {
        guard canAdd else { return }
        adding = true
        error = nil
        Task {
            do {
                try await AppStore.shared.addPastedKey(secret, nickname: nickname)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            adding = false
        }
    }
}

// MARK: - Spend Alert sheet (design §4.4)

@MainActor
struct SpendRuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let store = AppStore.shared
    let isNew: Bool
    @State private var rule: SpendRule
    @State private var amount: String

    init(rule: SpendRule, isNew: Bool) {
        self.isNew = isNew
        _rule = State(initialValue: rule)
        _amount = State(initialValue: String(format: "%g", rule.threshold))
    }

    /// Accepts "5.5" and "5,5".
    private var threshold: Double? {
        Double(amount.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
    private var hasManagementKey: Bool { store.settings.openRouter.managementKeyConfigured }
    private var amountValid: Bool { (threshold ?? 0) > 0 }
    private var canSave: Bool { amountValid && (rule.kind != .balance || hasManagementKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Add Spend Alert" : "Edit Spend Alert").font(.headline)
            Form {
                Picker("Alert when", selection: $rule.kind) {
                    Text("Spend").tag(SpendRule.Kind.spend)
                    Text("Cap left").tag(SpendRule.Kind.capRemaining)
                    Text("Balance").tag(SpendRule.Kind.balance).disabled(!hasManagementKey)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()

                if rule.kind != .balance {
                    Picker("Keys", selection: $rule.scope) {
                        if rule.kind == .spend { Text("All keys combined").tag(SpendRule.Scope.allKeys) }
                        Text("Each key").tag(SpendRule.Scope.eachKey)
                        Divider()
                        ForEach(store.openRouterKeys) { Text($0.displayName).tag(SpendRule.Scope.key($0.id)) }
                        if case .key(let id) = rule.scope, !store.openRouterKeys.contains(where: { $0.id == id }) {
                            Text("Removed key").tag(rule.scope)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if rule.kind == .spend {
                    Picker("Window", selection: $rule.window) {
                        ForEach(SpendWindow.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                }

                LabeledContent(rule.kind == .spend ? "Over" : "Below") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            if rule.kind != .capRemaining { Text("$") }
                            TextField("Amount", text: $amount)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .monospacedDigit()
                            if rule.kind == .capRemaining {
                                Picker("Unit", selection: $rule.unit) {
                                    Text("dollars").tag(SpendRule.Unit.usd)
                                    Text("percent").tag(SpendRule.Unit.percent)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .fixedSize()
                            }
                        }
                        if !amountValid { InlineError(text: "Enter an amount above 0.") }
                    }
                }

                Picker("Level", selection: $rule.level) {
                    Text("Warning").tag(AlertLevel.warning)
                    Text("Critical").tag(AlertLevel.critical)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
            }
            Group {
                if !hasManagementKey { Text("Balance alerts need a management key (Settings → OpenRouter).") }
                if rule.kind == .spend {
                    Text("Today, this week and this month follow OpenRouter's UTC calendar, as on its dashboard. Last hour and last 24 hours are measured by Agents Monitor from its polls.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
        // Cap left has no "all keys combined": a sum of caps means nothing.
        .onChange(of: rule.kind) { _, kind in
            if kind == .capRemaining, rule.scope == .allKeys { rule.scope = .eachKey }
        }
    }

    private func save() {
        guard canSave, let threshold else { return }
        rule.threshold = threshold
        if let index = store.spendRules.firstIndex(where: { $0.id == rule.id }) {
            store.spendRules[index] = rule
        } else {
            store.spendRules.append(rule)
        }
        store.save()
        dismiss()
    }
}
