import SwiftUI

/// Opened by holding a palm for 2 s: swipe left = fan ON, swipe right = fan AUTO, pinch = close.
/// Uses the box's test switch (manual goes back to auto on the box after 10 minutes). Charging is never
/// on a gesture: it stays automatic, it's a safety feature.
struct FanPanel: View {
    let live: LiveFeed?
    /// Set briefly after a choice, to show it was done before the panel closes.
    let confirmation: String?

    var body: some View {
        let fanOn = live?.latest?.fan
        let mode = live?.modes.fan ?? "auto"
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "fan")
                Text("Fan").font(.system(size: 26, weight: .medium, design: .monospaced))
                Text(fanOn.map { $0 ? "on" : "off" } ?? "–").foregroundStyle(fanOn == true ? Color.blue : DayPanel.faint)
                Text("(\(mode))").foregroundStyle(DayPanel.faint)
            }
            .font(.system(.title3, design: .monospaced))
            .foregroundStyle(DayPanel.text)

            if let confirmation {
                Text(confirmation)
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(DayPanel.accent)
            } else {
                HStack(spacing: 28) {
                    Label("swipe left: ON", systemImage: "arrow.left")
                    Label("swipe right: AUTO", systemImage: "arrow.right")
                }
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(DayPanel.text)
                Text("pinch to close").font(.system(.caption, design: .monospaced)).foregroundStyle(DayPanel.faint)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 20)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(white: 0.18)))
    }
}
