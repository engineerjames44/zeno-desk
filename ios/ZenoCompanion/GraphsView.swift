import Charts
import SwiftUI

/// Live graphs of everything the black box measures. Double-tap (or swipe) to go back.
struct GraphsView: View {
    let live: LiveFeed
    var gestures: HandGestures?
    /// Counts pinches on this screen; each one switches between 2 and 10 minutes.
    var pinches = 0

    // Fan thresholds on the box (firmware v4): on at 38 °C, off again at 35 °C.
    static let fanOn = 38.0
    static let fanOff = 35.0

    @State private var tenMinutes = false

    var body: some View {
        let window: TimeInterval = tenMinutes ? 600 : 120
        let now = live.latest?.t ?? .now
        // 2 min: every sample (≈1,200 points). 10 min: 1 s averages (600 points).
        let points = live.series(window: window, bucket: tenMinutes ? 1 : 0, now: now)
        let domain = now.addingTimeInterval(-window)...now
        let last = live.latest

        VStack(spacing: 8) {
            header

            Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Tile(title: "Current", value: last?.current.map { "\(Int($0)) mA" }, color: DayPanel.accent,
                         points: points, key: \.current, domain: domain, scale: 0...1000, bands: Self.bands(points, \.charging), bandColor: .green)
                    Tile(title: "Voltage", value: last?.volts.map { String(format: "%.2f V", $0) }, color: .cyan,
                         points: points, key: \.volts, domain: domain, scale: 0...6)
                    Tile(title: "Power", value: last?.power.map { "\(Int($0)) mW" }, color: .yellow,
                         points: points, key: \.power, domain: domain, scale: 0...5000)
                }
                GridRow {
                    Tile(title: "Phone temp", value: last?.temp.map { String(format: "%.1f °C", $0) }, color: .pink,
                         points: points, key: \.temp, domain: domain, scale: 25...40, bands: Self.bands(points, \.fan), bandColor: .blue,
                         rules: [(Self.fanOn, "fan on"), (Self.fanOff, "fan off")])
                    Tile(title: "Battery", value: last?.battery.map { "\(Int($0.rounded()))%" }, color: .green,
                         points: points, key: \.battery, domain: domain, scale: 0...100, rules: [(80, "80"), (40, "40")])
                    ControlsTile(live: live)
                }
                GridRow {
                    OnOffTile(points: points, domain: domain, last: last)
                        .gridCellColumns(3)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.black)
        .monospaced()
        .environment(\.colorScheme, .dark)
        .onChange(of: pinches) { tenMinutes.toggle() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("ZENO DESK · LIVE").foregroundStyle(DayPanel.text)
            Circle()
                .fill(sourceColor)
                .frame(width: 8, height: 8)
            Text(sourceText).foregroundStyle(DayPanel.faint)
            Spacer()
            Picker("Window", selection: $tenMinutes) {
                Text("2 min").tag(false)
                Text("10 min").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            if let gestures {
                GestureBadge(gestures: gestures, compact: true)
                    .frame(width: 118, alignment: .leading)
            }
            Text("back: swipe →").foregroundStyle(DayPanel.faint).lineLimit(1).fixedSize()
        }
        .font(.caption)
    }

    private var sourceText: String {
        switch live.source {
        case .live: String(format: "%.0f Hz", live.rate)
        case .stats: "1 Hz (box on old firmware)"
        case .offline: "box not answering"
        }
    }

    private var sourceColor: Color {
        switch live.source {
        case .live: .green
        case .stats: .yellow
        case .offline: .red
        }
    }

    /// Time spans where a flag (fan, charging) was on, for shading behind a chart.
    static func bands(_ points: [LiveFeed.Sample], _ key: KeyPath<LiveFeed.Sample, Bool?>) -> [ClosedRange<Date>] {
        var out: [ClosedRange<Date>] = []
        var start: Date?
        for p in points {
            if p[keyPath: key] == true { start = start ?? p.t } else if let s = start { out.append(s...p.t); start = nil }
        }
        if let s = start, let end = points.last?.t, s < end { out.append(s...end) }
        return out
    }
}

private struct Tile: View {
    let title: String
    let value: String?
    let color: Color
    let points: [LiveFeed.Sample]
    let key: KeyPath<LiveFeed.Sample, Double?>
    let domain: ClosedRange<Date>
    /// The y range always shown, widened only if a reading falls outside it, so a 1 mA flicker stays flat.
    let scale: ClosedRange<Double>
    var bands: [ClosedRange<Date>] = []
    var bandColor: Color = .clear
    var rules: [(Double, String)] = []

    private var yRange: ClosedRange<Double> {
        let values = points.compactMap { $0[keyPath: key] }
        return min(scale.lowerBound, values.min() ?? scale.lowerBound)...max(scale.upperBound, values.max() ?? scale.upperBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption2).foregroundStyle(DayPanel.faint)
                Spacer()
                Text(value ?? "–").font(.callout).foregroundStyle(color).contentTransition(.numericText())
            }
            Chart {
                ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                    RectangleMark(xStart: .value("from", band.lowerBound), xEnd: .value("to", band.upperBound))
                        .foregroundStyle(bandColor.opacity(0.14))
                }
                ForEach(rules, id: \.0) { rule in
                    RuleMark(y: .value(rule.1, rule.0))
                        .foregroundStyle(Color(white: 0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading, spacing: 0) {
                            Text(rule.1).font(.system(size: 8)).foregroundStyle(DayPanel.faint)
                        }
                }
                ForEach(points) { p in
                    if let y = p[keyPath: key] {
                        LineMark(x: .value("time", p.t), y: .value(title, y))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: yRange)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                    AxisGridLine().foregroundStyle(Color(white: 0.15))
                    AxisValueLabel().font(.system(size: 8)).foregroundStyle(DayPanel.faint)
                }
            }
            .transaction { $0.animation = nil }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.06)))
    }
}

/// Fan and charging over time: one lane each, filled while it's on.
private struct OnOffTile: View {
    let points: [LiveFeed.Sample]
    let domain: ClosedRange<Date>
    let last: LiveFeed.Sample?

    var body: some View {
        let lanes: [(name: String, color: Color, now: Bool?, bands: [ClosedRange<Date>])] = [
            ("Fan", .blue, last?.fan, GraphsView.bands(points, \.fan)),
            ("Charging", .green, last?.charging, GraphsView.bands(points, \.charging)),
        ]
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lanes, id: \.name) { lane in
                    HStack(spacing: 6) {
                        Circle().fill(lane.now == true ? lane.color : Color(white: 0.25)).frame(width: 7, height: 7)
                        Text("\(lane.name) \(lane.now.map { $0 ? "on" : "off" } ?? "–")")
                            .font(.caption2).foregroundStyle(DayPanel.text)
                    }
                }
            }
            .frame(width: 110, alignment: .leading)

            Chart {
                ForEach(lanes, id: \.name) { lane in
                    // A dim track for the whole window, then the "on" spans on top.
                    RectangleMark(xStart: .value("from", domain.lowerBound), xEnd: .value("to", domain.upperBound),
                                  y: .value("lane", lane.name), height: 8)
                        .foregroundStyle(Color(white: 0.12))
                    ForEach(Array(lane.bands.enumerated()), id: \.offset) { _, band in
                        RectangleMark(xStart: .value("from", band.lowerBound), xEnd: .value("to", band.upperBound),
                                      y: .value("lane", lane.name), height: 8)
                            .foregroundStyle(lane.color.opacity(0.8))
                    }
                }
            }
            .chartXScale(domain: domain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .transaction { $0.animation = nil }
        }
        .padding(8)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.06)))
    }
}

/// Test buttons: force the fan or charging on/off for 10 minutes, or hand back to auto.
private struct ControlsTile: View {
    let live: LiveFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Test · auto again in 10 min").font(.caption2).foregroundStyle(DayPanel.faint)
            row("Fan", current: live.modes.fan, on: live.latest?.fan) { await live.control(fan: $0) }
            row("Charge", current: live.modes.charge, on: live.latest?.charging) { await live.control(charge: $0) }
            if live.source != .live {
                Text("Needs box firmware v4").font(.caption2).foregroundStyle(.yellow)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.06)))
        .disabled(live.source != .live)
    }

    /// One line per switch, so the tile stays short enough for the whole screen to fit in landscape.
    private func row(_ name: String, current: String, on: Bool?, send: @escaping (String) async -> Void) -> some View {
        HStack(spacing: 6) {
            Text("\(name) \(on.map { $0 ? "on" : "off" } ?? "–")")
                .font(.caption).foregroundStyle(DayPanel.text)
                .frame(width: 78, alignment: .leading)
            ForEach(["on", "off", "auto"], id: \.self) { choice in
                Button { Task { await send(choice) } } label: {
                    Text(choice).lineLimit(1).fixedSize()
                }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(choice == current || (choice != "auto" && current == "manual" && (on == true) == (choice == "on")) ? DayPanel.accent : .gray)
            }
        }
    }
}
