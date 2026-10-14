import CoreAI
import CryptoKit
import Darwin
import Foundation
import ImageIO
import LocalImageGeneration
import MemoryProbeCounters
import Metal
import UniformTypeIdentifiers

@main
struct FluxMemoryRetest {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 5 else {
            print("Usage: FluxMemoryRetest generate <models> <safety.mlmodelc> <fresh-output> | component <asset.aimodel> <gpu|reshape|cpu|summary> <fresh-output>")
            return
        }
        let output = URL(fileURLWithPath: args[4], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ProbeError.existingOutput }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        setenv("MIM_FLUX_EVENT_PATH", output.appendingPathComponent("runtime-events.jsonl").path, 1)
        let sampler = try MemorySampler(csv: output.appendingPathComponent("memory.csv"))
        defer { sampler.stop() }
        let device = MTLCreateSystemDefaultDevice()
        var records: [[String: Any]] = []
        func checkpoint(_ phase: String, _ fields: [String: Any] = [:]) throws {
            sampler.setPhase(phase)
            var item = fields; item["phase"] = phase; item["uptimeSeconds"] = ProcessInfo.processInfo.systemUptime
            records.append(item)
            let memory = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sampler.snapshot()))
            let report: [String: Any] = ["platform": "Mac; not a six-GB iPhone emulation",
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
                "mode": args[1], "gpu": device?.name ?? "unavailable",
                "maxBufferLength": device?.maxBufferLength ?? 0,
                "recommendedMaxWorkingSetSize": device?.recommendedMaxWorkingSetSize ?? 0,
                "memory": memory, "records": records,
                "counterScope": "Footprint, RSS and Metal are overlapping different metrics; do not add. Metal counter is from the default device object. Lifetime footprint peak covers the entire process. Sampling can miss spikes; prior disk compilation caches may exist."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("report.json"), options: .atomic)
            print("RETEST \(phase) \(fields)"); fflush(stdout)
        }
        try checkpoint("start")
        do {
            if args[1] == "component" {
                let url = URL(fileURLWithPath: args[2])
                if args[3] == "summary" {
                    try checkpoint("asset-summary-begin")
                    let asset = try AIModelAsset(contentsOf: url)
                    guard let summary = try asset.summary(includingStatistics: false) else { throw ProbeError.noFunction }
                    try checkpoint("asset-summary-end", ["functions": summary.functions.map(\.name)])
                } else {
                    var options = args[3] == "cpu" ? SpecializationOptions.cpuOnly : SpecializationOptions(preferredComputeUnitKind: .gpu)
                    options.expectFrequentReshapes = args[3] == "reshape"
                    try checkpoint("model-load-begin", ["specialization": args[3]])
                    let model = try await AIModel(contentsOf: url, options: options)
                    try checkpoint("model-load-end", ["functions": model.functionNames])
                    try checkpoint("function-load-begin")
                    guard let function = try model.loadFunction(named: "main") else { throw ProbeError.noFunction }
                    try checkpoint("function-load-end", ["inputs": function.descriptor.inputNames, "outputs": function.descriptor.outputNames])
                    try await Task.sleep(for: .seconds(1))
                    withExtendedLifetime((model, function)) {}
                }
            } else if args[1] == "generate" {
                let generator = LocalFluxGenerator(modelDirectory: URL(fileURLWithPath: args[2]),
                    safetyModelURL: URL(fileURLWithPath: args[3]), resourcePolicy: .keepWarm)
                let prompt = "A still life photograph of a red apple next to a blue ceramic mug on a wooden table, soft window light, realistic photography."
                let begin = ProcessInfo.processInfo.systemUptime
                try checkpoint("preparation-begin")
                try await generator.prepare(prompt: prompt)
                try checkpoint("preparation-end", ["seconds": ProcessInfo.processInfo.systemUptime - begin])
                for index in 0..<2 {
                    let label = index == 0 ? "first" : "repeat"
                    try checkpoint(label + "-begin")
                    let start = ProcessInfo.processInfo.systemUptime
                    let checked = try await generator.generate(prompt: prompt, seed: 42) { stage in
                        sampler.setPhase(label + "-" + String(describing: stage))
                    }
                    let seconds = ProcessInfo.processInfo.systemUptime - start
                    guard let pixels = checked.cgImage.dataProvider?.data,
                          let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(label + ".png") as CFURL,
                            UTType.png.identifier as CFString, 1, nil) else { throw ProbeError.invalidImage }
                    CGImageDestinationAddImage(destination, checked.cgImage, nil)
                    guard CGImageDestinationFinalize(destination) else { throw ProbeError.invalidImage }
                    let hash = SHA256.hash(data: pixels as Data).map { String(format: "%02x", $0) }.joined()
                    try checkpoint(label + "-approved", ["secondsIncludingSafety": seconds, "pixelSHA256": hash,
                        "safetyViews": checked.decisions.count, "seed": 42, "width": 512, "height": 512, "steps": 4])
                }
                try checkpoint("unload-begin")
                await generator.unload()
                try checkpoint("unload-end")
            } else { throw ProbeError.invalidMode }
            let final = sampler.stop()
            try checkpoint("complete", ["samplerWriteError": final.writeError ?? ""])
        } catch {
            sampler.stop()
            try checkpoint("failed", ["error": error.localizedDescription])
            exit(EXIT_FAILURE)
        }
    }
    enum ProbeError: Error { case existingOutput, noFunction, invalidImage, invalidMode }
}
