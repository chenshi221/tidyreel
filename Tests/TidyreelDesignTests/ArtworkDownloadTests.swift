import Foundation
import Testing
import TidyreelModels

@Test("Cached artwork reads preserve small payloads and reject oversized files")
func boundedArtworkReads() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let contents = Data([1, 2, 3])
    try contents.write(to: file)
    #expect(try ArtworkDownload.readFile(file) == contents)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(ArtworkDownload.maximumBytes + 1))
    try handle.close()
    #expect(throws: URLError(.dataLengthExceedsMaximum)) { try ArtworkDownload.readFile(file) }
}

private final class ArtworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let status = url.lastPathComponent == "missing" ? 404 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.lastPathComponent == "large" {
            let block = Data(repeating: 0, count: 1024 * 1024)
            for _ in 0...ArtworkDownload.maximumBytes / block.count {
                client?.urlProtocol(self, didLoad: block)
            }
        } else {
            client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Test("Artwork HTTP reads enforce the byte cap on chunked responses and preserve 404 status")
func boundedArtworkResponses() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ArtworkProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let base = URL(string: "https://example.invalid/")!
    let (small, _) = try await ArtworkDownload.fetch(base.appendingPathComponent("small"), session: session)
    #expect(small == Data([1, 2, 3]))
    let (empty, missing) = try await ArtworkDownload.fetch(base.appendingPathComponent("missing"), session: session)
    #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    #expect(empty.isEmpty)
    await #expect(throws: URLError(.dataLengthExceedsMaximum)) {
        try await ArtworkDownload.fetch(base.appendingPathComponent("large"), session: session)
    }
}
