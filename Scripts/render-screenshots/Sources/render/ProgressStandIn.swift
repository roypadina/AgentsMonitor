import SwiftUI

// Shadows SwiftUI.ProgressView in this module only: the AppKit-backed bar draws grey in an offscreen
// (never key) window, which would hide the severity colours the screenshots are meant to show.
struct ProgressView: View {
    let value: Double
    let total: Double
    init(value: Double, total: Double) { self.value = value; self.total = total }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(.tint).frame(width: max(4, geo.size.width * value / total))
            }
        }
        .frame(height: 6)
    }
}
