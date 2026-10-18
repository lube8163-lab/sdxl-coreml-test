import Foundation
import CryptoKit
import Testing
import ZIPFoundation
@testable import LocalImageGeneration

@Suite struct ModelSelectionTests {
    @Test func eachModelHasItsOwnVerifiedPackageAndStorage() throws {
        let old = GenerationModel.flux2.package, new = GenerationModel.flux3.package
        #expect(old.installationDirectory == FluxModelPackage.installationDirectory)
        #expect(old.archiveURL == FluxModelPackage.archiveURL)
        #expect(old.archiveSHA256 == FluxModelPackage.archiveSHA256)
        #expect(old.installationDirectory != new.installationDirectory)
        #expect(old.archiveURL != new.archiveURL)
        for model in GenerationModel.allCases {
            let package = model.package
            let files = try package.files()
            #expect(files.reduce(0) { $0 + $1.bytes } == package.installedBytes)
            #expect(try package.fragments().reduce(0) { $0 + $1.bytes } == package.archiveBytes)
        }
    }
    @Test func resumesBeyondFourGigabytesWithoutMixingModelParts() throws {
        let package = GenerationModel.flux3.package
        let offset: Int64 = 4_500_000_123
        let segments = try package.remainingSegments(at: offset)
        #expect(segments.first?.start == 4_400_000_000)
        #expect(segments.first?.offset == 100_000_123)
        #expect(segments.reduce(0) { $0 + $1.fragment.bytes - $1.offset } == package.archiveBytes - offset)
        #expect(try package.remainingSegments(at: package.archiveBytes).isEmpty)
        #expect(throws: ModelInstallationError.self) { try package.remainingSegments(at: package.archiveBytes + 1) }
    }
    @Test(arguments: GenerationModel.allCases)
    func unsafePromptCannotEnterEitherRuntime(_ model: GenerationModel) async {
        let generator = LocalImageGenerator(model: model, modelDirectory: nil, safetyModelURL: nil)
        do {
            _ = try await generator.generate(prompt: "nude adult portrait", seed: 42, steps: 4) { _ in
                Issue.record("Unsafe prompt reached runtime")
            }
            Issue.record("Unsafe prompt produced an image")
        } catch { #expect(error as? PromptSafetyError == .blocked) }
    }
    @Test(arguments: [(GenerationModel.flux2, 8), (.flux3, 2), (.flux3, 32)])
    func unsupportedStepsFailBeforeModelLoading(_ input: (GenerationModel, Int)) async {
        let generator = LocalImageGenerator(model: input.0, modelDirectory: nil, safetyModelURL: nil)
        do {
            _ = try await generator.generate(prompt: "a red apple", seed: 42, steps: input.1) { _ in
                Issue.record("Unsupported step count reached runtime")
            }
            Issue.record("Unsupported step count generated output")
        } catch { #expect(error as? GenerationError == .invalidSteps) }
    }
    @Test func flux3CannotGenerateWithoutClassifier() async {
        let generator = LocalImageGenerator(model: .flux3, modelDirectory: nil, safetyModelURL: nil)
        do {
            _ = try await generator.generate(prompt: "a red apple", seed: 42, steps: 4) { _ in }
            Issue.record("Missing classifier produced output")
        } catch { #expect(error.localizedDescription.contains("安全性を確認するモデル")) }
    }

    // Real ZIP64 central directory plus two compressed records in a sparse file.
    // This checks the shipping dependency's >4GB offsets without duplicating weights.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLUX3_ZIP64_FIXTURE"] != nil))
    func zip64ReaderExtractsRecordsOnBothSidesOfFourGigabytes() throws {
        let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FLUX3_ZIP64_FIXTURE"]!)
        let zip = try Archive(url: file, accessMode: .read)
        let catalog = try GenerationModel.flux3.package.files()
        #expect(Array(zip).count == catalog.count)
        for path in ["licenses/FLUX3-LICENSE.md", "te_embed.aimodel/metadata.json"] {
            let expected = try #require(catalog.first(where: { $0.path == path }))
            let entry = try #require(zip["flux3-klein-512-v1/" + path])
            var bytes = Data()
            _ = try zip.extract(entry) { bytes.append($0) }
            #expect(bytes.count == expected.bytes)
            #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == expected.sha256)
        }
    }
}

#if canImport(CoreAI) && !targetEnvironment(simulator)
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FLUX3_CONTRACT_ROOT"] != nil))
struct Flux3TokenizerContractTests {
    struct Fixture: Decodable {
        struct Item: Decodable { let prompt: String; let ids: [Int] }
        let cases: [Item]
    }
    @Test @MainActor func swiftTokenizerMatchesPinnedPythonReference() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FLUX3_CONTRACT_ROOT"]!)
        let fixtures = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.deletingLastPathComponent().appendingPathComponent("tokenizer-contract.json")))
        let runtime = try await Flux3Runtime(directory: root)
        for item in fixtures.cases { #expect(try runtime.tokens(for: item.prompt) == item.ids) }
        #expect(throws: GenerationError.self) { try runtime.tokens(for: String(repeating: "long description ", count: 200)) }
        let first = Flux3Runtime.noise(seed: 42)
        #expect(first.count == 1024 * 128 && first.allSatisfy(\.isFinite))
        #expect(first == Flux3Runtime.noise(seed: 42))
        #expect(first != Flux3Runtime.noise(seed: 1234))
    }
}
#endif
