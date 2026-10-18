import Foundation
import CoreGraphics
import LocalGenerationSafety
#if canImport(CoreAI) && !targetEnvironment(simulator)
import CoreAI
import CoreAIDiffusionPipeline
import Tokenizers

private enum Flux3RuntimeError: Error { case invalidData(String) }

private struct Flux3Configuration: Decodable {
    let formatVersion: Int
    let revision: String
    let textLength: Int
    let imageTokens: Int
    let bnMean: [Float]
    let bnVar: [Float]
    let bnEps: Float
    let schedule16: [Float]
    let assetPaths: [String: String]
    let imageBlocks: [String]
    let textBlocks: [String]
    let sharedBlocks: [String]
}

private func loadFloats(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count % 4 == 0 else { throw Flux3RuntimeError.invalidData(url.lastPathComponent) }
    return data.withUnsafeBytes { raw in
        (0..<(data.count / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
    }
}

private func array(_ values: [Float], shape: [Int], type: NDArray.ScalarType = .float16) throws -> NDArray {
    guard values.count == shape.reduce(1, *), values.allSatisfy(\.isFinite) else { throw Flux3RuntimeError.invalidData("array") }
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
    default: throw Flux3RuntimeError.invalidData("unsupported scalar")
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
    default: throw Flux3RuntimeError.invalidData("scalar type")
    }
    guard !requireFinite || output.allSatisfy(\.isFinite) else { throw Flux3RuntimeError.invalidData("nonfinite tensor") }
    return output
}


@MainActor
final class Flux3Runtime {
    private struct Loaded { let model: AIModel; let function: InferenceFunction }
    private let directory: URL
    private let config: Flux3Configuration
    private let tokenizer: any Tokenizer
    private let cosTable: [Float]
    private let sinTable: [Float]
    private var models: [String: Loaded] = [:]
    private var pinned: Set<String> = []

    init(directory: URL) async throws {
        self.directory = directory
        config = try JSONDecoder().decode(Flux3Configuration.self,
            from: Data(contentsOf: directory.appendingPathComponent("runtime-config.json")))
        guard config.formatVersion == 1, config.revision == GenerationModel.flux3.package.revision,
              config.textLength == 160, config.imageTokens == 1024,
              config.bnMean.count == 128, config.bnVar.count == 128,
              config.bnMean.allSatisfy(\.isFinite), config.bnVar.allSatisfy({ $0.isFinite && $0 >= 0 }),
              config.bnEps.isFinite, config.bnEps > 0,
              config.schedule16.count == 17, config.schedule16.first == 1, config.schedule16.last == 0,
              config.schedule16.allSatisfy(\.isFinite),
              zip(config.schedule16, config.schedule16.dropFirst()).allSatisfy({ $0 > $1 }),
              config.assetPaths.count == 44,
              config.assetPaths.values.allSatisfy({ FluxModelPackage.safePath($0) }),
              config.imageBlocks == ["image_g00"], config.textBlocks == ["text_g00"],
              config.sharedBlocks == ["shared_g00", "shared_g01", "shared_g02", "shared_g03"] else {
            throw GenerationError.missingAssets
        }
        cosTable = try loadFloats(directory.appendingPathComponent("text-cos.f32"))
        sinTable = try loadFloats(directory.appendingPathComponent("text-sin.f32"))
        guard cosTable.count == 160 * 128, sinTable.count == 160 * 128 else { throw GenerationError.missingAssets }
        tokenizer = try await AutoTokenizer.from(modelFolder: directory.appendingPathComponent("tokenizer"))
    }

    func unload() { models.removeAll(); pinned.removeAll() }

    func tokens(for prompt: String) throws -> [Int] {
        let chat = "<|im_start|>user\n" + prompt + "<|im_end|>\n<|im_start|>assistant\n"
        let ids = tokenizer.encode(text: chat, addSpecialTokens: false)
        guard !ids.isEmpty, ids.first == 151644, ids.count <= 160 else { throw GenerationError.promptTooLong }
        return ids
    }

    private func run(_ name: String, _ inputs: [String: NDArray]) async throws -> [String: NDArray] {
        try Task.checkCancellation()
        let loaded: Loaded
        if let existing = models[name] { loaded = existing }
        else {
            guard let path = config.assetPaths[name] else { throw GenerationError.missingAssets }
            let model = try await AIModel(contentsOf: directory.appendingPathComponent(path),
                options: SpecializationOptions(preferredComputeUnitKind: .gpu))
            try Task.checkCancellation()
            guard let function = try model.loadFunction(named: "main") else { throw GenerationError.missingAssets }
            loaded = Loaded(model: model, function: function)
            if pinned.contains(name) { models[name] = loaded }
        }
        var outputs = try await loaded.function.run(inputs: inputs)
        try Task.checkCancellation()
        var values: [String: NDArray] = [:]
        for name in loaded.function.descriptor.outputNames {
            guard let array = outputs.remove(name)?.ndArray else { throw GenerationError.invalidOutput }
            values[name] = array
        }
        return values
    }

    private func only(_ outputs: [String: NDArray], _ name: String) throws -> NDArray {
        guard let value = outputs[name] else { throw GenerationError.invalidOutput }
        return value
    }

    static func noise(seed: UInt32) -> [Float] {
        var random = TorchRandomSource(seed: seed)
        return random.normalArray([1024, 128], mean: 0, stdev: 1).map { value in
            let bits = value.bitPattern
            return Float(bitPattern: (bits &+ 0x7fff &+ ((bits >> 16) & 1)) & 0xffff0000)
        }
    }

    func generate(prompt: String, seed: UInt32, steps: Int,
                  progress: @escaping @Sendable (GenerationProgress) -> Void) async throws -> CGImage {
        try GenerationSteps.validate(steps, for: .flux3)
        defer { unload() }
        let ids = try tokens(for: prompt)
        let length = config.textLength, real = ids.count
        let padded = ids + [Int](repeating: 151643, count: length - real)
        var cos = [Float](repeating: 0, count: length * 128)
        var sin = cos
        var mask = [Float](repeating: -65504, count: length * length)
        for row in 0..<length {
            let position = row < real ? row : 1
            for c in 0..<128 { cos[row * 128 + c] = cosTable[position * 128 + c]; sin[row * 128 + c] = sinTable[position * 128 + c] }
            for column in 0..<min(row + 1, real) { mask[row * length + column] = 0 }
        }
        var hidden = try only(await run("te_embed", ["token_ids": array(padded.map(Float.init), shape: [1, length], type: .int32)]), "hidden")
        let cosArray = try array(cos, shape: [1, length, 128])
        let sinArray = try array(sin, shape: [1, length, 128])
        let maskArray = try array(mask, shape: [1, 1, length, length])
        var layers: [[Float]] = []
        for index in 0..<32 {
            hidden = try only(await run(String(format: "te_%02d", index),
                ["hidden": hidden, "cos": cosArray, "sin": sinArray, "mask": maskArray]), "hidden")
            if (index + 1) % 4 == 0 { layers.append(try floats(hidden)) }
        }
        guard layers.count == 8, layers.allSatisfy({ $0.count == length * 2560 }) else { throw GenerationError.invalidOutput }
        var features = [Float](repeating: 0, count: length * 20480)
        for token in 0..<length { for layer in 0..<8 { for c in 0..<2560 {
            features[token * 20480 + layer * 2560 + c] = layers[layer][token * 2560 + c]
        } } }
        layers.removeAll()
        let conditioning = try array(features, shape: [length, 20480], type: .bfloat16)
        features.removeAll()
        let schedule = stride(from: 0, through: 16, by: 16 / steps).map { config.schedule16[$0] }
        pinned = Set(["input"] + config.textBlocks)
        let zero = try array([Float](repeating: 0, count: 1024 * 128), shape: [1024, 128], type: .bfloat16)
        var cached: [[String: NDArray]] = []
        func owned(_ value: NDArray) throws -> NDArray { try array(floats(value), shape: value.shape, type: .bfloat16) }
        for step in 0..<steps {
            let heads = try await run("input", ["image": zero, "text": conditioning,
                "current_t": array([schedule[step]], shape: [1], type: .bfloat16),
                "target_t": array([schedule[step + 1]], shape: [1], type: .bfloat16)])
            var text = try only(heads, "text_h")
            for name in config.textBlocks { text = try only(await run(name, ["hidden": text, "mods": only(heads, "early_text")]), "hidden") }
            cached.append(["text_h": try owned(text), "early_image": try owned(only(heads, "early_image")),
                "shared_mods": try owned(only(heads, "shared_mods")), "image_vec": try owned(only(heads, "image_vec"))])
        }
        unload()
        pinned = Set(["input_image", "join", "output"] + config.imageBlocks + config.sharedBlocks)
        var latents = Self.noise(seed: seed)
        progress(.denoising(step: 0, total: steps))
        for step in 0..<steps {
            let heads = cached[step]; cached[step] = [:]
            var image = try only(await run("input_image", ["image": array(latents, shape: [1024, 128], type: .bfloat16)]), "image_h")
            for name in config.imageBlocks { image = try only(await run(name, ["hidden": image, "mods": only(heads, "early_image")]), "hidden") }
            var shared = try only(await run("join", ["image_hidden": image, "text_hidden": only(heads, "text_h")]), "hidden")
            for name in config.sharedBlocks { shared = try only(await run(name, ["hidden": shared, "mods": only(heads, "shared_mods")]), "hidden") }
            let velocity = try floats(only(await run("output", ["image_hidden": shared, "image_vec": only(heads, "image_vec")]), "velocity"))
            guard velocity.count == latents.count else { throw GenerationError.invalidOutput }
            let dt = schedule[step + 1] - schedule[step]
            for index in latents.indices { latents[index] += dt * velocity[index] }
            guard latents.allSatisfy(\.isFinite) else { throw GenerationError.invalidOutput }
            progress(.denoising(step: step + 1, total: steps))
        }
        cached.removeAll(); unload()
        var spatial = [Float](repeating: 0, count: 32 * 64 * 64)
        for y in 0..<32 { for x in 0..<32 { for c in 0..<128 {
            let value = latents[(y * 32 + x) * 128 + c] * sqrt(config.bnVar[c] + config.bnEps) + config.bnMean[c]
            spatial[((c / 4) * 64 + y * 2 + (c % 4) / 2) * 64 + x * 2 + c % 2] = value
        } } }
        let pixels = try floats(only(await run("vae", ["spatial_latents": array(spatial, shape: [1, 32, 64, 64])]), "pixels"))
        guard pixels.count == 3 * 512 * 512 else { throw GenerationError.invalidOutput }
        var rgba = [UInt8](repeating: 255, count: 512 * 512 * 4)
        for pixel in 0..<(512 * 512) { for c in 0..<3 {
            rgba[pixel * 4 + c] = UInt8(max(0, min(255, ((pixels[c * 512 * 512 + pixel] * 0.5 + 0.5) * 255).rounded(.towardZero))))
        } }
        try Task.checkCancellation()
        guard let provider = CGDataProvider(data: Data(rgba) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: 512, height: 512, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 512 * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw GenerationError.invalidOutput }
        return image
    }
}
#endif
