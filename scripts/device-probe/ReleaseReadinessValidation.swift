// Appended only to an isolated development copy. Never compiled into the store app.
import CryptoKit
import ImageIO
import LocalGenerationSafety
import Photos

@MainActor
private enum ReleaseReadinessValidation {
    static var started = false
    static func start(_ view: ContentView) {
        guard !started else { return }
        started = true
        Task { await view.runReleaseReadinessValidation() }
    }
}

@MainActor
private final class ReleaseReadinessRecorder {
    let directory = URL.documentsDirectory.appendingPathComponent("ReleaseReadinessValidation")
    var records: [[String: Any]] = []
    var observers: [NSObjectProtocol] = []

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func record(_ event: String, _ fields: [String: Any] = [:]) {
        var row = fields
        row["event"] = event
        row["timestamp"] = ISO8601DateFormatter().string(from: Date())
        row["uptime"] = ProcessInfo.processInfo.systemUptime
        records.append(row)
        let report: [String: Any] = [
            "scope": "Isolated development driver calls production view-model and Photos UI handlers. OS notifications are observed, not synthesized. Screenshots render the actual app window; the store export renders it directly at 1284x2778. No engine, model, RAM guard or safety overrides.",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "records": records
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        }
    }

    func pixelHash(_ image: GeneratedImage?) -> String {
        guard let bytes = image?.cgImage.dataProvider?.data else { return "none" }
        return SHA256.hash(data: bytes as Data).map { String(format: "%02x", $0) }.joined()
    }

    func capture(_ label: String, checked: GeneratedImage?) {
        guard UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow) else {
            record("capture-unavailable", ["label": label]); return
        }
        let safeLabel = label.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        for (suffix, size) in [("native", window.bounds.size.applying(.init(scaleX: window.screen.scale, y: window.screen.scale))),
                               ("store65", CGSize(width: 1284, height: 2778))] {
            let format = UIGraphicsImageRendererFormat()
            format.opaque = true
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                context.cgContext.scaleBy(x: size.width / window.bounds.width, y: size.height / window.bounds.height)
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try? image.pngData()?.write(to: directory.appendingPathComponent(safeLabel + "-" + suffix + ".png"), options: .atomic)
        }
        if let checked {
            try? UIImage(cgImage: checked.cgImage).pngData()?.write(to: directory.appendingPathComponent(safeLabel + "-checked.png"), options: .atomic)
        }
        record("capture", ["label": safeLabel, "windowPoints": [window.bounds.width, window.bounds.height],
            "nativeScale": window.screen.scale, "storePixels": [1284, 2778]])
    }
}

extension ContentView {
    @MainActor fileprivate func runReleaseReadinessValidation() async {
        struct Command: Decodable {
            let id: String
            let action: String
            let example: String?
            let label: String?
        }
        guard let recorder = try? ReleaseReadinessRecorder() else { return }
        func snapshot() -> [String: Any] {
            ["applicationState": UIApplication.shared.applicationState.rawValue,
             "isGenerating": viewModel.isGenerating, "isPreparing": viewModel.isPreparing,
             "isReleasing": viewModel.isReleasingResources, "hasPreloadedResources": viewModel.hasPreloadedResources,
             "currentStep": viewModel.currentStep, "progressTitle": viewModel.progressTitle,
             "resultID": viewModel.resultID?.uuidString ?? "none",
             "resultPixelSHA256": recorder.pixelHash(viewModel.result),
             "safetyRevision": viewModel.result?.safetyRevision ?? "none",
             "resultDecisions": viewModel.result?.decisions.map { ["sfw": $0.sfw, "nsfw": $0.nsfw, "nsfl": $0.nsfl] } ?? [],
             "lastResultPrompt": viewModel.lastResultPrompt ?? "none",
             "lastUsedSeed": viewModel.lastUsedSeed.map(String.init) ?? "none",
             "error": viewModel.errorMessage ?? "none", "isSavingImage": isSavingImage,
             "alert": alertMessage ?? "none", "needsPhotoSettings": needsPhotoSettings,
             "photoAddOnlyStatus": PHPhotoLibrary.authorizationStatus(for: .addOnly).rawValue]
        }
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            recorder.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { recorder.record(name.rawValue, snapshot()) }
            })
        }
        recorder.record("start", snapshot())
        var previousState = Data()
        var previousCommand = ""
        let commandURL = recorder.directory.appendingPathComponent("command.json")
        while !Task.isCancelled {
            let state = snapshot()
            let encoded = (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])) ?? Data()
            if encoded != previousState {
                recorder.record("state", state)
                previousState = encoded
            }
            if let data = try? Data(contentsOf: commandURL),
               let command = try? JSONDecoder().decode(Command.self, from: data), command.id != previousCommand {
                previousCommand = command.id
                recorder.record("command", ["id": command.id, "action": command.action])
                switch command.action {
                case "generate":
                    if let name = command.example, let example = PromptExample(rawValue: name) { viewModel.selectExample(example) }
                    viewModel.seedMode = .manual; viewModel.manualSeedText = "42"
                    viewModel.generate()
                case "select":
                    if let name = command.example, let example = PromptExample(rawValue: name) { viewModel.selectExample(example) }
                case "capture": recorder.capture(command.label ?? "capture", checked: viewModel.result)
                case "inputTop":
                    func scrollViews(_ view: UIView) -> [UIScrollView] {
                        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                    }
                    for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                        for window in scene.windows where window.isKeyWindow {
                            scrollViews(window).filter { $0.contentSize.height > $0.bounds.height }.forEach {
                                $0.setContentOffset(CGPoint(x: 0, y: -$0.adjustedContentInset.top), animated: false)
                            }
                        }
                    }
                case "save": if let checked = viewModel.result { saveImageToPhotos(checked) }
                case "dismissAlert": alertMessage = nil; needsPhotoSettings = false
                case "openPhotoSettings":
                    alertMessage = nil
                    if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
                case "showSettings": isShowingSettings = true
                case "hideSettings": isShowingSettings = false
                case "checkFixtures":
                    let checker = ImageSafetyChecker(modelURL: Bundle.main.url(forResource: "ImageSafetyClassifier", withExtension: "mlmodelc"))
                    let fixtures = recorder.directory.appendingPathComponent("fixtures")
                    for file in ((try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                        do {
                            _ = try await checker.check(image)
                            recorder.record("fixture", ["file": file.lastPathComponent, "approved": true, "revision": ImageSafetyDecision.revision])
                        } catch {
                            recorder.record("fixture", ["file": file.lastPathComponent, "approved": false, "blocked": error as? ImageSafetyError == .blocked,
                                "error": error.localizedDescription, "revision": ImageSafetyDecision.revision])
                        }
                    }
                default: recorder.record("unknown-command", ["action": command.action])
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
