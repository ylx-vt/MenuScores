import AppKit
import Foundation
import Testing
@testable import MenuScores

private final class AvatarClock: @unchecked Sendable {
    let lock = NSLock()
    var date = Date()
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}
private final class PreparedAvatarProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var png = Data()
    static var status = 200
    static var requests: [URL] = []
    static var active = 0
    static var maximum = 0
    static func reset(_ data: Data) { lock.withLock { png = data; status = 200; requests = []; active = 0; maximum = 0 } }
    static func count() -> Int { lock.withLock { requests.count } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { () -> (Data, Int) in
            Self.requests.append(request.url!); Self.active += 1; Self.maximum = max(Self.maximum, Self.active)
            return (Self.png, Self.status)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + (request.url?.query?.contains("slow=1") == true ? 0.5 : 0.01)) { [self] in
            Self.lock.withLock { Self.active -= 1 }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.1, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.0)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct NBAAvatarPreparationTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("AvatarPrepare-" + UUID().uuidString) }
    private func url(_ id: String) -> URL { URL(string: "https://a.espncdn.com/i/headshots/nba/players/full/\(id).png")! }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PreparedAvatarProtocol.self]
        return URLSession(configuration: config)
    }
    @MainActor private func png() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 436,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 2400, bitsPerPixel: 32))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
    private func idle(_ cache: NBAAvatarCache) async throws {
        for _ in 0..<4000 {
            let state = await cache.metrics()
            if state.active == 0 && state.queued == 0 { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw URLError(.timedOut)
    }

    @Test @MainActor func decodedFirstFrameDiskRestartAndNavigationShareOneDownload() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        PreparedAvatarProtocol.reset(try png())
        let session = session(); defer { session.invalidateAndCancel() }
        let cache = NBAAvatarCache(directory: root, session: session, seedURL: nil)
        let address = url("1")
        let dismissed = Task { await cache.image(for: address) }; dismissed.cancel()
        async let same = cache.image(for: address)
        #expect(await dismissed.value != nil)
        let image = try #require(await same)
        #expect(image.width == 160 && image.height == 116)
        #expect(PreparedAvatarProtocol.count() == 1)
        // This is the synchronous lookup used by the View's State initializer.
        #expect(cache.cachedImage(for: address) != nil)
        await cache.flush(); await cache.trimMemory()
        let restarted = NBAAvatarCache(directory: root, session: session, seedURL: nil)
        await restarted.prepareLeague(); try await idle(restarted)
        #expect(restarted.cachedImage(for: address) != nil)
        #expect(PreparedAvatarProtocol.count() == 1)
    }

    @Test @MainActor func localPixelsDoNotWaitForTwoSlowDownloads() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try png(); PreparedAvatarProtocol.reset(bytes)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let local = url("3")
        try bytes.write(to: root.appendingPathComponent(NBAAvatarDisk.key(local) + ".image"))
        let session = session(); defer { session.invalidateAndCancel() }
        let cache = NBAAvatarCache(directory: root, session: session, seedURL: nil)
        let slowA = URL(string: url("1").absoluteString + "?slow=1")!
        let slowB = URL(string: url("2").absoluteString + "?slow=1")!
        let first = Task { await cache.image(for: slowA) }
        let second = Task { await cache.image(for: slowB) }
        for _ in 0..<200 {
            if PreparedAvatarProtocol.lock.withLock({ PreparedAvatarProtocol.active }) == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await cache.image(for: local) != nil)
        #expect(PreparedAvatarProtocol.lock.withLock { PreparedAvatarProtocol.active } == 2)
        #expect(await first.value != nil); #expect(await second.value != nil)
    }

    @Test @MainActor func legacyOriginalsAreReusedAndNeverDeletedByThumbnailLimits() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let png = try png(); PreparedAvatarProtocol.reset(png)
        let session = session(); defer { session.invalidateAndCancel() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for id in ["1", "2", "3"] { try png.write(to: root.appendingPathComponent(NBAAvatarDisk.key(url(id)) + ".image")) }
        let memory = NBAAvatarImageMemory(costLimit: 80_000, countLimit: 1)
        let cache = NBAAvatarCache(directory: root, session: session, seedURL: nil, images: memory, diskCountLimit: 1)
        await cache.prewarm([url("1"), url("2"), url("3")]); try await idle(cache)
        let state = await cache.metrics()
        #expect(state.diskCount <= 1 && state.memoryCount <= 1 && state.memoryBytes <= 80_000)
        #expect(PreparedAvatarProtocol.count() == 0)
        for id in ["1", "2", "3"] { #expect(try Data(contentsOf: root.appendingPathComponent(NBAAvatarDisk.key(url(id)) + ".image")) == png) }
        await cache.trimMemory()
        #expect(await cache.image(for: url("1")) != nil)
        #expect(PreparedAvatarProtocol.count() == 0)
    }

    @Test @MainActor func full425IncrementalPreparationRestartsOfflineWithBoundedWorkers() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        PreparedAvatarProtocol.reset(try png())
        let session = session(); defer { session.invalidateAndCancel() }
        let cache = NBAAvatarCache(directory: root, session: session, seedURL: nil)
        let portraits = (1...425).map { NBAAvatarCache.Portrait(id: String($0), url: url(String($0)), teamID: String($0 % 30)) }
        await cache.register(portraits, season: 2027); try await idle(cache); await cache.flush()
        let state = await cache.metrics()
        #expect(state.leagueCount == 425 && state.leagueReady == 425 && state.memoryCount == 425)
        #expect(state.memoryBytes <= 48 * 1024 * 1024 && state.diskBytes <= 32 * 1024 * 1024)
        #expect(PreparedAvatarProtocol.count() == 425)
        #expect(PreparedAvatarProtocol.lock.withLock { PreparedAvatarProtocol.maximum } <= 2)
        await cache.prepareLeague(); try await idle(cache)
        #expect(PreparedAvatarProtocol.count() == 425)
        await cache.trimMemory()
        PreparedAvatarProtocol.lock.withLock { PreparedAvatarProtocol.status = 503 }
        let restarted = NBAAvatarCache(directory: root, session: session, seedURL: nil)
        await restarted.prepareLeague(); try await idle(restarted)
        #expect(await restarted.metrics().leagueReady == 425)
        #expect(restarted.cachedImage(for: url("425")) != nil)
        #expect(PreparedAvatarProtocol.count() == 425)
    }

    @Test @MainActor func visiblePriorityBypassesPausedBulkWithoutDuplicatingJobs() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        PreparedAvatarProtocol.reset(try png())
        let session = session(); defer { session.invalidateAndCancel() }
        let cache = NBAAvatarCache(directory: root, session: session, seedURL: nil)
        await cache.setBackgroundPaused(true)
        await cache.register((1...6).map { .init(id: String($0), url: url(String($0))) }, season: 2027)
        #expect(PreparedAvatarProtocol.count() == 0)
        #expect(await cache.metrics().queued == 6)
        async let a = cache.image(for: url("6")); async let b = cache.image(for: url("6"))
        #expect(await a != nil); #expect(await b != nil)
        #expect(PreparedAvatarProtocol.count() == 1)
        #expect(PreparedAvatarProtocol.lock.withLock { PreparedAvatarProtocol.requests.first } == url("6"))
        await cache.setBackgroundPaused(false); try await idle(cache)
        #expect(PreparedAvatarProtocol.count() == 6)
    }

    @Test @MainActor func persistentFailureCooldownAndChangedURLAreIndependent() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        PreparedAvatarProtocol.reset(try png())
        PreparedAvatarProtocol.lock.withLock { PreparedAvatarProtocol.status = 503 }
        let clock = AvatarClock(); let session = session(); defer { session.invalidateAndCancel() }
        let cache = NBAAvatarCache(directory: root, session: session, seedURL: nil, now: { clock.now() })
        #expect(await cache.image(for: url("1")) == nil)
        await cache.flush()
        let restarted = NBAAvatarCache(directory: root, session: session, seedURL: nil, now: { clock.now() })
        #expect(await restarted.image(for: url("1")) == nil)
        #expect(PreparedAvatarProtocol.count() == 1)
        clock.advance(60)
        #expect(await restarted.image(for: url("1")) == nil)
        #expect(PreparedAvatarProtocol.count() == 2)
        let changed = URL(string: url("1").absoluteString + "?revision=2")!
        PreparedAvatarProtocol.lock.withLock { PreparedAvatarProtocol.status = 200 }
        await restarted.register([.init(id: "1", url: changed)])
        #expect(await restarted.image(for: changed) != nil)
        #expect(restarted.cachedImage(for: changed) != nil)
        #expect(PreparedAvatarProtocol.count() == 3)
    }

    @Test @MainActor func stalePixelsRemainAvailableAfterRefreshFailsAndMemoryIsCleared() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        PreparedAvatarProtocol.reset(try png())
        let clock = AvatarClock(); let session = session(); defer { session.invalidateAndCancel() }
        let cache = NBAAvatarCache(directory: root, session: session, seedURL: nil, now: { clock.now() })
        #expect(await cache.image(for: url("1")) != nil)
        let originalDate = try #require(cache.images.value(for: url("1"))?.date)
        clock.advance(7 * 86400)
        PreparedAvatarProtocol.lock.withLock { PreparedAvatarProtocol.status = 503 }
        #expect(await cache.image(for: url("1")) != nil)
        try await idle(cache)
        #expect(PreparedAvatarProtocol.count() == 2)
        #expect(cache.images.value(for: url("1"))?.date == originalDate)
        await cache.trimMemory()
        #expect(await cache.image(for: url("1")) != nil)
        #expect(PreparedAvatarProtocol.count() == 2)
    }

    @Test @MainActor func newPlayersUpdateOnlyTheirImageAndHistoricalPoolCannotReplaceCurrent() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        PreparedAvatarProtocol.reset(try png())
        let session = session(); defer { session.invalidateAndCancel() }
        let cache = NBAAvatarCache(directory: root, session: session, seedURL: nil)
        await cache.register([.init(id: "1", url: url("1")), .init(id: "2", url: url("2"))], season: 2027)
        try await idle(cache)
        await cache.register([.init(id: "3", url: url("3"))], season: 2026)
        #expect(await cache.metrics().leagueCount == 2)
        #expect(PreparedAvatarProtocol.count() == 2)
        await cache.register([.init(id: "2", url: url("2")), .init(id: "4", url: url("4"))], season: 2027)
        try await idle(cache)
        #expect(PreparedAvatarProtocol.count() == 3)
        #expect(await cache.metrics().leagueReady == 2)
    }

    @Test func bundledPortraitSeedContains425ObservedURLsAndTeams() throws {
        let file = try #require(Bundle.main.url(forResource: "NBAAvatarSeed", withExtension: "json"))
        struct Seed: Decodable { let season: Int; let portraits: [NBAAvatarCache.Portrait] }
        let seed = try JSONDecoder().decode(Seed.self, from: Data(contentsOf: file))
        #expect(seed.season == 2027 && seed.portraits.count == 425 && Set(seed.portraits.map(\.id)).count == 425)
        #expect(seed.portraits.allSatisfy { $0.url.absoluteString == "https://a.espncdn.com/i/headshots/nba/players/full/\($0.id).png" && $0.teamID != nil })
    }
}
