import Foundation
import LocalGenerationSafety

/// Raw FLUX.3 pixels never leave this actor's operation before six-view approval.
public actor LocalFlux3Generator {
    private let directory: URL?
    private let checker: ImageSafetyChecker
    private var busy = false
    #if canImport(CoreAI) && !targetEnvironment(simulator)
    private var runtime: Flux3Runtime?
    #endif

    public init(modelDirectory: URL?, safetyModelURL: URL?) {
        directory = modelDirectory
        checker = ImageSafetyChecker(modelURL: safetyModelURL)
    }

    public func prepare(prompt: String? = nil) async throws {
        guard !busy else { throw GenerationError.busy }
        busy = true
        defer { busy = false }
        if let prompt { try LocalFluxGenerator.validatePrompt(prompt) }
        try Task.checkCancellation()
        try await ensurePrepared()
        #if canImport(CoreAI) && !targetEnvironment(simulator)
        if let prompt { _ = try await runtime?.tokens(for: prompt) }
        #endif
    }

    private func ensurePrepared() async throws {
        try await checker.prepare()
        try Task.checkCancellation()
        #if canImport(CoreAI) && !targetEnvironment(simulator)
        guard LocalFluxGenerator.supportsGeneration else { throw GenerationError.insufficientMemory }
        guard let directory else { throw GenerationError.missingAssets }
        if runtime == nil {
            guard GenerationModel.flux3.package.isInstalled(at: directory) else { throw GenerationError.missingAssets }
            runtime = try await Flux3Runtime(directory: directory)
        }
        #else
        throw GenerationError.unsupportedEnvironment
        #endif
    }

    public func generate(prompt: String, seed: UInt32, steps: Int,
        progress: @escaping @Sendable (GenerationProgress) -> Void) async throws -> SafetyCheckedImage {
        guard !busy else { throw GenerationError.busy }
        busy = true
        defer { busy = false }
        do {
            try LocalFluxGenerator.validatePrompt(prompt)
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GenerationError.invalidOutput }
            try GenerationSteps.validate(steps, for: .flux3)
            try Task.checkCancellation()
            progress(.preparing)
            try await ensurePrepared()
            #if canImport(CoreAI) && !targetEnvironment(simulator)
            guard let runtime else { throw GenerationError.missingAssets }
            let raw = try await runtime.generate(prompt: prompt, seed: seed, steps: steps, progress: progress)
            try Task.checkCancellation()
            progress(.checkingSafety)
            let approved = try await checker.check(raw)
            try Task.checkCancellation()
            return approved
            #else
            throw GenerationError.unsupportedEnvironment
            #endif
        } catch {
            await unload()
            throw error
        }
    }

    public func unload() async {
        #if canImport(CoreAI) && !targetEnvironment(simulator)
        await runtime?.unload()
        runtime = nil
        #endif
        await checker.unload()
    }

    public func releaseWarmResourcesIfNeeded() async {
        if !busy && (ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= 2) {
            await unload()
        }
    }
}

/// Common app entry point keeps each model's supported sampler and safety path.
public actor LocalImageGenerator {
    public let model: GenerationModel
    private let flux2: LocalFluxGenerator?
    private let flux3: LocalFlux3Generator?
    public init(model: GenerationModel, modelDirectory: URL?, safetyModelURL: URL?) {
        self.model = model
        flux2 = model == .flux2 ? LocalFluxGenerator(modelDirectory: modelDirectory, safetyModelURL: safetyModelURL) : nil
        flux3 = model == .flux3 ? LocalFlux3Generator(modelDirectory: modelDirectory, safetyModelURL: safetyModelURL) : nil
    }
    public func prepare(prompt: String? = nil) async throws {
        if let flux2 { try await flux2.prepare(prompt: prompt) }
        else if let flux3 { try await flux3.prepare(prompt: prompt) }
    }
    public func generate(prompt: String, seed: UInt32, steps: Int,
        progress: @escaping @Sendable (GenerationProgress) -> Void) async throws -> SafetyCheckedImage {
        try LocalFluxGenerator.validatePrompt(prompt)
        try GenerationSteps.validate(steps, for: model)
        if let flux2 { return try await flux2.generate(prompt: prompt, seed: seed, progress: progress) }
        if let flux3 { return try await flux3.generate(prompt: prompt, seed: seed, steps: steps, progress: progress) }
        throw GenerationError.unsupportedEnvironment
    }
    public func unload() async { await flux2?.unload(); await flux3?.unload() }
    public func releaseWarmResourcesIfNeeded() async {
        await flux2?.releaseWarmResourcesIfNeeded(); await flux3?.releaseWarmResourcesIfNeeded()
    }
}
