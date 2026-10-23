import AppKit
import SwiftUI
import AgentsMonitorKit

// Sources/render/*.swift (except this file) are symlinks to the app's views.
let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/screenshots")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
_ = NSApplication.shared

// Controls draw in their grey "inactive" look in a window that is not key; claim to be key (never shown).
final class ActiveWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@MainActor func render<V: View>(_ view: V, size: CGSize, name: String, dark: Bool = true) {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(rootView:
        ZStack { Color(nsColor: .windowBackgroundColor); view }
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key))
    let window = ActiveWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    host.frame = CGRect(origin: .zero, size: size)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    host.layoutSubtreeIfNeeded()
    // height 0 = fit the content
    let size = size.height == 0 ? CGSize(width: size.width, height: host.fittingSize.height) : size
    window.setContentSize(size)
    host.frame = CGRect(origin: .zero, size: size)
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    host.layoutSubtreeIfNeeded()
    let scale = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("\(name).png"))
    print("wrote \(name).png")
}

// MARK: fake data
let now = Date()
func limit(_ kind: String, _ pct: Int, resetsIn: TimeInterval, model: String? = nil, window: TimeInterval? = nil) -> LimitInfo {
    LimitInfo(kind: kind, group: nil, percent: pct,
              severity: pct >= 95 ? .critical : pct >= 80 ? .warning : .normal,
              resetsAt: now.addingTimeInterval(resetsIn), modelDisplayName: model, isActive: true, windowSeconds: window)
}
func spend(_ usedUSD: Int, _ limitUSD: Int) -> SpendInfo {
    let pct = usedUSD * 100 / limitUSD
    return SpendInfo(usedMinor: usedUSD * 100 + 40, limitMinor: limitUSD * 100, exponent: 2, currency: "USD",
                     percent: pct, severity: pct >= 95 ? .critical : pct >= 80 ? .warning : .normal, enabled: true)
}
let h = 3600.0
func claude(_ name: String, _ dir: String) -> Account { Account(name: name, kind: .local(configDirPath: dir), provider: .claude) }
let work = claude("Work", "/Users/example/.claude")
let personal = claude("Personal", "/Users/example/.claude-personal")
let side = claude("Side project", "/Users/example/.claude-side")
let codex = Account(name: "Codex", kind: .local(configDirPath: "/Users/example/.codex"), provider: .codex)

let snaps: [(Account, UsageSnapshot)] = [
    (work, UsageSnapshot(limits: [limit("session", 64, resetsIn: 2.6 * h), limit("weekly_all", 41, resetsIn: 96 * h),
                                  limit("weekly_scoped", 22, resetsIn: 96 * h, model: "Fable")], spend: spend(212, 800))),
    (personal, UsageSnapshot(limits: [limit("session", 12, resetsIn: 4.1 * h), limit("weekly_all", 93, resetsIn: 31 * h),
                                      limit("weekly_scoped", 84, resetsIn: 31 * h, model: "Fable")], spend: nil)),
    (side, UsageSnapshot(limits: [limit("session", 3, resetsIn: 4.8 * h), limit("weekly_all", 18, resetsIn: 140 * h),
                                  limit("weekly_scoped", 9, resetsIn: 140 * h, model: "Fable")], spend: nil)),
    (codex, UsageSnapshot(limits: [limit("session", 37, resetsIn: 3.2 * h, window: 5 * h), limit("weekly_all", 15, resetsIn: 120 * h, window: 7 * 86400)], spend: nil)),
]

// 30 days of samples every 30 min: session saw-tooth, weekly ramp, spend creep.
func mod(_ a: Double, _ m: Double) -> Double { let r = a.truncatingRemainder(dividingBy: m); return r < 0 ? r + m : r }
func samples(for account: Account, snap: UsageSnapshot) -> [UsageSample] {
    let step = 1800.0
    let n = Int(30 * 86400 / step)
    return (0...n).map { i in
        let age = Double(n - i) * step
        let limits: [LimitInfo] = snap.limits.map { l in
            let win = l.windowLength
            let elapsedNow = win - l.resetsAt!.timeIntervalSince(now)
            let x = mod(elapsedNow - age, win)
            let peak = min(97.0, Double(l.percent) * win / max(elapsedNow, 1800))
            let pct = l.kind == "session" ? min(peak, peak * x / win * 1.0) : Double(l.percent) * min(x / max(elapsedNow, 1), 1.0)
            return LimitInfo(kind: l.kind, group: nil, percent: Int(pct), severity: .normal, resetsAt: nil,
                             modelDisplayName: l.modelDisplayName, isActive: true, windowSeconds: win)
        }
        let sp = snap.spend.map {
            SpendInfo(usedMinor: Int(Double($0.usedMinor) * (1 - age / (30 * 86400))), limitMinor: $0.limitMinor, exponent: 2,
                      currency: "USD", percent: 0, severity: .normal, enabled: true)
        }
        return UsageSample(account: account.id, snapshot: UsageSnapshot(limits: limits, spend: sp), at: now.addingTimeInterval(-age))
    }
}

MainActor.assumeIsolated {
    let store = AppStore.shared
    store.accounts = snaps.map(\.0)
    for (a, s) in snaps { store.states[a.id] = .ok(s); store.history[a.id] = samples(for: a, snap: s) }
    store.lastRefresh = now
    render(PopoverView(), size: CGSize(width: 440, height: 0), name: "popover")
    RenderHooks.flipCards = true
    render(PopoverView(), size: CGSize(width: 440, height: 0), name: "graphs")
    RenderHooks.flipCards = false
    store.accounts = snaps.map(\.0)
    render(AccountsTab().frame(width: 460, height: 340), size: CGSize(width: 460, height: 340), name: "settings-accounts")

    let alerts = [
        Alert(accountId: personal.id, accountName: "Personal", key: "weekly_all", title: "Personal: Week at 93%",
              body: "Resets in 31h. Consider switching account.", level: .critical),
        Alert(accountId: work.id, accountName: "Work", key: "spend", title: "Work: extra usage",
              body: "$212.40 of $800.00 spent this month", level: .warning),
        Alert(accountId: codex.id, accountName: "Codex", key: "session", title: "Codex: Session at 80%",
              body: "Resets in 1h 05m", level: .warning),
    ]
    let stack = VStack(spacing: 8) { ForEach(alerts.indices, id: \.self) { ToastContent(alert: alerts[$0]) } }.padding(16)
    render(stack, size: CGSize(width: 352, height: 3 * 72 + 16), name: "toasts")
}
