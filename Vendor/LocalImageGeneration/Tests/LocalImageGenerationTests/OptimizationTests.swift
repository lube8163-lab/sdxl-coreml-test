import Foundation
import Testing
@testable import LocalImageGeneration
#if canImport(CoreAI) && !targetEnvironment(simulator)
@testable import CoreAIDiffusionPipeline
#endif

@Suite struct OptimizationTests {
    @Test(arguments: ["nude adult portrait", "全裸の人物", "p.o.r.n", "gore"])
    func unsafeWarmupIsRejectedBeforeLoadingModels(_ prompt: String) async {
        let generator = LocalFluxGenerator(modelDirectory: nil, safetyModelURL: nil)
        do {
            try await generator.prepare(prompt: prompt)
            Issue.record("Unsafe prompt reached pre-encoding")
        } catch { #expect(error as? PromptSafetyError == .blocked) }
    }

    @Test func warmupRequiresImageClassifier() async {
        let generator = LocalFluxGenerator(modelDirectory: nil, safetyModelURL: nil)
        do {
            try await generator.prepare(prompt: "a red apple")
            Issue.record("Warmup continued without mandatory classifier")
        } catch { #expect(error.localizedDescription.contains("安全性を確認するモデル")) }
    }

    @Test func cancelledWarmupCannotLoadModels() async {
        let generator = LocalFluxGenerator(modelDirectory: nil, safetyModelURL: nil)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await generator.prepare(prompt: "a red apple")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func highTemperatureAndLowPowerDisableRetention() {
        #expect(GenerationResourcePolicy.keepWarm.allowsRetention(thermalState: .nominal, lowPower: false))
        #expect(GenerationResourcePolicy.keepWarm.allowsRetention(thermalState: .fair, lowPower: false))
        for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            #expect(!GenerationResourcePolicy.keepWarm.allowsRetention(thermalState: thermal, lowPower: true))
            #expect(!GenerationResourcePolicy.releaseAfterGeneration.allowsRetention(thermalState: thermal, lowPower: false))
        }
        #expect(!GenerationResourcePolicy.keepWarm.allowsRetention(thermalState: .serious, lowPower: false))
        #expect(!GenerationResourcePolicy.keepWarm.allowsRetention(thermalState: .critical, lowPower: false))
    }

    #if canImport(CoreAI) && !targetEnvironment(simulator)
    @Test func repeatedPromptRemainsCachedWhileLeastRecentlyUsedIsEvicted() async {
        let cache = FluxSpeedTextCache(maximumEntries: 3, maximumBytes: 128)
        await cache.set("a", embeddings: [1, 2])
        await cache.set("b", embeddings: [3, 4])
        await cache.set("c", embeddings: [5, 6])
        #expect(await cache.get("a") == [1, 2])
        await cache.set("d", embeddings: [7, 8])
        #expect(await cache.get("b") == nil)
        #expect(await cache.get("a") == [1, 2])
        #expect(await cache.get("d") == [7, 8])
    }

    @Test func conditioningMemoryIsBoundedAndOversizeCannotDisplaceValidEntries() async {
        let cache = FluxSpeedTextCache(maximumEntries: 3, maximumBytes: 16)
        await cache.set("a", embeddings: [1, 2])
        await cache.set("b", embeddings: [3, 4])
        await cache.set("huge", embeddings: [1, 2, 3, 4, 5])
        #expect(await cache.get("a") == [1, 2])
        #expect(await cache.get("huge") == nil)
        await cache.set("c", embeddings: [5, 6])
        #expect(await cache.get("b") == nil)
        #expect(await cache.storedBytes <= 16)
    }
    #endif
}
