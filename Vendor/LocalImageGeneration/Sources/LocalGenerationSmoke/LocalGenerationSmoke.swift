import Foundation
import ImageIO
import LocalImageGeneration
import UniformTypeIdentifiers

@main
struct LocalGenerationSmoke {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else {
            print("Usage: LocalGenerationSmoke <model-directory> <safety.mlmodelc> <output-directory>")
            return
        }
        let output = URL(fileURLWithPath: args[3], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let generator = LocalFluxGenerator(modelDirectory: URL(fileURLWithPath: args[1]),
            safetyModelURL: URL(fileURLWithPath: args[2]))
        let prompts = [
            "A still life photograph of a red apple next to a blue ceramic mug on a wooden table, soft window light, realistic photography.",
            "A cinematic photo of a small robot walking in Tokyo at night, neon reflections, detailed.",
            "A portrait photograph of an adult woman wearing a winter coat and scarf in a public park, natural daylight."
        ]
        var records: [[String: Any]] = []
        for (index, prompt) in prompts.enumerated() {
            let start = Date()
            do {
                let checked = try await generator.generate(prompt: prompt, seed: UInt32(42 + index)) { stage in
                    switch stage {
                    case .preparing: print("Preparing")
                    case .denoising(let step, let total): print("Step \(step)/\(total)")
                    case .checkingSafety: print("Checking image safety")
                    }
                }
                let file = output.appendingPathComponent("safe-\(index + 1).png")
                guard let destination = CGImageDestinationCreateWithURL(file as CFURL,
                    UTType.png.identifier as CFString, 1, nil) else { throw GenerationError.invalidOutput }
                CGImageDestinationAddImage(destination, checked.cgImage, nil)
                guard CGImageDestinationFinalize(destination) else { throw GenerationError.invalidOutput }
                records.append(["case": index + 1, "status": "approved", "seconds": Date().timeIntervalSince(start),
                    "width": checked.cgImage.width, "height": checked.cgImage.height,
                    "safetyRevision": checked.safetyRevision,
                    "views": checked.decisions.map { ["sfw": $0.sfw, "nsfw": $0.nsfw, "nsfl": $0.nsfl] }])
                print("Approved case \(index + 1): \(Date().timeIntervalSince(start)) seconds")
            } catch {
                records.append(["case": index + 1, "status": "no-output", "seconds": Date().timeIntervalSince(start),
                                "error": error.localizedDescription])
                print("No output for case \(index + 1): \(error.localizedDescription)")
            }
            let report = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            try report.write(to: output.appendingPathComponent("report.json"), options: .atomic)
        }
        await generator.unload()
    }
}
