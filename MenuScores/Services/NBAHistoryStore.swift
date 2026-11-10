import Foundation

actor NBAHistoryStore {
    static let shared = NBAHistoryStore()
    struct Entry {
        let games: [Event]
        let date: Date
        let refreshFailed: Bool
        let isStale: Bool
    }
    typealias Fetch = @Sendable (URL) async throws -> Data
    private let cache: NBAResourceCache
    private let fetch: Fetch
    private let now: NBAResourceCache.Clock

    init(directory: URL? = nil, now: @escaping NBAResourceCache.Clock = { Date() }, fetch: Fetch? = nil) {
        self.now = now
        self.fetch = fetch ?? { try await Self.request($0) }
        cache = NBAResourceCache(directory: directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NBAHistory", isDirectory: true), now: now) { _, data in
                _ = try JSONDecoder().decode(ScoreboardResponse.self, from: data)
            }
    }

    static func dayKey(_ day: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    static func urls(for day: Date, calendar: Calendar = .current) -> [URL] {
        // ESPN groups schedules by US dates. Fetch both dates, then select the user's local day.
        let previous = calendar.date(byAdding: .day, value: -1, to: day)!
        return [previous, day].map { date in
            var url = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard")!
            url.queryItems = [.init(name: "dates", value: dayKey(date, calendar: calendar)), .init(name: "limit", value: "1000")]
            return url.url!
        }
    }
    static func merge(_ responses: [Data]) throws -> Data {
        var root: [String: Any] = [:]
        var events: [[String: Any]] = []
        var ids: Set<String> = []
        for data in responses {
            _ = try JSONDecoder().decode(ScoreboardResponse.self, from: data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let games = object["events"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
            if root.isEmpty { root = object }
            for game in games {
                guard let id = game["id"] as? String, ids.insert(id).inserted else { continue }
                events.append(game)
            }
        }
        root["events"] = events
        return try JSONSerialization.data(withJSONObject: root)
    }

    static func games(from data: Data, on day: Date, calendar: Calendar = .current) throws -> [Event] {
        let response = try JSONDecoder().decode(ScoreboardResponse.self, from: data)
        let iso = ISO8601DateFormatter()
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX"
        return response.events.filter { event in
            guard let start = iso.date(from: event.date) ?? fallback.date(from: event.date) else { return false }
            return calendar.isDate(start, inSameDayAs: day)
        }.sorted { $0.date < $1.date }
    }
    private func ttl(day: Date, calendar: Calendar) -> TimeInterval {
        let daysOld = calendar.dateComponents([.day], from: calendar.startOfDay(for: day),
                                             to: calendar.startOfDay(for: now())).day ?? 0
        return daysOld > 2 ? 86_400 : 300
    }

    func cached(day: Date, calendar: Calendar = .current) async -> Entry? {
        guard let result = await cache.cached(Self.dayKey(day, calendar: calendar)) else { return nil }
        return try? entry(result, day: day, calendar: calendar)
    }

    func load(day: Date, calendar: Calendar = .current, force: Bool = false) async throws -> [Event] {
        try await loadEntry(day: day, calendar: calendar, force: force).games
    }

    func loadEntry(day: Date, calendar: Calendar = .current, force: Bool = false) async throws -> Entry {
        let urls = Self.urls(for: day, calendar: calendar)
        let fetch = self.fetch
        let result = try await cache.load(Self.dayKey(day, calendar: calendar), ttl: ttl(day: day, calendar: calendar), force: force) {
            async let previous = fetch(urls[0])
            async let current = fetch(urls[1])
            return try await Self.merge([previous, current])
        }
        return try entry(result, day: day, calendar: calendar)
    }

    private func entry(_ result: NBAResourceCache.Result, day: Date, calendar: Calendar) throws -> Entry {
        Entry(games: try Self.games(from: result.entry.data, on: day, calendar: calendar), date: result.entry.date,
              refreshFailed: result.refreshFailed, isStale: now().timeIntervalSince(result.entry.date) >= ttl(day: day, calendar: calendar))
    }
    private static func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

}
