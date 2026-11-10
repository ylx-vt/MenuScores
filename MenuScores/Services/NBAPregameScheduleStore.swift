import Foundation

/// Optional fallback only for teams whose recent summary rows lack season/stage
/// provenance. The request is per team + season + stage, never per athlete.
actor NBAPregameScheduleStore {
    static let shared = NBAPregameScheduleStore()
    static let ttl: TimeInterval = 1800
    typealias Fetch = @Sendable (URL) async throws -> Data
    struct Entry {
        let schedule: NBAPregamePreview.Schedule
        let date: Date
        let refreshFailed: Bool
        let isStale: Bool
    }
    private let cache: NBAResourceCache
    private let fetch: Fetch
    private let now: NBAResourceCache.Clock

    init(directory: URL? = nil, now: @escaping NBAResourceCache.Clock = { Date() }, fetch: Fetch? = nil) {
        self.now = now
        self.fetch = fetch ?? { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 20; request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return data
        }
        cache = NBAResourceCache(directory: directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NBAPregameTeamSchedules-v1", isDirectory: true), now: now) { key, data in
                let parts = key.split(separator: "-")
                guard parts.count == 3, let year = Int(parts[0]), let stage = Int(parts[1]) else { throw URLError(.cannotParseResponse) }
                _ = try Self.decode(data, teamID: String(parts[2]), scope: .init(year: year, stage: stage))
            }
    }

    private func key(teamID: String, scope: NBAPregamePreview.Scope) throws -> String {
        guard !teamID.isEmpty, teamID.allSatisfy(\.isNumber), (1900...2200).contains(scope.year),
              [1, 2, 3].contains(scope.stage) else { throw URLError(.badURL) }
        return "\(scope.year)-\(scope.stage)-\(teamID)"
    }

    static func url(teamID: String, scope: NBAPregamePreview.Scope) -> URL {
        var components = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams/\(teamID)/schedule")!
        components.queryItems = [.init(name: "season", value: String(scope.year)), .init(name: "seasontype", value: String(scope.stage))]
        return components.url!
    }

    func cached(teamID: String, scope: NBAPregamePreview.Scope) async -> Entry? {
        guard let key = try? key(teamID: teamID, scope: scope), let result = await cache.cached(key) else { return nil }
        return try? entry(result, teamID: teamID, scope: scope)
    }

    func load(teamID: String, scope: NBAPregamePreview.Scope, force: Bool = false) async throws -> Entry {
        let key = try key(teamID: teamID, scope: scope)
        let fetch = fetch
        let result = try await cache.load(key, ttl: Self.ttl, force: force) { try await fetch(Self.url(teamID: teamID, scope: scope)) }
        return try entry(result, teamID: teamID, scope: scope)
    }

    private func entry(_ result: NBAResourceCache.Result, teamID: String, scope: NBAPregamePreview.Scope) throws -> Entry {
        Entry(schedule: try Self.decode(result.entry.data, teamID: teamID, scope: scope), date: result.entry.date,
              refreshFailed: result.refreshFailed, isStale: now().timeIntervalSince(result.entry.date) >= Self.ttl)
    }

    private struct Response: Decodable {
        struct RequestedSeason: Decodable { let year: Int; let type: Int }
        let requestedSeason: RequestedSeason
        let team: NBAPregamePreview.Team
        let events: [Event]
        struct Event: Decodable {
            let id: String
            let date: String
            let season: NBAPregamePreview.Season?
            let seasonType: NBAPregamePreview.RecentEvent.SeasonPhase?
            let competitions: [Competition]
        }
        struct Competition: Decodable { let competitors: [Side]?; let status: NBAPregamePreview.Status? }
        struct Side: Decodable { let id: String; let homeAway: String?; let team: NBAPregamePreview.Team?; let score: Score? }
        struct Score: Decodable {
            let value: Double?
            let displayValue: String?
            var points: Int? {
                if let value, value.isFinite, value >= 0, let exact = Int(exactly: value) { return exact }
                return displayValue.flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
            }
        }
    }

    static func decode(_ data: Data, teamID: String, scope: NBAPregamePreview.Scope) throws -> NBAPregamePreview.Schedule {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.team.id == teamID, response.requestedSeason.year == scope.year,
              response.requestedSeason.type == scope.stage else { throw URLError(.cannotParseResponse) }
        var ids: Set<String> = []
        let games = response.events.compactMap { event -> NBAPregamePreview.Game? in
            guard event.season?.year == scope.year, (event.seasonType?.type ?? event.season?.type) == scope.stage,
                  !event.id.isEmpty, let date = NBASchedulePolicy.startDate(event.date), scope.contains(date), let competition = event.competitions.first,
                  competition.status?.type?.completed == true, competition.status?.type?.state == "post",
                  let sides = competition.competitors, sides.count == 2,
                  let own = sides.first(where: { $0.id == teamID }), let other = sides.first(where: { $0.id != teamID }),
                  let points = own.score?.points, let opponentPoints = other.score?.points, points != opponentPoints else { return nil }
            let name = competition.status?.type?.name?.lowercased() ?? ""
            guard !name.contains("cancel"), !name.contains("postpon"), !name.contains("suspend"), ids.insert(event.id).inserted else { return nil }
            return .init(id: event.id, date: date, opponent: other.team?.name ?? "对手", isHome: own.homeAway == "home",
                         points: points, opponentPoints: opponentPoints)
        }.sorted { $0.date > $1.date }
        return .init(teamID: teamID, scope: scope, games: games)
    }
}
