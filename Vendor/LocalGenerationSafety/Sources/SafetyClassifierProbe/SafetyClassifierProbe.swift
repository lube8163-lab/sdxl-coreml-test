import Foundation
import ImageIO
import LocalGenerationSafety

@main struct SafetyClassifierProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { print("Usage: SafetyClassifierProbe <safety.mlmodelc> <image>"); return }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageSafetyError.invalidResult }
        let checker = ImageSafetyChecker(modelURL: URL(fileURLWithPath: args[1]))
        do {
            let result = try await checker.check(image)
            print("APPROVED \(result.safetyRevision) views=\(result.decisions.count)")
        } catch { print("NO_OUTPUT \(error.localizedDescription)") }
    }
}
