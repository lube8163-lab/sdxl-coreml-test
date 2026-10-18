import CryptoKit
import Foundation
import ZIPFoundation

public enum ModelInstallationError: Error, LocalizedError, Equatable {
    case invalidPackage, corruptedDownload, insufficientStorage, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .invalidPackage: "モデルを確認できませんでした。ダウンロードをやり直してください。"
        case .corruptedDownload: "ダウンロード内容を確認できませんでした。もう一度お試しください。"
        case .insufficientStorage: "モデルの準備に必要な空き容量が足りません。画面に表示された容量を確認して、空き容量を増やしてください。"
        case .invalidResponse: "配布サーバーからダウンロードできませんでした。通信状況を確認して再開してください。"
        }
    }
}

public enum FluxModelPackage {
    public static let revision = "coreai-512-4bit-a7f65cd-v1"
    public static let archiveBytes: Int64 = 3_542_141_404
    public static let installedBytes: Int64 = 4_043_710_174
    // The tested iPhone's compiled CoreAI cache uses ~4.03 GB in addition to weights.
    public static let runtimeCacheBudgetBytes: Int64 = 4_250_000_000
    public static func requiredFreeBytes(savedArchiveBytes: Int64) -> Int64 {
        max(archiveBytes - savedArchiveBytes + installedBytes + 256 * 1024 * 1024,
            installedBytes + runtimeCacheBudgetBytes + 512 * 1024 * 1024 - savedArchiveBytes)
    }
    public static let archiveSHA256 = "9eee2a1226677c396c165b7204d912a3c1d785fd89aa8b7b22b7aa7ac3af3968"

    public struct Fragment: Decodable, Sendable {
        public let url: URL
        public let bytes: Int64
        public let sha256: String
    }
    public struct Segment: Sendable {
        public let fragment: Fragment
        public let start: Int64
        public let offset: Int64
    }
    public static func remainingSegments(at offset: Int64) throws -> [Segment] {
        guard (0...archiveBytes).contains(offset) else { throw ModelInstallationError.corruptedDownload }
        var start: Int64 = 0
        return try fragments().compactMap { fragment in
            defer { start += fragment.bytes }
            guard start + fragment.bytes > offset else { return nil }
            return Segment(fragment: fragment, start: start, offset: max(0, offset - start))
        }
    }
    public static func acceptedOffset(status: Int, requestedOffset: Int64, fragmentBytes: Int64,
        contentRange: String?, contentLength: String?) throws -> Int64 {
        guard [200, 206].contains(status), requestedOffset >= 0, requestedOffset < fragmentBytes else {
            throw ModelInstallationError.invalidResponse
        }
        let accepted = status == 200 ? 0 : requestedOffset
        if status == 206 {
            guard contentRange == "bytes \(accepted)-\(fragmentBytes - 1)/\(fragmentBytes)" else {
                throw ModelInstallationError.invalidResponse
            }
        }
        if let contentLength, Int64(contentLength) != fragmentBytes - accepted {
            throw ModelInstallationError.invalidResponse
        }
        return accepted
    }
    struct FileSpec: Decodable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }
    private struct Catalog: Decodable {
        let revision: String
        let modelID: String
        let width: Int
        let height: Int
        let files: [FileSpec]
    }
    private struct Download: Decodable { let fragments: [Fragment] }

    public static var installationDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Models/" + revision, isDirectory: true)
    }
    public static var archiveURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("ModelDownloads/" + revision + ".zip")
    }
    public static func fragments() throws -> [Fragment] {
        guard let url = Bundle.module.url(forResource: "flux2-download-manifest", withExtension: "json") else {
            throw ModelInstallationError.invalidPackage
        }
        let result = try JSONDecoder().decode(Download.self, from: Data(contentsOf: url)).fragments
        guard result.count == 18, result.reduce(0, { $0 + $1.bytes }) == archiveBytes,
              result.allSatisfy({ $0.url.scheme == "https" &&
                  $0.url.host == "pub-41a85dcbeaae42d58c317781ea160d68.r2.dev" &&
                  $0.url.path.hasPrefix("/CoreAI/generation/flux2-klein-4b-512-a7f65cd-v1/") && $0.bytes > 0 }) else {
            throw ModelInstallationError.invalidPackage
        }
        return result
    }
    static func files() throws -> [FileSpec] {
        guard let url = Bundle.module.url(forResource: "flux2-catalog-manifest", withExtension: "json") else {
            throw ModelInstallationError.invalidPackage
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        guard catalog.revision == revision, catalog.modelID == "flux2-klein-4b",
              catalog.width == 512, catalog.height == 512, catalog.files.count == 17,
              catalog.files.reduce(0, { $0 + $1.bytes }) == installedBytes else {
            throw ModelInstallationError.invalidPackage
        }
        return catalog.files
    }
    public static func isInstalled(at root: URL = installationDirectory) -> Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(".installed")),
              String(decoding: data, as: UTF8.self) == revision,
              let files = try? files() else { return false }
        return (try? verify(root: root, files: files, hashes: false)) != nil
    }
    public static func verifyInstalled(at root: URL = installationDirectory,
        progress: @escaping @Sendable (Double) -> Void = { _ in }) throws {
        guard isInstalled(at: root) else { throw ModelInstallationError.invalidPackage }
        try verify(root: root, files: files(), hashes: true, progress: progress)
    }
    static func verify(root: URL, files: [FileSpec], hashes: Bool,
        progress: @escaping @Sendable (Double) -> Void = { _ in }) throws {
        let total = files.reduce(0, { $0 + $1.bytes })
        var checked: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            guard safePath(file.path) else { throw ModelInstallationError.invalidPackage }
            let url = root.appendingPathComponent(file.path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize == Int(file.bytes) else { throw ModelInstallationError.invalidPackage }
            if hashes, try fileSHA256(url) != file.sha256 { throw ModelInstallationError.invalidPackage }
            checked += file.bytes
            progress(total > 0 ? Double(checked) / Double(total) : 1)
        }
    }
    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") &&
            !path.split(separator: "/").contains("..")
    }
    public static func fileSHA256(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var digest = SHA256()
        while true {
            let consumed = try autoreleasepool {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 2 * 1024 * 1024), !chunk.isEmpty else { return false }
                digest.update(data: chunk)
                return true
            }
            if !consumed { break }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func install(archive: URL = archiveURL, at destination: URL = installationDirectory,
        progress: @escaping @Sendable (Double) -> Void = { _ in }) throws {
        guard try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(archiveBytes),
              try fileSHA256(archive) == archiveSHA256 else { throw ModelInstallationError.corruptedDownload }
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var staging = parent.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
        let backup = parent.appendingPathComponent(".previous-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let zip = try Archive(url: archive, accessMode: .read)
        var expanded: UInt64 = 0
        for entry in zip {
            try Task.checkCancellation()
            guard safePath(entry.path), entry.type != .symlink,
                  entry.path.hasPrefix("flux2-klein-4b-512-v1/") else {
                throw ModelInstallationError.invalidPackage
            }
            expanded += entry.uncompressedSize
            guard expanded <= UInt64(installedBytes + 16 * 1024 * 1024) else { throw ModelInstallationError.invalidPackage }
            let relative = String(entry.path.dropFirst("flux2-klein-4b-512-v1/".count))
            guard !relative.isEmpty else { continue }
            let output = staging.appendingPathComponent(relative)
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Archive SHA-256 and every required extracted file hash are compulsory.
            _ = try autoreleasepool { try zip.extract(entry, to: output, skipCRC32: true) }
            progress(min(0.7, 0.7 * Double(expanded) / Double(installedBytes)))
        }
        try verify(root: staging, files: files(), hashes: true) { progress(0.7 + 0.3 * $0) }
        try Data(revision.utf8).write(to: staging.appendingPathComponent(".installed"), options: .atomic)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try staging.setResourceValues(excluded)
        try Task.checkCancellation()
        let hadPrevious = fm.fileExists(atPath: destination.path)
        if hadPrevious { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: staging, to: destination) }
        catch {
            if hadPrevious { try? fm.moveItem(at: backup, to: destination) }
            throw error
        }
        if hadPrevious { try? fm.removeItem(at: backup) }
    }
}
