import Foundation
import LocalGenerationSafety
#if canImport(CoreAI) && !targetEnvironment(simulator)
import CoreAIDiffusionPipeline
#endif

public typealias GeneratedImage = SafetyCheckedImage
public typealias PromptSafetyError = ContentSafetyError

public enum GenerationError: Error, LocalizedError, Equatable {
    case unsupportedEnvironment, insufficientMemory, missingAssets, invalidOutput, busy, invalidSteps, promptTooLong

    public var errorDescription: String? {
        switch self {
        case .unsupportedEnvironment: "画像生成には iOS 27.0.1 以降の対応する実機が必要です。"
        case .insufficientMemory: "このモデルにはメモリ6GB以上の端末が必要です。"
        case .missingAssets: "モデルが不足または破損しています。モデル管理から準備し直してください。"
        case .invalidOutput: "画像を生成できませんでした。内容を変えてお試しください。"
        case .busy: "画像生成が進行中です。完了するまでお待ちください。"
        case .invalidSteps: "このモデルでは選択したステップ数を利用できません。設定を選び直してください。"
        case .promptTooLong: "FLUX.3の入力が長すぎます。文章を短くして、もう一度お試しください。"
        }
    }
}

public enum GenerationProgress: Sendable {
    case preparing, denoising(step: Int, total: Int), checkingSafety
}

public enum GenerationResourcePolicy: Sendable {
    case releaseAfterGeneration, keepWarm

    func allowsRetention(thermalState: ProcessInfo.ThermalState, lowPower: Bool) -> Bool {
        self == .keepWarm && !lowPower && [.nominal, .fair].contains(thermalState)
    }
}

public actor LocalFluxGenerator {
    public static let warmRetentionSeconds = 30
    // Six-GB devices report slightly less than six billion physical bytes.
    // The app also signs with Extended Virtual Addressing for CoreAI loading.
    public static let minimumPhysicalMemoryBytes: UInt64 = 5_500_000_000
    private let directory: URL?
    private let checker: ImageSafetyChecker
    private let resourcePolicy: GenerationResourcePolicy
    private var assetsValidated = false
    private var isGenerating = false
    private var isPreparingPrompt = false
    private var idleTask: Task<Void, Never>?
    private var idleTicket = UUID()
    private var resourceReleaseTask: Task<Void, Never>?
    #if canImport(CoreAI) && !targetEnvironment(simulator)
    private var pipeline: FlowTransformerPipeline?
    #endif

    public init(modelDirectory: URL?, safetyModelURL: URL?, resourcePolicy: GenerationResourcePolicy = .keepWarm) {
        directory = modelDirectory
        checker = ImageSafetyChecker(modelURL: safetyModelURL)
        self.resourcePolicy = resourcePolicy
    }

    public static var supportsGeneration: Bool {
        #if canImport(CoreAI) && !targetEnvironment(simulator)
        return ProcessInfo.processInfo.physicalMemory >= minimumPhysicalMemoryBytes
        #else
        return false
        #endif
    }

    public static func validatePrompt(_ prompt: String) throws {
        try ContentSafetyPolicy.bundled().validate(prompt, context: .generationPrompt)
    }

    public func prepare(prompt: String? = nil) async throws {
        guard !isGenerating, !isPreparingPrompt else { throw GenerationError.busy }
        isPreparingPrompt = true
        defer { isPreparingPrompt = false }
        do {
            if let prompt { try Self.validatePrompt(prompt) }
            stopIdleTimer()
            try await ensurePrepared()
            #if canImport(CoreAI) && !targetEnvironment(simulator)
            if mayKeepWarm, let prompt, !prompt.isEmpty, let pipeline {
                try await pipeline.preparePrompts([prompt])
                try Task.checkCancellation()
            }
            #endif
            if mayKeepWarm { scheduleIdleUnload() }
            else { await releaseHeavyResources() }
        } catch {
            await releaseHeavyResources()
            throw error
        }
    }

    private func ensurePrepared() async throws {
        await resourceReleaseTask?.value
        try Task.checkCancellation()
        _ = try ContentSafetyPolicy.bundled()
        try await checker.prepare()
        try Task.checkCancellation()
        #if canImport(CoreAI) && !targetEnvironment(simulator)
        guard Self.supportsGeneration else { throw GenerationError.insufficientMemory }
        guard let directory else { throw GenerationError.missingAssets }
        if !assetsValidated {
            try Self.validateAssets(directory)
            assetsValidated = true
        }
        if pipeline == nil {
            let prepared = try await FlowTransformerPipeline(from: directory, mode: .half)
            if Task.isCancelled {
                await prepared.unloadResources()
                throw CancellationError()
            }
            pipeline = prepared
        }
        #else
        throw GenerationError.unsupportedEnvironment
        #endif
    }

    /// Raw output stays inside this actor until the compulsory six-view classifier approves it.
    public func generate(prompt: String, seed: UInt32,
        progress: @escaping @Sendable (GenerationProgress) -> Void) async throws -> SafetyCheckedImage {
        guard !isGenerating, !isPreparingPrompt else { throw GenerationError.busy }
        isGenerating = true
        defer { isGenerating = false }
        do {
            let policy = try ContentSafetyPolicy.bundled()
            try policy.validate(prompt, context: .generationPrompt)
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GenerationError.invalidOutput
            }
            try Task.checkCancellation()
            stopIdleTimer()
            progress(.preparing)
            try await ensurePrepared()
            #if canImport(CoreAI) && !targetEnvironment(simulator)
            guard let pipeline else { throw GenerationError.missingAssets }
            let config = PipelineConfiguration(prompt: prompt, seed: seed, stepCount: 4,
                guidanceScale: 1, schedulerType: .discreteFlow, decodeResolution: .half,
                lazyModelLoading: true, keepDenoiserLoaded: mayKeepWarm)
            let output = try await pipeline.generateImages(configuration: config) { update in
                progress(.denoising(step: update.step, total: update.totalSteps))
                return !Task.isCancelled
            }
            try Task.checkCancellation()
            guard let raw = output.images.first, raw.width == 512, raw.height == 512 else {
                throw GenerationError.invalidOutput
            }
            progress(.checkingSafety)
            let approved = try await checker.check(raw)
            try Task.checkCancellation()
            if mayKeepWarm { scheduleIdleUnload() }
            else { await releaseHeavyResources() }
            return approved
            #else
            throw GenerationError.unsupportedEnvironment
            #endif
        } catch {
            stopIdleTimer()
            await releaseHeavyResources()
            throw error
        }
    }

    /// Call after the active generation task has finished cancelling.
    public func unload() async {
        stopIdleTimer()
        await releaseHeavyResources()
        #if canImport(CoreAI) && !targetEnvironment(simulator)
        pipeline = nil
        #endif
        await checker.unload()
        assetsValidated = false
    }

    /// An active operation reevaluates retention before decode and after safety.
    /// While idle, respond to power/thermal notifications without cancelling it.
    public func releaseWarmResourcesIfNeeded() async {
        guard !mayKeepWarm, !isGenerating, !isPreparingPrompt else { return }
        stopIdleTimer()
        await releaseHeavyResources()
    }

    private var mayKeepWarm: Bool {
        resourcePolicy.allowsRetention(thermalState: ProcessInfo.processInfo.thermalState,
                                      lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    private func stopIdleTimer() {
        idleTicket = UUID()
        idleTask?.cancel()
        idleTask = nil
    }

    private func scheduleIdleUnload() {
        stopIdleTimer()
        let ticket = idleTicket
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.warmRetentionSeconds)) }
            catch { return }
            await self?.expireWarmSession(ticket: ticket)
        }
    }

    private func expireWarmSession(ticket: UUID) async {
        guard ticket == idleTicket, !isGenerating, !isPreparingPrompt else { return }
        idleTask = nil
        await releaseHeavyResources()
    }

    private func releaseHeavyResources() async {
        if let task = resourceReleaseTask { await task.value; return }
        #if canImport(CoreAI) && !targetEnvironment(simulator)
        guard let pipeline else { return }
        let task = Task { await pipeline.unloadResources() }
        resourceReleaseTask = task
        await task.value
        resourceReleaseTask = nil
        #endif
    }

    private struct Manifest: Decodable {
        struct File: Decodable { let path: String; let bytes: Int64 }
        let revision: String
        let modelID: String
        let width: Int
        let height: Int
        let files: [File]
    }

    static func validateAssets(_ directory: URL) throws {
        do {
            guard let url = Bundle.module.url(forResource: "flux2-catalog-manifest", withExtension: "json") else {
                throw GenerationError.missingAssets
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
            guard manifest.revision == "coreai-512-4bit-a7f65cd-v1",
                  manifest.modelID == "flux2-klein-4b", manifest.width == 512, manifest.height == 512,
                  manifest.files.count == 17 else { throw GenerationError.missingAssets }
            // The model installer verifies every pinned hash before activation and at launch.
            // Per-pipeline size checks also prevent missing or truncated weights.
            for file in manifest.files {
                try Task.checkCancellation()
                guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else {
                    throw GenerationError.missingAssets
                }
                let url = directory.appendingPathComponent(file.path)
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true,
                      info.fileSize == Int(file.bytes) else { throw GenerationError.missingAssets }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw GenerationError.missingAssets }
    }
}
