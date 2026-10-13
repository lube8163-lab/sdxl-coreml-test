import Foundation
import Combine
import LocalImageGeneration
import UIKit

@MainActor
final class ModelSetupViewModel: NSObject, ObservableObject {
    enum State: Equatable { case idle, downloading, installing, verifying, ready, paused, failed(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published var allowsCellular = false
    private var operation: Task<Void, Never>?
    private var session: URLSession?
    private var networkTask: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var output: FileHandle?
    private var segment: FluxModelPackage.Segment?
    private var acceptedOffset: Int64 = 0
    private var received: Int64 = 0
    private var transferError: Error?
    private var lastPublication: TimeInterval = 0

    var isBusy: Bool { [.downloading, .installing, .verifying].contains(state) }
    var isReady: Bool { state == .ready }
    var savedBytes: Int64 { Int64((try? FluxModelPackage.archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    func inspectInstallation() {
        guard operation == nil, !isReady, LocalFluxGenerator.supportsGeneration else { return }
        downloadedBytes = savedBytes
        guard FluxModelPackage.isInstalled() else { return }
        state = .verifying
        operation = Task {
            defer { operation = nil }
            do {
                let verification = Task.detached(priority: .utility) { try FluxModelPackage.verifyInstalled() }
                try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
                try Task.checkCancellation()
                state = .ready
            } catch is CancellationError { state = .paused }
            catch { state = .failed(error.localizedDescription) }
        }
    }

    func start() {
        guard operation == nil, !isReady, LocalFluxGenerator.supportsGeneration else { return }
        operation = Task {
            defer { operation = nil }
            do {
                try prepareDownloadDirectory()
                state = .downloading
                progress = 0
                downloadedBytes = savedBytes
                for part in try FluxModelPackage.remainingSegments(at: downloadedBytes) {
                    try Task.checkCancellation()
                    try await download(part)
                    guard savedBytes == part.start + part.fragment.bytes else { throw ModelInstallationError.invalidResponse }
                }
                try Task.checkCancellation()
                state = .installing
                progress = 0
                let installation = Task.detached(priority: .utility) { [weak self] in
                    try FluxModelPackage.install { value in
                        Task { @MainActor [weak self] in self?.progress = value }
                    }
                }
                try await withTaskCancellationHandler { try await installation.value } onCancel: { installation.cancel() }
                try Task.checkCancellation()
                try? FileManager.default.removeItem(at: FluxModelPackage.archiveURL)
                state = .ready
                progress = 1
            } catch is CancellationError { state = .paused }
            catch let error as URLError where error.code == .cancelled { state = .paused }
            catch {
                if error as? ModelInstallationError == .corruptedDownload {
                    try? FileManager.default.removeItem(at: FluxModelPackage.archiveURL)
                    downloadedBytes = 0
                }
                state = .failed(error.localizedDescription)
            }
        }
    }

    func pause() {
        guard isBusy else { return }
        operation?.cancel()
        networkTask?.cancel()
    }

    private func prepareDownloadDirectory() throws {
        var parent = FluxModelPackage.archiveURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try parent.setResourceValues(excluded)
        if savedBytes > FluxModelPackage.archiveBytes { try FileManager.default.removeItem(at: FluxModelPackage.archiveURL) }
        let available = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        let required = FluxModelPackage.requiredFreeBytes(savedArchiveBytes: savedBytes)
        guard available.map({ $0 >= required }) ?? false else { throw ModelInstallationError.insufficientStorage }
    }

    private func download(_ part: FluxModelPackage.Segment) async throws {
        segment = part
        acceptedOffset = part.offset
        received = 0
        transferError = nil
        let url = FluxModelPackage.archiveURL
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        output = try FileHandle(forWritingTo: url)
        try output?.seek(toOffset: UInt64(part.start + part.offset))
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = allowsCellular
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        var request = URLRequest(url: part.fragment.url)
        request.setValue("bytes=\(part.offset)-", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("LocalImageGeneration/1.1", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        networkTask = task
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

extension ModelSetupViewModel: @preconcurrency URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let part = segment, let http = response as? HTTPURLResponse else { throw ModelInstallationError.invalidResponse }
            acceptedOffset = try FluxModelPackage.acceptedOffset(status: http.statusCode,
                requestedOffset: part.offset, fragmentBytes: part.fragment.bytes,
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length"))
            if acceptedOffset != part.offset {
                try output?.truncate(atOffset: UInt64(part.start))
                try output?.seek(toOffset: UInt64(part.start))
            }
            completionHandler(.allow)
        } catch { transferError = error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard transferError == nil, let part = segment, let output,
                  acceptedOffset + received + Int64(data.count) <= part.fragment.bytes else {
                throw ModelInstallationError.invalidResponse
            }
            try output.write(contentsOf: data)
            received += Int64(data.count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastPublication >= 0.25 {
                lastPublication = now
                downloadedBytes = part.start + acceptedOffset + received
                progress = Double(downloadedBytes) / Double(FluxModelPackage.archiveBytes)
            }
        } catch { transferError = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? output?.synchronize()
        try? output?.close()
        output = nil
        networkTask = nil
        self.session = nil
        downloadedBytes = savedBytes
        progress = Double(downloadedBytes) / Double(FluxModelPackage.archiveBytes)
        let pending = continuation
        continuation = nil
        session.finishTasksAndInvalidate()
        if let error = transferError ?? error { pending?.resume(throwing: error) }
        else { pending?.resume() }
    }
}
