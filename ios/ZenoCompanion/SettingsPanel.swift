import SwiftUI

/// Hidden settings, opened with a 3-finger hold. Also shows what the phone last told the box.
struct SettingsPanel: View {
    let telemetry: Telemetry
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Black box address") {
                    TextField(Telemetry.defaultURL, text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Button("Save and send now") {
                        telemetry.url = address.trimmingCharacters(in: .whitespaces)
                        Task { await telemetry.send(force: true) }
                    }
                    Button("Reset to zenodesk.local") { address = Telemetry.defaultURL }
                }

                Section("Last send") {
                    row("Status", telemetry.lastStatus, ok: telemetry.lastOK)
                    row("When", telemetry.lastSent?.formatted(date: .omitted, time: .standard) ?? "–")
                }

                Section("This phone") {
                    row("Battery", "\(telemetry.reading.battery)%  (raw \(telemetry.reading.rawLevel))")
                    row("Charging", telemetry.reading.charging)
                    row("Heat", telemetry.reading.thermal)
                    row("Battery steps seen", telemetry.levelsSeen.sorted().map { String(format: "%.3f", $0) }.joined(separator: " "))
                }

                if let s = telemetry.stats {
                    Section("Black box") {
                        row("Relay", s.relay ?? "–")
                        row("Fan", s.fan.map { $0 ? "on" : "off" } ?? "–")
                        row("Phone temp", s.temp_max_c.map { String(format: "%.1f °C", $0) } ?? "–")
                        row("Current", s.current_ma.map { String(format: "%.0f mA", $0) } ?? "–")
                        row("Volts", s.bus_v.map { String(format: "%.2f V", $0) } ?? "–")
                    }
                }
            }
            .navigationTitle("Zeno Desk")
            .toolbar { Button("Close") { dismiss() } }
        }
        .preferredColorScheme(.dark)
        .onAppear { address = telemetry.url }
    }

    private func row(_ label: String, _ value: String, ok: Bool? = nil) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(ok == nil ? .secondary : (ok! ? Color.green : Color.red))
        }
    }
}

/// The desk's gestures, attached to the whole window so they never block buttons underneath:
/// - three fingers held for 2 s: settings
/// - one-finger double-tap: graphs screen on/off
/// - swipe left or right: back from the graphs
/// Different finger counts and gesture kinds, so they can't be mistaken for each other.
struct DeskGestures: UIViewRepresentable {
    let onSettings: () -> Void
    let onDoubleTap: () -> Void
    let onSwipe: () -> Void

    func makeUIView(context: Context) -> WindowHook {
        let view = WindowHook()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: WindowHook, context: Context) {
        context.coordinator.handlers = (onSettings, onDoubleTap, onSwipe)
    }

    func makeCoordinator() -> Coordinator { Coordinator(handlers: (onSettings, onDoubleTap, onSwipe)) }

    final class WindowHook: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { coordinator?.attach(to: window) }
        }
    }

    @MainActor final class Coordinator: NSObject {
        var handlers: (settings: () -> Void, doubleTap: () -> Void, swipe: () -> Void)
        private weak var attached: UIWindow?

        init(handlers: (() -> Void, () -> Void, () -> Void)) { self.handlers = handlers }

        func attach(to window: UIWindow) {
            guard attached !== window else { return }
            attached = window

            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
            hold.numberOfTouchesRequired = 3
            hold.minimumPressDuration = 2

            let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
            double.numberOfTapsRequired = 2
            double.numberOfTouchesRequired = 1

            let left = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            left.direction = .left
            let right = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            right.direction = .right

            for g in [hold, double, left, right] as [UIGestureRecognizer] {
                g.cancelsTouchesInView = false   // buttons still get their taps
                g.delaysTouchesEnded = false
                window.addGestureRecognizer(g)
            }
        }

        @objc func held(_ g: UIGestureRecognizer) { if g.state == .began { handlers.settings() } }
        @objc func doubleTapped(_ g: UIGestureRecognizer) { if g.state == .ended { handlers.doubleTap() } }
        @objc func swiped(_ g: UIGestureRecognizer) { if g.state == .ended { handlers.swipe() } }
    }
}
