import Foundation
import Observation
import UIKit

/// Reports battery, charging and heat to the black box (ESP32) and keeps its latest stats.
/// Protocol: PROTOCOL.md at the repo root.
@MainActor @Observable
final class Telemetry {
    static let defaultURL = "http://zenodesk.local/telemetry"
    static let urlKey = "telemetryURL"
    static let interval: TimeInterval = 60

    private(set) var reading = Reading.now()
    private(set) var stats: DeskStats?
    private(set) var lastSent: Date?
    private(set) var lastStatus = "not sent yet"
    private(set) var lastOK = false
    /// Every distinct raw battery level seen since launch, to learn this phone's step size.
    private(set) var levelsSeen: Set<Float> = []

    private var seq = 0
    private var sending = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    var url: String {
        get { UserDefaults.standard.string(forKey: Self.urlKey) ?? Self.defaultURL }
        set { UserDefaults.standard.set(newValue, forKey: Self.urlKey) }
    }

    func start() {
        guard timer == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true

        let center = NotificationCenter.default
        for name in [UIDevice.batteryStateDidChangeNotification, ProcessInfo.thermalStateDidChangeNotification] {
            // Charging or heat changed: tell the box straight away, it may need to act.
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = Task { await self?.send() } }
            })
        }
        observers.append(center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })

        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.send() } }
        }
        Task { await send() }
    }

    private func refresh() {
        reading = Reading.now()
        levelsSeen.insert(UIDevice.current.batteryLevel)
    }

    /// `force` is for the settings button; automatic sends are at least 5 s apart,
    /// because the charging state can flicker many times a minute near 100%.
    func send(force: Bool = false) async {
        guard !sending else { return }
        if !force, let lastSent, Date.now.timeIntervalSince(lastSent) < 5 { return }
        sending = true
        defer { sending = false }

        refresh()
        guard var target = URL(string: url), target.host() != nil else {
            lastStatus = "bad address"; lastOK = false; return
        }
        // "http://zenodesk.local" on its own means the box's telemetry endpoint.
        if target.path().isEmpty || target.path() == "/" { target.append(path: "telemetry") }
        var request = URLRequest(url: target, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Message(reading: reading, seq: seq))
        seq += 1
        lastSent = .now

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastOK = (200..<300).contains(code)
            lastStatus = lastOK ? "OK (\(code))" : "box replied \(code)"
            if lastOK { stats = try? JSONDecoder().decode(DeskStats.self, from: data) }
        } catch {
            lastOK = false
            lastStatus = error.localizedDescription
        }
    }
}

/// What the phone knows about itself right now.
struct Reading: Equatable {
    var battery: Int        // 0–100, -1 if unknown
    var rawLevel: Float     // UIDevice's own value, for checking the step size
    var charging: String    // charging | full | unplugged | unknown
    var thermal: String     // nominal | fair | serious | critical

    @MainActor static func now() -> Reading {
        let device = UIDevice.current
        let level = device.batteryLevel
        let charging = switch device.batteryState {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "unplugged"
        default: "unknown"
        }
        let thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "critical"   // unknown new state: be safe, the box stops charging
        }
        return Reading(battery: level < 0 ? -1 : Int((level * 100).rounded()),
                       rawLevel: level, charging: charging, thermal: thermal)
    }
}

/// POST /telemetry body.
private struct Message: Encodable {
    let v = 1
    let battery: Int
    let charging: String
    let thermal: String
    let seq: Int

    init(reading: Reading, seq: Int) {
        battery = reading.battery
        charging = reading.charging
        thermal = reading.thermal
        self.seq = seq
    }
}

/// The box's reply (same as GET /stats). Every field optional: a broken sensor sends null.
struct DeskStats: Decodable {
    var relay: String?
    var fan: Bool?
    var bus_v: Double?
    var current_ma: Double?
    var power_mw: Double?
    var temp_max_c: Double?     // phone temperature (MLX90632 spot on its back)
    var ambient_c: Double?
    var uptime_s: Int?
    var rssi: Int?
}
