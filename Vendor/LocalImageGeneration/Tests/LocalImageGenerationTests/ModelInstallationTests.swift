import CryptoKit
import Foundation
import Testing
@testable import LocalImageGeneration

@Suite struct ModelInstallationTests {
    @Test func resumesAcrossFragmentBoundaries() throws {
        let beginning = try FluxModelPackage.remainingSegments(at: 0)
        #expect(beginning.count == 18)
        let boundary = try FluxModelPackage.remainingSegments(at: 200_000_000)
        #expect(boundary.count == 17 && boundary[0].start == 200_000_000 && boundary[0].offset == 0)
        let partial = try FluxModelPackage.remainingSegments(at: 210_000_123)
        #expect(partial[0].start == 200_000_000 && partial[0].offset == 10_000_123)
        #expect(try FluxModelPackage.remainingSegments(at: FluxModelPackage.archiveBytes).isEmpty)
        #expect(throws: ModelInstallationError.self) { try FluxModelPackage.remainingSegments(at: -1) }
        #expect(throws: ModelInstallationError.self) { try FluxModelPackage.remainingSegments(at: FluxModelPackage.archiveBytes + 1) }
    }
    @Test func rejectsIncorrectPartialHTTPResponses() throws {
        #expect(try FluxModelPackage.acceptedOffset(status: 206, requestedOffset: 20, fragmentBytes: 100,
            contentRange: "bytes 20-99/100", contentLength: "80") == 20)
        #expect(try FluxModelPackage.acceptedOffset(status: 200, requestedOffset: 20, fragmentBytes: 100,
            contentRange: nil, contentLength: "100") == 0)
        #expect(throws: ModelInstallationError.self) {
            try FluxModelPackage.acceptedOffset(status: 206, requestedOffset: 20, fragmentBytes: 100,
                contentRange: "bytes 0-99/100", contentLength: "100")
        }
        #expect(throws: ModelInstallationError.self) {
            try FluxModelPackage.acceptedOffset(status: 200, requestedOffset: 0, fragmentBytes: 100,
                contentRange: nil, contentLength: "10")
        }
        #expect(throws: ModelInstallationError.self) {
            try FluxModelPackage.acceptedOffset(status: 403, requestedOffset: 0, fragmentBytes: 100,
                contentRange: nil, contentLength: nil)
        }
    }
    @Test func sameSizeCorruptionAndSymlinksAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("model".utf8)
        let file = directory.appendingPathComponent("weight")
        try original.write(to: file)
        let sha = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let spec = FluxModelPackage.FileSpec(path: "weight", bytes: 5, sha256: sha)
        try FluxModelPackage.verify(root: directory, files: [spec], hashes: true)
        try Data("wrong".utf8).write(to: file)
        #expect(throws: ModelInstallationError.self) { try FluxModelPackage.verify(root: directory, files: [spec], hashes: true) }
        try FileManager.default.removeItem(at: file)
        let target = directory.appendingPathComponent("target")
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: ModelInstallationError.self) { try FluxModelPackage.verify(root: directory, files: [spec], hashes: true) }
    }
    @Test(arguments: ["../weight", "/weight", "folder/../../weight", "folder\\weight"])
    func archivePathCannotEscape(_ path: String) { #expect(!FluxModelPackage.safePath(path)) }
    @Test func cancelledVerificationStops() async {
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try FluxModelPackage.verify(root: URL(fileURLWithPath: "/unused"),
                files: [.init(path: "weight", bytes: 5, sha256: "unused")], hashes: true)
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
    }
}
