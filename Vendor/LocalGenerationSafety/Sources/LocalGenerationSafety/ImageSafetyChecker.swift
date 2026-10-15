import CoreGraphics
import CoreML
import Foundation
import Vision

public enum ImageSafetyError: Error, LocalizedError, Equatable {
    case unavailable, invalidResult, blocked

    public var errorDescription: String? {
        switch self {
        case .unavailable: "画像の安全性を確認するモデルを読み込めません。画像は表示・保存できません。"
        case .invalidResult: "画像の安全性を確認できませんでした。画像は表示・保存できません。"
        case .blocked: "安全性の確認により、この画像は表示・保存できません。内容を変えてお試しください。"
        }
    }
}

public struct ImageSafetyDecision: Sendable {
    public static let revision = "swiftformer-1d648298-sixviews-all-sfw90-v2"
    public let nsfw: Double
    public let nsfl: Double
    public let sfw: Double

    public init(nsfw: Double, nsfl: Double, sfw: Double) {
        self.nsfw = nsfw
        self.nsfl = nsfl
        self.sfw = sfw
    }

    public var isValid: Bool {
        let values = [nsfw, nsfl, sfw]
        return values.allSatisfy { $0.isFinite && (0...1).contains($0) }
            && abs(values.reduce(0, +) - 1) < 0.02
    }

    public var permitsDisplay: Bool {
        isValid && sfw >= 0.90 && nsfw + nsfl <= 0.10
    }
}

/// The initializer is private to the gate. UI, Photos and sharing receive only checked images.
public struct SafetyCheckedImage: Sendable {
    public let cgImage: CGImage
    public let decisions: [ImageSafetyDecision]
    public var safetyRevision: String { ImageSafetyDecision.revision }

    fileprivate init(cgImage: CGImage, decisions: [ImageSafetyDecision]) {
        self.cgImage = cgImage
        self.decisions = decisions
    }
}

enum ImageSafetyGate {
    static func approve(_ image: CGImage, decisions: [ImageSafetyDecision]) throws -> SafetyCheckedImage {
        try Task.checkCancellation()
        guard decisions.count == 6, decisions.allSatisfy(\.isValid) else {
            throw ImageSafetyError.invalidResult
        }
        // A safe-looking full frame cannot override an uncertain or unsafe region.
        // Require positive clearance from every view, accepting benign refusals
        // when a context-poor crop cannot be confidently cleared.
        guard decisions.allSatisfy(\.permitsDisplay) else {
            throw ImageSafetyError.blocked
        }
        return SafetyCheckedImage(cgImage: image, decisions: decisions)
    }
}

/// One actor serializes classifier use and keeps its small model separate from FLUX GPU weights.
public actor ImageSafetyChecker {
    private let modelURL: URL?
    private var model: VNCoreMLModel?

    public init(modelURL: URL?) { self.modelURL = modelURL }

    public func prepare() throws {
        try Task.checkCancellation()
        guard model == nil else { return }
        guard let modelURL else { throw ImageSafetyError.unavailable }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let mlModel = try MLModel(contentsOf: modelURL, configuration: configuration)
            guard let labels = mlModel.modelDescription.classLabels as? [String],
                  Set(labels) == Set(["SFW", "NSFW", "NSFL"]) else {
                throw ImageSafetyError.invalidResult
            }
            model = try VNCoreMLModel(for: mlModel)
        } catch is CancellationError { throw CancellationError() }
        catch { throw ImageSafetyError.unavailable }
    }

    public func check(_ image: CGImage) throws -> SafetyCheckedImage {
        try prepare()
        guard let model, image.width >= 64, image.height >= 64 else {
            throw ImageSafetyError.invalidResult
        }
        let views = try Self.views(of: image)
        let decisions = try autoreleasepool {
            try views.map { view -> ImageSafetyDecision in
                try Task.checkCancellation()
                let request = VNCoreMLRequest(model: model)
                request.imageCropAndScaleOption = .scaleFit
                try VNImageRequestHandler(cgImage: view, orientation: .up).perform([request])
                guard let results = request.results as? [VNClassificationObservation],
                      results.count == 3,
                      let sfw = results.first(where: { $0.identifier == "SFW" }),
                      let nsfw = results.first(where: { $0.identifier == "NSFW" }),
                      let nsfl = results.first(where: { $0.identifier == "NSFL" }) else {
                    throw ImageSafetyError.invalidResult
                }
                return .init(nsfw: Double(nsfw.confidence), nsfl: Double(nsfl.confidence),
                             sfw: Double(sfw.confidence))
            }
        }
        if ProcessInfo.processInfo.environment["LOCAL_GENERATION_SAFETY_DIAGNOSTICS"] == "1" {
            for (index, decision) in decisions.enumerated() {
                print("SAFETY_VIEW \(index) SFW=\(decision.sfw) NSFW=\(decision.nsfw) NSFL=\(decision.nsfl)")
            }
        }
        return try ImageSafetyGate.approve(views[0], decisions: decisions)
    }

    static func views(of image: CGImage) throws -> [CGImage] {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let w = floor(width * 0.67), h = floor(height * 0.67)
        let origins: [CGPoint] = [
            .init(x: 0, y: 0), .init(x: width - w, y: 0),
            .init(x: 0, y: height - h), .init(x: width - w, y: height - h),
            .init(x: floor((width - w) / 2), y: floor((height - h) / 2))
        ]
        func rasterize(origin: CGPoint, width outWidth: Int, height outHeight: Int) throws -> CGImage {
            // Materialize independent contiguous pixels. Core Image in macOS 27.0.1 can
            // read beyond a bottom/right CGImage crop's strided data provider.
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: outWidth, height: outHeight,
                    bitsPerComponent: 8, bytesPerRow: outWidth * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ImageSafetyError.invalidResult
            }
            context.translateBy(x: -origin.x, y: -origin.y)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let rendered = context.makeImage() else { throw ImageSafetyError.invalidResult }
            return rendered
        }
        return try [rasterize(origin: .zero, width: image.width, height: image.height)] + origins.map {
            try rasterize(origin: $0, width: Int(w), height: Int(h))
        }
    }

    public func unload() { model = nil }
}
