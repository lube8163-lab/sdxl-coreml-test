import Foundation
import Testing
@testable import LocalImageGeneration

@Suite struct GenerationTests {
    @Test(arguments: ["nude adult portrait", "全裸の人物", "p.o.r.n", "gore"])
    func blockedPromptStopsBeforeModelLoading(_ prompt: String) async throws {
        // Neither model exists: the error must be the prompt rejection, before any runtime stage.
        let generator = LocalFluxGenerator(modelDirectory: nil, safetyModelURL: nil)
        do {
            _ = try await generator.generate(prompt: prompt, seed: 42) { _ in
                Issue.record("Runtime was reached before prompt rejection")
            }
            Issue.record("Blocked prompt produced an exportable image")
        } catch {
            #expect(error as? PromptSafetyError == .blocked)
        }
    }

    @Test func missingClassifierPreventsGeneration() async {
        let generator = LocalFluxGenerator(modelDirectory: nil, safetyModelURL: nil)
        do {
            _ = try await generator.generate(prompt: "a red apple", seed: 42) { _ in }
            Issue.record("Missing classifier produced an exportable image")
        } catch {
            #expect(error.localizedDescription.contains("安全性を確認するモデル"))
        }
    }

    @Test func cancelledGenerationCannotStartInference() async {
        let generator = LocalFluxGenerator(modelDirectory: nil, safetyModelURL: nil)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await generator.generate(prompt: "a red apple", seed: 42) { _ in
                Issue.record("Cancelled operation entered the runtime")
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func missingModelAssetsAreRejected() {
        #expect(throws: GenerationError.self) {
            try LocalFluxGenerator.validateAssets(URL(fileURLWithPath: "/nonexistent/flux"))
        }
    }
}
