// Agents Monitor demo: the real PopoverView, MorePage, ToastContent and UsageDot (AgentsMonitor/*.swift, compiled unchanged) over fake data,
// filled through the app's own AppStore.shared. Status text = AppStore.menuBarSegments; the toast alert comes out of the real AlertEngine.
// Nothing reads a credential or the Keychain and the app is never launched: the views are only drawn into bitmaps.
import AppKit
import SwiftUI
import AgentsMonitorKit

private let W = Demo.size.width, H = Demo.size.height
private let hr = 3600.0

// MARK: fake data (fixtures follow Scripts/render-screenshots/Sources/render/main.swift)

/// The app's view files call `Date()` themselves ("resets in", the OpenRouter cap line): left alone, every render could differ by a minute
/// digit. This initializer shadows Foundation's for this module (a same-signature declaration in the current module wins) and returns `pinned`
/// while a view is being drawn.
private var pinned: Double?
extension Date {
    init() { self.init(timeIntervalSinceReferenceDate: pinned ?? CFAbsoluteTimeGetCurrent()) }
}

/// Fixtures hang off one anchor: while a view is drawn its `Date()` is exactly `base`, so "resets in" comes out the same on every run. (The
/// Kit's own default-argument `Date()`s stay real, so every countdown carries +30 s: its minute digit cannot flip.)
private var base = Date()

private func clockTime(_ h: Int, _ m: Int) -> Date {
    Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 30, hour: h, minute: m))!
}

/// `warnAt`: where the provider grades "warning" (Anthropic sends 81 % as warning, Codex.swift:191 grades Codex from 75 %).
private func limit(_ kind: String, _ pct: Int, resetsIn: TimeInterval, model: String? = nil, window: TimeInterval? = nil, warnAt: Int = 80) -> LimitInfo {
    LimitInfo(kind: kind, group: nil, percent: pct, severity: pct >= 95 ? .critical : pct >= warnAt ? .warning : .normal,
              resetsAt: base.addingTimeInterval(resetsIn + 30), modelDisplayName: model, isActive: true, windowSeconds: window)
}

private let work = Account(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "Work",
                           kind: .local(configDirPath: "/Users/example/.claude"), provider: .claude)
private let personal = Account(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!, name: "Personal",
                               kind: .local(configDirPath: "/Users/example/.claude-personal"), provider: .claude)
private let codex = Account(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, name: "Codex",
                            kind: .local(configDirPath: "/Users/example/.codex"), provider: .codex)

private func workSnap() -> UsageSnapshot {
    UsageSnapshot(limits: [limit("session", 64, resetsIn: 156 * 60), limit("weekly_all", 41, resetsIn: 96 * hr),
                           limit("weekly_scoped", 22, resetsIn: 96 * hr, model: "Fable")], spend: nil)
}
private func personalSnap() -> UsageSnapshot {
    UsageSnapshot(limits: [limit("session", 12, resetsIn: 246 * 60), limit("weekly_all", 93, resetsIn: 31 * hr),
                           limit("weekly_scoped", 84, resetsIn: 31 * hr, model: "Fable")], spend: nil)
}
private func codexSnap(_ session: Int) -> UsageSnapshot {
    UsageSnapshot(limits: [limit("session", session, resetsIn: 192 * 60, window: 5 * hr, warnAt: 75),
                           limit("weekly_all", 38, resetsIn: 120 * hr, window: 7 * 86400, warnAt: 75)], spend: nil)
}

/// OpenRouter keys: two pinned to the popover, the rest on the More page. Caps carry no reset period, because the "resets daily in …" countdown
/// runs to the next UTC midnight from the wall clock and would change between renders.
private func key(_ name: String, _ tail: String, day: Double, week: Double, month: Double, limit: Double? = nil, left: Double? = nil) -> OpenRouterKeyUsage {
    OpenRouterKeyUsage(id: "hash-\(name)", name: name, label: "sk-or-v1-\(tail)...\(tail)", limit: limit, limitRemaining: left,
                       usage: month * 3, usageDaily: day, usageWeekly: week, usageMonthly: month)
}
private let keys = [
    key("prod-agent", "c3f", day: 3.2, week: 18.4, month: 61.1, limit: 100, left: 38.9),
    key("research", "9a1", day: 0.65, week: 2.1, month: 9.8),
    key("ci-runner", "77b", day: 0.41, week: 3.9, month: 14.02),
    key("eval-batch", "e5a", day: 12.5, week: 88.2, month: 240.75, limit: 300, left: 59.25),
    key("nightly-etl", "b18", day: 2.75, week: 19.6, month: 70.4),
    key("support-bot", "a70", day: 0.88, week: 5.12, month: 21.9),
]

@MainActor private func setCodex(_ session: Int) {
    AppStore.shared.states[codex.id] = .ok(codexSnap(session))
}

/// The store as the popover finds it at 9:41 (three accounts collapsed to one line each, OpenRouter set up), anchored to the wall clock.
@MainActor private func freshFixtures() {
    base = Date()
    let store = AppStore.shared
    store.accounts = [work, personal, codex]
    store.expandedAccounts = []                                            // three accounts start as compact rows (AppStore.bootstrap)
    store.states[work.id] = .ok(workSnap())
    store.states[personal.id] = .ok(personalSnap())
    setCodex(74)
    store.openRouterKeys = keys.enumerated().map { i, k in
        OpenRouterKeyConfig(id: k.id, source: .managed, placement: i < 2 ? .popover : .more, lastName: k.name, lastLabel: k.label)
    }
    store.settings.openRouter.managementKeyConfigured = true
    store.openRouterState = .ok(OpenRouterSnapshot(keys: keys, balance: OpenRouterBalance(totalCredits: 100, totalUsage: 57.83)))
    store.lastRefresh = clockTime(9, 41)                                   // footer: "9:41 AM" (PopoverView.swift:68 ViewThatFits drops "Updated" at this width)
}

// MARK: drawing a SwiftUI view into a bitmap the way a window would (AppKit controls included), transparent, at the kit's pixel scale

private final class ActiveWindow: NSWindow {  // controls draw their grey "inactive" look in a window that is not key; claim to be key
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@MainActor private func capture<V: View>(_ view: V, width: CGFloat) -> CGImage {
    pinned = base.timeIntervalSinceReferenceDate; defer { pinned = nil }
    func settle(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceReferenceDate: CFAbsoluteTimeGetCurrent() + seconds)) }  // real time, not the pinned one
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).environment(\.controlActiveState, .key))
    let w = ActiveWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    w.appearance = NSAppearance(named: .darkAqua)
    w.isOpaque = false; w.backgroundColor = .clear
    w.contentView = host
    host.frame = CGRect(x: 0, y: 0, width: width, height: 100)
    settle(0.3)
    host.layoutSubtreeIfNeeded()
    let size = CGSize(width: width, height: host.fittingSize.height)
    w.setContentSize(size); host.frame = CGRect(origin: .zero, size: size)
    settle(0.4)
    host.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * Demo.scale).rounded()), pixelsHigh: Int((size.height * Demo.scale).rounded()),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.cgImage!
}

private func context(_ w: Int, _ h: Int) -> CGContext {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    return c
}

// MARK: the popover's rows

/// Rows (in image px, y-down) of the popover's rounded rows and cards: at x = 22 pt (12 pt popover padding + 10 pt corner radius) a row's fill
/// is the only thing, and its rounded corners no longer cut in.
private func rowRuns(_ img: CGImage) -> [Range<Int>] {
    let c = context(img.width, img.height)
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = c.data!.assumingMemoryBound(to: UInt8.self), bpr = c.bytesPerRow, x = Int(22 * Demo.scale)
    var runs: [Range<Int>] = [], start: Int?
    for row in 0..<img.height {   // CG memory is top row first
        let opaque = p[row * bpr + x * 4 + 3] > 0
        if opaque, start == nil { start = row }
        if !opaque, let s = start { if row - s > 30 { runs.append(s..<row) }; start = nil }
    }
    return runs
}

/// The More page as PopoverView shows it: MorePage, then the popover's Divider and footer, cut from the main page's capture (at x = 4 pt only
/// the full-width Divider is drawn; the footer's 10 pt padding keeps its text and buttons clear of it).
private func withFooter(_ page: CGImage, from main: CGImage) -> CGImage {
    let c = context(main.width, main.height)
    c.draw(main, in: CGRect(x: 0, y: 0, width: main.width, height: main.height))
    let p = c.data!.assumingMemoryBound(to: UInt8.self), bpr = c.bytesPerRow, x = Int(4 * Demo.scale)
    var top = main.height - 1
    while top > 0, p[top * bpr + x * 4 + 3] == 0 { top -= 1 }       // up from the bottom to the Divider
    while top > 0, p[(top - 1) * bpr + x * 4 + 3] > 0 { top -= 1 }   // its first row
    let footer = main.cropping(to: CGRect(x: 0, y: top, width: main.width, height: main.height - top))!
    let out = context(page.width, page.height + footer.height)
    out.draw(footer, in: CGRect(x: 0, y: 0, width: footer.width, height: footer.height))
    out.draw(page, in: CGRect(x: 0, y: footer.height, width: page.width, height: page.height))
    return out.makeImage()!
}

// MARK: status item (MenuBarLabel.swift: usage dots, then the segments' text)

@MainActor private struct StatusLook {
    let dots: CGImage, dotsSize: CGSize, item: StatusItem
    init() {
        let segments = AppStore.shared.menuBarSegments
        let shown = segments.filter(\.showDot)
        let text = segments.compactMap { s -> String? in                       // MenuBarLabel.swift:19-22
            let parts = [s.tag, s.text.isEmpty ? nil : s.text].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }.joined(separator: " · ")
        let image = UsageDot.composite(percents: shown.map(\.dotPercent), diameter: text.isEmpty ? 11 : 9)   // MenuBarLabel.swift:25
        dotsSize = image.size
        let c = context(Int((image.size.width * Demo.scale).rounded(.up)), Int((image.size.height * Demo.scale).rounded(.up)))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: c.width, height: c.height))
        NSGraphicsContext.restoreGraphicsState()
        dots = c.makeImage()!
        // The kit's bar takes one symbol/text item: reserve a blank slot for the dots (+ the HStack's 4 pt gap) and draw the real dots in it.
        let space = NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 13)]).size().width
        item = StatusItem(text: String(repeating: " ", count: Int(((image.size.width + 4) / space).rounded())) + text)
    }
}

// MARK: scenes

@MainActor func agentsMonitorScenes() -> [Scene] {
    let store = AppStore.shared
    freshFixtures()

    // status item before / after the 80 % poll
    let look74 = StatusLook()
    setCodex(80)
    let look80 = StatusLook()
    var engine = AlertEngine()                                             // the real engine: 74 % raises nothing, 80 % crosses the default warning threshold
    setCodex(74)
    _ = engine.evaluate(account: codex, state: store.states[codex.id]!)
    setCodex(80)
    let alert = engine.evaluate(account: codex, state: store.states[codex.id]!).first!
    setCodex(74)
    let toast = capture(ToastContent(alert: alert), width: 320)

    // the three popover pages: compact rows, the Codex row expanded into its card (AccountList), the More page (OpenRouterHeaderRow's action)
    freshFixtures()
    let compact = capture(PopoverView(), width: 460)
    store.expandedAccounts = [codex.id]
    let expanded = capture(PopoverView(), width: 460)
    let more = withFooter(capture(MorePage(filter: .constant(""), onBack: {}, onRepaste: { _ in }), width: 460), from: compact)
    let compactRows = rowRuns(compact), expandedRows = rowRuns(expanded)
    precondition(compactRows.count == 6 && expandedRows.count == 6, "expected Work, Personal, Codex, OpenRouter and two keys, found \(compactRows.count) / \(expandedRows.count)")
    precondition(expandedRows[2].count > compactRows[2].count * 2, "the Codex row did not expand into its card")

    func bar(_ look: StatusLook, clock: String, pressed: Bool = false) -> (Canvas, CGRect) {
        let c = Canvas()
        let frame = c.menuBar(app: look.item, appActive: pressed, clock: clock)
        c.draw(look.dots, in: CGRect(x: frame.minX + 8, y: (Demo.barHeight - look.dotsSize.height) / 2, width: look.dotsSize.width, height: look.dotsSize.height))
        return (c, frame)
    }
    let clock941 = Demo.clock, clock946 = "Thu Oct 30 9:46 AM"
    let item = bar(look74, clock: clock941).1
    let itemCenter = CGPoint(x: item.midX, y: Demo.barHeight / 2)
    let popOrigin = CGPoint(x: min(item.midX - 230, W - 460 - 8), y: Demo.barHeight + 6)
    func chevron(_ run: Range<Int>) -> CGPoint {                           // the row's trailing chevron: 12 pt popover padding + ~13 pt to its centre
        CGPoint(x: popOrigin.x + 460 - 25, y: popOrigin.y + CGFloat(run.lowerBound + run.upperBound) / 2 / Demo.scale)
    }
    let codexRow = chevron(compactRows[2]), openRouterRow = chevron(expandedRows[3])
    let panelRadius: CGFloat = 16
    let toastOrigin = CGPoint(x: W - 12 - 320, y: Demo.barHeight + 12)                      // ToastPanel.frame(forIndex:): 12 pt margin, top right

    // 1. the status item: one dot per account, then the numbers (MenuBarLabel)
    let s1 = Scene(name: "menu bar", duration: 2.0, caption: "Every account's usage sits in the menu bar") { _ in
        bar(look74, clock: clock941).0.image
    }

    // 2. a click opens the popover (MenuBarExtra .window): one line per account, the OpenRouter row and the keys pinned under it
    let path2 = CursorPath(start: CGPoint(x: W * 0.74, y: H * 0.44), moves: [.init(t0: 0.10, t1: 0.65, to: itemCenter)], clicks: [0.80])
    let s2 = Scene(name: "popover", duration: 2.8, caption: "One line per account and OpenRouter key") { t in
        let open = t >= 0.80
        let (c, _) = bar(look74, clock: clock941, pressed: open)
        if open { c.panel(compact, at: popOrigin, radius: panelRadius, alpha: CGFloat(ramp(t, 0.80, 0.92))) }
        let click = path2.click(t)
        c.cursor(at: path2.position(t), alpha: CGFloat(ramp(t, 0.0, 0.25)), press: click.press, pulse: click.pulse)
        return c.image
    }

    // 3. a click on the Codex row expands it into the full card in place (AccountList toggles expandedAccounts, no animation)
    let path3 = CursorPath(start: itemCenter, moves: [.init(t0: 0.10, t1: 0.75, to: codexRow)], clicks: [0.90])
    let s3 = Scene(name: "expand", duration: 2.6, caption: "Click a row for bars and reset times") { t in
        let (c, _) = bar(look74, clock: clock941, pressed: true)
        c.panel(t >= 0.90 ? expanded : compact, at: popOrigin, radius: panelRadius)
        let click = path3.click(t)
        c.cursor(at: path3.position(t), press: click.press, pulse: click.pulse)
        return c.image
    }

    // 4. the OpenRouter row opens the More page inside the same popover: balance, every key, caps
    let path4 = CursorPath(start: codexRow, moves: [.init(t0: 0.10, t1: 0.65, to: openRouterRow)], clicks: [0.80])
    let s4 = Scene(name: "more", duration: 2.6, caption: "Every OpenRouter key's spend on the More page") { t in
        let (c, _) = bar(look74, clock: clock941, pressed: true)
        c.panel(t >= 0.80 ? more : expanded, at: popOrigin, radius: panelRadius)
        let click = path4.click(t)
        c.cursor(at: path4.position(t), alpha: CGFloat(1 - ramp(t, 1.30, 1.55)), press: click.press, pulse: click.pulse)  // gone once the page has opened
        return c.image
    }

    // 5. a click elsewhere closes the popover at once; the next poll sees Codex at 80 %: dot + number change, the toast slides in
    let path5 = CursorPath(start: openRouterRow, moves: [.init(t0: 0.10, t1: 0.45, to: CGPoint(x: W * 0.30, y: H * 0.62))], clicks: [0.55])
    let pollAt = 0.95, toastAt = 1.05
    let s5 = Scene(name: "toast", duration: 2.8, caption: "Warns near the limit: toast, notification, phone push") { t in
        let polled = t >= pollAt
        let closing = 1 - ramp(t, 0.55, 0.67)
        let (c, _) = polled ? bar(look80, clock: clock946) : bar(look74, clock: clock941, pressed: closing > 0)
        if closing > 0 { c.panel(more, at: popOrigin, radius: panelRadius, alpha: CGFloat(closing)) }
        if t >= toastAt {  // ToastPanel.show: 0.25 s slide in from the right (width + margin) while fading in
            let k = ease((t - toastAt) / 0.25)
            c.panel(toast, at: CGPoint(x: toastOrigin.x + (320 + 12) * (1 - k), y: toastOrigin.y), radius: 10, alpha: CGFloat(k))
        }
        let click = path5.click(t)
        c.cursor(at: path5.position(t), alpha: CGFloat(ramp(t, 0.0, 0.25) * (1 - ramp(t, 0.70, 0.95))), press: click.press, pulse: click.pulse)
        return c.image
    }
    return [s1, s2, s3, s4, s5]
}

@main struct AgentsMonitorDemo {
    @MainActor static func main() {
        _ = NSApplication.shared
        Demo.run(scenes: agentsMonitorScenes())
    }
}
