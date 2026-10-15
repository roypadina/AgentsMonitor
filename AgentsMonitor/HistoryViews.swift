import SwiftUI
import Charts
import AgentsMonitorKit

// MARK: - Card flip

/// How far back the graph side of a card reaches; tapping the header chip cycles it.
enum GraphSpan: String, CaseIterable {
    case day = "24h", week = "7d", month = "30d"

    var seconds: TimeInterval {
        switch self {
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return AppStore.historyDays * 86400
        }
    }

    var next: GraphSpan {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// One face of a flipping card: visible only on its half of the turn, so the face that is
/// turned away never shows mirrored and never takes clicks. Each face turns itself, so the one
/// showing sits at 0° at rest — clicks never reach a view left rotated by 180°.
struct FlipFace: AnimatableModifier {
    var angle: Double                    // 0 = front up, 180 = back up
    let isBack: Bool

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let visible = (angle >= 90) == isBack
        content
            .rotation3DEffect(.degrees(isBack ? angle - 180 : angle), axis: (x: 0, y: 1, z: 0), perspective: 0.3)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}

extension Severity {
    /// Same green/orange/red as the limit bars.
    var tint: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - Graph row

/// The graph side of one limit row: same header as the bar, then the value over time in the
/// bar's color, ccpool switches as dashed rules and "no free account" moments as red ones.
struct LimitGraphRow: View {
    let label: String
    let value: String
    let color: Color
    let points: [(date: Date, value: Double)]
    let since: Date
    let events: [PoolEvent]
    /// nil = scale to the data (spend without a cap).
    var domain: ClosedRange<Double>? = 0...100

    var body: some View {
        let now = Date()
        let shown = Self.thin(points.filter { $0.date >= since }, to: 150)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(value).font(.caption.monospacedDigit())
            }
            Chart {
                ForEach(shown.indices, id: \.self) { i in
                    AreaMark(x: .value("Time", shown[i].date), y: .value("Value", shown[i].value))
                        .foregroundStyle(color.opacity(0.25))
                    LineMark(x: .value("Time", shown[i].date), y: .value("Value", shown[i].value))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                ForEach(events) { event in
                    RuleMark(x: .value("Time", event.ts))
                        .foregroundStyle(event.noFreeAccount ? Color.red : Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: event.noFreeAccount ? [] : [3, 2]))
                }
            }
            .chartXScale(domain: since...now)
            .chartYScale(domain: domain ?? 0...max(shown.map(\.value).max() ?? 1, 1))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { plot in
                plot.background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .overlay {
                if shown.count < 2 {
                    Text("collecting data…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 18, maxHeight: .infinity)
        }
    }

    /// Every n-th point, so 30 days of 5-minute polls stays a few hundred marks.
    private static func thin(_ points: [(date: Date, value: Double)], to maxCount: Int) -> [(date: Date, value: Double)] {
        let step = max(1, points.count / maxCount)
        return step == 1 ? points : stride(from: 0, to: points.count, by: step).map { points[$0] }
    }
}

// MARK: - ccpool event row

/// "09:12  claude → claude2  hard", then session / week / Fable % of the two accounts it moved
/// between (every account when none was free).
struct PoolEventRow: View {
    let event: PoolEvent
    private let store = AppStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(event.ts.formatted(date: .omitted, time: .shortened))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(title).foregroundStyle(event.noFreeAccount ? Color.red : Color.primary)
                Spacer()
                if let trigger = event.trigger {
                    Text(trigger).foregroundStyle(.secondary)
                }
            }
            if !numbers.isEmpty {
                Text(numbers).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .font(.caption)
        .help(event.reason ?? "")
    }

    private var title: String {
        switch event.event {
        case "switch":
            return "\(store.poolName(event.from, in: event)) → \(store.poolName(event.to, in: event))"
        case "park":
            return "No free account — session parked"
        case "extra":
            return "No free account — paid usage on \(store.poolName(event.to, in: event))"
        default:
            return event.event
        }
    }

    private var numbers: String {
        let names = event.noFreeAccount ? event.accounts.keys.sorted() : [event.from, event.to].compactMap { $0 }
        return names.compactMap { name -> String? in
            guard let a = event.accounts[name] else { return nil }
            return "\(store.poolName(name, in: event)) \(Self.pct(a.session))/\(Self.pct(a.week))/\(Self.pct(a.fable))"
        }.joined(separator: " · ")
    }

    private static func pct(_ value: Double?) -> String {
        value.map { String(Int($0.rounded())) } ?? "–"
    }
}
