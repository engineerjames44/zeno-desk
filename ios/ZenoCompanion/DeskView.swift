import Combine
import SwiftUI

/// The whole desk screen: Zeno with the day panel by day, black by night.
struct DeskView: View {
    // Night: Zeno sleeps and the screen is black. Hours on the phone's clock.
    static let nightStartHour = 23
    static let nightEndHour = 6

    // James's call: full brightness by day. Burn-in care is the drift and the black night.
    static let dayBrightness: CGFloat = 1.0
    static let driftRange: CGFloat = 14   // points everything may wander from centre
    static let driftEvery: TimeInterval = 180
    static let driftDuration: TimeInterval = 60   // slow enough that you never see it move

    @State private var isNight = DeskView.nightNow()
    @State private var offset = CGSize.zero
    @State private var telemetry = Telemetry()
    @State private var feed = FeedStore()
    @State private var weather = Weather()
    @State private var live: LiveFeed?
    @State private var gestures = HandGestures()
    #if DEBUG
    @State private var showGraphs = UserDefaults.standard.bool(forKey: "showGraphs")   // `-showGraphs 1`
    #else
    @State private var showGraphs = false
    #endif
    @Environment(\.scenePhase) private var scenePhase

    /// The graphs screen closes by itself after this, so it can't sit static on the OLED.
    static let graphsTimeout: Duration = .seconds(5 * 60)
    @State private var server: FeedServer?
    @State private var showSettings = false

    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let drift = Timer.publish(every: DeskView.driftEvery, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !isNight, showGraphs, let live {
                GraphsView(live: live)
                    .transition(.opacity)
            } else if !isNight {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let call = feed.activeCall(at: context.date)
                    HStack(spacing: 24) {
                        ZStack {
                            WeatherScene(weather: weather.now)
                            LoopingVideo(name: "zeno-idle-alpha", playing: !isNight)
                        }
                        .frame(width: 220, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        DayPanel(now: context.date, feed: feed, call: call, telemetry: telemetry, weather: weather, live: live)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Room for the drift, so nothing slides under the screen's edges.
                    .padding(.horizontal, DeskView.driftRange + 4)
                    .padding(.vertical, DeskView.driftRange + 4)
                }
                .offset(offset)
                .transition(.opacity)
            }

            if !isNight && !showGraphs {
                GestureBadge(gestures: gestures)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 6)
                    .padding(.trailing, DeskView.driftRange + 4)
                    .allowsHitTesting(false)
            }

            RecordingOverlay(recorder: gestures.recorder)
                .allowsHitTesting(false)

            DeskGestures(
                onSettings: { showSettings = true },
                onDoubleTap: { if !showSettings && !isNight { withAnimation(.easeInOut(duration: 0.3)) { showGraphs.toggle() } } },
                onSwipe: { if showGraphs && !showSettings { withAnimation(.easeInOut(duration: 0.3)) { showGraphs = false } } }
            )
            .allowsHitTesting(false)
        }
        .sheet(isPresented: $showSettings) { SettingsPanel(telemetry: telemetry) }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            applyBrightness()
            telemetry.start()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "stress") { Stress.start() }
            // Layout checks in the Simulator: `-orientation left` or `-orientation right`.
            if let side = UserDefaults.standard.string(forKey: "orientation"),
               let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: side == "left" ? .landscapeLeft : .landscapeRight))
            }
            #endif
            weather.start()
            if live == nil { live = LiveFeed(telemetry: telemetry) }
            updateLive()
            if server == nil {
                server = FeedServer(store: feed)
                server?.recorder = gestures.recorder
                server?.gestures = gestures
                server?.start()
            }
        }
        .onReceive(clock) { _ in
            let night = DeskView.nightNow()
            if night != isNight {
                withAnimation(.easeInOut(duration: 3)) { isNight = night }
                if night { showGraphs = false }
                updateLive()
            }
            // Re-applied every tick: iOS Auto-Brightness would otherwise drift it back down.
            applyBrightness()
        }
        .onChange(of: scenePhase) { updateLive() }
        .task(id: showGraphs) {
            guard showGraphs else { return }
            try? await Task.sleep(for: DeskView.graphsTimeout)
            if !Task.isCancelled { withAnimation { showGraphs = false } }
        }
        .onReceive(drift) { _ in
            withAnimation(.easeInOut(duration: DeskView.driftDuration)) {
                offset = CGSize(width: .random(in: -DeskView.driftRange...DeskView.driftRange),
                                height: .random(in: -DeskView.driftRange...DeskView.driftRange))
            }
        }
    }

    /// 10 Hz polling only while the screen is showing something: not at night, not in the background.
    /// The 60 s telemetry (which drives the charging rule) runs regardless.
    private func updateLive() {
        if scenePhase == .active && !isNight { live?.start() } else { live?.stop() }
        // The camera only watches for gestures while the desk is awake and on screen.
        if scenePhase == .active && !isNight { gestures.start() } else { gestures.stop() }
    }

    static func nightNow(_ date: Date = .now) -> Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "forceDay") { return false }   // `-forceDay 1` for tests
        #endif
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= nightStartHour || hour < nightEndHour
    }

    private func applyBrightness() {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }.first
        screen?.brightness = isNight ? 0 : DeskView.dayBrightness
    }
}
