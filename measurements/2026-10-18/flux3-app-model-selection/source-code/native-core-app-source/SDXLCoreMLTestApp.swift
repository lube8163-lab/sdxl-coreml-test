import SwiftUI
import UIKit
import LocalImageGeneration

@main
struct SDXLCoreMLTestApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = SDXLGeneratorViewModel()
    @StateObject private var setup = ModelSetupViewModel()
    @AppStorage("welcomeCompletedV1") private var welcomeCompleted = false

    var body: some Scene {
        WindowGroup {
            Group {
                if !welcomeCompleted {
                    WelcomeView { welcomeCompleted = true }
                } else if !LocalFluxGenerator.supportsGeneration {
                    UnsupportedDeviceView()
                } else if setup.isReady {
                    ContentView(viewModel: viewModel, setup: setup)
                } else {
                    ModelSetupView(setup: setup)
                }
            }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    viewModel.releaseCachedResources(backgrounded: false, allowPreload: false,
                                                     cancelActiveOperations: false)
                }
                .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                    viewModel.resourceConditionsChanged()
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                    viewModel.resourceConditionsChanged()
                }
                .task {
                    if CommandLine.arguments.contains("--model-selection-validation") { ModelSelectionValidation.start(self) }
                    else if welcomeCompleted { setup.inspectInstallation() }
                }
                .onChange(of: welcomeCompleted) { _, completed in
                    if completed { setup.inspectInstallation() }
                }
                .onChange(of: setup.model) { _, _ in
                    viewModel.releaseCachedResources(backgrounded: false, allowPreload: false)
                }
                .onChange(of: setup.isReady) { _, ready in
                    if ready { viewModel.activateModel(setup.model) }
                }
                .onChange(of: viewModel.isGenerating || viewModel.isPreparing || setup.isBusy) { _, busy in
                    UIApplication.shared.isIdleTimerDisabled = busy && scenePhase == .active
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        UIApplication.shared.isIdleTimerDisabled = viewModel.isGenerating || viewModel.isPreparing || setup.isBusy
                        if setup.isReady { viewModel.activateModel(setup.model) }
                        else if welcomeCompleted { setup.inspectInstallation() }
                    case .background:
                        UIApplication.shared.isIdleTimerDisabled = false
                        setup.pause()
                        viewModel.releaseCachedResources()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}

// Appended only to a copied Preview bootstrap by prepare_model_preview.py.
// Calls real setup/VM methods; this is not an XCTest tap run.
import CryptoKit

@MainActor
private enum ModelSelectionValidation {
    static var started = false
    static func start(_ app: SDXLCoreMLTestApp) {
        guard !started else { return }
        started = true
        Task { await app.runModelSelectionValidation() }
    }
}

@MainActor
private final class ModelSelectionRecorder {
    let directory = URL.documentsDirectory.appendingPathComponent("ModelSelectionValidation", isDirectory: true)
    var report: [String: Any]
    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        report = (try? JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("report.json"))) as? [String: Any]) ?? [:]
        if report["phase"] as? String == "failed" { report = [:] }
        report["scope"] = "Test-only startup driver calls unchanged main app setup, VM, native runtime and compulsory safety. Not an XCTest tap run."
        report["bundle_id"] = Bundle.main.bundleIdentifier
        report["os_version"] = UIDevice.current.systemVersion
        report["physical_memory_bytes"] = ProcessInfo.processInfo.physicalMemory
    }
    func save(_ phase: String) throws {
        report["phase"] = phase
        report["updated_at"] = ISO8601DateFormatter().string(from: Date())
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        print("MODEL_SELECTION " + phase); fflush(stdout)
    }
    func require(_ value: Bool, _ name: String) throws {
        guard value else { throw NSError(domain: "ModelSelectionValidation", code: 1,
            userInfo: [NSLocalizedDescriptionKey: name]) }
    }
    func screenshot(_ name: String) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: directory.appendingPathComponent(name + ".png"))
    }
    func hash(_ image: GeneratedImage) -> String {
        guard let bytes = image.cgImage.dataProvider?.data else { return "missing" }
        return SHA256.hash(data: bytes as Data).map { String(format: "%02x", $0) }.joined()
    }
}

extension SDXLCoreMLTestApp {
    @MainActor fileprivate func runModelSelectionValidation() async {
        guard let recorder = try? ModelSelectionRecorder() else { return }
        if recorder.report["complete"] as? Bool == true { return }
        welcomeCompleted = true
        func wait(_ seconds: TimeInterval, _ name: String, until condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline {
                if case .failed(let message) = setup.state {
                    throw NSError(domain: "ModelSelectionValidation", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            try recorder.require(condition(), name + ": " + (viewModel.errorMessage ?? String(describing: setup.state)))
            try await Task.sleep(for: .milliseconds(300))
        }
        func ready(_ model: GenerationModel) async throws {
            try await wait(3600, "model-ready-" + model.rawValue) {
                setup.isReady && viewModel.selectedModel == model && !viewModel.isBusy
            }
        }
        func switchTo(_ model: GenerationModel) async throws {
            if setup.model != model {
                try await wait(120, "setup-idle") { !setup.isBusy && !viewModel.isBusy }
                setup.selectModel(model)
            } else { setup.inspectInstallation() }
        }
        let prompt = "A watercolor painting of a red lighthouse standing on a grassy cliff above a calm blue sea. A small white sailboat is visible on the right. Warm afternoon sunlight comes from the left. Soft textured paper, delicate brush strokes, clear simple composition, no people, no text."
        do {
            let resume = recorder.report["phase"] as? String == "download-paused"
            setup.inspectInstallation()
            if setup.model == .flux2 { try await ready(.flux2) }
            try await switchTo(.flux3)
            try await wait(120, "release-previous-model") { !viewModel.isBusy }
            if !setup.isReady {
                if resume {
                    let previous = (recorder.report["paused_bytes"] as? NSNumber)?.int64Value ?? 0
                    try recorder.require(previous > 0 && setup.savedBytes >= previous, "partial-download-survives-process-relaunch")
                    recorder.report["resumed_bytes"] = setup.savedBytes
                }
                setup.start()
                try recorder.save(resume ? "download-resumed" : "download-started")
                if !resume {
                    try await wait(120, "received-partial-download") { setup.downloadedBytes > 8_000_000 }
                    try recorder.require(setup.state == .downloading, "download-started-successfully")
                    setup.pause()
                    try await wait(60, "download-paused") { !setup.isBusy }
                    recorder.report["paused_bytes"] = setup.savedBytes
                    recorder.screenshot("flux3-download-paused")
                    try recorder.save("download-paused")
                    return // Relaunch this same bundle with the same flag to test persisted HTTP resume.
                }
            }
            try await ready(.flux3)
            try recorder.require(GenerationModel.flux3.package.isInstalled(), "verified-flux3-installation")
            try recorder.require(GenerationModel.flux2.package.isInstalled(), "legacy-model-preserved")
            recorder.report["both_models_installed"] = true
            recorder.screenshot("flux3-controls")
            try recorder.save("models-ready")
            var cases: [[String: Any]] = []
            for steps in [4, 8, 16] {
                viewModel.prompt = prompt
                viewModel.seedMode = .manual; viewModel.manualSeedText = "42"
                viewModel.selectedSteps = steps
                let previous = viewModel.resultID, began = Date()
                viewModel.generate()
                try await wait(600, "generation-finished-\(steps)") { !viewModel.isBusy }
                try recorder.require(viewModel.resultID != previous && viewModel.result != nil, "new-checked-image-\(steps)")
                guard let image = viewModel.result else { throw GenerationError.invalidOutput }
                try recorder.require(viewModel.lastResultModel == .flux3 && viewModel.lastResultSteps == steps
                    && viewModel.lastResultPrompt == prompt && viewModel.lastUsedSeed == 42, "result-provenance-\(steps)")
                try recorder.require(image.decisions.count == 6, "six-output-safety-views")
                let filename = "flux3-\(steps)-steps-seed42-approved.png"
                try UIImage(cgImage: image.cgImage).pngData()?.write(to: recorder.directory.appendingPathComponent(filename))
                cases.append(["steps": steps, "seed": 42, "prompt": prompt,
                    "seconds_including_safety": Date().timeIntervalSince(began), "app_timing": viewModel.progressDetail,
                    "pixel_sha256": recorder.hash(image), "file": filename,
                    "safety": image.decisions.map { ["sfw": $0.sfw, "nsfw": $0.nsfw, "nsfl": $0.nsfl] }])
                recorder.report["cases"] = cases
                try await Task.sleep(for: .seconds(1))
                recorder.screenshot("flux3-\(steps)-steps-result")
                try recorder.save("generated-\(steps)")
            }
            guard let approved = viewModel.result else { throw GenerationError.invalidOutput }
            let id = viewModel.resultID, hash = recorder.hash(approved)
            viewModel.selectedSteps = 4
            try recorder.require(viewModel.lastResultSteps == 16, "settings-do-not-relabel-approved-image")
            viewModel.prompt = "nude adult portrait"
            viewModel.generate()
            try recorder.require(!viewModel.isGenerating && viewModel.errorMessage != nil && viewModel.resultID == id,
                "unsafe-prompt-blocked-before-generation")
            recorder.report["unsafe_prompt_preserved_result"] = true
            viewModel.prompt = prompt
            viewModel.generate()
            try recorder.require(viewModel.isGenerating, "cancellation-operation-started")
            try await Task.sleep(for: .seconds(1))
            viewModel.cancelGeneration()
            try await wait(120, "cancellation-finished") { !viewModel.isBusy }
            try recorder.require(viewModel.resultID == id && viewModel.progressTitle == "生成を中断しました", "cancel-preserves-image")
            if let result = viewModel.result { try recorder.require(recorder.hash(result) == hash, "same-approved-pixels-after-cancel") }
            recorder.report["cancel_preserved_result"] = true
            try await switchTo(.flux2); try await ready(.flux2)
            try recorder.require(viewModel.selectedSteps == 4 && viewModel.lastResultModel == .flux3
                && viewModel.lastResultSteps == 16 && viewModel.resultID == id, "switch-back-preserves-provenance")
            recorder.report["switch_back_preserved_provenance"] = true
            try await switchTo(.flux3); try await ready(.flux3)
            try recorder.require(viewModel.selectedSteps == 4 && viewModel.resultID == id, "model-step-choice-restored")
            recorder.report["complete"] = true
            try recorder.save("complete")
        } catch {
            recorder.report["complete"] = false
            recorder.report["error"] = error.localizedDescription
            recorder.screenshot("failure")
            try? recorder.save("failed")
        }
    }
}
