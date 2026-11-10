import AppKit
import Foundation
import Testing
@testable import MenuScores

private final class AvatarProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var png = Data()
    static var count = 0
    static var statusCode = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.lock.withLock { Self.count += 1; return (Self.png, Self.statusCode) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.1, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.0)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct NBAAvatarCacheTests {
    @Test @MainActor func memoryDiskAndConcurrentRequestsReuseOneDownload() async throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        AvatarProtocol.lock.withLock { AvatarProtocol.png = png; AvatarProtocol.count = 0; AvatarProtocol.statusCode = 200 }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AvatarProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://a.espncdn.com/i/headshots/nba/players/full/test.png")!
        let cache = NBAAvatarCache(directory: directory, session: session)
        async let first = cache.data(for: url)
        async let second = cache.data(for: url)
        let results = await [first, second]
        #expect(results.allSatisfy { $0 == png })
        #expect(AvatarProtocol.lock.withLock { AvatarProtocol.count } == 1)
        #expect(await cache.data(for: url) == png)
        // A new cache instance simulates restarting the app.
        let restarted = NBAAvatarCache(directory: directory, session: session)
        #expect(await restarted.data(for: url) == png)
        #expect(AvatarProtocol.lock.withLock { AvatarProtocol.count } == 1)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "image" }))
        try Data("corrupt".utf8).write(to: file)
        let repaired = NBAAvatarCache(directory: directory, session: session)
        #expect(await repaired.data(for: url) == png)
        #expect(AvatarProtocol.lock.withLock { AvatarProtocol.count } == 2)
        #expect(await repaired.data(for: URL(string: "https://example.com/avatar.png")!) == nil)
        AvatarProtocol.lock.withLock { AvatarProtocol.statusCode = 503 }
        let failingURL = URL(string: "https://a.espncdn.com/i/headshots/nba/players/full/missing.png")!
        #expect(await repaired.data(for: failingURL) == nil)
        #expect(await repaired.data(for: failingURL) == nil)
        #expect(AvatarProtocol.lock.withLock { AvatarProtocol.count } == 3)
    }
}
