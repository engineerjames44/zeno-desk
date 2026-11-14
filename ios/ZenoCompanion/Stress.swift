#if DEBUG
import Foundation
import Metal
import QuartzCore
import simd

/// Heat test only (debug builds): `-stress 1` runs every CPU core flat out on vector maths and keeps
/// the GPU busy with a heavy compute kernel, roughly what running an LLM on the phone would do.
enum Stress {
    nonisolated(unsafe) private static var sink = SIMD8<Float>()
    /// Read by the worker threads between batches; they exit once it goes false.
    nonisolated(unsafe) private(set) static var running = false
    /// Share of wall time the GPU spent on the stress kernel (0–1), measured from Metal's own timestamps.
    nonisolated(unsafe) private(set) static var gpuBusy = 0.0

    static func stop() { running = false }

    static func start() {
        guard !running else { return }
        running = true
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            let thread = Thread {
                var a = SIMD8<Float>(repeating: 1.0001), b = SIMD8<Float>(repeating: 0.9999)
                let c = SIMD8<Float>(repeating: 0.000_001)
                while running {
                    for _ in 0..<2_000_000 {
                        a = a * b + c
                        b = b * a - c
                    }
                    sink = a + b   // keeps the optimiser from deleting the loop
                    a = SIMD8<Float>(repeating: 1.0001); b = SIMD8<Float>(repeating: 0.9999)
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }
        startGPU()
    }

    private static let kernel = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        float x = float(id) * 0.0001 + 1.0;
        for (int i = 0; i < 20000; i++) { x = fma(x, 0.999999, 0.000001); x = sin(x) * cos(x) + x; }
        out[id] = x;
    }
    """

    private static func startGPU() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeLibrary(source: kernel, options: nil),
              let function = library.makeFunction(name: "burn"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let queue = device.makeCommandQueue() else { return }
        let count = 1 << 18
        guard let out = device.makeBuffer(length: count * MemoryLayout<Float>.size) else { return }
        let thread = Thread {
            while running {
                guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else { return }
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(out, offset: 0, index: 0)
                encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
                encoder.endEncoding()
                let wallStart = CACurrentMediaTime()
                buffer.commit()
                buffer.waitUntilCompleted()
                let wall = CACurrentMediaTime() - wallStart
                if wall > 0 { gpuBusy = gpuBusy * 0.8 + min((buffer.gpuEndTime - buffer.gpuStartTime) / wall, 1) * 0.2 }
            }
            gpuBusy = 0
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
#endif
