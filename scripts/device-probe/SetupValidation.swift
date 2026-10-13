// Appended only to an isolated copy of SDXLCoreMLTestApp.swift for device validation.
import CryptoKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

@MainActor
private enum SetupValidation {
    static var started = false
    static func start(_ app: SDXLCoreMLTestApp) {
        guard !started else { return }
        started = true
        Task { await app.runSetupValidation() }
    }
}

@MainActor
private final class SetupRecorder {
    let directory = URL.documentsDirectory.appendingPathComponent("FirstDownloadValidation")
    var records: [[String: Any]] = []
    var complete = false
    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("MIM_FLUX_EVENT_PATH", directory.appendingPathComponent("flux-events.jsonl").path, 1)
        let memory = directory.appendingPathComponent("memory.csv")
        FileManager.default.createFile(atPath: memory.path, contents: Data("uptime_seconds,physical_footprint_bytes\n".utf8))
        Task { @MainActor [weak self] in
            while let self, !self.complete, self.records.last?["phase"] as? String != "failed" {
                if let handle = try? FileHandle(forWritingTo: memory) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data("\(ProcessInfo.processInfo.systemUptime),\(Self.footprint())\n".utf8))
                    try? handle.close()
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
    static func footprint() -> UInt64 {
        var value = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? value.phys_footprint : 0
    }
    func record(_ phase: String, _ fields: [String: Any] = [:]) {
        var value = fields
        value["phase"] = phase
        value["uptimeSeconds"] = ProcessInfo.processInfo.systemUptime
        records.append(value)
        let report: [String: Any] = ["complete": complete, "records": records,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "OS": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "scope": "Test-only startup driver; unmodified production model setup, download, generation and safety methods. Main app bundle ID preserves downloaded assets."]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            print("SETUP_PROBE " + String(decoding: data, as: UTF8.self)); fflush(stdout)
        }
    }
    func screenshot(_ label: String) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: directory.appendingPathComponent(label + "-ui.png"))
    }
    func save(_ image: GeneratedImage, _ label: String) throws -> String {
        let url = directory.appendingPathComponent(label + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil),
              let pixels = image.cgImage.dataProvider?.data else { throw GenerationError.invalidOutput }
        CGImageDestinationAddImage(destination, image.cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw GenerationError.invalidOutput }
        return SHA256.hash(data: pixels as Data).map { String(format: "%02x", $0) }.joined()
    }
}

extension SDXLCoreMLTestApp {
    @MainActor fileprivate func runSetupValidation() async {
        guard let recorder = try? SetupRecorder() else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        recorder.record("start", ["supportsGeneration": LocalFluxGenerator.supportsGeneration,
            "bundledFluxExists": Bundle.main.resourceURL.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("BundledResources/flux2-klein-4b-512").path)
            } ?? false])
        do {
            guard LocalFluxGenerator.supportsGeneration else { throw GenerationError.insufficientMemory }
            welcomeCompleted = false
            try await Task.sleep(for: .seconds(2))
            recorder.screenshot("onboarding")
            welcomeCompleted = true
            try await Task.sleep(for: .seconds(2))
            recorder.screenshot("announcement")
            if CommandLine.arguments.contains("--capture-onboarding-only") {
                recorder.complete = true
                recorder.record("screenshots-only")
                return
            }
            let downloadStart = Date()
            setup.inspectInstallation()
            if !FluxModelPackage.isInstalled() {
                let completeArchive = setup.savedBytes == FluxModelPackage.archiveBytes
                setup.start()
                if !completeArchive {
                let pauseDeadline = Date().addingTimeInterval(180)
                while setup.downloadedBytes < 8_000_000 && Date() < pauseDeadline {
                    if case .failed(let message) = setup.state { throw NSError(domain: "SetupValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard setup.downloadedBytes >= 8_000_000 else { throw ModelInstallationError.invalidResponse }
                recorder.record("before-pause", ["bytes": setup.downloadedBytes])
                recorder.screenshot("downloading")
                setup.pause()
                while setup.isBusy { try await Task.sleep(for: .milliseconds(100)) }
                recorder.record("paused", ["bytes": setup.savedBytes, "state": String(describing: setup.state)])
                recorder.screenshot("paused")
                try await Task.sleep(for: .seconds(1))
                setup.start()
                } else {
                    recorder.record("resume-complete-archive", ["bytes": setup.savedBytes])
                }
                let installationDeadline = Date().addingTimeInterval(4800)
                var lastLog = Date.distantPast
                while !setup.isReady && Date() < installationDeadline {
                    if case .failed(let message) = setup.state { throw NSError(domain: "SetupValidation", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
                    if Date().timeIntervalSince(lastLog) > 10 {
                        lastLog = Date()
                        recorder.record("install-progress", ["bytes": setup.downloadedBytes, "fraction": setup.progress,
                            "state": String(describing: setup.state)])
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
            } else {
                while setup.isBusy { try await Task.sleep(for: .milliseconds(100)) }
            }
            guard setup.isReady else { throw ModelInstallationError.invalidPackage }
            recorder.record("model-ready", ["seconds": Date().timeIntervalSince(downloadStart),
                "receipt": FluxModelPackage.isInstalled(), "archiveRemoved": !FileManager.default.fileExists(atPath: FluxModelPackage.archiveURL.path)])
            viewModel.preloadResourcesIfNeeded()
            while viewModel.isPreparing { try await Task.sleep(for: .milliseconds(100)) }
            recorder.screenshot("ready")
            let prompts = [
                "A still life photograph of a red apple next to a blue ceramic mug on a wooden table, soft window light, realistic photography.",
                "A cinematic photo of a small robot walking in Tokyo at night, neon reflections, detailed."
            ]
            for (index, prompt) in prompts.enumerated() {
                try await Task.sleep(for: .seconds(2))
                viewModel.prompt = prompt
                viewModel.seedMode = .manual
                viewModel.manualSeedText = "42"
                recorder.screenshot("prompt-\(index)")
                let start = Date()
                viewModel.generate()
                while viewModel.isGenerating { try await Task.sleep(for: .milliseconds(100)) }
                guard let image = viewModel.result else {
                    throw NSError(domain: "SetupValidation", code: 3, userInfo: [NSLocalizedDescriptionKey: viewModel.errorMessage ?? viewModel.progressTitle])
                }
                let hash = try recorder.save(image, "generated-\(index)")
                recorder.record("generation-approved", ["case": index, "seed": 42,
                    "observedSecondsIncludingSafety": Date().timeIntervalSince(start), "appTimingText": viewModel.progressDetail,
                    "pixelSHA256": hash, "views": image.decisions.map { ["sfw": $0.sfw, "nsfw": $0.nsfw, "nsfl": $0.nsfl] }])
                try await Task.sleep(for: .seconds(1))
                recorder.screenshot("generated-\(index)")
            }
            recorder.complete = true
            recorder.record("complete")
        } catch {
            recorder.record("failed", ["error": error.localizedDescription])
        }
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
