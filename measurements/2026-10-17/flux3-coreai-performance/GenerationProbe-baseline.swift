import CoreAI
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import LocalGenerationSafety
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct Caption: Decodable {
    let originalPrompt: String
    let expandedCaption: String
    let textLength: Int
    let steps: Int
    let schedule: [Float]
}

private struct Component: Decodable {
    let component: String
    let assetFilesSha256: [String: String]
    let computeDtype: String
}

private struct Plan: Decodable {
    let caption: Caption
    let components: [Component]
    let bnMean: [Float]
    let bnVar: [Float]
    let bnEps: Float
    let fixtureFilesSha256: [String: String]
}

private enum ProbeError: Error { case missingAsset(String), invalidData(String), invalidOutput(String) }

private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
}

private final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum: UInt64 = 0
    private var samples = 0
    private var lastSample: TimeInterval = 0
    private var maximumGap: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private var file: FileHandle?
    init(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: Data("uptime,physical_footprint_bytes\n".utf8))
        file = try? FileHandle(forWritingTo: url)
        try? file?.seekToEnd()
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "flux3.memory"))
        source.schedule(deadline: .now(), repeating: .milliseconds(50))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let bytes = footprint()
            self.lock.lock()
            let now = ProcessInfo.processInfo.systemUptime
            if self.lastSample > 0 { self.maximumGap = max(self.maximumGap, now - self.lastSample) }
            self.lastSample = now
            self.maximum = max(self.maximum, bytes)
            self.samples += 1
            try? self.file?.write(contentsOf: Data("\(ProcessInfo.processInfo.systemUptime),\(bytes)\n".utf8))
            self.lock.unlock()
        }
        source.resume()
        timer = source
    }
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["sampled_peak_physical_footprint_bytes": maximum, "memory_sample_count": samples, "requested_sample_interval_ms": 50, "maximum_observed_sample_gap_ms": maximumGap * 1000]
    }
    func stop() {
        timer?.cancel(); timer = nil
        lock.lock(); defer { lock.unlock() }
        try? file?.close(); file = nil
    }
}

private func loadFloats(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count % 4 == 0 else { throw ProbeError.invalidData(url.lastPathComponent) }
    return data.withUnsafeBytes { raw in
        (0..<(data.count / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
    }
}

private func array(_ values: [Float], shape: [Int], type: NDArray.ScalarType = .float16) throws -> NDArray {
    guard values.count == shape.reduce(1, *), values.allSatisfy(\.isFinite) else { throw ProbeError.invalidData("array") }
    var result = NDArray(shape: shape, scalarType: type)
    switch type {
    case .float16:
        result.mutableView(as: Float16.self).withUnsafeMutablePointer { pointer, dims, strides in
            for linear in values.indices {
                var remaining = linear; var offset = 0
                for axis in (0..<dims.count).reversed() { offset += (remaining % dims[axis]) * strides[axis]; remaining /= dims[axis] }
                pointer[offset] = Float16(values[linear])
            }
        }
    case .float32:
        result.mutableView(as: Float.self).withUnsafeMutablePointer { pointer, dims, strides in
            for linear in values.indices {
                var remaining = linear; var offset = 0
                for axis in (0..<dims.count).reversed() { offset += (remaining % dims[axis]) * strides[axis]; remaining /= dims[axis] }
                pointer[offset] = values[linear]
            }
        }
    case .bfloat16:
        result.mutableRawView().withUnsafeMutableBytes { pointer, dims, strides in
            for linear in values.indices {
                var remaining = linear; var offset = 0
                for axis in (0..<dims.count).reversed() { offset += (remaining % dims[axis]) * strides[axis]; remaining /= dims[axis] }
                let bits = values[linear].bitPattern
                pointer.storeBytes(of: UInt16(truncatingIfNeeded: (bits &+ 0x7fff &+ ((bits >> 16) & 1)) >> 16), toByteOffset: offset * 2, as: UInt16.self)
            }
        }
    case .int32:
        result.mutableView(as: Int32.self).withUnsafeMutablePointer { pointer, _, _ in
            for index in values.indices { pointer[index] = Int32(values[index]) }
        }
    default: throw ProbeError.invalidData("unsupported scalar")
    }
    return result
}

private func floats(_ source: NDArray, requireFinite: Bool = true) throws -> [Float] {
    var output = [Float](repeating: 0, count: source.shape.reduce(1, *))
    func read<T: BinaryFloatingPoint & BitwiseCopyable>(_ type: T.Type) {
        source.view(as: type).withUnsafePointer { pointer, dims, strides in
            for linear in output.indices {
                var remaining = linear; var offset = 0
                for axis in (0..<dims.count).reversed() { offset += (remaining % dims[axis]) * strides[axis]; remaining /= dims[axis] }
                output[linear] = Float(pointer[offset])
            }
        }
    }
    switch source.scalarType {
    case .float16: read(Float16.self)
    case .float32: read(Float.self)
    case .bfloat16:
        source.rawView().withUnsafeBytes { pointer, dims, strides in
            for linear in output.indices {
                var remaining = linear; var offset = 0
                for axis in (0..<dims.count).reversed() { offset += (remaining % dims[axis]) * strides[axis]; remaining /= dims[axis] }
                output[linear] = Float(bitPattern: UInt32(pointer.loadUnaligned(fromByteOffset: offset * 2, as: UInt16.self)) << 16)
            }
        }
    default: throw ProbeError.invalidOutput("scalar type")
    }
    guard !requireFinite || output.allSatisfy(\.isFinite) else { throw ProbeError.invalidOutput("nonfinite tensor") }
    return output
}

@MainActor
private final class ModelPool {
    private struct Loaded { let model: AIModel; let function: InferenceFunction }
    private var cache: [String: Loaded] = [:]
    private var order: [String] = []
    let root: URL
    let capacity: Int
    var pinned: Set<String> = []
    private var diagnosticTrace: [[String: Any]] = []
    init(root: URL, capacity: Int) { self.root = root; self.capacity = capacity }
    func clear() { cache.removeAll(); order.removeAll() }
    func run(_ name: String, _ inputs: [String: NDArray]) async throws -> [String: NDArray] {
        let loaded: Loaded
        if let prior = cache[name] { loaded = prior }
        else {
            let url = root.appendingPathComponent(name + ".aimodel", isDirectory: true)
            let model = try await AIModel(contentsOf: url, options: SpecializationOptions(preferredComputeUnitKind: .gpu))
            guard let function = try model.loadFunction(named: "main") else { throw ProbeError.missingAsset(name) }
            loaded = Loaded(model: model, function: function)
            cache[name] = loaded
        }
        order.removeAll { $0 == name }; order.append(name)
        while order.filter({ !pinned.contains($0) }).count > capacity {
            guard let index = order.firstIndex(where: { !pinned.contains($0) }) else { break }
            let evicted = order.remove(at: index); cache.removeValue(forKey: evicted)
        }
        var outputs = try await loaded.function.run(inputs: inputs)
        var arrays: [String: NDArray] = [:]
        for key in loaded.function.descriptor.outputNames {
            guard let value = outputs.remove(key)?.ndArray else { throw ProbeError.invalidOutput(name + "/" + key) }
            arrays[key] = value
        }
        if ProcessInfo.processInfo.arguments.contains("--diagnose") {
            let directory = root.deletingLastPathComponent().appendingPathComponent("Flux3Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var summaries: [String: Any] = [:]
            var allFinite = true
            for (key, value) in arrays {
                let values = try floats(value, requireFinite: false)
                var minimum = Float.greatestFiniteMagnitude
                var maximum = -Float.greatestFiniteMagnitude
                var bad = 0
                for scalar in values {
                    if scalar.isFinite { minimum = min(minimum, scalar); maximum = max(maximum, scalar) }
                    else { bad += 1 }
                }
                allFinite = allFinite && bad == 0
                summaries[key] = ["shape": value.shape, "minimum_finite": minimum, "maximum_finite": maximum, "nonfinite_count": bad]
            }
            diagnosticTrace.append(["component": name, "outputs": summaries])
            try JSONSerialization.data(withJSONObject: diagnosticTrace, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("trace.json"), options: .atomic)
            if !allFinite {
                var inputMetadata: [String: Any] = [:]
                for (key, value) in inputs where value.scalarType == .float16 || value.scalarType == .float32 || value.scalarType == .bfloat16 {
                    let values = try floats(value)
                    let filename = name + "-" + key + ".f32"
                    try values.withUnsafeBytes { Data($0) }.write(to: directory.appendingPathComponent(filename))
                    inputMetadata[key] = ["shape": value.shape, "scalar_type": String(describing: value.scalarType), "file": filename]
                }
                try JSONSerialization.data(withJSONObject: ["component": name, "inputs": inputMetadata], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("failure-inputs.json"))
                throw ProbeError.invalidOutput("nonfinite output from " + name)
            }
        }
        return arrays
    }
}

@MainActor
private final class GenerationRun: ObservableObject {
    @Published var status = "FLUX.3 CoreAI 検証を準備中"
    @Published var approvedImage: CGImage?
    private var report: [String: Any] = [:]
    private var reportDirectory: URL!
    private var sampler: MemorySampler?
    private var stepRecords: [[String: Any]] = []
    private var started = false

    private func stage(_ text: String) {
        status = text
        report["stage"] = text
        report["uptime"] = ProcessInfo.processInfo.systemUptime
        report["physical_footprint_bytes"] = footprint()
        report["available_process_memory_bytes"] = os_proc_available_memory()
        if let sampler { report.merge(sampler.snapshot()) { _, new in new } }
        report["step_records"] = stepRecords
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reportDirectory.appendingPathComponent("report.json"), options: .atomic)
        }
        print("FLUX3_GENERATION \(text) footprint=\(footprint())")
        fflush(stdout)
    }

    private func only(_ outputs: [String: NDArray], _ name: String) throws -> NDArray {
        guard let value = outputs[name] else { throw ProbeError.invalidOutput(name) }
        return value
    }

    private func blockSmoke(documents: URL) async throws {
        report["mode"] = "one_real_INT4_block_numeric_smoke"
        let root = documents.appendingPathComponent("BlockSmoke", isDirectory: true)
        guard let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("smoke.json"))) as? [String: Any],
              let component = metadata["component"] as? String, component == "shared_00",
              let hashes = metadata["asset_files_sha256"] as? [String: String],
              let fixtureHashes = metadata["fixture_hashes"] as? [String: String],
              let hiddenShape = metadata["hidden_shape"] as? [Int],
              let modsShape = metadata["mods_shape"] as? [Int] else { throw ProbeError.invalidData("block smoke") }
        stage("実重みINT4ブロックを確認中")
        for (relative, hash) in hashes {
            let bytes = try Data(contentsOf: root.appendingPathComponent(component + ".aimodel").appendingPathComponent(relative), options: .mappedIfSafe)
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hash else { throw ProbeError.invalidData(relative) }
        }
        for (relative, hash) in fixtureHashes {
            let bytes = try Data(contentsOf: root.appendingPathComponent(relative))
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hash else { throw ProbeError.invalidData(relative) }
        }
        let inputs = ["hidden": try array(loadFloats(root.appendingPathComponent("hidden.f32")), shape: hiddenShape),
                      "mods": try array(loadFloats(root.appendingPathComponent("mods.f32")), shape: modsShape)]
        let expected = try loadFloats(root.appendingPathComponent("expected.f32"))
        let pool = ModelPool(root: root, capacity: 1)
        let start = ProcessInfo.processInfo.systemUptime
        stage("実重みINT4ブロックをCoreAIで実行中")
        let actual = try floats(only(await pool.run(component, inputs), "hidden"))
        guard actual.count == expected.count else { throw ProbeError.invalidOutput("smoke shape") }
        var errorEnergy: Double = 0; var referenceEnergy: Double = 0; var maximum: Float = 0
        for (value, reference) in zip(actual, expected) {
            let difference = value - reference
            errorEnergy += Double(difference) * Double(difference)
            referenceEnergy += Double(reference) * Double(reference)
            maximum = max(maximum, abs(difference))
        }
        let relative = sqrt(errorEnergy / max(referenceEnergy, 1e-18))
        report["real_checkpoint_used"] = true
        report["coreai_execution"] = true
        report["asset_hashes_verified"] = true
        report["source_sha256"] = metadata["source_sha256"]
        report["input_shape"] = hiddenShape
        report["finite"] = true
        report["coreai_vs_quantized_pytorch_relative_rmse"] = relative
        report["max_absolute_error"] = maximum
        report["numeric_smoke_passed"] = relative < 0.01
        report["numeric_smoke_seconds"] = ProcessInfo.processInfo.systemUptime - start
        pool.clear()
        stage(relative < 0.01 ? "実重みINT4の数値確認が完了しました" : "実重みINT4の数値差を検出しました")
    }

    func run() async {
        guard !started else { return }; started = true
        let manager = FileManager.default
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        reportDirectory = documents.appendingPathComponent("Flux3Results", isDirectory: true)
        try? manager.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        sampler = MemorySampler(url: reportDirectory.appendingPathComponent("memory.csv"))
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle; sampler?.stop() }
        var machine = utsname(); uname(&machine)
        let hardware = withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        report = ["started_at": ISO8601DateFormatter().string(from: Date()), "hardware_model": hardware,
                  "os_version": UIDevice.current.systemVersion, "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
                  "real_checkpoint_used": false, "coreai_execution": false, "image_generated": false,
                  "image_approved": false, "image_saved": false, "preferred_compute_unit": "GPU; fallback allowed",
                  "bundle_id": Bundle.main.bundleIdentifier ?? "unknown", "scope": "Fixed expanded caption, offline 512px text-to-image; CoreAI linear INT4; per-component floating-point precision in model plan"]
        report["free_storage_bytes_at_start"] = (try? manager.attributesOfFileSystem(forPath: documents.path)[.systemFreeSize]) ?? 0
        stage("検証環境を準備中")
        do {
            if ProcessInfo.processInfo.arguments.contains("--block-smoke") {
                try await blockSmoke(documents: documents)
                return
            }
            let root = documents.appendingPathComponent("Flux3Models", isDirectory: true)
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let plan = try decoder.decode(Plan.self, from: Data(contentsOf: root.appendingPathComponent("model-plan.json")))
            let diffusionType: NDArray.ScalarType = plan.components.first(where: { $0.component == "input" })?.computeDtype == "bfloat16" ? .bfloat16 : .float16
            report["diffusion_compute_dtype"] = String(describing: diffusionType)
            if diffusionType == .bfloat16 {
                let test: [Float] = [0, 1, -1.25, 131072, 70144, 0.0009765625]
                guard try floats(array(test, shape: [2, 3], type: .bfloat16)) == test else { throw ProbeError.invalidData("BF16 bridge") }
                report["bf16_bridge_verified"] = true
            }
            guard plan.caption.steps == 16, plan.caption.schedule.count == 17,
                  plan.components.count == 75, Set(plan.components.map(\.component)).count == 75,
                  plan.bnMean.count == 128, plan.bnVar.count == 128 else { throw ProbeError.invalidData("plan") }
            let policy = try ContentSafetyPolicy.bundled()
            try policy.validate(plan.caption.originalPrompt, context: .generationPrompt)
            try policy.validate(plan.caption.expandedCaption, context: .generationPrompt)
            report["input_safety_passed"] = true
            report["original_prompt"] = plan.caption.originalPrompt
            report["expanded_caption"] = plan.caption.expandedCaption
            report["seed"] = 42; report["steps"] = 16; report["text_length"] = plan.caption.textLength
            stage("モデルのハッシュを確認中")
            for component in plan.components {
                let asset = root.appendingPathComponent(component.component + ".aimodel", isDirectory: true)
                for (relative, hash) in component.assetFilesSha256 {
                    let bytes = try Data(contentsOf: asset.appendingPathComponent(relative), options: .mappedIfSafe)
                    let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    guard actual == hash else { throw ProbeError.invalidData(component.component + "/" + relative) }
                }
            }
            let fixture = root.appendingPathComponent("fixture", isDirectory: true)
            for (relative, hash) in plan.fixtureFilesSha256 {
                let bytes = try Data(contentsOf: fixture.appendingPathComponent(relative))
                let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                guard actual == hash else { throw ProbeError.invalidData(relative) }
            }
            report["asset_hashes_verified"] = true
            let safetyURL = Bundle.main.url(forResource: "ImageSafetyClassifier", withExtension: "mlmodelc")
            let checker = ImageSafetyChecker(modelURL: safetyURL)
            try await checker.prepare()
            let pool = ModelPool(root: root, capacity: ProcessInfo.processInfo.arguments.contains("--resident") ? 128 : 2)
            report["model_cache_capacity"] = pool.capacity
            let encodingStart = ProcessInfo.processInfo.systemUptime
            let length = plan.caption.textLength
            stage("Qwen3-VL テキスト埋め込み")
            let tokenData = try Data(contentsOf: fixture.appendingPathComponent("token_ids.i32"))
            let tokenIDs = tokenData.withUnsafeBytes { raw in (0..<length).map { Float(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: Int32.self))) } }
            let tokenArray = try array(tokenIDs, shape: [1, length], type: .int32)
            var hidden = try only(await pool.run("te_embed", ["token_ids": tokenArray]), "hidden")
            report["real_checkpoint_used"] = true
            report["coreai_execution"] = true
            let cos = try array(loadFloats(fixture.appendingPathComponent("cos.f32")), shape: [1, length, 128])
            let sin = try array(loadFloats(fixture.appendingPathComponent("sin.f32")), shape: [1, length, 128])
            let mask = try array(loadFloats(fixture.appendingPathComponent("mask.f32")), shape: [1, 1, length, length])
            var featureLayers: [[Float]] = []
            for index in 0..<32 {
                stage("Qwen3-VL \(index + 1)/32")
                hidden = try only(await pool.run(String(format: "te_%02d", index), ["hidden": hidden, "cos": cos, "sin": sin, "mask": mask]), "hidden")
                if (index + 1) % 4 == 0 { featureLayers.append(try floats(hidden)) }
            }
            guard featureLayers.count == 8 else { throw ProbeError.invalidOutput("text features") }
            var textFeatures = [Float](repeating: 0, count: length * 20480)
            for token in 0..<length {
                for layer in 0..<8 {
                    for channel in 0..<2560 { textFeatures[token * 20480 + layer * 2560 + channel] = featureLayers[layer][token * 2560 + channel] }
                }
            }
            featureLayers.removeAll()
            let conditioning = try array(textFeatures, shape: [length, 20480], type: diffusionType)
            textFeatures.removeAll()
            pool.clear()
            report["text_encoding_seconds"] = ProcessInfo.processInfo.systemUptime - encodingStart
            pool.pinned = ["input", "join", "output"]
            var latents = try loadFloats(fixture.appendingPathComponent("noise.f32"))
            guard latents.count == 1024 * 128 else { throw ProbeError.invalidData("noise") }
            let generationStart = ProcessInfo.processInfo.systemUptime
            for step in 0..<16 {
                let stepStart = ProcessInfo.processInfo.systemUptime
                stage("FLUX.3 \(step + 1)/16 入力")
                let heads = try await pool.run("input", ["image": array(latents, shape: [1024, 128], type: diffusionType), "text": conditioning,
                    "current_t": array([plan.caption.schedule[step]], shape: [1], type: diffusionType), "target_t": array([plan.caption.schedule[step + 1]], shape: [1], type: diffusionType)])
                var imageHidden = try only(heads, "image_h")
                var textHidden = try only(heads, "text_h")
                for index in 0..<5 {
                    stage("FLUX.3 \(step + 1)/16 画像 \(index + 1)/5")
                    imageHidden = try only(await pool.run(String(format: "image_%02d", index), ["hidden": imageHidden, "mods": only(heads, "early_image")]), "hidden")
                }
                for index in 0..<5 {
                    stage("FLUX.3 \(step + 1)/16 テキスト \(index + 1)/5")
                    textHidden = try only(await pool.run(String(format: "text_%02d", index), ["hidden": textHidden, "mods": only(heads, "early_text")]), "hidden")
                }
                var shared = try only(await pool.run("join", ["image_hidden": imageHidden, "text_hidden": textHidden]), "hidden")
                for index in 0..<28 {
                    stage("FLUX.3 \(step + 1)/16 統合 \(index + 1)/28")
                    shared = try only(await pool.run(String(format: "shared_%02d", index), ["hidden": shared, "mods": only(heads, "shared_mods")]), "hidden")
                }
                let prediction = try only(await pool.run("output", ["image_hidden": shared, "image_vec": only(heads, "image_vec")]), "velocity")
                let velocity = try floats(prediction)
                guard velocity.count == latents.count else { throw ProbeError.invalidOutput("velocity shape") }
                let dt = plan.caption.schedule[step + 1] - plan.caption.schedule[step]
                for index in latents.indices { latents[index] += dt * velocity[index] }
                guard latents.allSatisfy(\.isFinite) else { throw ProbeError.invalidOutput("nonfinite latents") }
                stepRecords.append(["step": step + 1, "seconds": ProcessInfo.processInfo.systemUptime - stepStart,
                                    "latent_min": latents.min() ?? 0, "latent_max": latents.max() ?? 0])
            }
            report["denoising_seconds"] = ProcessInfo.processInfo.systemUptime - generationStart
            pool.clear(); pool.pinned = []
            stage("VAE 画像復元")
            var spatial = [Float](repeating: 0, count: 32 * 64 * 64)
            for y in 0..<32 { for x in 0..<32 { for channel in 0..<128 {
                let value = latents[(y * 32 + x) * 128 + channel] * sqrt(plan.bnVar[channel] + plan.bnEps) + plan.bnMean[channel]
                let c = channel / 4; let row = y * 2 + (channel % 4) / 2; let col = x * 2 + channel % 2
                spatial[(c * 64 + row) * 64 + col] = value
            } } }
            let decodingStart = ProcessInfo.processInfo.systemUptime
            let pixels = try floats(only(await pool.run("vae", ["spatial_latents": array(spatial, shape: [1, 32, 64, 64])]), "pixels"))
            pool.clear()
            guard pixels.count == 3 * 512 * 512 else { throw ProbeError.invalidOutput("pixels shape") }
            report["vae_seconds"] = ProcessInfo.processInfo.systemUptime - decodingStart
            report["image_generated"] = true
            var rgba = [UInt8](repeating: 255, count: 512 * 512 * 4)
            for pixel in 0..<(512 * 512) { for channel in 0..<3 {
                let value = (pixels[channel * 512 * 512 + pixel] * 0.5 + 0.5) * 255
                rgba[pixel * 4 + channel] = UInt8(max(0, min(255, value.rounded(.towardZero))))
            } }
            let bytes = Data(rgba)
            guard let provider = CGDataProvider(data: bytes as CFData), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let rawImage = CGImage(width: 512, height: 512, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 512 * 4,
                    space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ProbeError.invalidOutput("CGImage") }
            stage("6画面の安全性を確認中")
            let approved = try await checker.check(rawImage)
            report["image_approved"] = true
            report["safety_revision"] = approved.safetyRevision
            report["safety_decisions"] = approved.decisions.map { ["sfw": $0.sfw, "nsfw": $0.nsfw, "nsfl": $0.nsfl] }
            let imageURL = reportDirectory.appendingPathComponent("flux3-512-seed42-approved.png")
            guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ProbeError.invalidOutput("PNG") }
            CGImageDestinationAddImage(destination, approved.cgImage, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "AI-generated with FLUX 3 Image Klein, CoreAI INT4 experiment"]] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ProbeError.invalidOutput("PNG write") }
            report["image_saved"] = true
            report["image_filename"] = imageURL.lastPathComponent
            report["image_sha256"] = SHA256.hash(data: try Data(contentsOf: imageURL)).map { String(format: "%02x", $0) }.joined()
            report["finished_at"] = ISO8601DateFormatter().string(from: Date())
            approvedImage = approved.cgImage
            stage("生成と安全性確認が完了しました")
        } catch {
            report["failure_stage"] = report["stage"]
            report["error"] = String(describing: error)
            stage("停止: \(error.localizedDescription)")
        }
    }
}

@main
struct Flux3GenerationProbeApp: App {
    @StateObject private var run = GenerationRun()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("FLUX.3 CoreAI 実機検証").font(.headline)
                Text("512px・16ステップ・固定プロンプト").font(.caption)
                if let image = run.approvedImage { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                Text(run.status).font(.caption).multilineTextAlignment(.center)
            }.padding().task { await run.run() }
        }
    }
}
