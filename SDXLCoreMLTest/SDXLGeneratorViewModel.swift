import Foundation
import LocalImageGeneration
import SwiftUI
import UIKit

enum SeedMode: String, CaseIterable, Identifiable {
    case random, manual
    var id: String { rawValue }
    var displayName: String { self == .random ? "毎回ランダム" : "固定値を使う" }
    var detailText: String {
        self == .random ? "生成するたびに別のシード値を自動で選びます。"
            : "同じ条件で似た結果を再現したいときに使います。"
    }
}

@MainActor
final class SDXLGeneratorViewModel: ObservableObject {
    @Published var prompt = "cinematic photo of a retro robot walking in Tokyo at night, neon reflections, 35mm film, detailed"
    @Published var seedMode: SeedMode = .random
    @Published var manualSeedText = ""
    @Published private(set) var isGenerating = false
    @Published private(set) var isPreparing = false
    @Published private(set) var result: GeneratedImage?
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasPreloadedResources = false
    @Published private(set) var lastUsedSeed: UInt32?
    @Published private(set) var progressTitle = "準備中"
    @Published private(set) var progressDetail = "モデルと安全機能を確認しています。"
    @Published private(set) var currentStep = 0
    @Published private(set) var totalSteps = 0

    private let generator: LocalFluxGenerator
    private var prepareTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var isBackgrounded = false
    private var operationID = UUID()
    private var checkingOutput = false

    init() {
        generator = LocalFluxGenerator(modelDirectory: FluxModelPackage.installationDirectory,
            safetyModelURL: Bundle.main.url(forResource: "ImageSafetyClassifier", withExtension: "mlmodelc"))
    }

    var modelSummaryText: String { "FLUX.2 Klein / 512×512" }
    var promptHintText: String { "例: a small cat in a Tokyo cafe, soft morning light" }
    var promptGuidanceText: String { "描きたい内容を入力してください。英語で具体的に書くと意図が伝わりやすくなります。" }
    var lastUsedSeedText: String { lastUsedSeed.map(String.init) ?? "まだ生成していません" }
    var progressStepText: String { "\(currentStep) / \(totalSteps) ステップ" }
    var progressValue: Double? {
        totalSteps > 0 ? Double(currentStep) / Double(totalSteps) : nil
    }

    func preloadResourcesIfNeeded() {
        isBackgrounded = false
        guard prepareTask == nil, cleanupTask == nil, !isGenerating, !hasPreloadedResources else { return }
        isPreparing = true
        prepareTask = Task { [weak self] in
            guard let self else { return }
            defer { isPreparing = false; prepareTask = nil }
            do {
                try await generator.prepare(prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                try Task.checkCancellation()
                hasPreloadedResources = true
                errorMessage = nil
                progressTitle = "準備完了"
                progressDetail = "入力と生成画像の安全性を端末内で確認します。"
            } catch is CancellationError {
                hasPreloadedResources = false
            } catch {
                hasPreloadedResources = false
                showError(error)
            }
        }
    }

    func releaseCachedResources(backgrounded: Bool = true, allowPreload: Bool = true,
                                cancelActiveOperations: Bool = true) {
        isBackgrounded = isBackgrounded || backgrounded
        if cancelActiveOperations {
            prepareTask?.cancel()
            generationTask?.cancel()
        }
        guard cleanupTask == nil else { return }
        let preparation = prepareTask, generation = generationTask
        cleanupTask = Task { [weak self] in
            await preparation?.value
            await generation?.value
            guard let self else { return }
            await generator.unload()
            hasPreloadedResources = false
            cleanupTask = nil
            if !isBackgrounded && allowPreload { preloadResourcesIfNeeded() }
        }
    }

    func cancelGeneration() { generationTask?.cancel() }

    func resourceConditionsChanged() {
        Task { await generator.releaseWarmResourcesIfNeeded() }
    }

    func generate() {
        guard !isGenerating, !isPreparing, cleanupTask == nil, !isBackgrounded else { return }
        result = nil
        errorMessage = nil
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            progressTitle = "入力待ち"
            progressDetail = "生成したい内容を書いてください。"
            return
        }
        let seed: UInt32
        do {
            try LocalFluxGenerator.validatePrompt(text)
            seed = try resolveSeed()
        } catch {
            showError(error)
            return
        }
        let id = UUID()
        operationID = id
        checkingOutput = false
        isGenerating = true
        currentStep = 0
        totalSteps = 0
        lastUsedSeed = seed
        progressTitle = "生成準備中"
        progressDetail = "モデルを準備しています。"
        let start = Date()
        generationTask = Task { [weak self] in
            guard let self else { return }
            defer { isGenerating = false; generationTask = nil }
            do {
                let approved = try await generator.generate(prompt: text, seed: seed) { [weak self] progress in
                    Task { @MainActor in self?.receive(progress, operation: id) }
                }
                try Task.checkCancellation()
                guard !isBackgrounded else { throw CancellationError() }
                result = approved
                hasPreloadedResources = true
                progressTitle = "生成完了"
                progressDetail = String(format: "安全性の確認を含めて %.1f 秒。保存や共有ができます。", Date().timeIntervalSince(start))
                currentStep = 0
                totalSteps = 0
            } catch is CancellationError {
                result = nil
                progressTitle = "生成を中断しました"
                progressDetail = "内容を確認して、もう一度生成できます。"
                currentStep = 0
                totalSteps = 0
            } catch {
                result = nil
                showError(error)
            }
        }
    }

    private func receive(_ progress: GenerationProgress, operation: UUID) {
        guard operation == operationID, isGenerating, !isBackgrounded else { return }
        switch progress {
        case .preparing:
            progressTitle = "生成準備中"
            progressDetail = "モデルを準備しています。"
        case .denoising(let step, let total):
            guard !checkingOutput else { return }
            progressTitle = "画像を生成中"
            progressDetail = "今は \(step) / \(total) ステップ目です。"
            currentStep = step
            totalSteps = total
        case .checkingSafety:
            checkingOutput = true
            currentStep = 0
            totalSteps = 0
            progressTitle = "画像の安全性を確認中"
            progressDetail = "確認が終わるまで画像は表示されません。"
        }
    }

    private func showError(_ error: Error) {
        errorMessage = error.localizedDescription
        progressTitle = "処理を停止しました"
        progressDetail = "内容や端末の対応状況を確認してください。"
        currentStep = 0
        totalSteps = 0
    }

    private func resolveSeed() throws -> UInt32 {
        if seedMode == .random { return UInt32.random(in: .min ... .max) }
        guard let value = UInt32(manualSeedText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SeedError.invalid
        }
        return value
    }

    private enum SeedError: LocalizedError {
        case invalid
        var errorDescription: String? { "固定シード値には 0 から 4294967295 の整数を入力してください。" }
    }
}
