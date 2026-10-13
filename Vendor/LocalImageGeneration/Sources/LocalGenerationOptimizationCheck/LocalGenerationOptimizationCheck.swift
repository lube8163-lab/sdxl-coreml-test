import CryptoKit
import Darwin
import Foundation
import ImageIO
import LocalImageGeneration
import Metal
import UniformTypeIdentifiers

/// Uses the shipping generation and safety gate. Every saved image has already
/// passed the six-view classifier. Comparisons keep model, steps and seeds fixed.
@main
struct LocalGenerationOptimizationCheck {
    struct Sample: Codable {
        let label: String
        let seed: UInt32
        let secondsIncludingSafety: Double
        let pixelSHA256: String
        let safetyRevision: String
        let safetyViews: Int
        let physFootprintBytes: UInt64
        let metalAllocatedBytes: Int
    }

    struct Run: Codable {
        let preparationSeconds: Double
        let totalSecondsIncludingPreparation: Double
        let samples: [Sample]
    }

    struct Report: Codable {
        let platform: String
        let osVersion: String
        let physicalMemoryBytes: UInt64
        let steps: Int
        let width: Int
        let height: Int
        let baseline: Run
        let optimized: Run
        let allMatchingPixels: Bool
        let differentSeedChangesPixels: Bool
        let afterIdle: Sample
        let afterFullUnload: Sample
        let warmRetentionSeconds: Int
    }

    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            print("Usage: LocalGenerationOptimizationCheck <model-directory> <safety.mlmodelc> <output-directory>")
            return
        }
        let directory = URL(fileURLWithPath: arguments[3], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let modelURL = URL(fileURLWithPath: arguments[1])
        let safetyURL = URL(fileURLWithPath: arguments[2])
        let apple = "A still life photograph of a red apple next to a blue ceramic mug on a wooden table, soft window light, realistic photography."
        let robot = "A cinematic photo of a small robot walking in Tokyo at night, neon reflections, detailed."
        let cases: [(String, String, UInt32)] = [
            ("first", apple, 42), ("repeat", apple, 42),
            ("new-prompt", robot, 43), ("cached-prompt-new-seed", apple, 44)
        ]

        let baselineGenerator = LocalFluxGenerator(modelDirectory: modelURL, safetyModelURL: safetyURL,
                                                   resourcePolicy: .releaseAfterGeneration)
        let baseline = try await run(baselineGenerator, name: "baseline", cases: cases,
                                     preparePrompt: nil, output: directory)
        await baselineGenerator.unload()

        let optimizedGenerator = LocalFluxGenerator(modelDirectory: modelURL, safetyModelURL: safetyURL)
        let optimized = try await run(optimizedGenerator, name: "optimized", cases: cases,
                                      preparePrompt: apple, output: directory)
        print("CHECK waiting for the 30-second idle release")
        fflush(stdout)
        try await Task.sleep(for: .seconds(LocalFluxGenerator.warmRetentionSeconds + 2))
        let afterIdle = try await generate(optimizedGenerator, prompt: apple, seed: 42,
                                          label: "after-idle", output: directory)
        await optimizedGenerator.unload()
        let afterFullUnload = try await generate(optimizedGenerator, prompt: apple, seed: 42,
                                                label: "after-full-unload", output: directory)
        await optimizedGenerator.unload()

        let referenceHash = baseline.samples[0].pixelSHA256
        let matching = zip(baseline.samples, optimized.samples).allSatisfy { $0.pixelSHA256 == $1.pixelSHA256 }
            && baseline.samples[1].pixelSHA256 == referenceHash
            && afterIdle.pixelSHA256 == referenceHash && afterFullUnload.pixelSHA256 == referenceHash
        let changed = optimized.samples[0].pixelSHA256 != optimized.samples[3].pixelSHA256
        let report = Report(platform: "Mac CLI using the shipping generation/safety library; not an iPhone measurement",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            steps: 4, width: 512, height: 512, baseline: baseline, optimized: optimized,
            allMatchingPixels: matching, differentSeedChangesPixels: changed,
            afterIdle: afterIdle, afterFullUnload: afterFullUnload,
            warmRetentionSeconds: LocalFluxGenerator.warmRetentionSeconds)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        guard matching, changed, optimized.samples.allSatisfy({ $0.safetyViews == 6 }) else {
            throw CheckError.mismatch
        }
        print("CHECK PASSED: baseline/optimized pixels match, seeds remain independent, every output checked")
    }

    static func run(_ generator: LocalFluxGenerator, name: String, cases: [(String, String, UInt32)],
                    preparePrompt: String?, output: URL) async throws -> Run {
        let start = Date()
        // Both paths load/validate the classifier and immutable model metadata.
        // Only the optimized path pre-encodes its first prompt. Report that cost.
        try await generator.prepare(prompt: preparePrompt)
        let preparation = Date().timeIntervalSince(start)
        print("CHECK \(name) preparation \(preparation) seconds")
        fflush(stdout)
        var samples: [Sample] = []
        for (label, prompt, seed) in cases {
            samples.append(try await generate(generator, prompt: prompt, seed: seed,
                                              label: "\(name)-\(label)", output: output))
        }
        return Run(preparationSeconds: preparation, totalSecondsIncludingPreparation: Date().timeIntervalSince(start),
                   samples: samples)
    }

    static func generate(_ generator: LocalFluxGenerator, prompt: String, seed: UInt32,
                         label: String, output: URL) async throws -> Sample {
        print("CHECK start \(label)")
        fflush(stdout)
        let start = Date()
        let image = try await generator.generate(prompt: prompt, seed: seed) { stage in
            if case .checkingSafety = stage { print("CHECK \(label) safety") }
        }
        let seconds = Date().timeIntervalSince(start)
        let file = output.appendingPathComponent("\(label).png")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL,
            UTType.png.identifier as CFString, 1, nil),
            let pixels = image.cgImage.dataProvider?.data else { throw GenerationError.invalidOutput }
        CGImageDestinationAddImage(destination, image.cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw GenerationError.invalidOutput }
        let hash = SHA256.hash(data: pixels as Data).map { String(format: "%02x", $0) }.joined()
        let sample = Sample(label: label, seed: seed, secondsIncludingSafety: seconds,
            pixelSHA256: hash, safetyRevision: image.safetyRevision, safetyViews: image.decisions.count,
            physFootprintBytes: footprint(), metalAllocatedBytes: MTLCreateSystemDefaultDevice()?.currentAllocatedSize ?? 0)
        print("CHECK approved \(label) \(seconds) seconds; pixels \(hash)")
        fflush(stdout)
        return sample
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    enum CheckError: Error { case mismatch }
}
