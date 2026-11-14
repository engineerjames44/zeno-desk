#if DEBUG
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Heat test only (debug builds): runs a real LLM on the phone non-stop.
/// Llama 3.2 1B Instruct, 4-bit (about 700 MB), downloaded once from Hugging Face and kept on the phone.
@MainActor
enum LLMStress {
    static let model = LLMRegistry.llama3_2_1B_4bit

    /// off | downloading 42% | loading | running | error: …
    private(set) static var state = "off"
    private(set) static var tokensPerSecond = 0.0
    private(set) static var tokens = 0
    /// The last few hundred characters it wrote, for the dashboard.
    private(set) static var tail = ""

    private static var task: Task<Void, Never>?
    private static var container: ModelContainer?

    private static let prompts = [
        "Write a short story about a robot that lives on a desk and watches the weather.",
        "Explain how a lithium-ion battery ages, and why keeping it between 40% and 80% helps.",
        "Describe Boston in November to someone who has never been there.",
        "Write a long poem about a small orange creature made of pixels.",
        "Explain step by step how an ESP32 could control a relay over Wi-Fi.",
    ]

    static func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    static func stop() {
        task?.cancel()
        task = nil
        state = "off"
        tokensPerSecond = 0
    }

    private static func run() async {
        do {
            if container == nil {
                Memory.cacheLimit = 32 * 1024 * 1024   // keep MLX's GPU buffer cache small on a phone
                state = "downloading 0%"
                container = try await #huggingFaceLoadModelContainer(configuration: model) { progress in
                    let percent = Int(progress.fractionCompleted * 100)
                    Task { @MainActor in
                        if LLMStress.task != nil { LLMStress.state = percent >= 100 ? "loading" : "downloading \(percent)%" }
                    }
                }
            }
            guard let container else { return }
            state = "running"
            var round = 0
            while !Task.isCancelled {
                let session = ChatSession(container)
                let started = Date.now
                var count = 0
                tail = ""
                for try await chunk in session.streamResponse(to: prompts[round % prompts.count]) {
                    if Task.isCancelled { break }
                    count += 1
                    tokens += 1
                    tail = String((tail + chunk).suffix(300))
                    tokensPerSecond = Double(count) / max(Date.now.timeIntervalSince(started), 0.001)
                }
                round += 1
            }
        } catch {
            state = "error: \(error.localizedDescription)"
            task = nil
        }
    }

    static var json: String {
        let body: [String: Any] = ["state": state, "tokens_per_s": (tokensPerSecond * 10).rounded() / 10,
                                   "tokens": tokens, "tail": tail]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
