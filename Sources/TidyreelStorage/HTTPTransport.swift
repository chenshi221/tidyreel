import Darwin
import Foundation
import TidyreelModels

private let privateDomainSuffixes: [String] = [
    ".local",
    ".lan",
    ".home",
    ".home.arpa",
    ".internal",
    ".ts.net",
]

private func isPrivateIPv4(_ b0: UInt8, _ b1: UInt8) -> Bool {
    b0 == 10
        || b0 == 127
        || (b0 == 172 && b1 >= 16 && b1 < 32)
        || (b0 == 192 && b1 == 168)
        || (b0 == 169 && b1 == 254)
        || (b0 == 100 && b1 >= 64 && b1 < 128)
}

private func isIPv4MappedIPv6(_ bytes: [UInt8]) -> Bool {
    guard bytes.count == 16 else { return false }
    for i in 0..<10 where bytes[i] != 0 {
        return false
    }
    return bytes[10] == 0xff && bytes[11] == 0xff
}

/// Returns true if `host` is on the local network or a private overlay
/// (loopback, RFC 1918, link-local, CGNAT / Tailscale 100.64.0.0/10, IPv6 ULA /
/// link-local / IPv4-mapped private IPv6, bare hostname, or `.local` / `.lan` /
/// `.home` / `.home.arpa` / `.internal` / `.ts.net`).
public func isPrivateHost(_ host: String) -> Bool {
    var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if h.hasPrefix("[") { h.removeFirst() }
    if h.hasSuffix("]") { h.removeLast() }
    while h.hasSuffix(".") {
        h.removeLast()
    }
    if h.isEmpty { return false }
    if !h.contains(".") && !h.contains(":") {
        return true
    }
    for suffix in privateDomainSuffixes where h.hasSuffix(suffix) {
        return true
    }

    var ipCandidate = h
    if ipCandidate.contains(":"), let pctIdx = ipCandidate.firstIndex(of: "%"), pctIdx > ipCandidate.startIndex {
        ipCandidate = String(ipCandidate[..<pctIdx])
    }

    var addr4 = in_addr()
    if inet_pton(AF_INET, ipCandidate, &addr4) == 1 {
        let bytes = withUnsafeBytes(of: addr4) { Array($0) }
        return isPrivateIPv4(bytes[0], bytes[1])
    }

    var addr6 = in6_addr()
    if inet_pton(AF_INET6, ipCandidate, &addr6) == 1 {
        let bytes = withUnsafeBytes(of: addr6) { Array($0) }
        if isIPv4MappedIPv6(bytes) {
            return isPrivateIPv4(bytes[12], bytes[13])
        }
        let isLoopback = bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1
        let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        let isULA = (bytes[0] & 0xfe) == 0xfc
        return isLoopback || isLinkLocal || isULA
    }

    return false
}

// MARK: - StorageHTTPTransport

public protocol StorageHTTPTransport: Sendable {
    func send(_ request: URLRequest, followRedirects: Bool) async throws -> (Data, HTTPURLResponse)
}

public extension StorageHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request, followRedirects: true)
    }
}

// MARK: - URLSessionStorageTransport

let maxUnrangedSkipBytes: Int64 = 512 * 1024
let maxUnrangedResponseBytes: Int = 64 * 1024 * 1024

private final class SingleHopTaskHandler: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let requestedRange: (start: Int64, length: Int)?
    private let maxUnrangedBytes: Int
    private var response: HTTPURLResponse?
    private var buffer = Data()
    private var maxBytesToCollect: Int?
    private var cancelAtExactCap = false
    private var stoppedAtCap = false
    private var exceededHardCap = false
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?

    init(
        requestedRange: (start: Int64, length: Int)?,
        maxUnrangedBytes: Int = maxUnrangedResponseBytes,
        continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    ) {
        self.requestedRange = requestedRange
        self.maxUnrangedBytes = maxUnrangedBytes
        self.continuation = continuation
    }

    func cancelExternally() {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: URLError(.cancelled))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never let URLSession silently follow redirects; URLSessionStorageTransport
        // handles origin checks and proxy selection on every hop.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        lock.lock()
        self.response = http
        if let range = requestedRange {
            let status = http.statusCode
            if status == 416 || (300..<400).contains(status) {
                stoppedAtCap = true
                lock.unlock()
                completionHandler(.cancel)
                return
            } else if status == 206 {
                maxBytesToCollect = range.length
                let expected = http.expectedContentLength
                // Let URLSession finish cleanly when the 206 payload fits within the requested
                // range so the underlying TCP/TLS keep-alive connection can be reused.
                cancelAtExactCap = !(expected > 0 && expected <= Int64(range.length))
                if expected > 0 {
                    let reserve = min(Int(min(expected, Int64(range.length))), 1024 * 1024)
                    buffer.reserveCapacity(reserve)
                }
            } else if status == 200 {
                if range.start > maxUnrangedSkipBytes {
                    stoppedAtCap = true
                    lock.unlock()
                    completionHandler(.cancel)
                    return
                }
                let needed = range.start + Int64(range.length)
                maxBytesToCollect = needed > Int64(Int.max) ? Int.max : Int(needed)
                cancelAtExactCap = true
            } else if http.expectedContentLength > Int64(maxUnrangedBytes) {
                exceededHardCap = true
                lock.unlock()
                completionHandler(.cancel)
                return
            }
        } else if http.expectedContentLength > Int64(maxUnrangedBytes) {
            exceededHardCap = true
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if let cap = maxBytesToCollect {
            let remaining = cap - buffer.count
            let overflowed = data.count > remaining
            if remaining > 0 {
                if data.count <= remaining {
                    buffer.append(data)
                } else {
                    buffer.append(data.prefix(remaining))
                }
            }
            if (cancelAtExactCap && buffer.count >= cap) || overflowed {
                stoppedAtCap = true
                lock.unlock()
                dataTask.cancel()
                return
            }
            lock.unlock()
        } else {
            if data.count > maxUnrangedBytes - buffer.count {
                exceededHardCap = true
                buffer.removeAll(keepingCapacity: false)
                lock.unlock()
                dataTask.cancel()
                return
            }
            buffer.append(data)
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let cont = continuation else {
            lock.unlock()
            return
        }
        continuation = nil
        let http = response
        let data = buffer
        let capped = stoppedAtCap
        let overHardCap = exceededHardCap
        lock.unlock()

        if overHardCap {
            cont.resume(throwing: URLError(.dataLengthExceedsMaximum))
            return
        }
        if capped, let http {
            cont.resume(returning: (data, http))
            return
        }
        if let error {
            cont.resume(throwing: error)
            return
        }
        guard let http else {
            cont.resume(throwing: URLError(.badServerResponse))
            return
        }
        cont.resume(returning: (data, http))
    }
}

public final class URLSessionStorageTransport: StorageHTTPTransport, @unchecked Sendable {
    public static let shared = URLSessionStorageTransport()

    private static let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]
    private static let maxRedirects = 8

    private let directSession: URLSession
    private let proxiedSession: URLSession
    private let maxUnrangedBytes: Int

    public convenience init(requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 60) {
        self.init(
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout,
            maxUnrangedBytes: maxUnrangedResponseBytes
        )
    }

    init(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        maxUnrangedBytes: Int
    ) {
        let directCfg = URLSessionConfiguration.ephemeral
        directCfg.connectionProxyDictionary = [:]
        directCfg.timeoutIntervalForRequest = requestTimeout
        directCfg.timeoutIntervalForResource = resourceTimeout
        directCfg.httpShouldSetCookies = false

        let proxiedCfg = URLSessionConfiguration.ephemeral
        proxiedCfg.timeoutIntervalForRequest = requestTimeout
        proxiedCfg.timeoutIntervalForResource = resourceTimeout
        proxiedCfg.httpShouldSetCookies = false

        self.directSession = URLSession(configuration: directCfg)
        self.proxiedSession = URLSession(configuration: proxiedCfg)
        self.maxUnrangedBytes = maxUnrangedBytes
    }

    deinit {
        directSession.finishTasksAndInvalidate()
        proxiedSession.finishTasksAndInvalidate()
    }

    private func performSingleHop(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        let session = isPrivateHost(url.host ?? "") ? directSession : proxiedSession
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        let parsedRange = parseRangeHeader(rangeHeader)
        let hardCap = maxUnrangedBytes

        let taskBox = UnsafeTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let delegate = SingleHopTaskHandler(
                    requestedRange: parsedRange,
                    maxUnrangedBytes: hardCap,
                    continuation: cont
                )
                let task = session.dataTask(with: request)
                task.delegate = delegate
                taskBox.set(task: task, handler: delegate)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    public func send(_ request: URLRequest, followRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        if !followRedirects {
            return try await performSingleHop(request)
        }

        var currentRequest = request
        for hop in 0...Self.maxRedirects {
            let (data, response) = try await performSingleHop(currentRequest)
            guard hop < Self.maxRedirects,
                  Self.redirectStatusCodes.contains(response.statusCode),
                  let location = response.value(forHTTPHeaderField: "Location"),
                  let currentURL = currentRequest.url else {
                return (data, response)
            }

            guard let nextURL = resolveValidURL(location, relativeTo: currentURL) else {
                throw URLError(.badURL)
            }

            guard let nextRequest = Self.redirectRequest(currentRequest, to: nextURL, status: response.statusCode) else {
                return (data, response)
            }
            currentRequest = nextRequest
        }

        throw URLError(.httpTooManyRedirects)
    }

    static func redirectRequest(_ current: URLRequest, to nextURL: URL, status: Int) -> URLRequest? {
        guard let currentURL = current.url else { return nil }
        let method = (current.httpMethod ?? "GET").uppercased()
        let isRead = method == "GET" || method == "HEAD"
        var next = current
        next.url = nextURL
        if (status == 303 && method != "HEAD") || ((status == 301 || status == 302) && !isRead) {
            next.httpMethod = "GET"
            next.httpBodyStream = nil
            next.httpBody = nil
            next.setValue(nil, forHTTPHeaderField: "Content-Length")
            next.setValue(nil, forHTTPHeaderField: "Content-Type")
        }
        if !isSameOrigin(currentURL, nextURL) {
            // A 307/308 may replay a login body or file upload. Only follow
            // cross-origin downloads and carry forward the byte range they need.
            guard next.httpMethod == "GET" || next.httpMethod == "HEAD",
                  next.httpBody == nil, next.httpBodyStream == nil else { return nil }
            var download = URLRequest(url: nextURL, cachePolicy: current.cachePolicy, timeoutInterval: current.timeoutInterval)
            download.httpMethod = next.httpMethod
            download.setValue(current.value(forHTTPHeaderField: "Range"), forHTTPHeaderField: "Range")
            return download
        }
        return next
    }
}

private final class UnsafeTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var handler: SingleHopTaskHandler?
    private var cancelled = false

    func set(task: URLSessionDataTask, handler: SingleHopTaskHandler) {
        lock.lock()
        let wasCancelled = cancelled
        self.task = task
        self.handler = handler
        lock.unlock()
        if wasCancelled {
            task.cancel()
            handler.cancelExternally()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        let h = handler
        lock.unlock()
        t?.cancel()
        h?.cancelExternally()
    }
}
