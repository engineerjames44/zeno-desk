import Foundation
import Observation
import Vision

/// Records labelled hand points for training a custom gesture model in Create ML (Activity Classifier).
/// Only numbers are saved: 21 hand points per frame plus where the hand is. Never an image.
/// Files: Documents/recordings/<label>/<label>_<time>.csv, one recording per file.
@MainActor @Observable
final class GestureRecorder {
    static let labels = ["palm", "pinch", "swipe_left", "swipe_right", "none"]
    static let countdown = 3

    enum State: Equatable {
        case idle
        case countingDown(label: String, secondsLeft: Int)
        case recording(label: String, until: Date)
    }

    private(set) var state = State.idle
    private(set) var lastSaved: String?
    private var rows: [String] = []
    private var job: Task<Void, Never>?

    /// The 21 Vision hand joints, in a fixed order for the CSV columns.
    nonisolated static let joints: [VNHumanHandPoseObservation.JointName] = [
        .wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    /// hand (1/0), which hand (1 right, -1 left, 0 unsure), where the hand is (wrist x, y in the frame),
    /// then each joint relative to the wrist, scaled by hand size, so the pose looks the same near or far.
    static let header: String = {
        let names = ["wrist", "thumb_cmc", "thumb_mp", "thumb_ip", "thumb_tip",
                     "index_mcp", "index_pip", "index_dip", "index_tip",
                     "middle_mcp", "middle_pip", "middle_dip", "middle_tip",
                     "ring_mcp", "ring_pip", "ring_dip", "ring_tip",
                     "little_mcp", "little_pip", "little_dip", "little_tip"]
        return (["t", "hand", "which_hand", "hand_x", "hand_y"] + names.flatMap { ["\($0)_x", "\($0)_y"] }).joined(separator: ",")
    }()

    nonisolated static let noHand = [Float](repeating: 0, count: 4 + 42)

    nonisolated static func features(_ points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint],
                                     wrist: CGPoint, knuckles: CGPoint,
                                     chirality: VNChirality) -> [Float] {
        let size = max(hypot(wrist.x - knuckles.x, wrist.y - knuckles.y), 0.001)
        let which: Float = switch chirality {
        case .right: 1
        case .left: -1
        default: 0
        }
        var out: [Float] = [1, which, Float(wrist.x), Float(wrist.y)]
        for joint in joints {
            if let p = points[joint], p.confidence > 0.2 {
                out += [Float((p.location.x - wrist.x) / size), Float((p.location.y - wrist.y) / size)]
            } else {
                out += [0, 0]
            }
        }
        return out
    }

    /// Long sessions are saved as one file per minute, so each minute counts as its own recording.
    static let chunkSeconds = 60

    /// 3-2-1 on the phone's screen, then records for `seconds` (up to 10 minutes).
    func start(label: String, seconds: Int) {
        guard Self.labels.contains(label), (2...600).contains(seconds), state == .idle else { return }
        job = Task {
            for left in stride(from: Self.countdown, to: 0, by: -1) {
                state = .countingDown(label: label, secondsLeft: left)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { state = .idle; return }
            }
            let end = Date.now.addingTimeInterval(TimeInterval(seconds))
            state = .recording(label: label, until: end)
            while !Task.isCancelled, Date.now < end {
                rows = []
                let chunk = min(TimeInterval(Self.chunkSeconds), end.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(chunk))
                if Task.isCancelled { break }
                save(label: label)
            }
            state = .idle
        }
    }

    func cancel() {
        job?.cancel()
        rows = []
        state = .idle
    }

    func add(_ features: [Float]) {
        guard case .recording = state else { return }
        let t = String(format: "%.3f", Date.now.timeIntervalSince1970)
        rows.append(([t] + features.map { String(format: "%.4f", $0) }).joined(separator: ","))
    }

    private func save(label: String) {
        guard !rows.isEmpty else { return }
        let dir = Self.folder.appending(path: label)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .dateSeparator(.omitted).timeSeparator(.omitted))
        let name = "\(label)_\(stamp).csv"
        let csv = ([Self.header] + rows).joined(separator: "\n") + "\n"
        try? csv.write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
        lastSaved = "\(label)/\(name) (\(rows.count) frames)"
        rows = []
    }

    static var folder: URL { URL.documentsDirectory.appending(path: "recordings") }

    /// Every saved recording, as "label/file.csv".
    static func list() -> [String] {
        labels.flatMap { label in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: label).path())) ?? [])
                .filter { $0.hasSuffix(".csv") }.sorted().map { "\(label)/\($0)" }
        }
    }

    /// One recording's CSV, for the Mac dashboard to save. Names are checked so nothing else can be read.
    static func file(_ name: String) -> String? {
        let parts = name.split(separator: "/").map(String.init)
        guard parts.count == 2, labels.contains(parts[0]),
              parts[1].hasSuffix(".csv"), !parts[1].contains(".."),
              parts[1].allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) else { return nil }
        return try? String(contentsOf: folder.appending(path: parts[0]).appending(path: parts[1]), encoding: .utf8)
    }
}

import SwiftUI

/// Big, readable prompt on the phone while recording training data, so you know when to start and stop.
struct RecordingOverlay: View {
    let recorder: GestureRecorder

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            switch recorder.state {
            case .idle:
                EmptyView()
            case .countingDown(let label, let left):
                prompt(title: Self.name(label), detail: "starting in \(left)", color: DayPanel.text)
            case .recording(let label, let until):
                prompt(title: "● " + Self.name(label),
                       detail: label == "none" ? "just do normal desk things · \(Self.left(until, context.date))s"
                                               : "keep doing it · \(Self.left(until, context.date))s",
                       color: .red)
            }
        }
    }

    private func prompt(title: String, detail: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 34, weight: .medium, design: .monospaced)).foregroundStyle(color)
            Text(detail).font(.system(.callout, design: .monospaced)).foregroundStyle(DayPanel.faint)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.08)))
    }

    static func name(_ label: String) -> String {
        switch label {
        case "swipe_left": "Swipe left"
        case "swipe_right": "Swipe right"
        case "none": "No gesture"
        default: label.capitalized
        }
    }

    static func left(_ until: Date, _ now: Date) -> Int { max(0, Int(until.timeIntervalSince(now).rounded(.up))) }
}
