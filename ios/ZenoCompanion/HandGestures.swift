import AVFoundation
import Observation
import Vision

/// Touch-free control, step 1: the front camera looks for hand gestures with Apple Vision's hand pose.
/// Sensing only for now: it reports what it sees and triggers nothing. Gestures will never approve
/// a Zeno action (Face ID stays the only approval). Every frame is processed on the phone and dropped;
/// nothing is saved or sent. It runs at a low frame rate, only while the desk screen is awake.
@MainActor @Observable
final class HandGestures {
    enum Gesture: String { case none, palm, pinch, swipeLeft = "swipe left", swipeRight = "swipe right", hold = "palm held" }

    static let framesPerSecond: Int32 = 10
    /// An open palm "wakes" gestures for this long; swipes and pinches outside it are ignored.
    static let armedFor: TimeInterval = 4
    /// Holding the palm this long is its own gesture (opens the fan panel).
    static let holdFor: TimeInterval = 2
    /// After a hold, the next gesture counts for this long without another palm (to use the panel).
    static let panelFor: TimeInterval = 6

    /// The pose seen in the latest frame (palm, pinch or none).
    private(set) var pose = Gesture.none
    /// The last gesture that counted as an event, and when: what later steps will act on.
    private(set) var lastEvent: (gesture: Gesture, at: Date)?
    private(set) var running = false
    private(set) var problem: String?
    /// Where the hand is across the camera's view (0 = your left, 1 = your right), for tuning swipes.
    private(set) var handX: Double?
    /// The latest frame's hand points, in the recorder's column order (all zeros = no hand counted).
    /// For the dashboard's live skeleton: numbers only, never the image.
    private(set) var latestFeatures = GestureRecorder.noHand

    /// Gestures count until this time; set by an open palm, extended by each gesture.
    private(set) var armedUntil: Date?
    /// Swipes and pinches seen while not armed: the false triggers the palm gate stopped.
    private(set) var ignored = 0
    /// When the current unbroken run of palm frames began (nil when no palm is showing).
    private var palmHeldSince: Date?
    /// The current palm has already produced a "palm held" event.
    private var holdFired = false

    func isArmed(at date: Date = .now) -> Bool { armedUntil.map { date < $0 } ?? false }

    /// Records labelled hand points for training a gesture model (see GestureRecorder).
    let recorder = GestureRecorder()
    /// True when James's trained model is deciding (false = the hand-written rules).
    var usesModel: Bool { reader.usesModel }

    private let session = AVCaptureSession()
    private let reader = FrameReader()
    private var configured = false
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationWatch: NSKeyValueObservation?

    init() {
        reader.onResult = { [weak self] pose, swipe, x, features in
            Task { @MainActor in
                self?.handle(pose: pose, swipe: swipe, x: x)
                self?.recorder.add(features)
                self?.latestFeatures = features
            }
        }
    }

    func start() {
        guard !running else { return }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else { problem = "camera not allowed"; return }
            if !configured { configure() }
            guard configured else { return }
            running = true
            let session = self.session
            DispatchQueue.global(qos: .utility).async { session.startRunning() }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        pose = .none
        let session = self.session
        DispatchQueue.global(qos: .utility).async { session.stopRunning() }
    }

    private func configure() {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: camera) else { problem = "no front camera"; return }
        session.beginConfiguration()
        session.sessionPreset = .vga640x480   // small frames: plenty for a hand, less heat
        guard session.canAddInput(input) else { session.commitConfiguration(); problem = "camera busy"; return }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(reader, queue: DispatchQueue(label: "hand-gestures", qos: .utility))
        guard session.canAddOutput(output) else { session.commitConfiguration(); problem = "camera busy"; return }
        session.addOutput(output)
        if let connection = output.connection(with: .video) {
            connection.isVideoMirrored = true   // so "left" means left as you look at the phone
            // Turn the frames upright for however the phone is standing, so sideways is sideways.
            let rotation = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
            connection.videoRotationAngle = rotation.videoRotationAngleForHorizonLevelCapture
            nonisolated(unsafe) let watched = connection   // only its rotation is touched from here
            rotationWatch = rotation.observe(\.videoRotationAngleForHorizonLevelCapture) { coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                if watched.isVideoRotationAngleSupported(angle) { watched.videoRotationAngle = angle }
            }
            self.rotation = rotation
        }
        session.commitConfiguration()

        // Low frame rate keeps the phone cool.
        if (try? camera.lockForConfiguration()) != nil {
            let duration = CMTime(value: 1, timescale: Self.framesPerSecond)
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
            camera.unlockForConfiguration()
        }
        configured = true
    }

    private func handle(pose: Gesture, swipe: Gesture?, x: Double?) {
        self.pose = pose
        handX = x
        let now = Date.now
        if pose == .palm {
            // The wake gesture: arms swipes and pinches. It has to be held for half a second, and not
            // within 1.5 s of the last swipe or pinch, so a hand settling after a gesture can't re-arm.
            if palmHeldSince == nil { palmHeldSince = now }
            let settled = lastEvent.map { $0.gesture == .palm || now.timeIntervalSince($0.at) > 1.5 } ?? true
            let held = now.timeIntervalSince(palmHeldSince!)
            if settled, held >= Self.holdFor, !holdFired {
                // Palm held for 2 s: its own gesture. Gestures stay live long enough to use the panel.
                holdFired = true
                lastEvent = (.hold, now)
                armedUntil = now.addingTimeInterval(Self.panelFor)
            } else if settled, held >= 0.5, !holdFired {
                if !isArmed(at: now) { lastEvent = (.palm, now) }
                armedUntil = now.addingTimeInterval(Self.armedFor)
            }
        } else {
            palmHeldSince = nil
            holdFired = false
        }
        let event = swipe ?? (pose == .pinch ? .pinch : nil)
        guard let event else { return }
        guard isArmed(at: now) else { ignored += 1; return }
        if event == .pinch, lastEvent?.gesture == .pinch, now.timeIntervalSince(lastEvent!.at) < 1.5 { return }
        lastEvent = (event, now)
        // One palm buys one gesture: "ready" ends straight away, so a stray movement afterwards can't
        // trigger anything. The next gesture needs a fresh palm.
        armedUntil = nil
        palmHeldSince = nil
    }
}

/// Runs Vision on camera frames (off the main thread) and turns hand points into a pose.
private final class FrameReader: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onResult: ((HandGestures.Gesture, HandGestures.Gesture?, Double?, [Float]) -> Void)?

    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()
    private var lastPose = HandGestures.Gesture.none
    private var sameCount = 0
    /// James's trained model; nil only if it fails to load, then the hand-written rules below are used.
    private let model: GestureModel? = UserDefaults.standard.bool(forKey: "gestureRules") ? nil : GestureModel()
    var usesModel: Bool { model != nil }
    /// Recent wrist positions (x across the image, 0–1) for spotting swipes.
    private var track: [(x: CGFloat, t: TimeInterval)] = []
    private var lastSwipe: TimeInterval = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up)
        try? handler.perform([request])
        let now = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        // A blurry, fast-moving hand is often missed for a frame or two: keep the track going
        // through short gaps instead of starting again.
        // Only a hand close to the phone counts (wrist to knuckles at least 7% of the frame):
        // people and things further away are ignored.
        guard let hand = request.results?.first,
              let points = try? hand.recognizedPoints(.all),
              let wrist = points[.wrist], wrist.confidence > 0.2,
              let knuckles = points[.middleMCP], knuckles.confidence > 0.2,
              hypot(wrist.location.x - knuckles.location.x, wrist.location.y - knuckles.location.y) > 0.07 else {
            if let last = track.last, now - last.t > 0.5 { track.removeAll() }
            if useModel(GestureRecorder.noHand, x: nil, swipe: nil, now: now) { return }
            report(.none, swipe: nil, x: nil, features: GestureRecorder.noHand)
            return
        }

        let features = GestureRecorder.features(points, wrist: wrist.location, knuckles: knuckles.location,
                                                chirality: hand.chirality)

        // Swipe: the hand travels a sixth of the frame sideways within 0.8 s, measured from where it was
        // to where it is now. The track survives short blur gaps (a fast hand is often lost for a few
        // frames mid-swipe), so the big jump across the gap still counts. Uses the knuckles, which Vision
        // finds more reliably than fingertips in motion blur. Direction comes from this measurement, not
        // the model: with most of a fast swipe blurred, the model sees too few frames to judge direction.
        let x = knuckles.location.x
        track.append((x, now))
        track.removeAll { now - $0.t > 0.8 }
        var swipe: HandGestures.Gesture?
        if track.count >= 2, let lowest = track.min(by: { $0.x < $1.x }), let highest = track.max(by: { $0.x < $1.x }),
           highest.x - lowest.x > 0.17, now - lastSwipe > 1.0 {
            swipe = highest.t > lowest.t ? .swipeRight : .swipeLeft
            lastSwipe = now
            track.removeAll()
        }
        if useModel(features, x: Double(x), swipe: swipe, now: now) { return }
        report(Self.pose(points, wrist: wrist.location), swipe: swipe, x: Double(x),
               features: GestureRecorder.features(points, wrist: wrist.location, knuckles: knuckles.location,
                                                  chirality: hand.chirality))
    }

    /// Palm: all four fingertips well away from the wrist (fingers spread).
    /// Pinch: thumb tip touching index tip, compared with the hand's size.
    private static func pose(_ p: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint], wrist: CGPoint) -> HandGestures.Gesture {
        func pt(_ j: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let q = p[j], q.confidence > 0.3 else { return nil }
            return q.location
        }
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        guard let middleBase = pt(.middleMCP) else { return .none }
        let size = dist(wrist, middleBase)
        guard size > 0.02 else { return .none }

        if let thumb = pt(.thumbTip), let index = pt(.indexTip), dist(thumb, index) < 0.25 * size {
            return .pinch
        }
        let tips: [VNHumanHandPoseObservation.JointName] = [.indexTip, .middleTip, .ringTip, .littleTip]
        let bases: [VNHumanHandPoseObservation.JointName] = [.indexPIP, .middlePIP, .ringPIP, .littlePIP]
        var extended = 0
        for (tip, base) in zip(tips, bases) {
            if let t = pt(tip), let b = pt(base), dist(t, wrist) > dist(b, wrist) * 1.15 { extended += 1 }
        }
        return extended == 4 ? .palm : .none
    }

    /// The trained model's decision for this frame. Returns false when there's no model (rules run instead).
    /// It must be at least 80% sure of a pose, held for 2 frames. Swipes are passed in from the
    /// movement measurement. The palm gate in HandGestures still applies on top.
    private func useModel(_ features: [Float], x: Double?, swipe: HandGestures.Gesture?, now: TimeInterval) -> Bool {
        guard let model else { return false }
        guard let probs = model.add(features), let best = probs.indices.max(by: { probs[$0] < probs[$1] }) else {
            onResult?(.none, swipe, x, features)
            return true
        }
        // The model decides hand shapes (palm, pinch, nothing); swipes come from the measured movement.
        let gesture = GestureModel.labels[best]
        var pose = HandGestures.Gesture.none
        if gesture == .palm || gesture == .pinch, probs[best] >= 0.8 { pose = gesture }
        sameCount = pose == lastPose ? sameCount + 1 : 1
        lastPose = pose
        onResult?(sameCount >= 2 ? pose : .none, swipe, x, features)
        return true
    }

    private func report(_ pose: HandGestures.Gesture, swipe: HandGestures.Gesture?, x: Double?, features: [Float]) {
        sameCount = pose == lastPose ? sameCount + 1 : 1
        lastPose = pose
        // Held for 3 frames in a row (0.3 s at 10 fps) before it counts: cuts false triggers.
        onResult?(sameCount >= 3 ? pose : .none, swipe, x, features)
    }
}

import SwiftUI

/// Step 1 only: a small label showing what the camera sees, so James can check it before gestures do anything.
struct GestureBadge: View {
    let gestures: HandGestures
    /// Compact: status word only, fixed width, so it never shifts what's next to it (the graphs header).
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            HStack(spacing: 6) {
                Image(systemName: gestures.running ? "hand.raised" : "hand.raised.slash")
                if let problem = gestures.problem {
                    Text(problem)
                } else if let event = gestures.lastEvent, event.gesture != .palm, event.gesture != .hold,
                          context.date.timeIntervalSince(event.at) < 2 {
                    Text(event.gesture.rawValue).foregroundStyle(DayPanel.accent)
                } else if gestures.isArmed(at: context.date) {
                    Text("ready").foregroundStyle(DayPanel.accent)
                } else {
                    Text("show palm")
                }
                if !compact {
                    if gestures.ignored > 0 { Text("· \(gestures.ignored) ignored") }
                    Text(gestures.usesModel ? "· ml" : "· rules")
                }
                // Tuning aid: where the hand is, 0 = your left … 1 = your right.
                if !compact, let x = gestures.handX { Text(String(format: "x %.2f", x)) }
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(DayPanel.faint)
        }
    }
}
