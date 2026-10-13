// Bounded cache scoped to one immutable model pipeline.
// Retains CPU Float conditioning, never the heavy text encoder or a generated image.
#if canImport(CoreAI) && !targetEnvironment(simulator)
import Foundation
actor FluxSpeedTextCache {
    private var entries: [String: [Float]] = [:]
    private var order: [String] = []
    private let maximumEntries: Int
    private let maximumBytes: Int

    init(maximumEntries: Int = 3, maximumBytes: Int = 45 * 1024 * 1024) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumBytes = max(0, maximumBytes)
    }

    func get(_ text: String) -> [Float]? {
        guard let value = entries[text] else { return nil }
        order.removeAll { $0 == text }
        order.append(text)
        return value
    }

    func set(_ text: String, embeddings: [Float]) {
        guard !embeddings.isEmpty, maximumEntries > 0,
              embeddings.count <= maximumBytes / MemoryLayout<Float>.stride else { return }
        order.removeAll { $0 == text }
        order.append(text)
        entries[text] = embeddings
        while order.count > maximumEntries || storedBytes > maximumBytes {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    var storedBytes: Int { entries.values.reduce(0) { $0 + $1.count * MemoryLayout<Float>.stride } }
}

enum FluxPromptError: LocalizedError {
    case tooManyTokens
    var errorDescription: String? { "プロンプトが長すぎます。内容を短くしてください。" }
}

#endif
