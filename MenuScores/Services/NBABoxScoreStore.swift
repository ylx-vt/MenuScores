import Foundation

actor NBABoxScoreStore {
    static let shared = NBABoxScoreStore()
    static let completedTTL: TimeInterval = 6 * 60 * 60
    struct Entry {
        let summary: NBABoxScore
        let data: Data
        let date: Date
        let refreshFailed: Bool
        let isStale: Bool
    }
    typealias Fetch = @Sendable (String) async throws -> Data
    private let cache: NBAResourceCache
    private let fetch: Fetch
    private let now: NBAResourceCache.Clock
    private var decoded: [String: (UUID, NBABoxScore)] = [:]

    init(directory: URL? = nil, now: @escaping NBAResourceCache.Clock = { Date() }, fetch: Fetch? = nil) {
        self.now = now
        self.fetch = fetch ?? { try await NBABoxScore.requestData(gameID: $0) }
        cache = NBAResourceCache(directory: directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NBABoxScores", isDirectory: true), now: now) { key, data in
                let summary = try JSONDecoder().decode(NBABoxScore.self, from: data)
                if let id = summary.header?.id, id != key { throw URLError(.cannotParseResponse) }
            }
    }

    static func ttl(for summary: NBABoxScore, liveInterval: TimeInterval = 15) -> TimeInterval {
        switch summary.match?.status?.type?.state {
        case "post": return completedTTL
        default: return liveInterval
        }
    }

    func cached(gameID: String, liveInterval: TimeInterval = 15) async -> Entry? {
        guard let result = await cache.cached(gameID) else { return nil }
        return try? entry(result, gameID: gameID, liveInterval: liveInterval)
    }

    func load(gameID: String, force: Bool = false, liveInterval: TimeInterval = 15) async throws -> Entry {
        guard !gameID.isEmpty, gameID.allSatisfy(\.isNumber) else { throw URLError(.badURL) }
        let old = await cached(gameID: gameID, liveInterval: liveInterval)
        let ttl = old.map { Self.ttl(for: $0.summary, liveInterval: liveInterval) } ?? liveInterval
        let fetch = self.fetch
        let result = try await cache.load(gameID, ttl: ttl, force: force) { try await fetch(gameID) }
        return try entry(result, gameID: gameID, liveInterval: liveInterval)
    }

    private func entry(_ result: NBAResourceCache.Result, gameID: String, liveInterval: TimeInterval) throws -> Entry {
        let summary: NBABoxScore
        if let saved = decoded[gameID], saved.0 == result.entry.revision { summary = saved.1 }
        else {
            summary = try JSONDecoder().decode(NBABoxScore.self, from: result.entry.data)
            decoded[gameID] = (result.entry.revision, summary)
        }
        return Entry(summary: summary, data: result.entry.data, date: result.entry.date, refreshFailed: result.refreshFailed,
                     isStale: now().timeIntervalSince(result.entry.date) >= Self.ttl(for: summary, liveInterval: liveInterval))
    }
}
