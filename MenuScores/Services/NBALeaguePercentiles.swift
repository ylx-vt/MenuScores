import Foundation

struct NBALeaguePosition {
    let rank: Int
    let population: Int
    let worseCount: Int
    init?(rank: Int, population: Int, worseCount: Int? = nil) {
        let worse = worseCount ?? population - rank
        guard rank > 0, population > 0, rank <= population, worse >= 0,
              worse <= population else { return nil }
        self.rank = rank; self.population = population; self.worseCount = worse
    }
    var topPercent: Double { Double(rank) / Double(population) * 100 }
    var text: String { String(format: "优于%.1f%%", Double(worseCount) / Double(population) * 100) }
    var tier: NBAPlayerProfile.RankTier { .init(topPercent: topPercent) }
}

struct NBALeagueSnapshot: Codable {
    let scope: NBALeaguePercentileStore.Scope
    let date: Date
    let players: [String: Player]
    let qualified: [String: Set<String>]
    struct Player: Codable {
        let values: [String: Double]
        let displays: [String: String]
    }
    static let keys = ["avgPoints", "avgRebounds", "avgAssists", "avgSteals", "avgBlocks", "avgTurnovers", "fieldGoalPct", "threePointPct", "freeThrowPct"]
    static let attempts = ["fieldGoalPct": "fieldGoalsAttempted", "threePointPct": "threePointFieldGoalsAttempted", "freeThrowPct": "freeThrowsAttempted"]

    /// The v1 disk snapshot stores raw inputs only. Both legacy snapshots and
    /// newly fetched inputs are reinterpreted by the current ranking algorithm;
    /// no cached overall score or tier is reused.
    var rankingAlgorithmVersion: String { NBASeasonPerformance.algorithmVersion }

    private func validValue(_ player: Player, key: String) -> Double? {
        guard let games = player.values["gamesPlayed"], games.isFinite, games > 0,
              let value = player.values[key], value.isFinite, value >= 0 else { return nil }
        if let attempts = Self.attempts[key] {
            guard value <= 100, let count = player.values[attempts], count.isFinite, count > 0 else { return nil }
        }
        return value
    }

    func rankingStatus(id: String, key: String) -> String {
        guard let player = players[id], let games = player.values["gamesPlayed"], games > 0,
              let value = player.values[key], value.isFinite, value >= 0 else { return "暂无排名" }
        guard let allowed = qualified[key] else { return "暂无排名" }
        if !allowed.contains(id) { return "样本不足" }
        if let attempts = Self.attempts[key], player.values[attempts] == 0 { return "样本不足" }
        return validValue(player, key: key) == nil ? "暂无排名" : ""
    }

    func position(id: String, key: String) -> NBALeaguePosition? {
        guard let allowed = qualified[key], allowed.contains(id), let player = players[id],
              let value = validValue(player, key: key) else { return nil }
        let participants = players.compactMap { otherID, other -> Double? in
            guard allowed.contains(otherID) else { return nil }
            return validValue(other, key: key)
        }
        let population = participants.count
        let lowerIsBetter = key == "avgTurnovers"
        var better = 0; var worse = 0
        for otherValue in participants {
            if lowerIsBetter ? otherValue < value : otherValue > value { better += 1 }
            if lowerIsBetter ? otherValue > value : otherValue < value { worse += 1 }
        }
        return NBALeaguePosition(rank: better + 1, population: population, worseCount: worse)
    }
    func display(id: String, key: String) -> String? {
        guard let player = players[id] else { return nil }
        if let attempts = Self.attempts[key], (player.values[attempts] ?? 0) <= 0 { return "—" }
        guard let value = player.displays[key], !value.isEmpty, value != "--", value != "-" else { return nil }
        return Self.attempts[key] == nil ? value : value + (value.hasSuffix("%") ? "" : "%")
    }
}

actor NBALeaguePercentileStore {
    static let shared = NBALeaguePercentileStore()
    struct Scope: Hashable, Codable {
        let year: Int; let type: Int
        var previous: Self? {
            guard (1947...2200).contains(year), (1...3).contains(type) else { return nil }
            return .init(year: year - 1, type: type)
        }
    }
    struct Response: Decodable {
        let pagination: Pagination
        let requestedSeason: Season
        let categories: [Columns]
        let athletes: [AthleteRow]
        struct Pagination: Decodable { let count: Int; let page: Int; let pages: Int }
        struct Season: Decodable { let year: Int; let type: SeasonType }
        struct SeasonType: Decodable { let type: Int }
        struct Columns: Decodable { let name: String; let names: [String] }
        struct AthleteRow: Decodable {
            let athlete: Identity
            let categories: [Category]
        }
        struct Identity: Decodable {
            let id: String
            let headshot: NBABoxScore.Headshot?
            let teamID: String?
            private enum CodingKeys: String, CodingKey { case id, headshot, teamId }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(String.self, forKey: .id)
                headshot = try values.decodeIfPresent(NBABoxScore.Headshot.self, forKey: .headshot)
                teamID = (try? values.decode(String.self, forKey: .teamId)) ?? (try? values.decode(Int.self, forKey: .teamId)).map(String.init)
            }
        }
        func portraits() -> [NBAAvatarCache.Portrait] {
            athletes.compactMap { row in
                guard let href = row.athlete.headshot?.href, let url = URL(string: href) else { return nil }
                return NBAAvatarCache.Portrait(id: row.athlete.id, url: url, teamID: row.athlete.teamID)
            }
        }
        struct Category: Decodable { let name: String; let values: [Double?]?; let totals: [String]? }
        func validate(scope: Scope) throws {
            guard requestedSeason.year == scope.year, requestedSeason.type.type == scope.type,
                  pagination.count >= 0, pagination.page == 1, pagination.pages <= 1,
                  Set(athletes.map { $0.athlete.id }).count == pagination.count,
                  athletes.count == pagination.count else { throw URLError(.cannotParseResponse) }
        }
        func players() -> [String: NBALeagueSnapshot.Player] {
            var result: [String: NBALeagueSnapshot.Player] = [:]
            for row in athletes {
                var values: [String: Double] = [:]; var displays: [String: String] = [:]
                for category in row.categories {
                    guard let names = categories.first(where: { $0.name == category.name })?.names else { continue }
                    for (index, name) in names.enumerated() {
                        let key = name == "threePointFieldGoalPct" ? "threePointPct" : name
                        if let stats = category.values, stats.indices.contains(index), let value = stats[index], value.isFinite {
                            values[key] = value
                        }
                        if let totals = category.totals, totals.indices.contains(index) { displays[key] = totals[index] }
                    }
                }
                result[row.athlete.id] = .init(values: values, displays: displays)
            }
            return result
        }
    }
    private var memory: [Scope: NBALeagueSnapshot] = [:]
    private var retryAfter: [Scope: Date] = [:]
    private var pending: [Scope: Task<NBALeagueSnapshot?, Never>] = [:]
    typealias Fetch = @Sendable (Scope, String, Bool) async throws -> Response
    private let directory: URL
    private let priorDirectory: URL
    private let fetch: Fetch
    private let recordsPortraits: Bool
    private let now: NBAResourceCache.Clock
    private var priorDiskRead: Set<Scope> = []
    private var priorMemory: [Scope: NBALeagueSnapshot] = [:]
    private var priorPending: [Scope: Task<NBALeagueSnapshot?, Never>] = [:]
    private var priorRetryAfter: [Scope: Date] = [:]

    init(directory: URL? = nil, priorDirectory: URL? = nil, fetch: Fetch? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? caches.appendingPathComponent("NBALeagueSnapshots-v1", isDirectory: true)
        self.priorDirectory = priorDirectory ?? caches.appendingPathComponent("NBALeaguePerformanceInputs-v1", isDirectory: true)
        self.fetch = fetch ?? { try await Self.request(scope: $0, sort: $1, qualified: $2) }
        self.recordsPortraits = fetch == nil
        self.now = { Date() }
    }

    init(directory: URL? = nil, priorDirectory: URL? = nil, now: @escaping NBAResourceCache.Clock, fetch: Fetch? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? caches.appendingPathComponent("NBALeagueSnapshots-v1", isDirectory: true)
        self.priorDirectory = priorDirectory ?? caches.appendingPathComponent("NBALeaguePerformanceInputs-v1", isDirectory: true)
        self.fetch = fetch ?? { try await Self.request(scope: $0, sort: $1, qualified: $2) }
        self.recordsPortraits = fetch == nil
        self.now = now
    }

    struct Pair {
        let snapshot: NBALeagueSnapshot?
        let prior: NBAPriorSeasonData
        let currentRefreshFailed: Bool
    }

    /// Independent seasons start together. A personal-data refresh should leave
    /// both flags false; forcing the prior season is a separate explicit action.
    func loadPair(scope: Scope, forceCurrent: Bool = false, forcePrior: Bool = false) async -> Pair {
        async let current = load(scope: scope, force: forceCurrent)
        async let prior = loadPrior(for: scope, force: forcePrior)
        let (snapshot, priorData) = await (current, prior)
        return Pair(snapshot: snapshot, prior: priorData, currentRefreshFailed: retryAfter[scope] != nil)
    }

    func cached(scope: Scope) -> NBALeagueSnapshot? {
        if let saved = memory[scope] { return saved }
        let file = directory.appendingPathComponent("\(scope.year)-\(scope.type).json")
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(NBALeagueSnapshot.self, from: data), saved.scope == scope else { return nil }
        memory[scope] = saved
        return saved
    }

    func cachedPair(scope: Scope) -> Pair {
        let prior = scope.previous.flatMap { cachedPrior(scope: $0) }
        return Pair(snapshot: cached(scope: scope), prior: .init(snapshot: prior,
            refreshFailed: scope.previous.map { priorRetryAfter[$0] != nil } ?? false), currentRefreshFailed: retryAfter[scope] != nil)
    }

    private func cachedPrior(scope: Scope) -> NBALeagueSnapshot? {
        var candidates = [priorMemory[scope], memory[scope]].compactMap { $0 }.filter { $0.scope == scope }
        // Compatible legacy raw inputs are considered once, never decoded again
        // on every warm read. No derived grade is persisted or migrated.
        if priorDiskRead.insert(scope).inserted {
            let name = "\(scope.year)-\(scope.type).json"
            for root in [priorDirectory, directory] {
                if let data = try? Data(contentsOf: root.appendingPathComponent(name)),
                   let value = try? JSONDecoder().decode(NBALeagueSnapshot.self, from: data), value.scope == scope {
                    candidates.append(value)
                }
            }
        }
        let saved = candidates.max { $0.date < $1.date }
        if let saved { priorMemory[scope] = saved }
        return saved
    }

    /// Prior inputs need one all-athlete request, not the four eligibility lists
    /// used by detail cards. Last-season raw inputs can reuse compatible legacy
    /// snapshots; computed ranks are never persisted or migrated.
    func loadPrior(for current: Scope, force: Bool = false) async -> NBAPriorSeasonData {
        guard let scope = current.previous else { return .unavailable }
        let cached = cachedPrior(scope: scope)
        if !force, let cached, now().timeIntervalSince(cached.date) < 86400 {
            priorMemory[scope] = cached
            return .init(snapshot: cached, refreshFailed: priorRetryAfter[scope] != nil)
        }
        if !force, let retry = priorRetryAfter[scope], now() < retry {
            return .init(snapshot: cached, refreshFailed: true)
        }
        if let task = priorPending[scope] {
            let result = await task.value
            return .init(snapshot: result ?? cached, refreshFailed: result == nil)
        }
        let task = Task { await self.refreshPrior(scope: scope) }
        priorPending[scope] = task
        let result = await task.value
        return .init(snapshot: result ?? cached, refreshFailed: result == nil)
    }

    func load(scope: Scope, force: Bool = false) async -> NBALeagueSnapshot? {
        let file = directory.appendingPathComponent("\(scope.year)-\(scope.type).json")
        let cached = memory[scope] ?? (try? JSONDecoder().decode(NBALeagueSnapshot.self, from: Data(contentsOf: file)))
        if let cached, cached.scope == scope { memory[scope] = cached }
        if !force, let cached, cached.scope == scope, now().timeIntervalSince(cached.date) < 900 {
            memory[scope] = cached
            return cached
        }
        if !force, let retry = retryAfter[scope], now() < retry { return cached?.scope == scope ? cached : nil }
        if let task = pending[scope] {
            let result = await task.value
            return result ?? (cached?.scope == scope ? cached : nil)
        }
        let task = Task { await self.refreshCurrent(scope: scope) }
        pending[scope] = task
        let snapshot = await task.value
        // A stale snapshot remains a coherent set of values and rankings, with its date visible.
        return snapshot ?? (cached?.scope == scope ? cached : nil)
    }
    private func refreshPrior(scope: Scope) async -> NBALeagueSnapshot? {
        defer { priorPending[scope] = nil }
        do {
            let response = try await fetch(scope, "offensive.avgPoints", false)
            try response.validate(scope: scope)
            let snapshot = NBALeagueSnapshot(scope: scope, date: now(), players: response.players(), qualified: [:])
            priorMemory[scope] = snapshot
            priorRetryAfter[scope] = nil
            persist(snapshot, directory: priorDirectory)
            return snapshot
        } catch {
            priorRetryAfter[scope] = now().addingTimeInterval(60)
            return nil
        }
    }

    private func refreshCurrent(scope: Scope) async -> NBALeagueSnapshot? {
        defer { pending[scope] = nil }
        do {
            async let all = fetch(scope, "offensive.avgPoints", false)
            async let general = fetch(scope, "offensive.avgPoints", true)
            async let fg = fetch(scope, "offensive.fieldGoalPct", true)
            async let three = fetch(scope, "offensive.threePointFieldGoalPct", true)
            async let ft = fetch(scope, "offensive.freeThrowPct", true)
            let (allRows, generalRows, fgRows, threeRows, ftRows) = try await (all, general, fg, three, ft)
            let snapshot = try Self.makeSnapshot(scope: scope, all: allRows, general: generalRows,
                shooting: ["fieldGoalPct": fgRows, "threePointPct": threeRows, "freeThrowPct": ftRows], date: now())
            memory[scope] = snapshot
            if recordsPortraits && scope.type == 2 {
                let portraits = allRows.portraits()
                if !portraits.isEmpty { Task(priority: .utility) { await NBAAvatarCache.shared.register(portraits, season: scope.year) } }
            }
            retryAfter[scope] = nil
            persist(snapshot, directory: directory)
            return snapshot
        } catch {
            retryAfter[scope] = now().addingTimeInterval(60)
            return nil
        }
    }

    private func persist(_ snapshot: NBALeagueSnapshot, directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: directory.appendingPathComponent("\(snapshot.scope.year)-\(snapshot.scope.type).json"), options: .atomic)
        }
    }

    static func makeSnapshot(scope: Scope, all: Response, general: Response, shooting: [String: Response], date: Date = Date()) throws -> NBALeagueSnapshot {
        try all.validate(scope: scope)
        try general.validate(scope: scope)
        for response in shooting.values { try response.validate(scope: scope) }
        let players = all.players()
        var eligible = Dictionary(uniqueKeysWithValues: NBALeagueSnapshot.keys.map { ($0, Set(general.athletes.map { $0.athlete.id })) })
        for key in NBALeagueSnapshot.attempts.keys {
            guard let response = shooting[key] else { throw URLError(.cannotParseResponse) }
            eligible[key] = Set(response.athletes.map { $0.athlete.id })
        }
        guard eligible.values.allSatisfy({ $0.isSubset(of: Set(players.keys)) }) else { throw URLError(.cannotParseResponse) }
        return NBALeagueSnapshot(scope: scope, date: date, players: players, qualified: eligible)
    }
    private static func request(scope: Scope, sort: String, qualified: Bool) async throws -> Response {
        var url = URLComponents(string: "https://site.web.api.espn.com/apis/common/v3/sports/basketball/nba/statistics/byathlete")!
        url.queryItems = [URLQueryItem(name: "season", value: String(scope.year)),
                          URLQueryItem(name: "seasontype", value: String(scope.type)),
                          URLQueryItem(name: "limit", value: "1000"),
                          URLQueryItem(name: "sort", value: sort + ":desc"),
                          URLQueryItem(name: "isqualified", value: qualified ? "true" : "false")]
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let result = try JSONDecoder().decode(Response.self, from: data)
        try result.validate(scope: scope)
        return result
    }
}

extension NBAPlayerProfile {
    var rankScope: NBALeaguePercentileStore.Scope? {
        guard let title = athlete.statsSummary?.displayName,
              let first = title.split(separator: " ").first,
              first.count == 7, first[first.index(first.startIndex, offsetBy: 4)] == "-",
              let start = Int(first.prefix(4)), (1946...2200).contains(start),
              Int(first.suffix(2)) == (start + 1) % 100 else { return nil }
        let type: Int
        switch seasonSplit {
        case "Regular Season": type = 2
        case "Postseason": type = 3
        case "Preseason": type = 1
        default: return nil
        }
        return .init(year: start + 1, type: type)
    }
}
