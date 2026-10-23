import SwiftUI
import Charts
import AgentsMonitorKit

// MARK: - Card flip

/// Dev-only switch for Scripts/render-screenshots: renders the cards graph side up.
enum RenderHooks { nonisolated(unsafe) static var flipCards = false }

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
/// bar's color.
struct LimitGraphRow: View {
    let label: String
    let value: String
    let color: Color
    let points: [(date: Date, value: Double)]
    let since: Date
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
