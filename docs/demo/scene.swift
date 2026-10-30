// Agents Monitor demo: the real PopoverView, ToastContent and UsageDot (AgentsMonitor/*.swift, compiled unchanged) over fake data,
// filled through the app's own AppStore.shared. Status text = AppStore.menuBarSegments; the toast alert comes out of the real AlertEngine.
// Nothing reads a credential or the Keychain and the app is never launched: the views are only drawn into bitmaps.
import AppKit
import CoreImage
import SwiftUI
import AgentsMonitorKit

private let W = Demo.size.width, H = Demo.size.height
private let hr = 3600.0

// MARK: fake data (fixtures follow Scripts/render-screenshots/Sources/render/main.swift)

/// The app's view files call `Date()` themselves (HistoryViews.swift:75 graph axis, PopoverView.swift:258 graph span, :333 "resets in"): left alone,
/// every render would differ by a few pixels at anti-aliased edges, because the chart's axis moves with the wall clock. This initializer shadows
/// Foundation's for this module (a same-signature declaration in the current module wins) and returns `pinned` while a view is being drawn.
private var pinned: Double?
extension Date {
    init() { self.init(timeIntervalSinceReferenceDate: pinned ?? CFAbsoluteTimeGetCurrent()) }
}

/// Fixtures hang off one anchor: while a view is drawn its `Date()` is exactly `base`, so "resets in", the pacing tick's neighbours and the graph
/// axis come out the same on every run. (The Kit's own default-argument `Date()`s stay real, so every countdown carries +30 s: its minute digit
/// cannot flip.)
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
private let codex = Account(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, name: "Codex",
                            kind: .local(configDirPath: "/Users/example/.codex"), provider: .codex)

private func workSnap() -> UsageSnapshot {
    UsageSnapshot(limits: [limit("session", 64, resetsIn: 156 * 60), limit("weekly_all", 41, resetsIn: 96 * hr),
                           limit("weekly_scoped", 22, resetsIn: 96 * hr, model: "Fable")], spend: nil)
}
private func codexSnap(_ session: Int) -> UsageSnapshot {
    UsageSnapshot(limits: [limit("session", session, resetsIn: 192 * 60, window: 5 * hr, warnAt: 75),
                           limit("weekly_all", 38, resetsIn: 120 * hr, window: 7 * 86400, warnAt: 75)], spend: nil)
}

/// Two days of polls every 10 min: the session limit as a saw-tooth (older windows peak at different heights, the current one reaches the
/// snapshot's number), the weekly limit as one slowing ramp. A made-up shape, not anyone's usage.
private func history(for account: Account, snap: UsageSnapshot) -> [UsageSample] {
    func pseudo(_ k: Int) -> Double { let s = sin(Double(k) * 12.9898 + 78.233) * 43758.5453; return s - floor(s) }
    return (0..<288).reversed().map { k in
        let age = 300.0 + 600.0 * Double(k)
        let limits = snap.limits.map { l -> LimitInfo in
            let win = l.windowLength
            let elapsed = win - (l.resetsAt!.timeIntervalSince(base) - 30)
            let x = elapsed - age
            let pct: Double
            if x >= 0 {
                let u = x / elapsed
                pct = Double(l.percent) * (1 - pow(1 - u, 3))
            } else {
                let cycle = Int((x / win).rounded(.down))
                pct = (45 + 45 * pseudo(cycle)) * pow((x - Double(cycle) * win) / win, 0.85)
            }
            return LimitInfo(kind: l.kind, group: nil, percent: Int(pct), severity: .normal, resetsAt: nil,
                             modelDisplayName: l.modelDisplayName, isActive: true, windowSeconds: win)
        }
        return UsageSample(account: account.id, snapshot: UsageSnapshot(limits: limits, spend: nil), at: base.addingTimeInterval(-age))
    }
}

@MainActor private func setCodex(_ session: Int) {
    AppStore.shared.states[codex.id] = .ok(codexSnap(session))
}

/// The store as the popover finds it at 9:41 (accounts, usage, two days of history for the graphs), anchored to the current wall clock.
@MainActor private func freshFixtures() {
    base = Date()
    let store = AppStore.shared
    store.accounts = [work, codex]
    store.states[work.id] = .ok(workSnap())
    setCodex(74)
    store.history[codex.id] = history(for: codex, snap: codexSnap(74))
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

// MARK: the popover and its flipping card

/// Rows (in image px, y-down) where the account cards sit: at x = 22 pt (12 pt popover padding + the card's 10 pt corner radius) the card fill
/// is the only thing, and its rounded corners no longer cut in.
private func cardRows(_ img: CGImage) -> [Range<Int>] {
    let c = context(img.width, img.height)
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = c.data!.assumingMemoryBound(to: UInt8.self), bpr = c.bytesPerRow, x = Int(22 * Demo.scale)
    var runs: [Range<Int>] = [], start: Int?
    for row in 0..<img.height {   // CG memory is top row first
        let opaque = p[row * bpr + x * 4 + 3] > 0
        if opaque, start == nil { start = row }
        if !opaque, let s = start { if row - s > 50 { runs.append(s..<row) }; start = nil }
    }
    return runs
}

/// What AccountCard's flip does at one instant: its front turns away (0-90 degrees) and its back turns in (90-180), the way the app's
/// FlipFace draws it (rotation3DEffect about the vertical axis, perspective 0.3). Approximated here with a perspective warp of the two
/// real faces; at rest (0 and 180) the images are the app's own.
@MainActor private struct CardFlip {
    let front: CGImage, back: CGImage, rect: CGRect  // rect: the card in image px, y-down
    private let ci = CIContext()

    /// `angle` in degrees, 0 = front up, 180 = back up.
    func image(angle: Double) -> CGImage {
        let w = front.width, h = front.height
        let c = context(w, h)
        // the page without the card (the panel's glass shows through where it was)
        c.draw(front, in: CGRect(x: 0, y: 0, width: w, height: h))
        let hole = CGRect(x: rect.minX, y: CGFloat(h) - rect.maxY, width: rect.width, height: rect.height).insetBy(dx: -2, dy: -2)
        c.saveGState()
        c.addPath(CGPath(roundedRect: hole, cornerWidth: 10 * Demo.scale + 2, cornerHeight: 10 * Demo.scale + 2, transform: nil))
        c.clip(); c.clear(hole); c.restoreGState()

        let face = angle < 90 ? front : back
        let theta = (angle < 90 ? angle : angle - 180) * .pi / 180
        if abs(cos(theta)) > 0.03, let cropped = face.cropping(to: rect) {
            let cw = CGFloat(cropped.width), ch = CGFloat(cropped.height), d = cw / 0.3  // eye distance for perspective 0.3
            func corner(_ sx: CGFloat, _ sy: CGFloat) -> CGPoint {
                let x = sx * cw / 2, z = x * CGFloat(sin(theta)), s = d / (d - z)
                return CGPoint(x: cw / 2 + x * CGFloat(cos(theta)) * s, y: ch / 2 + sy * ch / 2 * s)
            }
            let f = CIFilter(name: "CIPerspectiveTransform")!
            f.setValue(CIImage(cgImage: cropped), forKey: kCIInputImageKey)
            f.setValue(CIVector(cgPoint: corner(-1, 1)), forKey: "inputTopLeft"); f.setValue(CIVector(cgPoint: corner(1, 1)), forKey: "inputTopRight")
            f.setValue(CIVector(cgPoint: corner(-1, -1)), forKey: "inputBottomLeft"); f.setValue(CIVector(cgPoint: corner(1, -1)), forKey: "inputBottomRight")
            if let out = f.outputImage, let warped = ci.createCGImage(out, from: out.extent) {
                c.draw(warped, in: CGRect(x: rect.minX + out.extent.minX, y: CGFloat(h) - rect.maxY + out.extent.minY, width: out.extent.width, height: out.extent.height))
            }
        }
        return c.makeImage()!
    }
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

    freshFixtures(); RenderHooks.flipCards = false
    let front = capture(PopoverView(), width: 440)
    freshFixtures(); RenderHooks.flipCards = true
    let back = capture(PopoverView(), width: 440)
    RenderHooks.flipCards = false
    precondition(front.width == back.width && front.height == back.height, "the card back keeps the card's size")
    let cards = cardRows(front)
    precondition(cards.count == 2, "expected two account cards, found \(cards.count)")
    let codexCard = CGRect(x: 12 * Demo.scale, y: Double(cards[1].lowerBound), width: Double(front.width) - 24 * Demo.scale, height: Double(cards[1].count))
    let flip = CardFlip(front: front, back: back, rect: codexCard)
    let flipped = flip.image(angle: 180)
    let popSize = CGSize(width: CGFloat(front.width) / Demo.scale, height: CGFloat(front.height) / Demo.scale)

    func bar(_ look: StatusLook, clock: String, pressed: Bool = false) -> (Canvas, CGRect) {
        let c = Canvas()
        let frame = c.menuBar(app: look.item, appActive: pressed, clock: clock)
        c.draw(look.dots, in: CGRect(x: frame.minX + 8, y: (Demo.barHeight - look.dotsSize.height) / 2, width: look.dotsSize.width, height: look.dotsSize.height))
        return (c, frame)
    }
    let clock941 = Demo.clock, clock946 = "Thu Oct 30 9:46 AM"
    let item = bar(look74, clock: clock941).1
    let item80 = bar(look80, clock: clock946).1
    let itemCenter = CGPoint(x: item.midX, y: Demo.barHeight / 2)
    let popOrigin = CGPoint(x: min(item.midX - popSize.width / 2, W - popSize.width - 8), y: Demo.barHeight + 6)
    let chartButton = CGPoint(x: popOrigin.x + popSize.width - 12 - 12 - 7,                  // card padding 12 + popover padding 12 + half the 14 pt icon
                              y: popOrigin.y + codexCard.minY / Demo.scale + 12 + 9)          // PopoverView header row: 12 pt card padding, ~18 pt row
    let panelRadius: CGFloat = 16
    let toastOrigin = CGPoint(x: W - 12 - 320, y: Demo.barHeight + 12)                      // ToastPanel.frame(forIndex:): 12 pt margin, top right

    // 1. the status item: one dot per account, then the numbers (MenuBarLabel)
    let s1 = Scene(name: "menu bar", duration: 2.4, caption: "Every account's usage sits in the menu bar") { _ in
        bar(look74, clock: clock941).0.image
    }

    // 2. a click opens the popover (MenuBarExtra .window): limit bars, pacing ticks, reset countdowns
    let path2 = CursorPath(start: CGPoint(x: W * 0.74, y: H * 0.44), moves: [.init(t0: 0.10, t1: 0.70, to: itemCenter)], clicks: [0.85])
    let s2 = Scene(name: "popover", duration: 3.2, caption: "Click for limit bars and reset times") { t in
        let open = t >= 0.85
        let (c, _) = bar(look74, clock: clock941, pressed: open)
        if open { c.panel(front, at: popOrigin, radius: panelRadius, alpha: CGFloat(ramp(t, 0.85, 0.97))) }
        let click = path2.click(t)
        c.cursor(at: path2.position(t), alpha: CGFloat(ramp(t, 0.0, 0.25) * (1 - ramp(t, 1.25, 1.50))), press: click.press, pulse: click.pulse)
        return c.image
    }

    // 3. the chart button turns the Codex card over (withAnimation(.easeInOut(duration: 0.45)), PopoverView.swift:166)
    let path3 = CursorPath(start: itemCenter, moves: [.init(t0: 0.10, t1: 0.95, to: chartButton)], clicks: [1.15])
    let s3 = Scene(name: "graph", duration: 3.6, caption: "Flip a card for its usage graph") { t in
        let (c, _) = bar(look74, clock: clock941, pressed: true)
        let angle = 180 * ease((t - 1.15) / 0.45)
        c.panel(angle >= 180 ? flipped : flip.image(angle: angle), at: popOrigin, radius: panelRadius)
        let click = path3.click(t)
        c.cursor(at: path3.position(t), alpha: CGFloat(ramp(t, 0.0, 0.25)), press: click.press, pulse: click.pulse)
        return c.image
    }

    // 4. a click elsewhere closes the popover at once; the next poll sees Codex at 80 %: dot + number change, the toast slides in
    let path4 = CursorPath(start: chartButton, moves: [.init(t0: 0.10, t1: 0.55, to: CGPoint(x: W * 0.30, y: H * 0.62))], clicks: [0.65])
    let pollAt = 1.15, toastAt = 1.30
    let s4 = Scene(name: "toast", duration: 3.6, caption: "Warns near the limit: toast, notification, phone push") { t in
        let polled = t >= pollAt
        let closing = 1 - ramp(t, 0.65, 0.77)
        let (c, _) = polled ? bar(look80, clock: clock946) : bar(look74, clock: clock941, pressed: closing > 0)
        if closing > 0 { c.panel(flipped, at: popOrigin, radius: panelRadius, alpha: CGFloat(closing)) }
        if t >= toastAt {  // ToastPanel.show: 0.25 s slide in from the right (width + margin) while fading in
            let k = ease((t - toastAt) / 0.25)
            c.panel(toast, at: CGPoint(x: toastOrigin.x + (320 + 12) * (1 - k), y: toastOrigin.y), radius: 10, alpha: CGFloat(k))
        }
        let click = path4.click(t)
        c.cursor(at: path4.position(t), alpha: CGFloat((1 - ramp(t, 0.80, 1.05))), press: click.press, pulse: click.pulse)
        return c.image
    }
    _ = item80
    return [s1, s2, s3, s4]
}

@main struct AgentsMonitorDemo {
    @MainActor static func main() {
        _ = NSApplication.shared
        Demo.run(scenes: agentsMonitorScenes())
    }
}
