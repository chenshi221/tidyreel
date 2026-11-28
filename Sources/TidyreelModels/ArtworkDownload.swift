import Foundation

/// Bounds both cached files and HTTP responses, including chunked transfers.
public enum ArtworkDownload {
    public static let maximumBytes = 32 * 1024 * 1024

    private final class Request: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        // Callbacks for this task run on the URLSession delegate queue.
        private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        private var buffer = Data()
        private var response: URLResponse?
        private var tooLarge = false

        func start(
            _ url: URL, session: URLSession,
            continuation: CheckedContinuation<(Data, URLResponse), Error>
        ) {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let task = session.dataTask(with: url)
            self.task = task
            task.delegate = self
            task.resume()
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let current = task
            lock.unlock()
            current?.cancel()
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            self.response = response
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completionHandler(.cancel)
                return
            }
            tooLarge = response.expectedContentLength > Int64(ArtworkDownload.maximumBytes)
            completionHandler(tooLarge ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !tooLarge else { return }
            guard data.count <= ArtworkDownload.maximumBytes - buffer.count else {
                tooLarge = true
                buffer.removeAll()
                dataTask.cancel()
                return
            }
            buffer.append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            self.task = nil
            let wasCancelled = cancelled
            lock.unlock()
            guard let continuation else { return }
            self.continuation = nil
            if wasCancelled {
                continuation.resume(throwing: CancellationError())
            } else if tooLarge {
                continuation.resume(throwing: URLError(.dataLengthExceedsMaximum))
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                continuation.resume(returning: (Data(), http))
            } else if let error {
                continuation.resume(throwing: error)
            } else if let response {
                continuation.resume(returning: (buffer, response))
            } else {
                continuation.resume(throwing: URLError(.badServerResponse))
            }
        }
    }

    public static func readFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= UInt64(maximumBytes) else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        try handle.seek(toOffset: 0)
        return try handle.read(upToCount: Int(size)) ?? Data()
    }

    public static func fetchBytes(_ url: URL, session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(url, session: session)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .dataLengthExceedsMaximum {
            throw StorageError(.other, "下载 \(url.absoluteString)：文件过大（超过 32 MiB 限制）")
        } catch {
            throw StorageError(.network, "下载 \(url.absoluteString)：\(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let code: StorageErrorCode
            switch http.statusCode {
            case 404: code = .notFound
            case 429: code = .rateLimited
            case 401, 403: code = .unauthorized
            default: code = .network
            }
            throw StorageError(code, "下载 \(url.absoluteString)：HTTP \(http.statusCode)")
        }
        return data
    }

    public static func fetch(_ url: URL, session: URLSession) async throws -> (Data, URLResponse) {
        let request = Request()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.start(url, session: session, continuation: continuation)
            }
        } onCancel: {
            request.cancel()
        }
    }
}
