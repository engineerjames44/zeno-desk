import Foundation
import Observation

/// Current weather from Open-Meteo (free, no key), refreshed every 15 minutes.
/// Fixed location, so the app never asks for location access.
@MainActor @Observable
final class Weather {
    static let latitude = 42.36     // Boston
    static let longitude = -71.06
    static let refreshEvery: TimeInterval = 15 * 60

    private(set) var now: Now?

    struct Now {
        var temp: Double
        var high: Double
        var low: Double
        var code: Int
        var isDay: Bool
    }

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.refresh() } }
        }
        Task { await refresh() }
    }

    func refresh() async {
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: "\(Self.latitude)"),
            .init(name: "longitude", value: "\(Self.longitude)"),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "timezone", value: "auto"),
        ]
        guard let (data, _) = try? await URLSession.shared.data(from: url.url!),
              let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let high = reply.daily.temperature_2m_max.first,
              let low = reply.daily.temperature_2m_min.first else { return }   // keep the last good reading
        now = Now(temp: reply.current.temperature_2m, high: high, low: low,
                  code: reply.current.weather_code, isDay: reply.current.is_day == 1)
        #if DEBUG
        // Preview any sky: launch with `-weatherCode 61 -weatherDay 1`.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "weatherCode") != nil { now?.code = defaults.integer(forKey: "weatherCode") }
        if defaults.object(forKey: "weatherDay") != nil { now?.isDay = defaults.bool(forKey: "weatherDay") }
        #endif
    }

    private struct Reply: Decodable {
        struct Current: Decodable { var temperature_2m: Double; var weather_code: Int; var is_day: Int }
        struct Daily: Decodable { var temperature_2m_max: [Double]; var temperature_2m_min: [Double] }
        var current: Current
        var daily: Daily
    }
}

extension Weather {
    enum Kind { case clear, partly, cloudy, fog, rain, snow, storm }
}

extension Weather.Now {
    var kind: Weather.Kind {
        switch code {
        case 0: .clear
        case 1, 2: .partly
        case 45, 48: .fog
        case 51...67, 80...82: .rain
        case 71...77, 85, 86: .snow
        case 95...99: .storm
        default: .cloudy
        }
    }

    /// SF Symbol for a WMO weather code.
    var symbol: String {
        switch code {
        case 0: isDay ? "sun.max" : "moon.stars"
        case 1, 2: isDay ? "cloud.sun" : "cloud.moon"
        case 3: "cloud"
        case 45, 48: "cloud.fog"
        case 51...57: "cloud.drizzle"
        case 61...67, 80...82: "cloud.rain"
        case 71...77, 85, 86: "cloud.snow"
        case 95...99: "cloud.bolt.rain"
        default: "cloud"
        }
    }
}
