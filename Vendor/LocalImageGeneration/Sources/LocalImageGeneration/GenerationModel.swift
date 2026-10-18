import Foundation

public enum GenerationModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case flux2 = "flux2-klein-4b"
    case flux3 = "flux3-klein"
    public var id: String { rawValue }
    public var title: String { self == .flux2 ? "FLUX.2 Klein 4B" : "FLUX.3 Image Klein" }
    public var shortTitle: String { self == .flux2 ? "FLUX.2" : "FLUX.3" }
    public var subtitle: String {
        self == .flux2 ? "生成速度を重視したモデル" : "細部や文字の描写を試せる新しいモデル"
    }
    public var availableSteps: [Int] { self == .flux2 ? [4] : [4, 8, 16] }
    public var defaultSteps: Int { 4 }
    public var package: GenerationModelPackage { .init(model: self) }
    public var licenseURL: URL {
        URL(string: self == .flux2
            ? "https://huggingface.co/black-forest-labs/FLUX.2-klein-4B"
            : "https://huggingface.co/black-forest-labs/flux-3-image-klein/blob/main/LICENSE.md")!
    }
}

public enum GenerationSteps {
    public static func title(_ steps: Int) -> String {
        switch steps { case 4: "高速"; case 8: "標準"; case 16: "じっくり"; default: "\(steps)ステップ" }
    }
    public static func validate(_ steps: Int, for model: GenerationModel) throws {
        guard model.availableSteps.contains(steps) else { throw GenerationError.invalidSteps }
    }
}
