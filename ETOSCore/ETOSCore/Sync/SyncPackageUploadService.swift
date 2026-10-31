import Foundation

public struct SyncPackageDownloadProgress: Equatable, Sendable {
    public let bytesReceived: Int64
    public let totalBytes: Int64
    public let isConfirmedComplete: Bool

    public init(bytesReceived: Int64, totalBytes: Int64, isConfirmedComplete: Bool = false) {
        let normalizedTotalBytes = max(0, totalBytes)
        let normalizedBytesReceived = max(0, bytesReceived)
        self.totalBytes = normalizedTotalBytes
        self.bytesReceived = normalizedTotalBytes > 0
            ? min(normalizedBytesReceived, normalizedTotalBytes)
            : normalizedBytesReceived
        self.isConfirmedComplete = isConfirmedComplete
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(bytesReceived) / Double(totalBytes), 0), 1)
    }

    public var displayPercentage: Int {
        isConfirmedComplete ? 100 : min(Int((fractionCompleted * 100).rounded()), 99)
    }
}

public enum SyncPackageUploadError: LocalizedError {
    case invalidHTTPResponse
    case unexpectedStatusCode(Int, String?)
    case invalidS3Configuration(String)
    case invalidS3ListResponse
    case fileHashFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return NSLocalizedString("上传失败：服务端返回了无效响应。", comment: "")
        case .unexpectedStatusCode(let statusCode, let preview):
            if let preview, !preview.isEmpty {
                return String(
                    format: NSLocalizedString("上传失败：HTTP %d，响应：%@", comment: ""),
                    statusCode,
                    preview
                )
            }
            return String(format: NSLocalizedString("上传失败：HTTP %d。", comment: ""), statusCode)
        case .invalidS3Configuration(let reason):
            return reason
        case .invalidS3ListResponse:
            return NSLocalizedString("远端快照列表解析失败。", comment: "")
        case .fileHashFailed(let reason):
            return String(format: NSLocalizedString("计算备份文件校验值失败：%@", comment: ""), reason)
        }
    }
}

public enum SyncPackageUploadService {
    public typealias DownloadProgressHandler = @Sendable (SyncPackageDownloadProgress) -> Void

    public static func downloadTemporaryFile(
        request: URLRequest,
        progress: DownloadProgressHandler? = nil
    ) async throws -> (URL, URLResponse) {
        try await DownloadProgressDelegate(progress: progress).download(request: request)
    }
}

private final class DownloadProgressDelegate: NetworkSecuritySessionDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: SyncPackageUploadService.DownloadProgressHandler?
    private let lock = NSLock()
    private var session: URLSession?
    private var downloadedURL: URL?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?

    init(progress: SyncPackageUploadService.DownloadProgressHandler?) {
        self.progress = progress
    }

    func download(request: URLRequest) async throws -> (URL, URLResponse) {
        try await NetworkConnectionSecurity.shared.authorizeHTTP(request.url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(configuration: NetworkSessionConfiguration.makeConfiguration(), delegate: self, delegateQueue: nil)
                self.session = session
                NetworkSessionConfiguration.track(session)
                session.downloadTask(with: request).resume()
                lock.unlock()
            }
        } onCancel: { [weak self] in self?.cancelTransfer() }
    }

    private func cancelTransfer() {
        lock.lock()
        let session = session
        lock.unlock()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expectedBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        progress?(SyncPackageDownloadProgress(bytesReceived: totalBytesWritten, totalBytes: expectedBytes))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let destinationURL = try SyncTemporaryFileCleaner.makeFileURL(prefix: "ETOS-Download")
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            downloadedURL = destinationURL
        } catch {
            finish(.failure(error))
        }
    }

    override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        super.urlSession(session, task: task, didCompleteWithError: error)
        if let error {
            finish(.failure(error))
            return
        }

        guard let response = task.response else {
            finish(.failure(SyncPackageUploadError.invalidHTTPResponse))
            return
        }

        guard let downloadedURL else {
            finish(.failure(URLError(.cannotOpenFile)))
            return
        }

        finish(.success((downloadedURL, response)))
    }

    private func finish(_ result: Result<(URL, URLResponse), Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        let downloadedURL = self.downloadedURL
        lock.unlock()

        guard let continuation else { return }
        session?.finishTasksAndInvalidate()

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            if let downloadedURL {
                try? FileManager.default.removeItem(at: downloadedURL)
            }
            continuation.resume(throwing: error)
        }
    }
}
