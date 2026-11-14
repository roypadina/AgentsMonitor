import AppKit
import CoreAudio
import SwiftUI
import AgentsMonitorKit

/// When the Ko-fi card shows. The moment: the user opened the popover, saw calm numbers (every account
/// fresh and under the warning threshold) and closed it; the card follows ~10 s later if they are still
/// settled at the desk. The ask rules themselves are SupportPromptState (Kit, unit-tested).
@MainActor
final class SupportPrompt {
    static let shared = SupportPrompt()
    private(set) var showing = false  // mirrored in the status menu: the card never takes keyboard focus
    weak var popover: NSWindow?  // set by PopoverWindowReader: MenuBarExtra gives no handle to its window
    private var pending: Task<Void, Never>?
    private var lastAlertAt = Date.distantPast
    private var kofiOpenedAt = Date.distantPast
    private var popoverKeyAt = Date.distantFuture  // when the popover last took focus: a look needs ≥ 2 s

    private static let installDateKey = "AgentsMonitor.supportInstallDate"
    private static let alertsSentKey = "AgentsMonitor.alertsSent"
    private static let stateKey = "AgentsMonitor.supportPrompt"
    private static var appVersion: String { AboutInfo.version }

    private var state: SupportPromptState {
        get {
            UserDefaults.standard.data(forKey: Self.stateKey)
                .flatMap { try? JSONDecoder().decode(SupportPromptState.self, from: $0) } ?? SupportPromptState()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.stateKey) }
    }

    /// At launch: the first-ask clock starts at the first launch of the version that ships the card. Our own UI
    /// taking focus (popover, Settings, About, Welcome, Sparkle) or the user leaving (sleep, screen lock) drops a
    /// pending try and closes a card on screen as "Ask me in 2 weeks".
    func start() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.installDateKey) == nil { d.set(Date(), forKey: Self.installDateKey) }
        let makeWay: @Sendable (Notification) -> Void = { _ in MainActor.assumeIsolated { SupportPrompt.shared.makeWay() } }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if (note.object as? NSWindow) === SupportPrompt.shared.popover { SupportPrompt.shared.popoverKeyAt = Date() }
                SupportPrompt.shared.makeWay()
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { SupportPrompt.shared.resigned(note.object as? NSWindow) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                          queue: .main, using: makeWay)
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil,
                                                            queue: .main, using: makeWay)
    }

    /// An alert just fired: stressful, so no card for the next hour, and one on screen makes way.
    /// `sent` = alerts that went out on at least one channel (the receipt's "Alerts sent").
    func alerted(sent: Int) {
        lastAlertAt = Date()
        let d = UserDefaults.standard
        if sent > 0 { d.set(d.integer(forKey: Self.alertsSentKey) + sent, forKey: Self.alertsSentKey) }
        makeWay()
    }

    /// The Support buttons: no card right after the user went to Ko-fi on their own.
    func openKofi() {
        kofiOpenedAt = Date()
        NSWorkspace.shared.open(AboutInfo.kofi)
    }

    func makeWay() {
        pending?.cancel()
        guard showing else { return }
        SupportPanel.respond(.snooze)
        SupportPanel.close()
    }

    /// The popover lost focus: it closed (Settings or a sheet taking over cancels via makeWay). A calm look is
    /// the moment; one try ~10 s later, a newer close replaces it.
    private func resigned(_ window: NSWindow?) {
        guard let window, window === popover else { return }
        pending?.cancel()
        guard AppStore.shared.isCalm, Date().timeIntervalSince(popoverKeyAt) >= 2 else { return }
        let start = Date()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            // Cancelled (our UI, an alert, sleep, lock) or the Mac slept meanwhile: the user isn't settled.
            guard !Task.isCancelled, Date().timeIntervalSince(start) < 30 else { return }
            self?.maybeShow()
        }
    }

    private func maybeShow(now: Date = Date()) {
        let store = AppStore.shared
        // Not now: our own UI up (popover, Settings, About, Welcome, Sparkle), a poll running, an alert in the last
        // hour or numbers no longer calm, Ko-fi just opened by hand, nobody settled at the desk (input in the last
        // 10 s, but not mid-typing), a menu open or a mouse button down, the screen locked, or a call (mic in use).
        // Skipped, not queued: the next calm look tries again.
        guard !showing, popover?.isVisible != true,
              !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }),
              !store.isRefreshing, store.isCalm,
              now.timeIntervalSince(lastAlertAt) > 3600, now.timeIntervalSince(kofiOpenedAt) > 600,
              Self.idleSeconds() < 10, Self.idleSeconds(.keyDown) > 2,
              RunLoop.main.currentMode != .eventTracking, !Self.menuOpen(), NSEvent.pressedMouseButtons == 0,
              !Self.screenLocked, !Self.micInUse(),
              let installDate = UserDefaults.standard.object(forKey: Self.installDateKey) as? Date,
              state.mayAsk(now: now, installDate: installDate, usageChecks: store.usageChecks, appVersion: Self.appVersion)
        else { return }
        state.recordShown(now)
        present()
    }

    /// `record: false` = the ⌥ menu preview: shows the real card but never touches the ask bookkeeping.
    func present(record: Bool = true) {
        guard !showing else { return }
        showing = true
        SupportPanel.show(usageChecks: AppStore.shared.usageChecks,
                          alertsSent: UserDefaults.standard.integer(forKey: Self.alertsSentKey),
                          accounts: AppStore.shared.accounts.count,
                          onAnswer: { [weak self] answer in self?.answer(answer, record: record) },
                          onClosed: { [weak self] in self?.showing = false })
    }

    /// The status menu's mirror of the card's buttons.
    func answerFromMenu(_ answer: SupportPromptState.Answer) {
        SupportPanel.respond(answer)
        SupportPanel.close()
    }

    private func answer(_ answer: SupportPromptState.Answer, record: Bool) {
        if answer == .support { NSWorkspace.shared.open(AboutInfo.kofi) }
        guard record else { return }
        state.record(answer, now: Date(), appVersion: Self.appVersion)
    }

    /// Seconds since the last input (or since the last key press).
    static func idleSeconds(_ type: CGEventType = CGEventType(rawValue: ~0)!) -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
    }

    private static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Another app's menu is on screen (a pop-up-menu-level window). Reads only layer, owner pid and alpha, which
    /// need no Screen Recording permission (window names would).
    private static func menuOpen() -> Bool {
        let me = Int(getpid()), level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .contains {
                $0[kCGWindowLayer as String] as? Int == level && $0[kCGWindowOwnerPID as String] as? Int != me
                    && ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0
            }
    }

    /// The default input device is recording for some app (a call, dictation). Reading it needs no mic permission.
    private static func micInUse() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }
}

/// Hands the popover's window to SupportPrompt: its closing after a calm look is the card's moment.
struct PopoverWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Reader() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Reader: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { SupportPrompt.shared.popover = window }
        }
    }
}

/// One dynamic colour from a light/dark pair (plus optional Increase Contrast variants), so every Color
/// below flips with the appearance automatically.
private func dyn(light: NSColor, dark: NSColor, hcLight: NSColor? = nil, hcDark: NSColor? = nil) -> Color {
    Color(nsColor: NSColor(name: nil) {
        switch $0.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .darkAqua: dark
        case .accessibilityHighContrastAqua: hcLight ?? light
        case .accessibilityHighContrastDarkAqua: hcDark ?? dark
        default: light
        }
    })
}

/// The card's colours (MeetAlert's Theme values; Agents Monitor has no theme file).
private enum Theme {
    /// Card base tint over .regularMaterial. Navy-ink, not neutral black.
    static let ink = dyn(light: NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 0.45),
                         dark: NSColor(red: 0.05, green: 0.07, blue: 0.13, alpha: 0.55))
    static let kofi = dyn(light: NSColor(red: 0.78, green: 0.19, blue: 0.18, alpha: 1),   // #C8302D
                          dark: NSColor(red: 1.00, green: 0.37, blue: 0.36, alpha: 1),    // #FF5E5B
                          hcLight: NSColor(red: 0.64, green: 0.14, blue: 0.13, alpha: 1), // #A32320
                          hcDark: NSColor(red: 1.00, green: 0.53, blue: 0.51, alpha: 1))  // #FF8783
    /// Ink text on the bright dark-mode fill, white on the deep light-mode fill.
    static let onSignal = dyn(light: .white, dark: NSColor(red: 0.05, green: 0.07, blue: 0.13, alpha: 1))
}

/// The floating receipt card, top-right under the menu bar. Borderless, so it can never become key:
/// no keystroke can reach its buttons (a stray Return must not tip or opt out). Keyboard and
/// VoiceOver users get the same three actions in the status menu instead.
@MainActor
enum SupportPanel {
    private static var panel: NSPanel?
    private static var onAnswer: ((SupportPromptState.Answer) -> Void)?
    private static var onClosed: (@MainActor () -> Void)?  // @MainActor = Sendable: close()'s completion captures it
    /// Transparent room around the card: shadow on top/right, coffee burst on left/bottom.
    static let insets = EdgeInsets(top: 12, leading: 48, bottom: 48, trailing: 12)

    static func show(usageChecks: Int, alertsSent: Int, accounts: Int,
                     onAnswer: @escaping (SupportPromptState.Answer) -> Void,
                     onClosed: @escaping @MainActor () -> Void) {
        guard panel == nil else { return }
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) ?? NSScreen.main else {
            return onClosed()
        }
        let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false  // Swift owns it via `panel`
        p.isFloatingPanel = true
        p.level = .floating
        p.hasShadow = false  // the card draws its own; a window shadow would outline the transparent margin
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: SupportPromptView(usageChecks: usageChecks, alertsSent: alertsSent, accounts: accounts))
        p.contentView = host
        let size = host.fittingSize
        let visible = screen.visibleFrame  // card lands 12pt in from the top-right corner (= the insets)
        p.setFrame(NSRect(x: visible.maxX - size.width, y: visible.maxY - size.height,
                          width: size.width, height: size.height), display: false)
        p.orderFrontRegardless()
        panel = p
        self.onAnswer = onAnswer
        self.onClosed = onClosed
        AccessibilityNotification.Announcement(
            "Agents Monitor: \(usageChecks.formatted()) usage checks, every limit watched for you. Tip a coffee on Ko-fi? Options are in the Agents Monitor menu: right-click its icon."
        ).post()
        Task {  // unanswered 5 min, or 2 min without input (walked off): fade away as "Ask me in 2 weeks"
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(15))
                guard panel === p else { return }
                if SupportPrompt.idleSeconds() > 120 { break }
            }
            respond(.snooze)
            close()
        }
    }

    /// One answer per card (button or menu). Records it; the caller animates and closes.
    static func respond(_ answer: SupportPromptState.Answer) {
        onAnswer?(answer)
        onAnswer = nil
    }

    static func close() {
        guard let p = panel else { return }
        panel = nil
        onAnswer = nil
        let closed = onClosed
        onClosed = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {  // AppKit calls it on the main thread; the SDK just doesn't say so
                // close + drop the view: a hidden panel keeps rendering its loops
                p.contentView = nil
                p.close()
                closed?()
            }
        })
    }

    /// Snooze: slide the window so the (SwiftUI-shrinking) card ends on the menu-bar icon.
    static func flyToStatusItem(duration: TimeInterval) {
        guard let p = panel, let target = statusItemWindow()?.frame else { return }
        let card = NSRect(x: p.frame.minX + insets.leading, y: p.frame.minY + insets.bottom,
                          width: p.frame.width - insets.leading - insets.trailing,
                          height: p.frame.height - insets.top - insets.bottom)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.8, 0.2)
            p.animator().setFrameOrigin(NSPoint(x: p.frame.minX + target.midX - card.midX,
                                                y: p.frame.minY + target.midY - card.midY))
        }
    }

    /// One accent-coloured flash behind the menu-bar icon, as the snoozed card lands in it.
    static func pulseStatusItem() {
        guard let view = statusItemWindow()?.contentView else { return }
        view.wantsLayer = true
        view.layer?.cornerRadius = 5
        let pulse = CAKeyframeAnimation(keyPath: "backgroundColor")
        let red = NSColor(red: 1.00, green: 0.37, blue: 0.36, alpha: 0.9).cgColor  // Ko-fi red #FF5E5B
        pulse.values = [NSColor.clear.cgColor, red, NSColor.clear.cgColor]
        pulse.keyTimes = [0, 0.3, 1]
        pulse.duration = 0.9
        view.layer?.add(pulse, forKey: "supportPulse")
    }

    // shortcut: MenuBarExtra exposes no status-item frame, so find its private NSStatusBarWindow by
    // class name (as StatusMenu does); nil → snooze just fades. Upgrade if Apple ships a public frame API.
    private static func statusItemWindow() -> NSWindow? {
        NSApp.windows.first { $0.className.contains("NSStatusBarWindow") && $0.isVisible }
    }
}

/// The receipt: prints out of a slot, itemises what Agents Monitor did, ends in "TIP? ☕ optional".
struct SupportPromptView: View {
    let usageChecks: Int
    let alertsSent: Int
    let accounts: Int
    var settled = false  // start fully printed, no entry animation (screenshot renders)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var shown = false
    @State private var printed: CGFloat = 0  // 0 = paper inside the slot, 1 = fully out
    @State private var paperHeight: CGFloat = 0
    @State private var buttonsShown = false
    @State private var sheen: CGFloat = -1  // sheen band position across the Support button, -1…1
    @State private var answered = false
    @State private var bursting = false
    @State private var thanked = false
    @State private var leaving = false  // never / final fade: scale 0.94 + fade
    @State private var flying = false  // snooze: shrink toward the menu-bar icon

    private static let width: CGFloat = 340
    private static let radius: CGFloat = 18
    private var title: String { "\(usageChecks.formatted()) usage checks.\nEvery limit watched for you. 🎯" }

    var body: some View {
        card
            .scaleEffect(flying ? 0.06 : leaving ? 0.94 : 1)
            .opacity(flying || leaving || !(shown || settled) ? 0 : 1)
            .padding(SupportPanel.insets)
            .task { await sheenLoop() }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        return ZStack {
            receipt.opacity(thanked ? 0 : 1)
            if thanked { thanks }  // same card size: content crossfades, nothing jumps
        }
        .padding(14)
        .frame(width: Self.width)
        .background {
            ZStack {
                if contrast == .increased {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    shape.fill(.regularMaterial)
                    shape.fill(Theme.ink)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        }
        .overlay(shape.strokeBorder(contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(0.12)),
                                    lineWidth: contrast == .increased ? 2 : 1))
        .overlay { if bursting { CoffeeBurst() } }
    }

    private var receipt: some View {
        VStack(spacing: 0) {
            Capsule()  // the printer slot
                .fill(LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                .frame(height: 9)
                .zIndex(1)  // the paper slides out from under the slot
                .accessibilityHidden(true)
            paper  // measured first, then printed: the card stays invisible until then (no full-paper flash)
                .background(GeometryReader { g in Color.clear.onAppear { paperHeight = g.size.height; enter() } })
                .offset(y: -(1 - (settled ? 1 : printed)) * (paperHeight + 9))  // + the torn edge
                .padding(.bottom, 9)  // room for the torn edge
                .clipped()
                .padding(.horizontal, 8)
                .padding(.top, -3)
            buttons.opacity(buttonsShown || settled ? 1 : 0)
        }
    }

    private var paper: some View {
        let ink = Color(red: 0.16, green: 0.15, blue: 0.13)
        let faded = Color(red: 0.36, green: 0.33, blue: 0.29)
        return VStack(spacing: 3) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text("AGENTS MONITOR ★ RECEIPT").font(.system(size: 11.5, weight: .bold, design: .monospaced)).tracking(1.4)
            Text(Date().formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(faded)
                .padding(.bottom, 6)
            if usageChecks > 0 { row("Usage checks", usageChecks.formatted()) }
            if alertsSent > 0 { row("Alerts sent", alertsSent.formatted()) }
            if accounts > 0 { row("Accounts watched", accounts.formatted()) }
            row("Price paid", "$0.00")
            Divider().overlay(faded.opacity(0.5)).padding(.vertical, 3)
            HStack { Text("TIP?"); Spacer(); Text("☕ optional") }
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
            VStack(spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text("Agents Monitor is free, open source and made by one person. Tip the human behind the meter?")
                    .font(.system(size: 11.5)).foregroundStyle(faded)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            Barcode().fill(ink).frame(height: 22).padding(.horizontal, 20).padding(.top, 8)
                .accessibilityHidden(true)
        }
        .foregroundStyle(ink)
        .padding(EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13))
        .background(TornPaper().fill(Color(red: 0.98, green: 0.97, blue: 0.93)).padding(.bottom, -8)
            .shadow(color: .black.opacity(0.15), radius: 3, y: 2))
        .accessibilityElement(children: .combine)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(label).fixedSize()  // the leader shrinks, never the label
            Leader().stroke(Color(red: 0.71, green: 0.68, blue: 0.62), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
                .frame(height: 1)
                .accessibilityHidden(true)
            Text(value).fixedSize()
        }
        .font(.system(size: 11.5, design: .monospaced))
    }

    private var buttons: some View {
        VStack(spacing: 6) {
            Button("Tip a coffee ☕") { answer(.support) }
                .buttonStyle(SupportButtonStyle(prominent: true))
                .overlay { sheenBand }
            HStack(spacing: 6) {
                Button("Ask me in 2 weeks") { answer(.snooze) }.buttonStyle(SupportButtonStyle())
                Button("Nope, don't ask again") { answer(.never) }.buttonStyle(SupportButtonStyle())
            }
            Text("I only ask after a calm look at your usage — at most 3× a year.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .padding(.top, 3)
        }
        .padding(.top, 4)
        .disabled(answered)
    }

    private var sheenBand: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.35)
                .offset(x: sheen * g.size.width * 0.9 + g.size.width * 0.325)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var thanks: some View {
        VStack(spacing: 6) {
            Text("♥").font(.system(size: 40)).foregroundStyle(Theme.kofi)
            Text("Thank you!").font(.system(size: 16, weight: .semibold))
            Text("Opening Ko-fi…").font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    // MARK: motion

    private func enter() {
        guard !settled else { return }
        if reduceMotion {
            printed = 1
            buttonsShown = true
            withAnimation(.easeOut(duration: 0.15)) { shown = true }
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { shown = true }
        Task {
            // Stepped jerks, ~1 s total: (target, move seconds) with a short hold after each.
            for (target, seconds) in [(0.17, 0.15), (0.43, 0.19), (0.71, 0.20), (1.0, 0.30)] as [(CGFloat, Double)] {
                withAnimation(.easeOut(duration: seconds)) { printed = target }
                try? await Task.sleep(for: .seconds(seconds + 0.06))
            }
            withAnimation(.easeOut(duration: 0.3)) { buttonsShown = true }
        }
    }

    private func sheenLoop() async {
        guard !settled, !reduceMotion else { return }
        for _ in 0..<2 {  // two passes catch the eye once; an endless shine reads as nagging
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !answered else { return }
            sheen = -1
            withAnimation(.easeInOut(duration: 1.2)) { sheen = 1 }
        }
    }

    private func answer(_ a: SupportPromptState.Answer) {
        guard !answered else { return }
        answered = true
        SupportPanel.respond(a)
        Task {
            switch a {
            case .support:
                bursting = !reduceMotion
                try? await Task.sleep(for: .seconds(reduceMotion ? 0 : 0.35))
                withAnimation(.easeInOut(duration: 0.3)) { thanked = true }
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.easeOut(duration: 0.25)) { leaving = true }
                try? await Task.sleep(for: .seconds(0.25))
            case .snooze where !reduceMotion:
                withAnimation(.timingCurve(0.55, 0, 0.8, 0.2, duration: 0.55)) { flying = true }
                SupportPanel.flyToStatusItem(duration: 0.55)
                try? await Task.sleep(for: .seconds(0.5))
                SupportPanel.pulseStatusItem()
            case .snooze, .never:
                withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.25)) { leaving = true }
                try? await Task.sleep(for: .seconds(0.25))
            }
            SupportPanel.close()
        }
    }
}

/// Fill-the-card buttons. Custom on purpose: the app is never active while the card shows, so
/// system bordered buttons would render in their gray inactive look.
private struct SupportButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(cfg: configuration, prominent: prominent)
    }

    private struct StyledButton: View {
        let cfg: Configuration
        let prominent: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: prominent ? 9 : 7, style: .continuous)
            cfg.label
                .font(.system(size: prominent ? 13 : 12, weight: prominent ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .frame(height: prominent ? 34 : 28)
                .foregroundStyle(prominent ? AnyShapeStyle(Theme.onSignal) : AnyShapeStyle(.primary))
                .background(shape.fill(prominent ? AnyShapeStyle(Theme.kofi)
                                                 : AnyShapeStyle(Color.primary.opacity(hover ? 0.14 : 0.08))))
                .contentShape(shape)
                .opacity(prominent && hover ? 0.92 : enabled ? 1 : 0.6)
                .scaleEffect(cfg.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: hover)
                .onHover { hover = $0 }
        }
    }
}

/// Coffee cups and beans flying out of the card's centre, once.
private struct CoffeeBurst: View {
    @State private var fired = false

    var body: some View {
        ZStack {
            ForEach(0..<24, id: \.self) { i in
                let angle = Double(i) * 2.39996  // golden angle: an even, deterministic spread
                let distance = 90 + Double((i * 37) % 80)
                Group {
                    if i % 3 == 0 {
                        Text("☕").font(.system(size: 18))
                    } else {
                        Capsule().fill(Color(red: 0.42, green: 0.24, blue: 0.12)).frame(width: 7, height: 10)
                    }
                }
                .rotationEffect(.degrees(fired ? Double((i * 53) % 360) - 180 : 0))
                .scaleEffect(fired ? 1 : 0.5)
                .offset(x: fired ? cos(angle) * distance : 0, y: fired ? sin(angle) * distance - 20 : 0)
                .opacity(fired ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { withAnimation(.easeOut(duration: 1.2)) { fired = true } }
    }
}

/// Receipt paper with a zig-zag torn bottom edge (8pt teeth).
private struct TornPaper: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let tooth: CGFloat = 12, depth: CGFloat = 8
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - depth))
        var x = r.maxX
        while x > r.minX {
            p.addLine(to: CGPoint(x: max(r.minX, x - tooth / 2), y: r.maxY))
            x -= tooth
            p.addLine(to: CGPoint(x: max(r.minX, x), y: r.maxY - depth))
        }
        p.closeSubpath()
        return p
    }
}

/// Dotted leader between a receipt label and its value.
private struct Leader: Shape {
    func path(in r: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: r.minX, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) }
    }
}

/// Decorative barcode: fixed bar widths, so it looks the same every time.
private struct Barcode: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let pattern: [CGFloat] = [2, 1, 1, 3, 2, 1, 3, 1, 1, 2, 1, 1, 2, 3, 1, 2]
        var x = r.minX, i = 0
        while x < r.maxX {
            let bar = pattern[i % pattern.count]
            if i % 2 == 0 { p.addRect(CGRect(x: x, y: r.minY, width: min(bar, r.maxX - x), height: r.height)) }
            x += bar + 1
            i += 1
        }
        return p
    }
}
