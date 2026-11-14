import CoreML
import Foundation

/// James's own gesture model (ml/train_torch.py → ml/convert_coreml.py): a 21k-weight 1D-CNN that reads
/// the last second of hand points (10 frames x 45 numbers) and says none / palm / pinch / swipe left / right.
/// Cross-validated on his recordings: 96% of 1-second windows right, 4.9% false triggers (before the palm gate).
final class GestureModel: @unchecked Sendable {
    static let labels: [HandGestures.Gesture] = [.none, .palm, .pinch, .swipeLeft, .swipeRight]
    static let window = 10
    static let features = 45

    private let model: MLModel
    private var frames: [[Float]] = []
    private var previous: (x: Float, y: Float)?

    init?() {
        guard let url = Bundle.main.url(forResource: "ZenoGestures", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url) else { return nil }
        self.model = model
    }

    /// Adds one frame (the recorder's columns) and returns the model's probabilities once a full second is in.
    func add(_ recorder: [Float]) -> [Float]? {
        frames.append(Self.modelColumns(recorder, previous: &previous))
        if frames.count > Self.window { frames.removeFirst(frames.count - Self.window) }
        guard frames.count == Self.window,
              let input = try? MLMultiArray(shape: [1, NSNumber(value: Self.window), NSNumber(value: Self.features)], dataType: .float32)
        else { return nil }
        for (t, row) in frames.enumerated() {
            for (f, v) in row.enumerated() { input[t * Self.features + f] = NSNumber(value: v) }
        }
        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["frames": input])),
              let probs = out.featureValue(for: "probs")?.multiArrayValue else { return nil }
        return (0..<Self.labels.count).map { probs[$0].floatValue }
    }

    func reset() {
        frames.removeAll()
        previous = nil
    }

    /// Same columns as train_torch.frames(): hand, hand_x, hand_y, hand_dx, hand_dy, then the 20 joints
    /// (thumb_cmc … little_tip) x, y relative to the wrist. The recorder's row is
    /// hand, which_hand, hand_x, hand_y, wrist_x, wrist_y (always 0), thumb_cmc_x, …
    static func modelColumns(_ r: [Float], previous: inout (x: Float, y: Float)?) -> [Float] {
        let seen = r[0] > 0
        let x = seen ? r[2] : 0, y = seen ? r[3] : 0
        let dx = seen && previous != nil ? x - previous!.x : 0
        let dy = seen && previous != nil ? y - previous!.y : 0
        previous = seen ? (x, y) : nil
        return [seen ? 1 : 0, x, y, dx, dy] + Array(r[6...])
    }
}
