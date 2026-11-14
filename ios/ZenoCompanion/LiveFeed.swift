import Foundation
import Observation
import UIKit

/// Live numbers from the black box: every 10 Hz sample from GET /live while the desk is awake.
/// A box still on firmware v3 has no /live (404): then it falls back to GET /stats once a second
/// and checks for /live again every 15 s, so an upgraded box is picked up by itself.
@MainActor @Observable
final class LiveFeed {
    enum Source: Equatable { case live, stats, offline }

    /// Asks a little faster than the box's 10 Hz so no sample is missed; repeats are skipped by `n`.
    static let livePeriod: TimeInterval = 0.06
    static let statsPeriod: TimeInterval = 1
    static let liveRetry: TimeInterval = 15
    static let keep: TimeInterval = 10 * 60

    private(set) var source = Source.offline
    private(set) var latest: Sample?
    private(set) var modes = Modes()
    /// Last 10 minutes, oldest first.
    private(set) var history: [Sample] = []

    struct Sample: Identifiable {
        var id: Date { t }
        var t: Date
        var current: Double?    // mA
        var volts: Double?
        var power: Double?      // mW
        var temp: Double?       // phone's back, °C
        var ambient: Double?
        var battery: Double?    // the phone's own reading, %
        var fan: Bool?
        var charging: Bool?
    }

    struct Modes: Equatable {
        var charge = "auto"
        var fan = "auto"
    }

    /// Samples per second actually received over the last second.
    var rate: Double {
        guard let last = history.last else { return 0 }
        return Double(history.reversed().prefix { last.t.timeIntervalSince($0.t) < 1 }.count)
    }

    private let telemetry: Telemetry
    private var task: Task<Void, Never>?
    private var lastN: Int?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.httpMaximumConnectionsPerHost = 1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    init(telemetry: Telemetry) { self.telemetry = telemetry }

    func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Base address of the box, taken from the telemetry address in settings.
    private var base: URL? {
        guard var parts = URLComponents(string: telemetry.url), parts.host != nil else { return nil }
        parts.path = ""
        parts.query = nil
        return parts.url
    }

    private func run() async {
        var nextLiveTry = Date.distantPast
        var failures = 0
        while !Task.isCancelled {
            let started = Date.now
            if source != .stats || started >= nextLiveTry {
                switch await fetchLive() {
                case .ok: source = .live; failures = 0
                case .missing: source = .stats; nextLiveTry = started.addingTimeInterval(Self.liveRetry)
                case .failed: failures += 1
                }
            }
            if source == .stats {
                if await fetchStats() { failures = 0 } else { failures += 1 }
            }
            if failures >= 5 { source = .offline }

            let period = source == .live ? Self.livePeriod : Self.statsPeriod
            let wait = period - Date.now.timeIntervalSince(started)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
    }

    private enum Fetch { case ok, missing, failed }

    private func fetchLive() async -> Fetch {
        guard let url = base?.appending(path: "live"),
              let (data, response) = try? await session.data(from: url) else { return .failed }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return .missing }
        guard code == 200, let r = try? JSONDecoder().decode(LiveReading.self, from: data) else { return .failed }
        modes = Modes(charge: r.charge_mode ?? "auto", fan: r.fan_mode ?? "auto")
        if let n = r.n, n == lastN { return .ok }   // the box hasn't taken a new sample yet
        lastN = r.n
        add(Sample(t: .now, current: r.current_ma, volts: r.bus_v, power: r.power_mw, temp: r.temp_c,
                   ambient: r.ambient_c, battery: Self.phoneBattery(), fan: r.fan, charging: r.relay.map { $0 == "charging" }))
        return .ok
    }

    private func fetchStats() async -> Bool {
        guard let url = base?.appending(path: "stats"),
              let (data, _) = try? await session.data(from: url),
              let s = try? JSONDecoder().decode(DeskStats.self, from: data) else { return false }
        add(Sample(t: .now, current: s.current_ma, volts: s.bus_v, power: s.power_mw, temp: s.temp_max_c,
                   ambient: s.ambient_c, battery: Self.phoneBattery(), fan: s.fan, charging: s.relay.map { $0 == "charging" }))
        return true
    }

    private func add(_ sample: Sample) {
        latest = sample
        history.append(sample)
        if let first = history.first, sample.t.timeIntervalSince(first.t) > Self.keep + 30 {
            history.removeAll { sample.t.timeIntervalSince($0.t) > Self.keep }
        }
    }

    private static func phoneBattery() -> Double? {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Double(level * 100)
    }

    /// Manual fan or charging override (reverts to auto on the box after 10 minutes).
    func control(fan: String? = nil, charge: String? = nil) async {
        guard let base, var parts = URLComponents(url: base.appending(path: "control"), resolvingAgainstBaseURL: false) else { return }
        parts.queryItems = [fan.map { URLQueryItem(name: "fan", value: $0) },
                            charge.map { URLQueryItem(name: "charge", value: $0) }].compactMap { $0 }
        guard let url = parts.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        guard let (data, _) = try? await session.data(for: request),
              let r = try? JSONDecoder().decode(LiveReading.self, from: data) else { return }
        modes = Modes(charge: r.charge_mode ?? "auto", fan: r.fan_mode ?? "auto")
    }

    /// History over the last `window` seconds, averaged into buckets so the charts stay light.
    func series(window: TimeInterval, bucket: TimeInterval, now: Date) -> [Sample] {
        let from = now.addingTimeInterval(-window)
        let recent = history.drop { $0.t < from }
        guard bucket > 0 else { return Array(recent) }

        var out: [Sample] = []
        var group: [Sample] = []
        var groupStart = from
        func flush() {
            guard let last = group.last else { return }
            func avg(_ key: KeyPath<Sample, Double?>) -> Double? {
                let values = group.compactMap { $0[keyPath: key] }
                return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            }
            out.append(Sample(t: last.t, current: avg(\.current), volts: avg(\.volts), power: avg(\.power),
                              temp: avg(\.temp), ambient: avg(\.ambient), battery: avg(\.battery),
                              fan: last.fan, charging: last.charging))
            group.removeAll(keepingCapacity: true)
        }
        for sample in recent {
            if sample.t.timeIntervalSince(groupStart) >= bucket {
                flush()
                groupStart = sample.t
            }
            group.append(sample)
        }
        flush()
        return out
    }
}

/// GET /live (firmware v4).
private struct LiveReading: Decodable {
    var n: Int?
    var ms: Int?
    var relay: String?
    var fan: Bool?
    var charge_mode: String?
    var fan_mode: String?
    var bus_v: Double?
    var current_ma: Double?
    var power_mw: Double?
    var temp_c: Double?
    var ambient_c: Double?
    var phone_battery: Double?
}
