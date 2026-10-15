import Foundation
import LocalImageGeneration
import LocalGenerationSafety
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

enum PromptExample: String, CaseIterable, Identifiable {
    case stillLife, landscape, robot, illustration
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stillLife: "静物写真"
        case .landscape: "風景"
        case .robot: "ロボット"
        case .illustration: "イラスト"
        }
    }
    var prompt: String {
        switch self {
        case .stillLife:
            "A still life photograph of a red apple next to a blue ceramic mug on a wooden table, soft window light, realistic photography."
        case .landscape:
            "A landscape photograph of a quiet mountain lake at sunrise, soft golden light, natural colors, detailed."
        case .robot:
            "A cinematic photo of a small robot walking in Tokyo at night, neon reflections, detailed."
        case .illustration:
            "A watercolor illustration of a small cat sitting beside a window with potted plants, warm afternoon light, gentle colors."
        }
    }
}

@MainActor
final class SDXLGeneratorViewModel: ObservableObject {
    @Published var prompt = PromptExample.robot.prompt
    @Published var seedMode: SeedMode = .random
    @Published var manualSeedText = ""
    @Published private(set) var isGenerating = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isReleasingResources = false
    @Published private(set) var isCancellationRequested = false
    @Published private(set) var operationStartedAt: Date?
    @Published private(set) var result: GeneratedImage?
    @Published private(set) var resultID: UUID?
    @Published private(set) var lastResultPrompt: String?
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
    var isBusy: Bool { isGenerating || isPreparing || isReleasingResources }

    func selectExample(_ example: PromptExample) { prompt = example.prompt }

    func preloadResourcesIfNeeded() {
        isBackgrounded = false
        guard prepareTask == nil, cleanupTask == nil, !isGenerating, !hasPreloadedResources else { return }
        isPreparing = true
        errorMessage = nil
        isCancellationRequested = false
        operationStartedAt = Date()
        progressTitle = "画像生成の準備中"
        progressDetail = "安全機能とモデルを準備しています。初回は数分かかることがあります。画面を開いたままお待ちください。"
        let preparedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        prepareTask = Task { [weak self] in
            guard let self else { return }
            defer { isPreparing = false; isCancellationRequested = false; operationStartedAt = nil; prepareTask = nil }
            do {
                try await generator.prepare(prompt: preparedPrompt)
                try Task.checkCancellation()
                hasPreloadedResources = true
                errorMessage = nil
                progressTitle = "準備完了"
                progressDetail = "入力と生成画像の安全性を端末内で確認します。"
            } catch is CancellationError {
                hasPreloadedResources = false
                progressTitle = "準備を中断しました"
                progressDetail = "「画像を生成する」を押すと準備から再開します。" + previousResultMessage
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
        isReleasingResources = true
        let preparation = prepareTask, generation = generationTask
        cleanupTask = Task { [weak self] in
            await preparation?.value
            await generation?.value
            guard let self else { return }
            await generator.unload()
            hasPreloadedResources = false
            cleanupTask = nil
            isReleasingResources = false
            if !isBackgrounded && allowPreload { preloadResourcesIfNeeded() }
        }
    }

    func cancelGeneration() {
        guard (isGenerating || isPreparing), !isCancellationRequested else { return }
        isCancellationRequested = true
        progressTitle = "中断しています"
        progressDetail = "実行中の処理を終了しています。少し時間がかかることがあります。" + previousResultMessage
        prepareTask?.cancel()
        generationTask?.cancel()
    }

    func resourceConditionsChanged() {
        Task { await generator.releaseWarmResourcesIfNeeded() }
    }

    func generate() {
        guard !isGenerating, !isPreparing, cleanupTask == nil, !isBackgrounded else { return }
        errorMessage = nil
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            progressTitle = "入力待ち"
            progressDetail = "生成したい内容を書いてください。" + previousResultMessage
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
        isCancellationRequested = false
        operationStartedAt = Date()
        currentStep = 0
        totalSteps = 0
        progressTitle = "生成準備中"
        progressDetail = "モデルを準備しています。初回や準備し直す際は時間がかかることがあります。"
        let start = Date()
        generationTask = Task { [weak self] in
            guard let self else { return }
            defer { isGenerating = false; isCancellationRequested = false; operationStartedAt = nil; generationTask = nil }
            do {
                let approved = try await generator.generate(prompt: text, seed: seed) { [weak self] progress in
                    Task { @MainActor in self?.receive(progress, operation: id) }
                }
                try Task.checkCancellation()
                guard !isBackgrounded else { throw CancellationError() }
                lastUsedSeed = seed
                lastResultPrompt = text
                result = approved
                resultID = id
                hasPreloadedResources = true
                progressTitle = "生成完了"
                progressDetail = String(format: "安全性の確認を含めて %.1f 秒。保存や共有ができます。", Date().timeIntervalSince(start))
                currentStep = 0
                totalSteps = 0
            } catch is CancellationError {
                progressTitle = "生成を中断しました"
                progressDetail = "内容を確認して、もう一度生成できます。" + previousResultMessage
                currentStep = 0
                totalSteps = 0
            } catch {
                showError(error)
            }
        }
    }

    private func receive(_ progress: GenerationProgress, operation: UUID) {
        guard operation == operationID, isGenerating, !isBackgrounded, !isCancellationRequested else { return }
        switch progress {
        case .preparing:
            progressTitle = "生成準備中"
            progressDetail = "モデルを準備しています。初回や準備し直す際は時間がかかることがあります。"
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
            progressDetail = "新しい画像は、安全性の確認が終わるまで表示しません。" + previousResultMessage
        }
    }

    private func showError(_ error: Error) {
        errorMessage = error.localizedDescription
        if let safety = error as? ContentSafetyError {
            progressTitle = safety == .blocked ? "この内容では生成できません" : "入力を確認してください"
            progressDetail = "内容を変えて、もう一度お試しください。" + previousResultMessage
        } else if error is SeedError {
            progressTitle = "シード値を確認してください"
            progressDetail = "固定シードには指定範囲の整数を入力してください。" + previousResultMessage
        } else if error is ImageSafetyError {
            progressTitle = "新しい画像を表示できませんでした"
            progressDetail = "今回の画像は安全性を確認できなかったため、表示・保存・共有しません。" + previousResultMessage
        } else {
            progressTitle = "処理を完了できませんでした"
            progressDetail = "入力やモデルの準備状況を確認して、もう一度お試しください。" + previousResultMessage
        }
        currentStep = 0
        totalSteps = 0
    }

    private var previousResultMessage: String {
        result == nil ? "" : " 前回の生成画像は引き続き保存・共有できます。"
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
