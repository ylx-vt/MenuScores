import Foundation

/// Cache raw ESPN schedule dates, so today's and tomorrow's overlapping date
/// requests share both downloads and in-flight work. Date keys are provider
/// buckets; only NBASchedulePolicy decides which Beijing day an event belongs to.
actor NBAScheduleStore {
    static let shared = NBAScheduleStore()
    typealias Fetch = @Sendable (URL) async throws -> Data
    struct Entry {
        let games: [Event]
        let date: Date
        let refreshFailed: Bool
        let notificationObservations: [NBAGameObservation]
    }
    private let cache: NBAResourceCache
    private let fetch: Fetch
    private let now: NBAResourceCache.Clock

    init(directory: URL? = nil, now: @escaping NBAResourceCache.Clock = { Date() }, fetch: Fetch? = nil) {
        self.now = now
        self.fetch = fetch ?? { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return data
        }
        cache = NBAResourceCache(directory: directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NBAScheduleDates-v1", isDirectory: true), now: now) { _, data in
                _ = try JSONDecoder().decode(ScoreboardResponse.self, from: data)
            }
    }

    static func providerKeys(for day: Date) -> [String] {
        // A Beijing day spans the previous and same US schedule dates. Request
        // this superset, then filter actual ISO start times, never US date labels.
        let calendar = NBASchedulePolicy.calendar
        let previous = calendar.date(byAdding: .day, value: -1, to: day)!
        return [previous, day].map { NBAHistoryStore.dayKey($0, calendar: calendar) }
    }

    static func url(key: String) -> URL {
        var components = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard")!
        components.queryItems = [.init(name: "dates", value: key), .init(name: "limit", value: "1000")]
        return components.url!
    }

    static func ttl(games: [Event], now: Date) -> TimeInterval {
        if games.contains(where: { $0.status.type.state == "in" }) { return 15 }
        if games.contains(where: {
            guard $0.status.type.state == "pre", let date = NBASchedulePolicy.startDate($0.date) else { return false }
            return abs(date.timeIntervalSince(now)) <= 900
        }) { return 30 }
        return 900
    }

    private func keys(day: Date, extraDays: [Date]) -> [String] {
        Array(Set(Self.providerKeys(for: day) + extraDays.flatMap { Self.providerKeys(for: $0) })).sorted()
    }

    func cached(day: Date, extraDays: [Date] = []) async -> Entry? {
        var values: [NBAResourceCache.Result] = []
        for key in keys(day: day, extraDays: extraDays) {
            guard let value = await cache.cached(key) else { return nil }
            values.append(value)
        }
        return try? entry(values, loaded: false)
    }

    func load(day: Date, extraDays: [Date] = []) async throws -> Entry {
        let keys = keys(day: day, extraDays: extraDays)
        let values = try await withThrowingTaskGroup(of: (Int, NBAResourceCache.Result).self) { group in
            for (index, key) in keys.enumerated() {
                group.addTask { (index, try await self.loadRaw(key)) }
            }
            var collected: [Int: NBAResourceCache.Result] = [:]
            for try await (index, value) in group { collected[index] = value }
            return keys.indices.map { collected[$0]! }
        }
        return try entry(values, loaded: true)
    }

    private func loadRaw(_ key: String) async throws -> NBAResourceCache.Result {
        let old = await cache.cached(key)
        let games = old.flatMap { try? JSONDecoder().decode(ScoreboardResponse.self, from: $0.entry.data).events } ?? []
        let fetch = fetch
        return try await cache.load(key, ttl: Self.ttl(games: games, now: now())) { try await fetch(Self.url(key: key)) }
    }

    private func entry(_ values: [NBAResourceCache.Result], loaded: Bool) throws -> Entry {
        var seen: Set<String> = []
        var games: [Event] = []
        var observations: [String: NBAGameObservation] = [:]
        for value in values {
            let events = try JSONDecoder().decode(ScoreboardResponse.self, from: value.entry.data).events
            games += events.filter { seen.insert($0.id).inserted }
            if loaded && !value.refreshFailed {
                for game in events {
                    let observation = NBAGameObservation(game: game, fetchedAt: value.entry.date)
                    if observations[game.id].map({ $0.fetchedAt < observation.fetchedAt }) ?? true {
                        observations[game.id] = observation
                    }
                }
            }
        }
        return Entry(games: games, date: values.map(\.entry.date).min()!, refreshFailed: values.contains(where: \.refreshFailed),
                     notificationObservations: Array(observations.values))
    }
}
