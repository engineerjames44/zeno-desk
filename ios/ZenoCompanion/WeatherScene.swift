import SwiftUI

/// A small pixel-art sky behind Zeno that follows the real weather: sun or moon and stars,
/// drifting clouds, rain, snow, fog, lightning. Drawn on a 40×40 grid so it matches his pixels.
struct WeatherScene: View {
    let weather: Weather.Now?

    private static let grid = 40

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { context in
            Canvas { gc, size in
                draw(&gc, size: size, t: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func draw(_ gc: inout GraphicsContext, size: CGSize, t: Double) {
        let cell = size.width / CGFloat(Self.grid)
        let kind = weather?.kind ?? .cloudy
        let day = weather?.isDay ?? true

        // One "pixel" of the scene, snapped to whole screen points so neighbours never leave seams.
        func px(_ x: Double, _ y: Double, _ w: Double = 1, _ h: Double = 1, _ color: Color) {
            let x0 = (floor(x) * cell).rounded(), y0 = (floor(y) * cell).rounded()
            let x1 = ((floor(x) + w) * cell).rounded(), y1 = ((floor(y) + h) * cell).rounded()
            gc.fill(Path(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)), with: .color(color))
        }

        // Sky, in pixel bands of 5 rows.
        let (top, bottom) = Self.sky(kind, day: day)
        func skyAt(_ row: Double) -> Color { Self.mix(top, bottom, Double(Int(row) / 5) / 7) }
        for band in 0..<(Self.grid / 5) {
            px(0, Double(band * 5), Double(Self.grid), 5, skyAt(Double(band * 5)))
        }

        // Stars on clear nights.
        if !day && (kind == .clear || kind == .partly) {
            for i in 0..<28 {
                let twinkle = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * (0.8 + Self.rand(i, 3)) + Self.rand(i, 4) * 6))
                px(Self.rand(i, 1) * 40, Self.rand(i, 2) * 24, 1, 1, .white.opacity(twinkle * 0.8))
            }
        }

        // Sun or moon.
        if kind == .clear || kind == .partly {
            if day {
                // Top-left corner, clear of Zeno.
                let sun = Color(red: 1, green: 0.85, blue: 0.35)
                Self.disc(cx: 6, cy: 6, r: 3.5) { x, y in px(x, y, 1, 1, sun) }
                let bright = Int(t / 0.8) % 2 == 0
                for (dx, dy) in [(0, -6), (0, 6), (-6, 0), (6, 0), (-4, -4), (4, -4), (-4, 4), (4, 4)] {
                    px(Double(6 + dx), Double(6 + dy), 1, 1, sun.opacity(bright ? 0.9 : 0.45))
                }
            } else {
                // A crescent: a disc with a second, offset disc cut out of it.
                Self.disc(cx: 6, cy: 6, r: 3.5) { x, y in
                    if pow(x - 7.6, 2) + pow(y - 4.8, 2) > 3.2 * 3.2 { px(x, y, 1, 1, Color(white: 0.92)) }
                }
            }
        }

        // Clouds drift across, wrapping around.
        let clouds: Int = switch kind {
        case .clear: 0
        case .partly: 2
        case .fog: 0
        default: 4
        }
        let cloudColor = kind == .rain || kind == .storm ? Color(white: day ? 0.55 : 0.3) : Color(white: day ? 0.92 : 0.45)
        for i in 0..<clouds {
            let speed = 0.25 + Self.rand(i, 7) * 0.35
            let x = (Self.rand(i, 5) * 52 + t * speed).truncatingRemainder(dividingBy: 52) - 12
            let y = 2 + Self.rand(i, 6) * 12
            for (dx, dy, w) in [(3.0, 0.0, 5.0), (1, 1, 9), (0, 2, 12), (0, 3, 12)] {
                px(x + dx, y + dy, w, 1, cloudColor)
            }
        }

        // Rain, snow.
        if kind == .rain || kind == .storm {
            for i in 0..<36 {
                let speed = 14 + Self.rand(i, 9) * 8
                let y = (Self.rand(i, 8) * 44 + t * speed).truncatingRemainder(dividingBy: 44) - 2
                let x = (Self.rand(i, 10) * 40 - y * 0.25).truncatingRemainder(dividingBy: 40) + 4
                px(x, y, 1, 2, Color(red: 0.6, green: 0.75, blue: 1).opacity(0.75))
            }
        }
        if kind == .snow {
            for i in 0..<34 {
                let y = (Self.rand(i, 11) * 42 + t * (2 + Self.rand(i, 12) * 2)).truncatingRemainder(dividingBy: 42) - 1
                let x = Self.rand(i, 13) * 40 + sin(t * 0.8 + Self.rand(i, 14) * 6) * 1.2
                px(x, y, 1, 1, .white.opacity(0.9))
            }
        }

        // Fog: soft bands sliding slowly.
        if kind == .fog {
            for i in 0..<6 {
                let x = (t * (0.4 + Double(i) * 0.1) + Double(i) * 9).truncatingRemainder(dividingBy: 60) - 20
                px(x, Double(8 + i * 5), 30, 2, Color(white: 0.85).opacity(0.35))
            }
        }

        // Ground: grass, or snow on it.
        let ground = kind == .snow ? Color(white: day ? 0.9 : 0.55) : (day ? Color(red: 0.2, green: 0.45, blue: 0.25) : Color(red: 0.06, green: 0.16, blue: 0.1))
        px(0, 36, 40, 4, ground)
        for x in stride(from: 0, to: 40, by: 3) { px(Double(x), 35, 1, 1, ground) }

        // Lightning: a short flash every few seconds.
        if kind == .storm, (t / 6.5).truncatingRemainder(dividingBy: 1) < 0.035 {
            gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.55)))
        }
    }

    // MARK: helpers

    private static func sky(_ kind: Weather.Kind, day: Bool) -> (Color, Color) {
        switch (kind, day) {
        case (.clear, true), (.partly, true): (Color(red: 0.2, green: 0.45, blue: 0.85), Color(red: 0.55, green: 0.78, blue: 1))
        case (.clear, false), (.partly, false): (Color(red: 0.03, green: 0.04, blue: 0.14), Color(red: 0.1, green: 0.13, blue: 0.3))
        case (.snow, true), (.fog, true), (.cloudy, true): (Color(red: 0.5, green: 0.56, blue: 0.64), Color(red: 0.72, green: 0.76, blue: 0.82))
        case (.rain, true), (.storm, true): (Color(red: 0.25, green: 0.29, blue: 0.36), Color(red: 0.42, green: 0.47, blue: 0.55))
        default: (Color(red: 0.05, green: 0.06, blue: 0.1), Color(red: 0.14, green: 0.16, blue: 0.22))
        }
    }

    private static func mix(_ a: Color, _ b: Color, _ f: Double) -> Color {
        let a = a.resolve(in: .init()), b = b.resolve(in: .init()), f = Float(f)
        return Color(red: Double(a.red + (b.red - a.red) * f), green: Double(a.green + (b.green - a.green) * f), blue: Double(a.blue + (b.blue - a.blue) * f))
    }

    /// Fixed pseudo-random number in 0..<1 for item `i`, so things keep their places frame to frame.
    private static func rand(_ i: Int, _ salt: Int) -> Double {
        var x = UInt64(i &* 7919 &+ salt &* 104_729) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((x ^ (x >> 31)) % 10_000) / 10_000
    }

    private static func disc(cx: Double, cy: Double, r: Double, _ cell: (Double, Double) -> Void) {
        for y in Int(cy - r)...Int(cy + r) {
            for x in Int(cx - r)...Int(cx + r) where pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2) <= r * r {
                cell(Double(x), Double(y))
            }
        }
    }
}
