#if DEBUG
import Darwin
import Foundation

/// Heat test only (debug builds): what this app is costing the phone, for the Mac dashboard.
/// iOS doesn't let apps read the whole phone's CPU or GPU load, so this is the app's own share.
enum Metrics {
    /// This app's CPU use as a share of the whole phone (all cores = 100%), and its thread count.
    static func cpu() -> (percent: Double, threads: Int) {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return (0, 0) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var size = mach_msg_type_number_t(THREAD_INFO_MAX)
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &size)
                }
            }
            if ok == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE)
            }
        }
        return (total / Double(ProcessInfo.processInfo.activeProcessorCount) * 100, Int(count))
    }

    /// Memory the app is using (what iOS counts against it), in MB.
    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
            }
        }
        return ok == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    @MainActor static var json: String {
        let (cpu, threads) = cpu()
        var body: [String: Any] = [
            "cpu_pct": (cpu * 10).rounded() / 10,
            "cores": ProcessInfo.processInfo.activeProcessorCount,
            "threads": threads,
            "mem_mb": memoryMB().rounded(),
            "stress": Stress.running,
            "llm": LLMStress.state,
            "llm_tps": (LLMStress.tokensPerSecond * 10).rounded() / 10,
        ]
        body["gpu_stress_pct"] = Stress.running ? (Stress.gpuBusy * 1000).rounded() / 10 : NSNull()
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
