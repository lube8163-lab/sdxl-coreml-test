import Foundation
import ZIPFoundation

/// Model-specific downloads preserve the installed FLUX.2 revision and its API.
public struct GenerationModelPackage: Sendable {
    public let model: GenerationModel
    public init(model: GenerationModel) { self.model = model }
    public var revision: String { model == .flux2 ? FluxModelPackage.revision : "coreai-flux3-512-int4-dd2ae0a-v1" }
    public var archiveBytes: Int64 { model == .flux2 ? FluxModelPackage.archiveBytes : (try? descriptor().archiveBytes) ?? 0 }
    public var installedBytes: Int64 { model == .flux2 ? FluxModelPackage.installedBytes : (try? descriptor().installedBytes) ?? 0 }
    public var archiveSHA256: String { model == .flux2 ? FluxModelPackage.archiveSHA256 : (try? descriptor().archiveSHA256) ?? "" }
    public var runtimeCacheBudgetBytes: Int64 { model == .flux2 ? FluxModelPackage.runtimeCacheBudgetBytes : 6_500_000_000 }
    public var installationDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Models/" + revision, isDirectory: true)
    }
    public var archiveURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("ModelDownloads/" + revision + ".zip")
    }
    public func requiredFreeBytes(savedArchiveBytes: Int64) -> Int64 {
        max(archiveBytes - savedArchiveBytes + installedBytes + 256 * 1024 * 1024,
            installedBytes + runtimeCacheBudgetBytes + 512 * 1024 * 1024 - savedArchiveBytes)
    }
    private struct Download: Decodable {
        let revision: String
        let modelID: String
        let archiveBytes: Int64
        let installedBytes: Int64
        let archiveSHA256: String
        let manifestSHA256: String
        let fragments: [FluxModelPackage.Fragment]
    }
    private struct Catalog: Decodable {
        let revision: String
        let modelID: String
        let width: Int
        let height: Int
        let files: [FluxModelPackage.FileSpec]
    }
    private func descriptor() throws -> Download {
        guard let url = Bundle.module.url(forResource: "flux3-download-manifest", withExtension: "json") else {
            throw ModelInstallationError.invalidPackage
        }
        let value = try JSONDecoder().decode(Download.self, from: Data(contentsOf: url))
        guard value.revision == revision, value.modelID == model.rawValue,
              value.archiveBytes > 0, value.installedBytes > 0,
              Self.validHash(value.archiveSHA256), Self.validHash(value.manifestSHA256),
              !value.fragments.isEmpty, value.fragments.count <= 64,
              value.fragments.reduce(0, { $0 + $1.bytes }) == value.archiveBytes else {
            throw ModelInstallationError.invalidPackage
        }
        return value
    }
    private static func validHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.allSatisfy({ $0.isASCII && $0.isHexDigit })
    }
    public func fragments() throws -> [FluxModelPackage.Fragment] {
        if model == .flux2 { return try FluxModelPackage.fragments() }
        let parts = try descriptor().fragments
        guard Set(parts.map(\.url)).count == parts.count,
              parts.allSatisfy({ $0.url.scheme == "https" &&
                  $0.url.host == "pub-41a85dcbeaae42d58c317781ea160d68.r2.dev" &&
                  $0.url.path.hasPrefix("/CoreAI/generation/flux3-klein-512-int4-dd2ae0a-v1/") &&
                  $0.bytes > 0 && $0.bytes <= 200_000_000 && Self.validHash($0.sha256) }) else {
            throw ModelInstallationError.invalidPackage
        }
        return parts
    }
    public func remainingSegments(at offset: Int64) throws -> [FluxModelPackage.Segment] {
        guard (0...archiveBytes).contains(offset) else { throw ModelInstallationError.corruptedDownload }
        var start: Int64 = 0
        return try fragments().compactMap { fragment in
            defer { start += fragment.bytes }
            guard start + fragment.bytes > offset else { return nil }
            return .init(fragment: fragment, start: start, offset: max(0, offset - start))
        }
    }
    func files() throws -> [FluxModelPackage.FileSpec] {
        if model == .flux2 { return try FluxModelPackage.files() }
        guard let url = Bundle.module.url(forResource: "flux3-catalog-manifest", withExtension: "json"),
              try FluxModelPackage.fileSHA256(url) == descriptor().manifestSHA256 else {
            throw ModelInstallationError.invalidPackage
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        guard catalog.revision == revision, catalog.modelID == model.rawValue,
              catalog.width == 512, catalog.height == 512,
              Set(catalog.files.map(\.path)).count == catalog.files.count,
              catalog.files.allSatisfy({ FluxModelPackage.safePath($0.path) && $0.bytes > 0 && Self.validHash($0.sha256) }),
              catalog.files.reduce(0, { $0 + $1.bytes }) == installedBytes,
              catalog.files.contains(where: { $0.path == "runtime-config.json" }),
              catalog.files.contains(where: { $0.path == "licenses/FLUX3-LICENSE.md" }) else {
            throw ModelInstallationError.invalidPackage
        }
        return catalog.files
    }
    public func isInstalled(at root: URL? = nil) -> Bool {
        let root = root ?? installationDirectory
        guard let marker = try? Data(contentsOf: root.appendingPathComponent(".installed")),
              String(decoding: marker, as: UTF8.self) == revision, let files = try? files() else { return false }
        return (try? FluxModelPackage.verify(root: root, files: files, hashes: false)) != nil
    }
    public func verifyInstalled(at root: URL? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }) throws {
        let root = root ?? installationDirectory
        guard isInstalled(at: root) else { throw ModelInstallationError.invalidPackage }
        try FluxModelPackage.verify(root: root, files: files(), hashes: true, progress: progress)
    }
    public func install(archive: URL? = nil, at destination: URL? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }) throws {
        let archive = archive ?? archiveURL, destination = destination ?? installationDirectory
        if model == .flux2 { try FluxModelPackage.install(archive: archive, at: destination, progress: progress); return }
        guard try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(archiveBytes),
              try FluxModelPackage.fileSHA256(archive) == archiveSHA256 else { throw ModelInstallationError.corruptedDownload }
        let fm = FileManager.default, parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var staging = parent.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
        let backup = parent.appendingPathComponent(".previous-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let zip = try Archive(url: archive, accessMode: .read)
        let root = "flux3-klein-512-v1/"
        var expanded: UInt64 = 0
        var extracted: Set<String> = []
        for entry in zip {
            try Task.checkCancellation()
            guard FluxModelPackage.safePath(entry.path), entry.type != .symlink,
                  entry.path.hasPrefix(root) else { throw ModelInstallationError.invalidPackage }
            expanded += entry.uncompressedSize
            guard expanded <= UInt64(installedBytes + 16 * 1024 * 1024) else { throw ModelInstallationError.invalidPackage }
            let relative = String(entry.path.dropFirst(root.count))
            guard !relative.isEmpty else { continue }
            guard extracted.insert(relative).inserted else { throw ModelInstallationError.invalidPackage }
            let output = staging.appendingPathComponent(relative)
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try autoreleasepool { try zip.extract(entry, to: output, skipCRC32: true) }
            progress(min(0.7, 0.7 * Double(expanded) / Double(installedBytes)))
        }
        try FluxModelPackage.verify(root: staging, files: files(), hashes: true) { progress(0.7 + 0.3 * $0) }
        try Data(revision.utf8).write(to: staging.appendingPathComponent(".installed"), options: .atomic)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try staging.setResourceValues(excluded)
        try Task.checkCancellation()
        let hadPrevious = fm.fileExists(atPath: destination.path)
        if hadPrevious { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: staging, to: destination) }
        catch { if hadPrevious { try? fm.moveItem(at: backup, to: destination) }; throw error }
        if hadPrevious { try? fm.removeItem(at: backup) }
    }
}
