// Train the baseline gesture model with Create ML's Activity Classifier (the same engine as the Create ML app).
// Run:  swift ml/train_createml.swift      (after python3 ml/prepare_createml.py)
// In:   ml/createml/train/<label>/*.csv, ml/createml/test/<label>/*.csv (one CSV per recording)
// Out:  ml/ZenoGestures.mlmodel, plus accuracy and a confusion table for the write-up.
import CreateML
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let trainDir = root.appending(path: "createml/train")
let testDir = root.appending(path: "createml/test")
let windowFrames = 10   // one decision per 1 s of frames (10 fps)

// Feature columns: everything in the CSV except wrist_x / wrist_y, which are always 0
// (every point is measured from the wrist).
let header = try String(contentsOf: try FileManager.default
    .contentsOfDirectory(at: trainDir.appending(path: "palm"), includingPropertiesForKeys: nil)
    .first { $0.pathExtension == "csv" }!, encoding: .utf8).split(separator: "\n")[0]
let features = header.split(separator: ",").map(String.init).filter { !["t", "wrist_x", "wrist_y"].contains($0) }
print("features: \(features.count)")

let started = Date()
// The held-out test recordings go in as validation data: Create ML only scores them, it never learns from them.
let parameters = MLActivityClassifier.ModelParameters(validationData: .labeledDirectories(at: testDir),
                                                      batchSize: 32, maximumIterations: 40,
                                                      predictionWindowSize: windowFrames)
let model = try MLActivityClassifier(trainingData: .labeledDirectories(at: trainDir), featureColumns: features,
                                     parameters: parameters)
print(String(format: "trained in %.0f s", Date().timeIntervalSince(started)))

let trainAcc = (1 - model.trainingMetrics.classificationError) * 100
let testAcc = (1 - model.validationMetrics.classificationError) * 100
print(String(format: "\nACCURACY  training %.1f%%   TEST, recordings it never saw: %.1f%%", trainAcc, testAcc))
print("\nconfusion on the test recordings (True Label = what you did, Predicted = what the model said):")
print(model.validationMetrics.confusion)
print("\nper gesture (precision = when it says X, how often it's right; recall = of all the X you did, how many it caught):")
print(model.validationMetrics.precisionRecall)

let out = root.appending(path: "ZenoGestures.mlmodel")
try model.write(to: out, metadata: MLModelMetadata(author: "James Cronin",
    shortDescription: "Zeno Desk hand gestures from Apple Vision hand points, 1 s windows at 10 fps", version: "1"))
print("\nsaved \(out.path())")
