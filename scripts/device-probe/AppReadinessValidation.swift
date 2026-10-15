// Appended only to the isolated ContentView copy by --readiness.
import CryptoKit
import ImageIO
import Photos
import UniformTypeIdentifiers

@MainActor
private enum AppReadinessValidation {
    static var started = false
    static func start(_ view: ContentView) {
        guard !started else { return }
        started = true
        Task { await view.runAppReadinessValidation() }
    }
}

@MainActor
private final class AppReadinessRecorder {
    let directory = URL.documentsDirectory.appendingPathComponent("AppReadinessValidation")
    var records: [[String: Any]] = []
    var complete = false
    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func record(_ phase: String, _ fields: [String: Any] = [:]) {
        var row = fields; row["phase"] = phase
        records.append(row)
        let report: [String: Any] = ["complete": complete, "records": records,
            "deviceRAMBytes": ProcessInfo.processInfo.physicalMemory,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Isolated startup driver invokes production view model, share sheet and photo saver. No model/RAM/safety overrides. No messages are sent or share destinations selected."]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        }
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            print("APP_READINESS " + String(decoding: data, as: UTF8.self)); fflush(stdout)
        }
    }
    func require(_ condition: Bool, _ name: String) throws {
        record(name, ["passed": condition])
        if !condition { throw NSError(domain: "AppReadiness", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    }
    func screenshot(_ label: String) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: directory.appendingPathComponent(label + ".png"))
    }
    func hash(_ checked: GeneratedImage) -> String {
        guard let data = checked.cgImage.dataProvider?.data else { return "missing-pixels" }
        return SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
    }
}

extension ContentView {
    @MainActor fileprivate func runAppReadinessValidation() async {
        guard let recorder = try? AppReadinessRecorder() else { return }
        let previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleSetting }
        func waitUntilIdle() async throws {
            let deadline = Date().addingTimeInterval(300)
            while viewModel.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            try recorder.require(!viewModel.isBusy, "operation-finished-within-deadline")
        }
        do {
            recorder.record("start")
            try await Task.sleep(for: .seconds(1))
            if viewModel.isPreparing {
                try recorder.require(viewModel.operationStartedAt != nil, "preparation-has-elapsed-time")
                recorder.screenshot("preparation")
            }
            try await waitUntilIdle()
            for example in PromptExample.allCases {
                try LocalFluxGenerator.validatePrompt(example.prompt)
                viewModel.selectExample(example)
                try recorder.require(viewModel.prompt == example.prompt, "example-select-" + example.id)
                viewModel.seedMode = .manual; viewModel.manualSeedText = "42"
                let previousID = viewModel.resultID
                let previousSeed = viewModel.lastUsedSeed
                let previousPrompt = viewModel.lastResultPrompt
                let start = Date()
                viewModel.generate()
                try recorder.require(viewModel.resultID == previousID && viewModel.lastUsedSeed == previousSeed
                    && viewModel.lastResultPrompt == previousPrompt, "previous-result-retained-during-" + example.id)
                try recorder.require(viewModel.isGenerating && viewModel.operationStartedAt != nil, "generation-has-elapsed-time-" + example.id)
                try await Task.sleep(for: .seconds(1))
                recorder.screenshot("generating-" + example.id)
                try await waitUntilIdle()
                guard let image = viewModel.result, viewModel.resultID != previousID else {
                    throw NSError(domain: "AppReadiness", code: 2, userInfo: [NSLocalizedDescriptionKey: viewModel.errorMessage ?? "No new checked image"])
                }
                try recorder.require(viewModel.lastResultPrompt == example.prompt && viewModel.lastUsedSeed == 42,
                    "approved-result-metadata-" + example.id)
                recorder.record("generation-approved", ["example": example.id, "seconds": Date().timeIntervalSince(start),
                    "appTiming": viewModel.progressDetail, "seed": 42, "pixelSHA256": recorder.hash(image),
                    "views": image.decisions.map { ["sfw": $0.sfw, "nsfw": $0.nsfw, "nsfl": $0.nsfl] }])
                try await Task.sleep(for: .seconds(1))
                recorder.screenshot("result-" + example.id)
            }

            let retainedID = viewModel.resultID
            let retainedSeed = viewModel.lastUsedSeed
            let retainedPrompt = viewModel.lastResultPrompt
            let retainedHash = viewModel.result.map(recorder.hash)
            func retained() -> Bool {
                viewModel.resultID == retainedID && viewModel.lastUsedSeed == retainedSeed
                    && viewModel.lastResultPrompt == retainedPrompt && viewModel.result.map(recorder.hash) == retainedHash
            }
            for blocked in ["explicit sexual content", "全裸の人物", "色情图片", "포르노", "desnudo", "pornografia", "n\u{200D}ude", "gore"] {
                viewModel.prompt = blocked; viewModel.manualSeedText = "99"
                viewModel.generate()
                try recorder.require(!viewModel.isGenerating && viewModel.errorMessage != nil && retained(), "blocked-input-keeps-approved-result")
            }
            viewModel.prompt = ""; viewModel.generate()
            try recorder.require(!viewModel.isGenerating && retained(), "empty-input-keeps-approved-result")
            viewModel.selectExample(.stillLife); viewModel.manualSeedText = "invalid"
            viewModel.generate()
            try recorder.require(!viewModel.isGenerating && viewModel.errorMessage != nil && retained(), "invalid-seed-keeps-approved-result")

            viewModel.manualSeedText = "99"
            viewModel.generate()
            let deadline = Date().addingTimeInterval(90)
            while viewModel.isGenerating && viewModel.currentStep == 0 && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try recorder.require(viewModel.isGenerating && viewModel.currentStep > 0, "cancellation-reached-active-diffusion")
            viewModel.cancelGeneration()
            try await waitUntilIdle()
            try recorder.require(retained(), "cancelled-generation-keeps-approved-result")

            viewModel.releaseCachedResources(backgrounded: false, allowPreload: false)
            try await waitUntilIdle()
            viewModel.preloadResourcesIfNeeded()
            viewModel.cancelGeneration()
            try await waitUntilIdle()
            try recorder.require(retained(), "cancelled-preparation-keeps-approved-result")

            viewModel.releaseCachedResources(backgrounded: true, allowPreload: false)
            try await waitUntilIdle()
            viewModel.preloadResourcesIfNeeded()
            try await waitUntilIdle()
            try recorder.require(retained(), "view-model-background-resume-keeps-approved-result")
            recorder.record("lifecycle-scope", ["note": "Calls production view-model lifecycle methods; this is not an OS suspension test."])
            viewModel.prompt = retainedPrompt ?? PromptExample.robot.prompt
            viewModel.manualSeedText = "42"

            if let checked = viewModel.result {
                shareRequest = ImageShareRequest(image: checked)
                try await Task.sleep(for: .seconds(2))
                let presented = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController?.presentedViewController
                try recorder.require(presented != nil, "share-sheet-presented")
                // System share suggestions can contain personal contacts; no screenshot is retained.
                shareRequest = nil
                try await Task.sleep(for: .seconds(1))
                try recorder.require(retained(), "share-dismiss-keeps-approved-result")
                if CommandLine.arguments.contains("--photo-save-validation") {
                    recorder.record("photo-permission-pending", ["status": PHPhotoLibrary.authorizationStatus(for: .addOnly).rawValue])
                    saveImageToPhotos(checked)
                    while isSavingImage { try await Task.sleep(for: .milliseconds(100)) }
                    recorder.record("photo-save-result", ["message": alertMessage ?? "", "permissionSettingsOffered": needsPhotoSettings,
                        "authorizationStatus": PHPhotoLibrary.authorizationStatus(for: .addOnly).rawValue])
                    try recorder.require(retained(), "photo-flow-keeps-approved-result")
                } else {
                    recorder.record("photo-save-not-requested", ["note": "Permission dialog and actual photo write require a separate explicit test run."])
                }
            }
            recorder.complete = true
            recorder.record("complete")
            recorder.screenshot("final")
        } catch {
            recorder.record("failed", ["error": error.localizedDescription])
        }
    }
}
