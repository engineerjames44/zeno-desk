import SwiftUI

/// Right-hand side of the day screen: clock, Zeno's news (or a live call), and the box's stats.
/// Dim greys only: bright, static pixels are what burn into an OLED.
struct DayPanel: View {
    let now: Date
    let feed: FeedStore
    let call: Feed.LiveCall?
    let telemetry: Telemetry
    let weather: Weather
    let live: LiveFeed?

    static let text = Color(white: 0.62)
    static let faint = Color(white: 0.38)
    static let accent = Color(red: 0.96, green: 0.65, blue: 0.36).opacity(0.85)   // Zeno's orange

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text(now, format: .dateTime.hour().minute())
                    .font(.system(size: 48, weight: .light, design: .monospaced))
                    .foregroundStyle(Self.text)
                    .lineLimit(1)
                    .fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    Text(now, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .foregroundStyle(Self.faint)
                    if let w = weather.now {
                        HStack(spacing: 6) {
                            Image(systemName: w.symbol).foregroundStyle(Self.accent)
                            Text("\(Int(w.temp.rounded()))°").foregroundStyle(Self.text)
                            Text("\(Int(w.high.rounded()))°/\(Int(w.low.rounded()))°").foregroundStyle(Self.faint)
                        }
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
            }

            if let call {
                CallView(call: call)
            } else {
                NewsView(now: now, feed: feed)
            }

            Spacer(minLength: 0)
            StatsStrip(telemetry: telemetry, live: live)
        }
        .monospaced()
    }
}

private struct NewsView: View {
    let now: Date
    let feed: FeedStore

    var body: some View {
        let ticker = feed.feed.ticker ?? []
        let items = Array((feed.feed.items ?? []).prefix(3))

        VStack(alignment: .leading, spacing: 8) {
            if !ticker.isEmpty {
                // A new ticker line every 8 seconds.
                Text(ticker[Int(now.timeIntervalSince1970 / 8) % ticker.count])
                    .font(.callout)
                    .foregroundStyle(DayPanel.accent)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.6), value: ticker[Int(now.timeIntervalSince1970 / 8) % ticker.count])
            }

            if items.isEmpty {
                Text("Nothing new from Zeno yet")
                    .font(.callout)
                    .foregroundStyle(DayPanel.faint)
            }
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: Self.symbol(item.kind))
                        .frame(width: 18)
                        .foregroundStyle(DayPanel.faint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).foregroundStyle(DayPanel.text).lineLimit(1)
                        if let detail = item.detail {
                            Text(detail).foregroundStyle(DayPanel.faint).lineLimit(1)
                        }
                    }
                }
                .font(.footnote)
            }

            if let received = feed.receivedAt, now.timeIntervalSince(received) > 2 * 3600 {
                Text("updated \(received, format: .relative(presentation: .named))")
                    .font(.caption2)
                    .foregroundStyle(DayPanel.faint)
            }
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "briefing": "sun.max"
        case "call": "phone"
        case "mission": "flag"
        case "routine": "arrow.trianglehead.2.clockwise"
        case "email": "envelope"
        case "calendar": "calendar"
        default: "note.text"
        }
    }
}

/// Zeno on the phone: who he's calling and the last lines of the transcript.
private struct CallView: View {
    let call: Feed.LiveCall

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: call.state == "ended" ? "phone.down" : "phone.fill")
                    .symbolEffect(.pulse, isActive: call.state != "ended")
                Text(Self.heading(call))
            }
            .font(.callout)
            .foregroundStyle(DayPanel.accent)

            ForEach(Array((call.lines ?? []).suffix(4).enumerated()), id: \.offset) { _, line in
                let who = Text(line.who == "zeno" ? "Zeno  " : "Them  ")
                    .foregroundStyle(line.who == "zeno" ? DayPanel.accent : DayPanel.faint)
                Text("\(who)\(Text(line.text).foregroundStyle(DayPanel.text))")
                    .font(.footnote)
                    .lineLimit(2)
            }
        }
    }

    static func heading(_ call: Feed.LiveCall) -> String {
        switch call.state {
        case "ringing": "Calling \(call.to)…"
        case "ended": "Call with \(call.to) ended"
        default: "On the phone with \(call.to)"
        }
    }
}

/// The black box's live numbers (10 Hz from /live, or the slower fallback), plus the phone's own battery.
private struct StatsStrip: View {
    let telemetry: Telemetry
    let live: LiveFeed?

    var body: some View {
        let l = live?.latest
        let s = telemetry.stats
        let r = telemetry.reading
        let battery = l?.battery ?? (r.battery < 0 ? nil : Double(r.battery))
        let current = l?.current ?? s?.current_ma
        let temp = l?.temp ?? s?.temp_max_c
        let fan = l?.fan ?? s?.fan
        let charging = l?.charging ?? s?.relay.map { $0 == "charging" }
        HStack(spacing: 12) {
            stat(Self.batterySymbol(r), battery.map { "\(Int($0.rounded()))%" } ?? "–")
            stat("bolt", current.map { "\(Int($0)) mA" } ?? "–")
            stat("thermometer.medium", temp.map { String(format: "%.1f°", $0) } ?? "–")
            stat("fan", fan.map { $0 ? "on" : "off" } ?? "–")
            stat("powerplug", charging.map { $0 ? "charging" : "off" } ?? "–")
            if live?.source == .offline || (live == nil && !telemetry.lastOK) {
                stat("wifi.exclamationmark", "box?")
            }
        }
        .font(.caption)
        .foregroundStyle(DayPanel.faint)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .monospacedDigit()
    }

    /// The battery icon follows the real level, with a bolt while charging.
    static func batterySymbol(_ r: Reading) -> String {
        if r.charging == "charging" || r.charging == "full" { return "battery.100percent.bolt" }
        return switch r.battery {
        case ..<0: "battery.0percent"
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private func stat(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(value)
        }
    }
}
