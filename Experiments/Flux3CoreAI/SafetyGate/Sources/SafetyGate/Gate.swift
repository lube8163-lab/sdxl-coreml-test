import Foundation
import CryptoKit
import CoreML
import ImageIO
import LocalGenerationSafety
import UniformTypeIdentifiers

private func emit(_ value: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    data.append(10)
    try FileHandle.standardOutput.write(contentsOf: data)
}

@main struct Gate {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("classifier URL, output directory, cases JSON required") }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[3]))) as! [String: Any]
        let cases = manifest["cases"] as! [[String: Any]]
        let policy = try ContentSafetyPolicy.bundled()
        for item in cases {
            try policy.validate((item["original_prompt"] as! String), context: .generationPrompt)
            try policy.validate((item["caption"] as! String), context: .generationPrompt)
        }
        let allowedIDs = Set(cases.map { $0["id"] as! String })
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: args[1])
        let modelURL: URL
        if source.pathExtension == "mlpackage" { modelURL = try await MLModel.compileModel(at: source) }
        else { modelURL = source }
        let checker = ImageSafetyChecker(modelURL: modelURL)
        try await checker.prepare()
        try emit(["ready": true, "input_safety_passed": true, "cases": cases.count])
        while let line = readLine() {
            let item = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let label = item["label"] as! String
            guard label.count < 160, label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  allowedIDs.contains(item["case_id"] as! String) else { throw ImageSafetyError.invalidResult }
            do {
                guard let bytes = Data(base64Encoded: item["png_base64"] as! String),
                      let decoder = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(decoder, 0, nil), image.width == 512, image.height == 512 else { throw ImageSafetyError.invalidResult }
                let approved = try await checker.check(image)
                let url = output.appendingPathComponent(label + ".png")
                guard !FileManager.default.fileExists(atPath: url.path),
                      let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ImageSafetyError.invalidResult }
                CGImageDestinationAddImage(writer, approved.cgImage, nil)
                guard CGImageDestinationFinalize(writer) else { throw ImageSafetyError.invalidResult }
                let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                try emit(["label": label, "approved": true, "filename": url.lastPathComponent, "sha256": hash,
                          "safety_revision": approved.safetyRevision,
                          "decisions": approved.decisions.map { ["sfw": $0.sfw, "nsfw": $0.nsfw, "nsfl": $0.nsfl] }])
            } catch {
                try emit(["label": label, "approved": false, "error": String(describing: error)])
            }
        }
    }
}
