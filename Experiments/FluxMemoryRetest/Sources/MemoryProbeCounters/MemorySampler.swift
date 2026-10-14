import Darwin
import Foundation
import Metal

/// Test instrumentation only. A separate serial queue samples while an actor is
/// inside native model compilation. Counters overlap and must never be summed.
public final class MemorySampler: @unchecked Sendable {
    public struct Totals: Codable, Sendable {
        public var samples = 0
        public var maxFootprintBytes: UInt64 = 0
        public var maxResidentBytes: UInt64 = 0
        public var maxLifetimeFootprintBytes: UInt64 = 0
        public var maxMetalAllocatedBytes: UInt64 = 0
        public var maxSampleGapSeconds: Double = 0
    }
    public struct Report: Codable, Sendable {
        public let requestedIntervalSeconds: Double
        public let overall: Totals
        public let phases: [String: Totals]
        public let writeError: String?
    }
    private let queue = DispatchQueue(label: "local-image-generation.memory-probe", qos: .utility)
    private let timer: DispatchSourceTimer
    private let output: FileHandle
    private let device: (any MTLDevice)?
    private let interval: Double
    private var phase = "startup"
    private var closed = false
    private var lastUptime: Double?
    private var overall = Totals()
    private var phases: [String: Totals] = [:]
    private var writeError: String?

    public init(csv: URL, interval: Double = 0.05) throws {
        guard interval >= 0.01, !FileManager.default.fileExists(atPath: csv.path) else {
            throw NSError(domain: "MemorySampler", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Choose a fresh output path and interval >= 10 ms."])
        }
        self.interval = interval
        device = MTLCreateSystemDefaultDevice()
        FileManager.default.createFile(atPath: csv.path, contents: Data(
            "uptime_seconds,phase,footprint_bytes,resident_bytes,lifetime_max_footprint_bytes,metal_allocated_bytes,available_process_memory_bytes\n".utf8))
        output = try FileHandle(forWritingTo: csv)
        try output.seekToEnd()
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }
    public func setPhase(_ value: String) {
        queue.sync {
            phase = value.replacingOccurrences(of: ",", with: "_").replacingOccurrences(of: "\n", with: "_")
            sample()
        }
    }
    public func snapshot() -> Report { queue.sync { report() } }
    @discardableResult public func stop() -> Report {
        timer.cancel()
        return queue.sync {
            if !closed {
                sample()
                try? output.synchronize()
                try? output.close()
                closed = true
            }
            return report()
        }
    }
    private func report() -> Report {
        Report(requestedIntervalSeconds: interval, overall: overall, phases: phases, writeError: writeError)
    }
    private func sample() {
        guard !closed else { return }
        autoreleasepool {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { writeError = "task_info failed: \(result)"; return }
            let uptime = ProcessInfo.processInfo.systemUptime
            let gap = lastUptime.map { uptime - $0 } ?? 0
            lastUptime = uptime
            let metal = UInt64(device?.currentAllocatedSize ?? 0)
            #if os(iOS)
            let available = String(os_proc_available_memory())
            #else
            let available = ""
            #endif
            func update(_ total: inout Totals) {
                total.samples += 1
                total.maxFootprintBytes = max(total.maxFootprintBytes, info.phys_footprint)
                total.maxResidentBytes = max(total.maxResidentBytes, info.resident_size)
                total.maxLifetimeFootprintBytes = max(total.maxLifetimeFootprintBytes, UInt64(max(0, info.ledger_phys_footprint_peak)))
                total.maxMetalAllocatedBytes = max(total.maxMetalAllocatedBytes, metal)
                total.maxSampleGapSeconds = max(total.maxSampleGapSeconds, gap)
            }
            update(&overall)
            var totals = phases[phase] ?? Totals(); update(&totals); phases[phase] = totals
            do {
                try output.write(contentsOf: Data("\(uptime),\(phase),\(info.phys_footprint),\(info.resident_size),\(UInt64(max(0, info.ledger_phys_footprint_peak))),\(metal),\(available)\n".utf8))
            } catch { writeError = "CSV write failed" }
        }
    }
}
