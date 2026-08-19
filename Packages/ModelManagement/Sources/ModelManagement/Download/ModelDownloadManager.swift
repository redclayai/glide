import Foundation
import ModelRuntime
import Observation
import os

/// Downloads catalog GGUFs on demand into KeyType's per-user Models directory.
///
/// This intentionally only manages the GGUF file. ACPF profile generation (which needs the llama
/// runtime) is a separate concern handled by `ProfileGenerator`; an orchestrator in the app target
/// chains the two so a model is only "ready" once both files exist.
@MainActor
@Observable
public final class ModelDownloadManager {

    /// Per-model state, keyed by GGUF filename.
    public private(set) var states: [String: ModelDownloadState] = [:]

    /// Invoked on the main actor after a model's GGUF is validated and committed to disk. The app
    /// uses this to kick off ACPF profile generation and refresh the runtime's model list.
    public var onGGUFInstalled: ((DownloadableRuntimeModel) -> Void)?

    private let modelsDirectoryURL: URL
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    /// The in-flight session delegate per filename, so `pause(filename:)` can reach the live task.
    private var activeDelegates: [String: ModelDownloadSessionDelegate] = [:]
    /// `URLSession` resume blobs captured when a download is paused, keyed by filename.
    private var resumeDataByFilename: [String: Data] = [:]
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "model-download")

    public let catalog: [DownloadableRuntimeModel]

    /// `modelsDirectoryURL` defaults to `ModelContainer.modelsDirectoryURL(create:)`. Tests pass a
    /// temporary directory.
    public init(
        catalog: [DownloadableRuntimeModel] = RuntimeModelCatalog.models,
        modelsDirectoryURL: URL? = nil
    ) {
        self.catalog = catalog
        if let modelsDirectoryURL {
            self.modelsDirectoryURL = modelsDirectoryURL
        } else {
            self.modelsDirectoryURL = (try? ModelContainer.modelsDirectoryURL(create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }
        refreshStates()
    }

    // MARK: - Queries

    public func state(forFilename filename: String) -> ModelDownloadState {
        states[filename] ?? .idle
    }

    public func state(for model: DownloadableRuntimeModel) -> ModelDownloadState {
        state(forFilename: model.filename)
    }

    public func isInstalled(filename: String) -> Bool {
        let url = modelsDirectoryURL.appendingPathComponent(filename, isDirectory: false)
        return ModelContainer.modelExists(at: url)
    }

    /// Recomputes every catalog entry's state from disk + in-flight tasks. An installed file reads
    /// as `.downloaded`; a tracked task as `.downloading`; a paused download keeps its `.paused`
    /// state; a failure is preserved until retried; otherwise `.idle`.
    public func refreshStates() {
        for model in catalog {
            if downloadTasks[model.filename] != nil {
                if case .downloading = states[model.filename] { continue }
                states[model.filename] = .downloading(progress: nil)
            } else if isInstalled(filename: model.filename) {
                states[model.filename] = .downloaded
            } else if states[model.filename]?.isPaused == true {
                continue
            } else if case .failed = states[model.filename] {
                // Preserve a failure message until the user retries.
                continue
            } else {
                states[model.filename] = .idle
            }
        }
    }

    // MARK: - Download

    public func download(_ model: DownloadableRuntimeModel) {
        guard downloadTasks[model.filename] == nil else { return }

        if isInstalled(filename: model.filename) {
            states[model.filename] = .downloaded
            onGGUFInstalled?(model)
            return
        }

        guard model.isDownloadable, let url = model.downloadURL else {
            let reason = model.unavailableReason ?? "This model can't be downloaded yet."
            states[model.filename] = .failed(reason)
            return
        }

        resumeDataByFilename[model.filename] = nil
        startTask(model, url: url, resumeData: nil)
    }

    /// Resume a paused download, continuing from the captured offset when possible. Falls back to a
    /// fresh download if there is no resume blob.
    public func resume(_ model: DownloadableRuntimeModel) {
        guard downloadTasks[model.filename] == nil else { return }
        guard let url = model.downloadURL else { download(model); return }
        startTask(model, url: url, resumeData: resumeDataByFilename[model.filename])
    }

    /// Pause an in-flight download, capturing resume data so it can continue later. A no-op when the
    /// model isn't currently downloading.
    public func pause(filename: String) {
        guard downloadTasks[filename] != nil, states[filename]?.isDownloading == true else { return }
        activeDelegates[filename]?.pause()
    }

    /// User-initiated cancel. Stops any in-flight download and discards resume data; a paused
    /// download is reset to idle.
    public func cancel(filename: String) {
        resumeDataByFilename[filename] = nil
        if let task = downloadTasks[filename] {
            task.cancel()
        } else if states[filename]?.isPaused == true {
            states[filename] = isInstalled(filename: filename) ? .downloaded : .idle
        }
    }

    public func cancelAll() {
        for filename in downloadTasks.keys { cancel(filename: filename) }
    }

    private func startTask(_ model: DownloadableRuntimeModel, url: URL, resumeData: Data?) {
        states[model.filename] = .downloading(progress: progressFraction(forFilename: model.filename))
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(model, url: url, resumeData: resumeData)
        }
        downloadTasks[model.filename] = task
    }

    private func progressFraction(forFilename filename: String) -> Double? {
        states[filename]?.progressFraction
    }

    private func runDownload(_ model: DownloadableRuntimeModel, url: URL, resumeData: Data?) async {
        let filename = model.filename
        defer {
            downloadTasks[filename] = nil
            activeDelegates[filename] = nil
        }
        do {
            try await fetchValidateInstall(model, url: url, resumeData: resumeData)
            resumeDataByFilename[filename] = nil
            log.info("Download complete for \(filename, privacy: .public)")
            states[filename] = .downloaded
            onGGUFInstalled?(model)
        } catch let paused as ModelDownloadSessionDelegate.DownloadPaused {
            resumeDataByFilename[filename] = paused.resumeData
            states[filename] = .paused(progress: progressFraction(forFilename: filename))
            log.info("Download paused for \(filename, privacy: .public)")
        } catch {
            if DownloadOutcomeClassifier.isUserCancellation(error) {
                resumeDataByFilename[filename] = nil
                log.info("Download cancelled for \(filename, privacy: .public)")
                states[filename] = isInstalled(filename: filename) ? .downloaded : .idle
            } else {
                log.error("Download failed for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                states[filename] = .failed(error.localizedDescription)
            }
        }
    }

    private func fetchValidateInstall(_ model: DownloadableRuntimeModel, url: URL, resumeData: Data?) async throws {
        try ensureModelsDirectoryExists()
        let destinationURL = modelsDirectoryURL.appendingPathComponent(model.filename, isDirectory: false)

        let progressHandler: @Sendable (Double?) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.downloadTasks[model.filename] != nil,
                      self.states[model.filename]?.isDownloading == true else { return }
                self.states[model.filename] = .downloading(progress: progress)
            }
        }

        let result = try await fetch(
            filename: model.filename,
            url: url,
            resumeData: resumeData,
            progressHandler: progressHandler
        )
        try Task.checkCancellation()
        try validate(response: result.response)

        let fileManager = FileManager.default
        let stagingURL = modelsDirectoryURL.appendingPathComponent(
            "\(model.filename).staging-\(UUID().uuidString)", isDirectory: false
        )
        try fileManager.moveItem(at: result.temporaryURL, to: stagingURL)

        do {
            try ModelFileValidator.validateSize(of: stagingURL, expectedBytes: model.expectedSizeBytes)
            try ModelFileValidator.validateSHA256(of: stagingURL, expectedSHA256: model.sha256)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: stagingURL, to: destinationURL)
    }

    /// Resolves a download result: resumes from `resumeData` when present (falling back to a fresh
    /// download if the resume blob is rejected), otherwise downloads fresh with mirror fallback.
    private func fetch(
        filename: String,
        url: URL,
        resumeData: Data?,
        progressHandler: @escaping @Sendable (Double?) -> Void
    ) async throws -> ModelDownloadSessionDelegate.DownloadResult {
        if let resumeData {
            let delegate = ModelDownloadSessionDelegate(progressHandler: progressHandler)
            activeDelegates[filename] = delegate
            do {
                return try await delegate.download(resumeData: resumeData)
            } catch let paused as ModelDownloadSessionDelegate.DownloadPaused {
                throw paused
            } catch {
                if DownloadOutcomeClassifier.isUserCancellation(error) { throw error }
                // Stale/invalid resume blob — start over rather than stranding the user.
                try Task.checkCancellation()
                progressHandler(0)
                return try await fetchFresh(filename: filename, url: url, progressHandler: progressHandler)
            }
        }
        return try await fetchFresh(filename: filename, url: url, progressHandler: progressHandler)
    }

    /// Fresh download of `url`, transparently retrying against the Hugging Face mirror
    /// (`hf-mirror.com`) when the primary host is unreachable. Cancellation, pause, and
    /// non-connectivity failures are not retried.
    private func fetchFresh(
        filename: String,
        url: URL,
        progressHandler: @escaping @Sendable (Double?) -> Void
    ) async throws -> ModelDownloadSessionDelegate.DownloadResult {
        let delegate = ModelDownloadSessionDelegate(progressHandler: progressHandler)
        activeDelegates[filename] = delegate
        do {
            return try await delegate.download(from: url)
        } catch let paused as ModelDownloadSessionDelegate.DownloadPaused {
            throw paused
        } catch {
            guard !DownloadOutcomeClassifier.isUserCancellation(error),
                  HuggingFaceMirror.isUnreachableHostError(error),
                  let mirrorURL = HuggingFaceMirror.mirrorURL(for: url) else {
                throw error
            }
            try Task.checkCancellation()
            log.info("huggingface.co unreachable for \(filename, privacy: .public); retrying via \(HuggingFaceMirror.mirrorHost, privacy: .public)")
            progressHandler(0)
            let mirrorDelegate = ModelDownloadSessionDelegate(progressHandler: progressHandler)
            activeDelegates[filename] = mirrorDelegate
            return try await mirrorDelegate.download(from: mirrorURL)
        }
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw DownloadError.badStatus(http.statusCode)
        }
    }

    // MARK: - Local import / delete

    /// Copies a user-selected GGUF into the Models directory (off the main thread for large files).
    /// The app owns the file picker (AppKit); this is the Foundation-only copy step.
    public func installLocalModel(from sourceURL: URL) async throws {
        try ensureModelsDirectoryExists()
        let destinationURL = modelsDirectoryURL.appendingPathComponent(
            sourceURL.lastPathComponent, isDirectory: false
        )
        let destinationPath = destinationURL.path
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destinationPath) {
                try fileManager.removeItem(atPath: destinationPath)
            }
            try fileManager.copyItem(at: sourceURL, to: URL(fileURLWithPath: destinationPath))
        }.value
        states[sourceURL.lastPathComponent] = .downloaded
        refreshStates()
    }

    public func deleteModel(filename: String) {
        let url = modelsDirectoryURL.appendingPathComponent(filename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        refreshStates()
    }

    private func ensureModelsDirectoryExists() throws {
        try FileManager.default.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true)
    }

    public enum DownloadError: Error, CustomStringConvertible {
        case badStatus(Int)
        public var description: String {
            switch self {
            case let .badStatus(code):
                return "Model download failed with HTTP status \(code)."
            }
        }
    }
}

/// Bridges `URLSessionDownloadDelegate` into one async result plus incremental progress. Needed
/// because `URLSession.download(from:)` lacks observable progress suitable for SwiftUI, and so a
/// download can be paused (producing resume data) and resumed later.
private final class ModelDownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    struct DownloadResult {
        let temporaryURL: URL
        let response: URLResponse
    }

    /// Thrown out of `download(...)` when the user pauses. Carries the `URLSession` resume blob
    /// (`nil` if the server doesn't support resuming, in which case a later resume restarts).
    struct DownloadPaused: Error {
        let resumeData: Data?
    }

    private let progressHandler: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<DownloadResult, Error>?
    private var rescuedURL: URL?
    private var response: URLResponse?
    private var hasCompleted = false
    private var activeTask: URLSessionDownloadTask?
    private var finishError: Error?
    /// Set when `pause()` is requested so `didCompleteWithError` resolves as paused (not cancelled).
    private var isPausing = false

    init(progressHandler: @escaping @Sendable (Double?) -> Void) {
        self.progressHandler = progressHandler
    }

    func download(from url: URL) async throws -> DownloadResult {
        try await run { session in session.downloadTask(with: url) }
    }

    func download(resumeData: Data) async throws -> DownloadResult {
        try await run { session in session.downloadTask(withResumeData: resumeData) }
    }

    private func run(
        _ makeTask: @escaping (URLSession) -> URLSessionDownloadTask
    ) async throws -> DownloadResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task = makeTask(session)
                self.activeTask = task
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.activeTask?.cancel()
        }
    }

    /// Cancels the task while producing resume data; resolves the call as `DownloadPaused`.
    func pause() {
        guard !hasCompleted, let task = activeTask else { return }
        isPausing = true
        task.cancel(byProducingResumeData: { [weak self] data in
            self?.finishPaused(resumeData: data)
        })
    }

    private func finishPaused(resumeData: Data?) {
        guard !hasCompleted else { return }
        hasCompleted = true
        if let rescuedURL { try? FileManager.default.removeItem(at: rescuedURL) }
        rescuedURL = nil
        continuation?.resume(throwing: DownloadPaused(resumeData: resumeData))
        continuation = nil
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress: Double? = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : nil
        progressHandler(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file is deleted when this callback returns, so move it somewhere we own now.
        let holding = FileManager.default.temporaryDirectory
            .appendingPathComponent("keytype-model-\(UUID().uuidString)", isDirectory: false)
        do {
            try FileManager.default.moveItem(at: location, to: holding)
            rescuedURL = holding
        } catch {
            finishError = error
        }
        response = downloadTask.response
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !hasCompleted else { return }
        // When pausing, resume data normally arrives via the `cancel(byProducingResumeData:)`
        // closure; if this fires first, recover it from the cancellation error's userInfo.
        if isPausing {
            let resumeData = (error as NSError?)?
                .userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            finishPaused(resumeData: resumeData)
            session.finishTasksAndInvalidate()
            return
        }
        hasCompleted = true
        defer {
            continuation = nil
            session.finishTasksAndInvalidate()
        }
        if let failure = error ?? finishError {
            if let rescuedURL { try? FileManager.default.removeItem(at: rescuedURL) }
            rescuedURL = nil
            continuation?.resume(throwing: failure)
            return
        }
        guard let rescuedURL, let response else {
            continuation?.resume(throwing: URLError(.badServerResponse))
            return
        }
        continuation?.resume(returning: DownloadResult(temporaryURL: rescuedURL, response: response))
    }
}
